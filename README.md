# Serverless Mood Bot

A personal project I built to learn AWS serverless architecture end-to-end. The idea is simple — a user sends in how they're feeling, and the system processes it asynchronously, calls an AI model (Vertex AI) for coping suggestions, stores the result, and notifies the user.

I used Vertex AI to help me come up with the initial project idea and skeleton structure, then built, fixed, and wired everything together myself.

---

## What It Does

- Accepts a mood submission via a REST API endpoint (`POST /mood`)
- Validates the request and puts an event onto EventBridge
- A processing Lambda picks it up, calls Vertex AI for personalized coping suggestions
- The result gets stored in DynamoDB and a notification is sent via SNS/SQS
- Everything is async — the user gets a `request_id` immediately and is notified when ready

---

## Architecture

```
User
  └── POST /mood
        └── API Gateway (REST)
              └── Webhook Lambda (validate + generate request_id)
                    └── EventBridge (event routing + retry logic)
                          └── Processor Lambda (call Vertex AI)
                                └── SNS Topic
                                      └── Response Handler Lambda
                                            ├── DynamoDB (store mood + AI response)
                                            └── Notification Lambda (email via SQS)
```

**Dead Letter Queues (SQS)** catch any failed events at both the EventBridge and SNS layers so nothing gets silently dropped.

---

## Tech Stack

| Layer | Service |
|---|---|
| Infrastructure | Terraform >= 1.5 |
| Entry Point | AWS API Gateway (REST) |
| Compute | AWS Lambda (Python 3.11) |
| Orchestration | AWS EventBridge |
| Messaging | AWS SNS + SQS |
| Database | AWS DynamoDB |
| AI | Google Vertex AI (gemini-1.5-flash) |
| Observability | CloudWatch Logs + X-Ray |

---

## Project Structure

```
serverless-mood-bot/
├── infrastructure/
│   ├── main.tf          # API Gateway + Lambda + EventBridge
│   ├── dynamodb.tf      # DynamoDB tables
│   ├── messaging.tf     # SNS topics + SQS queues + DLQs
│   └── iam.tf           # IAM roles (least privilege)
├── lambdas/
│   ├── webhook/         # Validates input, fires EventBridge event
│   ├── event-processor/ # Calls Vertex AI, publishes to SNS
│   ├── response-handler/# Writes enriched data to DynamoDB
│   └── notifications/   # Sends email notification via SQS
├── tests/
│   ├── unit/
│   └── integration/
├── docs/
│   ├── ARCHITECTURE.md
│   └── DEPLOYMENT.md
└── README.md
```

---

## DynamoDB Tables

| Table | Primary Key | Sort Key | TTL | Purpose |
|---|---|---|---|---|
| moods | user_id | timestamp | 90 days | Mood history + AI responses |
| users | user_id | — | — | User preferences |
| audit | request_id | — | 30 days | Request tracking |

> **Fix note:** The response handler updates mood records using the original `request_id` passed through the event, not a new timestamp. This ensures the right DynamoDB item is always found and updated.

---

## Lambda Functions

### 1. Webhook (`POST /mood`)
- Validates API key header and request body schema
- Generates a unique `request_id`
- Puts event on EventBridge
- Returns `202 Accepted` with `request_id` immediately

### 2. Event Processor
- Triggered by EventBridge rule
- Calls Vertex AI Gemini with mood context
- Parses AI response and publishes to SNS topic
- Falls back to a default coping message if AI call fails

### 3. Response Handler
- Triggered by SNS
- Enriches mood data with AI suggestions
- Writes to DynamoDB using `request_id` as the lookup key
- Triggers notification Lambda

### 4. Notifications
- Reads from SQS queue
- Sends email notification to user
- Batched processing (up to 10 messages at once)

---

## Vertex AI Integration

This project uses **Google Cloud Vertex AI** (Gemini 1.5 Flash) from inside an AWS Lambda. Since this is cross-cloud, authentication is handled via a GCP service account JSON key stored in AWS Secrets Manager.

