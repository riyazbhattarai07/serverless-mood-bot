import json
import uuid
import os
import boto3
import logging
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

eventbridge = boto3.client("events")
EVENT_BUS_NAME = os.environ["EVENT_BUS_NAME"]

# Fields we expect in the request body
REQUIRED_FIELDS = {"user_id", "mood"}
ALLOWED_MOODS = {
    "happy", "sad", "anxious", "angry",
    "stressed", "calm", "excited", "tired", "overwhelmed", "neutral"
}


def lambda_handler(event, context):
    """
    Entry point for POST /mood

    Validates the request, generates a request_id,
    puts an event on EventBridge, and returns 202 immediately.
    The actual AI processing happens asynchronously.
    """
    logger.info("Received request: %s", json.dumps(event))

    # Parse and validate the request body
    try:
        body = json.loads(event.get("body", "{}"))
    except json.JSONDecodeError:
        return _response(400, {"error": "Request body must be valid JSON"})

    # Check required fields are present
    missing = REQUIRED_FIELDS - set(body.keys())
    if missing:
        return _response(400, {"error": f"Missing required fields: {', '.join(missing)}"})

    user_id = str(body["user_id"]).strip()
    mood = str(body["mood"]).strip().lower()
    context_text = str(body.get("context", "")).strip()

    # Validate mood value
    if mood not in ALLOWED_MOODS:
        return _response(400, {
            "error": f"Invalid mood '{mood}'. Allowed values: {', '.join(sorted(ALLOWED_MOODS))}"
        })

    # Generate a unique request ID to track this submission end-to-end
    request_id = str(uuid.uuid4())
    timestamp = datetime.now(timezone.utc).isoformat()

    # Build the event payload
    event_detail = {
        "request_id": request_id,
        "user_id": user_id,
        "mood": mood,
        "context": context_text,
        "timestamp": timestamp,
    }

    # Put the event onto our custom EventBridge bus
    try:
        response = eventbridge.put_events(
            Entries=[
                {
                    "Source": "mood-bot.webhook",
                    "DetailType": "MoodSubmitted",
                    "Detail": json.dumps(event_detail),
                    "EventBusName": EVENT_BUS_NAME,
                }
            ]
        )

        failed = response.get("FailedEntryCount", 0)
        if failed > 0:
            logger.error("EventBridge put_events failed: %s", response)
            return _response(500, {"error": "Failed to queue event for processing"})

    except Exception as e:
        logger.exception("Unexpected error putting event to EventBridge")
        return _response(500, {"error": "Internal server error"})

    logger.info("Event queued successfully. request_id=%s", request_id)

    # Return 202 immediately - processing happens async
    return _response(202, {
        "request_id": request_id,
        "status": "processing",
        "message": "Your mood has been received. You'll be notified when it's ready."
    })


def _response(status_code, body):
    """Helper to build a consistent API Gateway response."""
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(body),
    }
