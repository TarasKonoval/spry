"""Report mailer: a new reports/*.csv in S3 -> that CSV, attached, through SES.

Runs outside the VPC (SES is on the internet) and never touches the database.
Terraform zips this one file as index.py (infra/reports.tf) and deploys it, so
it imports nothing from app.
It only reads from S3: writing into reports/ would trigger itself forever.
"""

import logging
import os
import posixpath
import urllib.parse
from email.message import EmailMessage

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

SENDER = os.environ.get("REPORTS_FROM", "")
RECIPIENTS = [a.strip() for a in os.environ.get("REPORTS_TO", "").split(",") if a.strip()]

s3 = boto3.client("s3")
ses = boto3.client("sesv2")


def handler(event, context):
    for record in event["Records"]:
        bucket = record["s3"]["bucket"]["name"]
        # Keys arrive URL-encoded in S3 events.
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        log.info(
            "report-mailer triggered trigger=s3 event=%s bucket=%s key=%s",
            record["eventName"],
            bucket,
            key,
        )
        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        name = posixpath.basename(key)
        week = name.removesuffix(".csv")

        msg = EmailMessage()
        msg["Subject"] = f"Weekly meetings report {week}"
        msg["From"] = SENDER
        msg["To"] = ", ".join(RECIPIENTS)
        msg.set_content(f"The meetings report for {week} is attached.\n\ns3://{bucket}/{key}\n")
        msg.add_attachment(body, maintype="text", subtype="csv", filename=name)

        result = ses.send_email(Content={"Raw": {"Data": msg.as_bytes()}})
        # Addresses stay out of the logs; the count is enough to debug with.
        log.info(
            "report sent key=%s message_id=%s recipients=%d",
            key,
            result["MessageId"],
            len(RECIPIENTS),
        )
