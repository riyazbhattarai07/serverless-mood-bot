# -------------------------------------------------------
# dynamodb.tf - DynamoDB tables for moods, users, and audit
# -------------------------------------------------------

# Moods table - stores mood submissions + AI responses
# Primary key: user_id (partition) + timestamp (sort)
# TTL: 90 days
resource "aws_dynamodb_table" "moods" {
  name         = "${var.project_name}-moods"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"
  range_key    = "timestamp"

  attribute {
    name = "user_id"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  attribute {
    name = "request_id"
    type = "S"
  }

  # Global Secondary Index so we can look up by request_id
  # This is the key fix - response handler uses request_id, not timestamp
  global_secondary_index {
    name            = "request_id-index"
    hash_key        = "request_id"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = {
    Project = var.project_name
    Purpose = "mood-history"
  }
}

# Users table - stores user preferences and email
resource "aws_dynamodb_table" "users" {
  name         = "${var.project_name}-users"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"

  attribute {
    name = "user_id"
    type = "S"
  }

  tags = {
    Project = var.project_name
    Purpose = "user-preferences"
  }
}

# Audit table - tracks every request end-to-end
# TTL: 30 days
resource "aws_dynamodb_table" "audit" {
  name         = "${var.project_name}-audit"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "request_id"

  attribute {
    name = "request_id"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = {
    Project = var.project_name
    Purpose = "request-audit"
  }
}
