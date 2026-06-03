# -------------------------------------------------------
# iam.tf - Least-privilege IAM roles for each Lambda
# Each Lambda only gets the permissions it actually needs
# -------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# -------------------------------------------------------
# Webhook Lambda Role
# Needs: EventBridge PutEvents, CloudWatch Logs, X-Ray
# -------------------------------------------------------
resource "aws_iam_role" "webhook_role" {
  name               = "${var.project_name}-webhook-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy" "webhook_policy" {
  name = "webhook-policy"
  role = aws_iam_role.webhook_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["events:PutEvents"]
        Resource = aws_cloudwatch_event_bus.mood_bus.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }
    ]
  })
}

# -------------------------------------------------------
# Event Processor Lambda Role
# Needs: SNS Publish, Secrets Manager (GCP creds), CloudWatch, X-Ray
# Note: Vertex AI auth is handled via GCP service account, not AWS IAM
# -------------------------------------------------------
resource "aws_iam_role" "processor_role" {
  name               = "${var.project_name}-processor-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy" "processor_policy" {
  name = "processor-policy"
  role = aws_iam_role.processor_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.mood_response.arn
      },
      {
        # Fetch GCP service account credentials at runtime
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = "arn:aws:secretsmanager:*:*:secret:gcp-vertex-credentials*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }
    ]
  })
}

# -------------------------------------------------------
# Response Handler Lambda Role
# Needs: DynamoDB write, SQS SendMessage, CloudWatch, X-Ray
# -------------------------------------------------------
resource "aws_iam_role" "response_handler_role" {
  name               = "${var.project_name}-response-handler-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy" "response_handler_policy" {
  name = "response-handler-policy"
  role = aws_iam_role.response_handler_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query"
        ]
        Resource = [
          aws_dynamodb_table.moods.arn,
          "${aws_dynamodb_table.moods.arn}/index/*",
          aws_dynamodb_table.audit.arn
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.notifications.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }
    ]
  })
}

# -------------------------------------------------------
# Notifications Lambda Role
# Needs: SQS receive/delete, CloudWatch, X-Ray
# -------------------------------------------------------
resource "aws_iam_role" "notifications_role" {
  name               = "${var.project_name}-notifications-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy" "notifications_policy" {
  name = "notifications-policy"
  role = aws_iam_role.notifications_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.notifications.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }
    ]
  })
}
