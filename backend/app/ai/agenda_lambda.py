"""AWS Lambda entry point for the agenda parser, behind its own function URL.

Same image as the API, different command (app.ai.agenda_lambda.handler). It
runs outside the VPC: it needs Bedrock and Cognito's JWKS, both on the
internet, and never the database, so nothing here may import app.db. It only
suggests; the browser saves through PUT /api/v1/meetings/{id}/agenda.

CORS belongs to the function URL, so no response here sets CORS headers.
"""

import asyncio
import base64
import binascii
import json
import logging
import time
from datetime import date
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import anthropic

from app.ai.agenda import PROMPT_VERSION, AgendaParseError, cost_usd, parse_agenda
from app.auth import AuthError, AuthNotConfiguredError, CurrentUser, get_verifier
from app.config import settings

logger = logging.getLogger("meetings.ai")
# Lambda's runtime owns the root handler, so basicConfig would do nothing here.
logger.setLevel(settings.log_level.upper())

# The verifier is async; one loop for the life of the execution environment,
# as in the report builder.
loop = asyncio.new_event_loop()


class BadRequestError(Exception):
    """The request body is not {"text": str, "today": "YYYY-MM-DD", "tz": "Area/City"}."""


def respond(status: int, body: dict[str, Any], headers: dict[str, str] | None = None) -> dict:
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json", **(headers or {})},
        "body": json.dumps(body, ensure_ascii=False),
    }


def error(status: int, code: str, message: str, headers: dict[str, str] | None = None) -> dict:
    """The same error envelope as the API (app.errors)."""
    return respond(status, {"error": {"code": code, "message": message, "details": []}}, headers)


def authenticate(headers: dict[str, str]) -> CurrentUser:
    """Check the Cognito access token. The JWKS are fetched from Cognito on first use."""
    scheme, _, token = headers.get("authorization", "").partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise AuthError("Sign in to continue.")
    return loop.run_until_complete(get_verifier().verify(token.strip()))


def read_body(event: dict) -> tuple[str, date, str]:
    raw = event.get("body") or ""
    try:
        if event.get("isBase64Encoded"):
            raw = base64.b64decode(raw).decode()
        body = json.loads(raw)
    except (binascii.Error, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BadRequestError("The body must be JSON.") from exc
    if not isinstance(body, dict):
        raise BadRequestError("The body must be a JSON object.")

    text, today, tz = body.get("text"), body.get("today"), body.get("tz")
    if not isinstance(text, str) or not text.strip():
        raise BadRequestError("text is required.")
    try:
        parsed_today = date.fromisoformat(today) if isinstance(today, str) else None
    except ValueError:
        parsed_today = None
    if parsed_today is None:
        raise BadRequestError("today must be a date, e.g. 2026-10-19.")
    tz_error = BadRequestError("tz must be an IANA time zone, e.g. Europe/Kyiv.")
    if not isinstance(tz, str) or not tz:
        raise tz_error
    try:
        ZoneInfo(tz)
    except (ZoneInfoNotFoundError, ValueError) as exc:
        raise tz_error from exc
    return text, parsed_today, tz


def log_parse(event_name: str, user: CurrentUser, usage: dict[str, int], started: float) -> None:
    """One JSON line per parse: what it cost and how long it took."""
    logger.info(
        json.dumps(
            {
                "event": event_name,
                "user": user.sub,
                "model": settings.parser_model,
                "prompt_version": PROMPT_VERSION,
                **usage,
                "latency_ms": int((time.monotonic() - started) * 1000),
                "cost_usd": cost_usd(settings.parser_model, usage),
            }
        )
    )


def handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "POST")
    if method != "POST":
        return error(405, "method_not_allowed", "Use POST.", {"allow": "POST"})

    # Every call costs money, so the token is checked before anything else.
    try:
        user = authenticate(event.get("headers") or {})
    except AuthError as exc:
        return error(401, "unauthorized", str(exc), {"www-authenticate": "Bearer"})
    except AuthNotConfiguredError:
        logger.error("COGNITO_USER_POOL_ID / COGNITO_CLIENT_ID are not set; refusing requests.")
        return error(503, "service_unavailable", "Sign-in is not configured on the server.")

    try:
        text, today, tz = read_body(event)
    except BadRequestError as exc:
        return error(400, "bad_request", str(exc))
    if len(text) > settings.parser_max_chars:
        return error(
            413,
            "too_long",
            f"The text is longer than {settings.parser_max_chars:,} characters.",
        )

    started = time.monotonic()
    try:
        agenda, usage = parse_agenda(text, today, tz)
    except AgendaParseError as exc:
        log_parse("agenda_not_found", user, exc.usage, started)
        return error(422, "no_agenda", "Could not find an agenda in this text.")
    except anthropic.RateLimitError:
        logger.warning("Bedrock throttled the parse for %s", user.sub)
        return error(
            429, "busy", "The parser is busy right now. Try again shortly.", {"retry-after": "10"}
        )
    except (anthropic.InternalServerError, anthropic.APIConnectionError):
        logger.exception("Bedrock is unavailable")
        return error(503, "service_unavailable", "The parser is unavailable right now.")
    except anthropic.APIStatusError as exc:
        # 400/403 from Bedrock (e.g. no model access) are our fault, not the user's.
        # Status and message on the first line: Lambda splits tracebacks across lines.
        logger.exception("Bedrock rejected the parse request: %s %s", exc.status_code, exc.message)
        return error(502, "upstream_error", "The parser could not process this request.")

    log_parse("agenda_parsed", user, usage, started)
    return respond(
        200,
        {
            "agenda": agenda.model_dump(mode="json"),
            "model": settings.parser_model,
            "prompt_version": PROMPT_VERSION,
        },
    )
