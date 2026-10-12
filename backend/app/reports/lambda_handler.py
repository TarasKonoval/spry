"""AWS Lambda entry point for the report builder: build one week's CSV and save it to S3.

Same image as the API, different command (app.reports.lambda_handler.handler).
The function sits in the VPC to reach Aurora, and reaches S3 through the
gateway endpoint; it has no other way out.
"""

import asyncio
import json
import logging
import os
from datetime import UTC, datetime

import boto3

from app.config import settings
from app.db import engine
from app.reports.weekly import build_weekly_report, previous_week, report_key

logger = logging.getLogger("meetings.reports")
# Lambda's runtime owns the root handler, so basicConfig would do nothing here.
logger.setLevel(settings.log_level.upper())

BUCKET = os.environ.get("REPORTS_BUCKET", "")

s3 = boto3.client("s3")

# One loop for the life of the execution environment, as Mangum does for the API.
loop = asyncio.new_event_loop()


def requests(event: dict) -> tuple[str, list[dict]]:
    """Split an event into (transport, payloads): an SQS batch or one direct invoke."""
    records = event.get("Records") or []
    if records and records[0].get("eventSource") == "aws:sqs":
        return "sqs", [json.loads(record["body"]) for record in records]
    return "invoke", [event]


def detect_trigger(transport: str, payload: dict) -> str:
    """Who started the build: the schedule (direct or queued), the queue, or a person."""
    if payload.get("source") == "schedule":
        return "schedule"
    if transport == "sqs":
        return "sqs"
    return "direct"


async def _build(week: str) -> bytes:
    try:
        return await build_weekly_report(week)
    finally:
        # Close the connection now: a pooled one would keep Aurora from pausing
        # for as long as this execution environment stays warm.
        await engine.dispose()


def handler(event, context):
    transport, payloads = requests(event)
    # BatchSize is 1, so this is one report. Raising returns the message to the
    # queue; after three failed receives it moves to the dead-letter queue.
    return [_handle(transport, payload) for payload in payloads]


def _handle(transport: str, payload: dict) -> dict:
    trigger = detect_trigger(transport, payload)
    # The caller decides the week; with none, it is the week before this one.
    week = payload.get("week") or previous_week()
    logger.info(
        "report-builder triggered trigger=%s via=%s source=%s week=%s",
        trigger,
        transport,
        payload.get("source", "-"),
        week,
    )

    body = loop.run_until_complete(_build(week))
    key = report_key(week)
    s3.put_object(
        Bucket=BUCKET,
        Key=key,
        Body=body,
        ContentType="text/csv; charset=utf-8",
        Metadata={"generated-at": datetime.now(UTC).isoformat(), "trigger": trigger},
    )
    logger.info("report saved s3://%s/%s bytes=%d", BUCKET, key, len(body))
    return {"bucket": BUCKET, "key": key}
