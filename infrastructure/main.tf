# -------------------------------------------------------
# main.tf - API Gateway (REST), Lambda functions, EventBridge
# -------------------------------------------------------

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default = "ca-central-1"
}

variable "project_name" {
  default = "serverless-mood-bot"
}

# -------------------------------------------------------
# Lambda: Webhook (API Gateway handler)
# -------------------------------------------------------
data "archive_file" "webhook_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambdas/webhook/handler.py"
  output_path = "/tmp/webhook.zip"
}

resource "aws_lambda_function" "webhook" {
  function_name    = "${var.project_name}-webhook"
  filename         = data.archive_file.webhook_zip.output_path
  source_code_hash = data.archive_file.webhook_zip.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.11"
  role             = aws_iam_role.webhook_role.arn
  timeout          = 30

  environment {
    variables = {
      EVENT_BUS_NAME = aws_cloudwatch_event_bus.mood_bus.name
      PROJECT_NAME   = var.project_name
    }
  }

  tracing_config {
    mode = "Active"
  }
}

# -------------------------------------------------------
# Lambda: Event Processor (EventBridge -> Vertex AI)
# -------------------------------------------------------
data "archive_file" "processor_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambdas/event-processor/handler.py"
  output_path = "/tmp/processor.zip"
}

resource "aws_lambda_function" "event_processor" {
  function_name    = "${var.project_name}-event-processor"
  filename         = data.archive_file.processor_zip.output_path
  source_code_hash = data.archive_file.processor_zip.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.11"
  role             = aws_iam_role.processor_role.arn
  timeout          = 60

  environment {
    variables = {
      SNS_TOPIC_ARN         = aws_sns_topic.mood_response.arn
      GCP_SECRET_NAME       = "gcp-vertex-credentials"
      VERTEX_PROJECT        = var.vertex_project_id
      VERTEX_LOCATION       = "us-central1"
    }
  }

  tracing_config {
    mode = "Active"
  }
}

variable "vertex_project_id" {
  description = "Your GCP project ID for Vertex AI"
  type        = string
}

# -------------------------------------------------------
# Lambda: Response Handler (writes to DynamoDB)
# -------------------------------------------------------
data "archive_file" "response_handler_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambdas/response-handler/handler.py"
  output_path = "/tmp/response_handler.zip"
}

resource "aws_lambda_function" "response_handler" {
  function_name    = "${var.project_name}-response-handler"
  filename         = data.archive_file.response_handler_zip.output_path
  source_code_hash = data.archive_file.response_handler_zip.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.11"
  role             = aws_iam_role.response_handler_role.arn
  timeout          = 60

  environment {
    variables = {
      MOODS_TABLE           = aws_dynamodb_table.moods.name
      AUDIT_TABLE           = aws_dynamodb_table.audit.name
      NOTIFICATION_QUEUE_URL = aws_sqs_queue.notifications.url
    }
  }

  tracing_config {
    mode = "Active"
  }
}

# -------------------------------------------------------
# Lambda: Notifications (SQS -> email sender)
# -------------------------------------------------------
data "archive_file" "notifications_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambdas/notifications/handler.py"
  output_path = "/tmp/notifications.zip"
}

resource "aws_lambda_function" "notifications" {
  function_name    = "${var.project_name}-notifications"
  filename         = data.archive_file.notifications_zip.output_path
  source_code_hash = data.archive_file.notifications_zip.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.11"
  role             = aws_iam_role.notifications_role.arn
  timeout          = 30

  tracing_config {
    mode = "Active"
  }
}

# SQS -> Notifications Lambda trigger
resource "aws_lambda_event_source_mapping" "sqs_to_notifications" {
  event_source_arn = aws_sqs_queue.notifications.arn
  function_name    = aws_lambda_function.notifications.arn
  batch_size       = 10
  enabled          = true
}

# -------------------------------------------------------
# API Gateway (REST API)
# -------------------------------------------------------
resource "aws_api_gateway_rest_api" "mood_api" {
  name        = "${var.project_name}-api"
  description = "Mood Bot REST API"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "mood" {
  rest_api_id = aws_api_gateway_rest_api.mood_api.id
  parent_id   = aws_api_gateway_rest_api.mood_api.root_resource_id
  path_part   = "mood"
}

resource "aws_api_gateway_method" "post_mood" {
  rest_api_id      = aws_api_gateway_rest_api.mood_api.id
  resource_id      = aws_api_gateway_resource.mood.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_integration" "webhook_integration" {
  rest_api_id             = aws_api_gateway_rest_api.mood_api.id
  resource_id             = aws_api_gateway_resource.mood.id
  http_method             = aws_api_gateway_method.post_mood.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.webhook.invoke_arn
}

resource "aws_api_gateway_deployment" "prod" {
  rest_api_id = aws_api_gateway_rest_api.mood_api.id

  depends_on = [
    aws_api_gateway_integration.webhook_integration
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.prod.id
  rest_api_id   = aws_api_gateway_rest_api.mood_api.id
  stage_name    = "prod"
}

resource "aws_api_gateway_usage_plan" "mood_plan" {
  name = "${var.project_name}-usage-plan"

  api_stages {
    api_id = aws_api_gateway_rest_api.mood_api.id
    stage  = aws_api_gateway_stage.prod.stage_name
  }
}

resource "aws_api_gateway_api_key" "mood_key" {
  name = "${var.project_name}-api-key"
}

resource "aws_api_gateway_usage_plan_key" "mood_plan_key" {
  key_id        = aws_api_gateway_api_key.mood_key.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.mood_plan.id
}

resource "aws_lambda_permission" "apigw_webhook" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.webhook.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.mood_api.execution_arn}/*/*"
}

# -------------------------------------------------------
# EventBridge (Custom Event Bus)
# -------------------------------------------------------
resource "aws_cloudwatch_event_bus" "mood_bus" {
  name = "${var.project_name}-bus"
}

resource "aws_cloudwatch_event_rule" "mood_submitted" {
  name           = "mood-submitted"
  event_bus_name = aws_cloudwatch_event_bus.mood_bus.name
  description    = "Fires when a mood is submitted"

  event_pattern = jsonencode({
    source      = ["mood-bot.webhook"]
    detail-type = ["MoodSubmitted"]
  })
}

resource "aws_cloudwatch_event_target" "processor_target" {
  rule           = aws_cloudwatch_event_rule.mood_submitted.name
  event_bus_name = aws_cloudwatch_event_bus.mood_bus.name
  target_id      = "EventProcessor"
  arn            = aws_lambda_function.event_processor.arn

  retry_policy {
    maximum_retry_attempts       = 2
    maximum_event_age_in_seconds = 60
  }

  dead_letter_config {
    arn = aws_sqs_queue.event_dlq.arn
  }
}

resource "aws_lambda_permission" "eventbridge_processor" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.event_processor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.mood_submitted.arn
}

# SNS -> Response Handler
resource "aws_sns_topic_subscription" "response_handler_sub" {
  topic_arn = aws_sns_topic.mood_response.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.response_handler.arn
}

resource "aws_lambda_permission" "sns_response_handler" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.response_handler.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.mood_response.arn
}

# -------------------------------------------------------
# Outputs
# -------------------------------------------------------
output "api_endpoint" {
  value = "${aws_api_gateway_stage.prod.invoke_url}/mood"
}

output "api_key_id" {
  value = aws_api_gateway_api_key.mood_key.id
}
