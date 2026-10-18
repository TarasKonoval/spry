"""The parser Lambda's handler: auth, limits and error mapping, with a fake parser."""

import base64
import json
import logging
from datetime import date

import anthropic
import httpx2
import pytest

from app.ai import agenda_lambda
from app.ai.agenda import AgendaParseError
from app.config import settings
from app.schemas import ParsedAgenda
from tests.tokens import make_token, make_verifier

AGENDA = ParsedAgenda(
    title="Синк по прайсингу",
    items=[{"topic": "нові тарифи Pro", "owner": "Олена", "minutes": 15}],
    language="uk",
)
USAGE = {"input_tokens": 1800, "output_tokens": 400}


@pytest.fixture
def calls(monkeypatch, private_key) -> list[tuple]:
    """Points the handler at the test pool and records every parse it asks for."""
    recorded: list[tuple] = []

    def fake_parse(text, today, tz):
        recorded.append((text, today, tz))
        return AGENDA, USAGE

    verifier = make_verifier(private_key)
    monkeypatch.setattr(agenda_lambda, "get_verifier", lambda: verifier)
    monkeypatch.setattr(agenda_lambda, "parse_agenda", fake_parse)
    return recorded


def fail_with(monkeypatch, exc: Exception) -> None:
    def raising(text, today, tz):
        raise exc

    monkeypatch.setattr(agenda_lambda, "parse_agenda", raising)


def event(private_key, body=None, token: str | None = "valid", method="POST", **extra) -> dict:
    """A function URL event, as Lambda delivers it (headers lower-cased)."""
    headers = {"content-type": "application/json"}
    if token == "valid":
        token = make_token(private_key)
    if token is not None:
        headers["authorization"] = f"Bearer {token}"
    if body is None:
        body = {"text": "Пн 10:00, синк по прайсингу", "today": "2026-10-18", "tz": "Europe/Kyiv"}
    return {
        "requestContext": {"http": {"method": method}},
        "headers": headers,
        "body": body if isinstance(body, str) else json.dumps(body),
        "isBase64Encoded": False,
    } | extra


def call(evt) -> tuple[int, dict, dict]:
    response = agenda_lambda.handler(evt, None)
    return response["statusCode"], json.loads(response["body"]), response["headers"]


def test_parse_returns_agenda_model_and_prompt_version(calls, private_key):
    status, body, headers = call(event(private_key))

    assert status == 200
    assert body["agenda"]["title"] == "Синк по прайсингу"
    assert body["agenda"]["items"][0]["owner"] == "Олена"
    assert body["model"] == settings.parser_model
    assert body["prompt_version"] == "agenda-v1"
    assert headers["content-type"] == "application/json"
    assert not any(name.startswith("access-control-") for name in headers)
    assert calls == [("Пн 10:00, синк по прайсингу", date(2026, 10, 18), "Europe/Kyiv")]


def test_parse_logs_one_json_line(calls, private_key, caplog):
    with caplog.at_level(logging.INFO, logger="meetings.ai"):
        call(event(private_key))

    lines = [json.loads(r.getMessage()) for r in caplog.records if r.name == "meetings.ai"]
    assert len(lines) == 1
    line = lines[0]
    assert line["event"] == "agenda_parsed"
    assert line["user"] == "user-123"
    assert line["model"] == settings.parser_model
    assert line["prompt_version"] == "agenda-v1"
    assert (line["input_tokens"], line["output_tokens"]) == (1800, 400)
    assert line["cost_usd"] == 0.0152  # 1800×$4/M + 400×$20/M for Opus 5.5
    assert isinstance(line["latency_ms"], int)


def test_base64_body_is_decoded(calls, private_key):
    raw = json.dumps({"text": "Ретро", "today": "2026-10-18", "tz": "Europe/Kyiv"})
    evt = event(private_key, body=base64.b64encode(raw.encode()).decode(), isBase64Encoded=True)

    status, _, _ = call(evt)

    assert status == 200
    assert calls[0][0] == "Ретро"


def test_missing_token_is_401(calls, private_key):
    status, body, headers = call(event(private_key, token=None))

    assert status == 401
    assert body["error"]["code"] == "unauthorized"
    assert headers["www-authenticate"] == "Bearer"
    assert calls == []


def test_invalid_token_is_401(calls, private_key):
    status, _, _ = call(event(private_key, token="not-a-jwt"))

    assert status == 401
    assert calls == []


def test_expired_token_is_401(calls, private_key):
    status, body, _ = call(event(private_key, token=make_token(private_key, exp=1)))

    assert status == 401
    assert "expired" in body["error"]["message"]