```python
# Rough idea of how the prompt works
prompt = f"""
A user is feeling: {mood}
Context: {context}

Suggest 3 practical coping strategies in a warm, supportive tone.
Keep each suggestion under 2 sentences.
"""
```

Settings: `temperature=0.7`, `max_output_tokens=256`

> **Note on cross-cloud:** Using Vertex AI from AWS Lambda requires outbound internet access from Lambda (via NAT Gateway or public subnet) and valid GCP credentials. This is intentional — the goal was to explore multi-cloud integration.

---

## Setup

### Prerequisites
- AWS CLI configured (`aws configure`)
- Terraform >= 1.5 installed
- GCP project with Vertex AI API enabled
- GCP service account JSON key

### Deploy

```bash
# Clone the repo
git clone https://github.com/riyazbhattarai07/serverless-mood-bot.git
cd serverless-mood-bot

# Store your GCP credentials in AWS Secrets Manager first
aws secretsmanager create-secret \
  --name gcp-vertex-credentials \
  --secret-string file://your-gcp-key.json

# Deploy infrastructure
cd infrastructure
terraform init
terraform plan
terraform apply
```

### Test the API

```bash
curl -X POST https://<your-api-id>.execute-api.ca-central-1.amazonaws.com/prod/mood \
  -H "Content-Type: application/json" \
  -H "x-api-key: your-api-key" \
  -d '{
    "user_id": "user123",
    "mood": "anxious",
    "context": "Big job interview tomorrow"
  }'

# Response
# { "request_id": "abc-123", "status": "processing" }
```

---

## Running Tests

```bash
# Unit tests
pip install pytest boto3 moto
pytest tests/unit/ -v

# Integration tests (needs real AWS credentials)
pytest tests/integration/ -v
```

---

## Estimated Monthly Cost (AWS Free Tier)

| Service | Free Tier | Estimated Usage | Cost |
|---|---|---|---|
| Lambda | 1M requests/month | ~10K requests | $0 |
| API Gateway | 1M calls/month | ~10K calls | $0 |
| DynamoDB | 25GB + 25 WCU/RCU | Small table | $0 |
| SNS | 1M publishes | ~10K | $0 |
| SQS | 1M requests | ~20K | $0 |
| CloudWatch | 5GB logs | Minimal | $0 |
| **Vertex AI** | Pay-per-use | ~10K tokens | ~$0.01 |

**Total: basically free for personal/demo use.**

---

## What I Learned

**Why EventBridge instead of direct Lambda chaining?**
If the webhook Lambda called the processor Lambda directly, a failure in the processor would block the whole request and the user would wait. With EventBridge in the middle, the webhook returns instantly, EventBridge handles retries automatically (2 retries, 60s backoff), and failures land in a DLQ instead of being silently lost.

**The DynamoDB key bug I fixed:**
The original skeleton tried to update a mood record using a fresh `time.time()` call in the response handler. Since the sort key is a timestamp from when the record was first written, that lookup would always miss. The fix was to pass `request_id` through the entire event chain and use that as the consistent lookup key.

**Cross-cloud auth is not magic:**
AWS IAM cannot directly authorize calls to Google Cloud. I had to store a GCP service account key in Secrets Manager and load it at Lambda runtime. In production you'd use GCP Workload Identity Federation to avoid long-lived keys entirely.

---

## Status

- [x] Project structure and Terraform scaffolding
- [x] Webhook Lambda with input validation
- [x] EventBridge rule + DLQ
- [x] Event Processor Lambda with Vertex AI integration
- [x] Response Handler Lambda (DynamoDB write fixed)
- [x] SNS/SQS notification flow
- [x] IAM least-privilege roles
- [ ] Unit tests (in progress)
- [ ] CI/CD pipeline (GitHub Actions)
- [ ] Terraform remote state (S3 + DynamoDB lock)

---

## Author

Built by **Riyaz Bhattarai** as part of my AWS cloud engineering portfolio.

> Project idea and initial skeleton generated with Vertex AI (Gemini). Architecture design, implementation, bug fixes, and all code written by me.
