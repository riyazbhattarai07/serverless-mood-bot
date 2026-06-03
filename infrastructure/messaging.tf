# -------------------------------------------------------
# messaging.tf - SNS topics, SQS queues, Dead Letter Queues
# -------------------------------------------------------

# -------------------------------------------------------
# SNS: Main topic that processor publishes AI results to
# -------------------------------------------------------
resource "aws_sns_topic" "mood_response" {
  name = "${var.project_name}-mood-response"

  tags = {
    Project = var.project_name
  }
}

# -------------------------------------------------------
# SQS: Notification queue (response handler -> email sender)
# -------------------------------------------------------
resource "aws_sqs_queue" "notifications_dlq" {
  name                      = "${var.project_name}-notifications-dlq"
  message_retention_seconds = 1209600 # 14 days

  tags = {
    Project = var.project_name
  }
}

resource "aws_sqs_queue" "notifications" {
  name                       = "${var.project_name}-notifications"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 86400 # 1 day

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.notifications_dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Project = var.project_name
  }
}

# Allow SNS to send to notifications SQS queue
resource "aws_sqs_queue_policy" "notifications_policy" {
  queue_url = aws_sqs_queue.notifications.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "sns.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.notifications.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_sns_topic.mood_response.arn
          }
        }
      }
    ]
  })
}

# -------------------------------------------------------
# SQS: Dead Letter Queue for EventBridge failures
# If EventBridge can't deliver the event after retries, it lands here
# -------------------------------------------------------
resource "aws_sqs_queue" "event_dlq" {
  name                      = "${var.project_name}-event-dlq"
  message_retention_seconds = 1209600 # 14 days

  tags = {
    Project = var.project_name
    Purpose = "eventbridge-failures"
  }
}

# Allow EventBridge to send to the DLQ
resource "aws_sqs_queue_policy" "event_dlq_policy" {
  queue_url = aws_sqs_queue.event_dlq.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.event_dlq.arn
      }
    ]
  })
}

# -------------------------------------------------------
# CloudWatch Alarms - alert when DLQs have messages
# -------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "event_dlq_alarm" {
  alarm_name          = "${var.project_name}-event-dlq-not-empty"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "EventBridge DLQ has messages - check for Lambda failures"

  dimensions = {
    QueueName = aws_sqs_queue.event_dlq.name
  }
}
