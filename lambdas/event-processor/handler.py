import json
import os
import boto3
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sns = boto3.client("sns")
secretsmanager = boto3.client("secretsmanager")

SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
GCP_SECRET_NAME = os.environ["GCP_SECRET_NAME"]
VERTEX_PROJECT = os.environ["VERTEX_PROJECT"]
VERTEX_LOCATION = os.environ.get("VERTEX_LOCATION", "us-central1")
VERTEX_MODEL = "gemini-1.5-flash"

# Fallback response if Vertex AI is unavailable
FALLBACK_SUGGESTIONS = [
    "Take a few slow, deep breaths to help calm your nervous system.",
    "Write down what you're feeling - getting it out of your head and onto paper can help.",
    "Reach out to someone you trust and let them know how you're doing."
]


def lambda_handler(event, context):
    """
    Triggered by EventBridge when a MoodSubmitted event arrives.
    Calls Vertex AI Gemini to generate coping suggestions,
    then publishes the result to SNS for the response handler.
    """
    logger.info("Processing event: %s", json.dumps(event))

    # EventBridge wraps our payload in event["detail"]
    detail = event.get("detail", {})
    request_id = detail.get("request_id")
    user_id = detail.get("user_id")
    mood = detail.get("mood")
    mood_context = detail.get("context", "")
    timestamp = detail.get("timestamp")

    if not all([request_id, user_id, mood]):
        logger.error("Missing required fields in event detail: %s", detail)
        raise ValueError("Invalid event: missing request_id, user_id, or mood")

    # Call Vertex AI for coping suggestions
    suggestions = _get_ai_suggestions(mood, mood_context)

    # Build the message we'll publish to SNS
    message = {
        "request_id": request_id,
        "user_id": user_id,
        "mood": mood,
        "context": mood_context,
        "timestamp": timestamp,
        "suggestions": suggestions,
        "ai_powered": suggestions != FALLBACK_SUGGESTIONS,
    }

    # Publish to SNS - response handler will pick this up
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Message=json.dumps(message),
        Subject=f"Mood processed: {mood} for {user_id}",
        MessageAttributes={
            "event_type": {
                "DataType": "String",
                "StringValue": "MoodProcessed"
            }
        }
    )

    logger.info("Published to SNS. request_id=%s ai_powered=%s", request_id, message["ai_powered"])
    return {"status": "published", "request_id": request_id}


def _get_ai_suggestions(mood, context):
    """
    Calls Vertex AI Gemini to get coping suggestions.
    Falls back to static suggestions if anything goes wrong.

    Auth note: GCP service account credentials are loaded from
    AWS Secrets Manager at runtime. AWS IAM cannot directly
    authorize Vertex AI calls - that's a GCP concern.
    """
    try:
        # Load GCP credentials from Secrets Manager
        secret = secretsmanager.get_secret_value(SecretId=GCP_SECRET_NAME)
        gcp_creds_json = secret["SecretString"]

        # Import here so Lambda doesn't fail on cold start if package is missing
        import tempfile
        import google.auth
        from google.oauth2 import service_account
        import vertexai
        from vertexai.generative_models import GenerativeModel

        # Write creds to a temp file (Vertex AI SDK expects a file path)
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            f.write(gcp_creds_json)
            creds_file = f.name

        credentials = service_account.Credentials.from_service_account_file(
            creds_file,
            scopes=["https://www.googleapis.com/auth/cloud-platform"]
        )

        vertexai.init(
            project=VERTEX_PROJECT,
            location=VERTEX_LOCATION,
            credentials=credentials
        )

        model = GenerativeModel(VERTEX_MODEL)

        prompt = f"""A person is feeling {mood}."""
        if context:
            prompt += f" Context: {context}"
        prompt += """

Please suggest exactly 3 practical coping strategies in a warm, supportive tone.
Format your response as a JSON array of 3 strings.
Each suggestion should be 1-2 sentences. Example format:
["suggestion 1", "suggestion 2", "suggestion 3"]"""

        response = model.generate_content(
            prompt,
            generation_config={
                "temperature": 0.7,
                "max_output_tokens": 256,
            }
        )

        # Try to parse the response as JSON array
        text = response.text.strip()
        # Strip markdown code block if present
        if text.startswith("```"):
            text = text.split("\n", 1)[1].rsplit("```", 1)[0].strip()

        suggestions = json.loads(text)
        if isinstance(suggestions, list) and len(suggestions) >= 3:
            return suggestions[:3]

        logger.warning("Unexpected AI response format, using fallback")
        return FALLBACK_SUGGESTIONS

    except Exception:
        logger.exception("Vertex AI call failed, using fallback suggestions")
        return FALLBACK_SUGGESTIONS
