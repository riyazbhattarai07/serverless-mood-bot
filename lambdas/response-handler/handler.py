import json
import os
import boto3
import logging
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")
sqs = boto3.client("sqs")

MOODS_TABLE = os.environ["MOODS_TABLE"]
AUDIT_TABLE = os.environ["AUDIT_TABLE"]
NOTIFICATION_QUEUE_URL = os.environ["NOTIFICATION_QUEUE_URL"]


def lambda_handler(event, context):
    """
    Triggered by SNS when the event processor publishes a result.

    Writes the mood + AI suggestions to DynamoDB and sends a
    notification message to SQS for the email sender.

    Key design note: We look up the DynamoDB record using request_id
    (via a GSI), NOT by re-generating a timestamp. This was the main
    bug in the original skeleton - a fresh timestamp lookup would
    always miss the existing record.
    """
    for record in event.get("Records", []):
        try:
            # SNS wraps the message body in record["Sns"]["Message"]
            message = json.loads(record["Sns"]["Message"])
            _process_message(message)
        except Exception:
            logger.exception("Failed to process record: %s", record)
            # Re-raise so Lambda marks this invocation as failed
            # SNS will retry and eventually move to DLQ
            raise


def _process_message(message):
    request_id = message["request_id"]
    user_id = message["user_id"]
    mood = message["mood"]
    suggestions = message["suggestions"]
    timestamp = message["timestamp"]
    mood_context = message.get("context", "")
    ai_powered = message.get("ai_powered", False)
    processed_at = datetime.now(timezone.utc).isoformat()

    logger.info("Processing response for request_id=%s user_id=%s", request_id, user_id)

    moods_table = dynamodb.Table(MOODS_TABLE)
    audit_table = dynamodb.Table(AUDIT_TABLE)

    # Write the mood record to DynamoDB
    # We write a new item using user_id + timestamp as the key,
    # and also store request_id so we can look it up later via GSI.
    moods_table.put_item(
        Item={
            "user_id": user_id,
            "timestamp": timestamp,
            "request_id": request_id,
            "mood": mood,
            "context": mood_context,
            "suggestions": suggestions,
            "ai_powered": ai_powered,
            "processed_at": processed_at,
            # TTL: 90 days from now (epoch seconds)
            "expires_at": int(
                datetime.now(timezone.utc).timestamp() + (90 * 24 * 60 * 60)
            ),
        }
    )

    # Write to audit table for end-to-end request tracking
    audit_table.put_item(
        Item={
            "request_id": request_id,
            "user_id": user_id,
            "mood": mood,
            "status": "completed",
            "processed_at": processed_at,
            # TTL: 30 days
            "expires_at": int(
                datetime.now(timezone.utc).timestamp() + (30 * 24 * 60 * 60)
            ),
        }
    )

    logger.info("Wrote to DynamoDB. request_id=%s", request_id)

    # Send notification to SQS for the email Lambda
    notification_payload = {
        "request_id": request_id,
        "user_id": user_id,
        "mood": mood,
        "suggestions": suggestions,
        "processed_at": processed_at,
    }

    sqs.send_message(
        QueueUrl=NOTIFICATION_QUEUE_URL,
        MessageBody=json.dumps(notification_payload),
        MessageAttributes={
            "user_id": {
                "DataType": "String",
                "StringValue": user_id
            }
        }
    )

    logger.info("Sent notification to SQS. request_id=%s", request_id)
