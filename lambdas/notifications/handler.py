import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# In a real deployment, you'd integrate with SES or a third-party
# email provider here. For now this logs the notification and
# simulates the send so the architecture is testable end-to-end.
#
# To add real email: import boto3, use ses.send_email() with the
# user's email looked up from the users DynamoDB table.


def lambda_handler(event, context):
    """
    Triggered by SQS (batch size 10).
    Reads notification messages and sends emails to users.

    Each SQS message contains: request_id, user_id, mood, suggestions.
    """
    logger.info("Processing %d notification(s)", len(event.get("Records", [])))

    results = []
    for record in event.get("Records", []):
        try:
            message = json.loads(record["body"])
            result = _send_notification(message)
            results.append({"request_id": message.get("request_id"), "status": result})
        except Exception:
            logger.exception("Failed to process notification record: %s", record)
            # Don't re-raise for individual failures in batch processing
            # Failed messages will be retried up to maxReceiveCount, then go to DLQ
            results.append({"status": "failed"})

    logger.info("Processed %d notifications: %s", len(results), results)
    return {"processed": len(results), "results": results}


def _send_notification(message):
    """
    Send a notification to the user with their mood analysis results.

    Currently logs the notification. In production, replace this with
    an SES send_email() call using the user's email from DynamoDB.
    """
    request_id = message.get("request_id")
    user_id = message.get("user_id")
    mood = message.get("mood")
    suggestions = message.get("suggestions", [])
    processed_at = message.get("processed_at")

    # Build the notification content
    subject = f"Your mood analysis is ready - feeling {mood}"

    body_lines = [
        f"Hi {user_id},",
        "",
        f"We processed your mood submission (feeling: {mood}).",
        "Here are 3 coping strategies for you:",
        "",
    ]

    for i, suggestion in enumerate(suggestions, 1):
        body_lines.append(f"{i}. {suggestion}")

    body_lines += [
        "",
        f"Processed at: {processed_at}",
        f"Request ID: {request_id}",
        "",
        "Take care of yourself.",
        "- Mood Bot"
    ]

    email_body = "\n".join(body_lines)

    # TODO: Replace with real SES call
    # Example:
    # ses = boto3.client("ses")
    # ses.send_email(
    #     Source="noreply@yourdomain.com",
    #     Destination={"ToAddresses": [user_email]},
    #     Message={
    #         "Subject": {"Data": subject},
    #         "Body": {"Text": {"Data": email_body}}
    #     }
    # )

    logger.info(
        "[NOTIFICATION] To: %s | Subject: %s | Body preview: %s...",
        user_id,
        subject,
        email_body[:100]
    )

    return "sent"