def test_id_token_is_401(calls, private_key):
    id_token = make_token(private_key, token_use="id", aud="test-client", client_id=None)

    status, _, _ = call(event(private_key, token=id_token))

    assert status == 401


def test_bad_request_is_checked_after_auth(calls, private_key):
    status, _, _ = call(event(private_key, body="{not json", token=None))

    assert status == 401


@pytest.mark.parametrize(
    ("body", "message"),
    [
        ("{not json", "must be JSON"),
        ("[1, 2]", "JSON object"),
        ({"today": "2026-10-18", "tz": "Europe/Kyiv"}, "text is required"),
        ({"text": "   ", "today": "2026-10-18", "tz": "Europe/Kyiv"}, "text is required"),
        ({"text": "Ретро", "tz": "Europe/Kyiv"}, "today must be a date"),
        ({"text": "Ретро", "today": "Monday", "tz": "Europe/Kyiv"}, "today must be a date"),
        ({"text": "Ретро", "today": "2026-10-18"}, "tz must be"),
        ({"text": "Ретро", "today": "2026-10-18", "tz": "Mars/Olympus"}, "tz must be"),
    ],
)
def test_malformed_body_is_400(calls, private_key, body, message):
    status, response, _ = call(event(private_key, body=body))

    assert status == 400
    assert response["error"]["code"] == "bad_request"
    assert message in response["error"]["message"]
    assert calls == []


def test_text_over_the_limit_is_413_without_calling_the_model(calls, private_key):
    text = "x" * (settings.parser_max_chars + 1)

    status, body, _ = call(
        event(private_key, body={"text": text, "today": "2026-10-18", "tz": "Europe/Kyiv"})
    )

    assert status == 413
    assert body["error"]["code"] == "too_long"
    assert calls == []


def test_text_at_the_limit_is_parsed(calls, private_key):
    text = "x" * settings.parser_max_chars

    status, _, _ = call(
        event(private_key, body={"text": text, "today": "2026-10-18", "tz": "Europe/Kyiv"})
    )

    assert status == 200


def test_no_agenda_is_422_and_still_logged(calls, private_key, monkeypatch, caplog):
    fail_with(monkeypatch, AgendaParseError("no agenda found in the text", USAGE))

    with caplog.at_level(logging.INFO, logger="meetings.ai"):
        status, body, _ = call(event(private_key))

    assert status == 422
    assert body["error"]["code"] == "no_agenda"
    lines = [json.loads(r.getMessage()) for r in caplog.records if r.name == "meetings.ai"]
    assert lines[0]["event"] == "agenda_not_found"
    assert lines[0]["cost_usd"] == 0.0152


def test_throttling_is_429(calls, private_key, monkeypatch):
    request = httpx2.Request("POST", "https://bedrock-mantle.us-east-1.api.aws/v1/messages")
    fail_with(
        monkeypatch,
        anthropic.RateLimitError(
            "Too many requests", response=httpx2.Response(429, request=request), body=None
        ),
    )

    status, body, headers = call(event(private_key))

    assert status == 429
    assert body["error"]["code"] == "busy"
    assert headers["retry-after"] == "10"


def test_bedrock_unreachable_is_503(calls, private_key, monkeypatch):
    request = httpx2.Request("POST", "https://bedrock-mantle.us-east-1.api.aws/v1/messages")
    fail_with(monkeypatch, anthropic.APIConnectionError(request=request))

    status, body, _ = call(event(private_key))

    assert status == 503
    assert body["error"]["code"] == "service_unavailable"


def test_bedrock_access_denied_is_502(calls, private_key, monkeypatch):
    request = httpx2.Request("POST", "https://bedrock-mantle.us-east-1.api.aws/v1/messages")
    fail_with(
        monkeypatch,
        anthropic.PermissionDeniedError(
            "not available for this account",
            response=httpx2.Response(403, request=request),
            body=None,
        ),
    )

    status, body, _ = call(event(private_key))

    assert status == 502
    assert body["error"]["code"] == "upstream_error"


def test_other_methods_are_405(calls, private_key):
    status, _, headers = call(event(private_key, method="GET"))

    assert status == 405
    assert headers["allow"] == "POST"


def test_handler_does_not_load_the_database_module():
    """The function has no VPC: importing app.db would build an engine it cannot reach."""
    import subprocess
    import sys

    loaded = subprocess.run(
        [sys.executable, "-c", "import sys, app.ai.agenda_lambda; print('app.db' in sys.modules)"],
        capture_output=True,
        text=True,
        check=True,
    )
    assert loaded.stdout.strip() == "False"
