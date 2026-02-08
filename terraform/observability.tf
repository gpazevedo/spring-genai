# =============================================================================
# X-Ray Observability Configuration
# =============================================================================

# -----------------------------------------------------------------------------
# X-Ray Group: groups traces for this service with insights for anomaly detection
# -----------------------------------------------------------------------------
resource "aws_xray_group" "extended_chat" {
  group_name        = "${local.service_name}-${var.environment}"
  filter_expression = "service(\"${local.service_name}\")"

  insights_configuration {
    insights_enabled          = true
    notifications_enabled     = false
  }

  tags = {
    Environment = var.environment
    Service     = local.service_name
  }
}

# -----------------------------------------------------------------------------
# X-Ray Sampling Rule: controls what percentage of traces are sampled
#
# NOTE: The `attributes` field only works with API Gateway HTTP headers,
# NOT with OTEL attributes, error status, or response time. We use a simple
# service-level rule with no attributes.
# -----------------------------------------------------------------------------
resource "aws_xray_sampling_rule" "extended_chat" {
  rule_name      = "${local.service_name}-${var.environment}"
  priority       = 100
  version        = 1
  reservoir_size = 1
  fixed_rate     = 1
  url_path       = "*"
  host           = "*"
  http_method    = "*"
  service_type   = "*"
  service_name   = local.service_name
  resource_arn   = "*"

  tags = {
    Environment = var.environment
    Service     = local.service_name
  }
}

# -----------------------------------------------------------------------------
# CloudWatch Logs Resource Policy: allows X-Ray to write spans to CloudWatch Logs
# Required for Transaction Search to function
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_resource_policy" "xray_transaction_search" {
  policy_name = "xray-transaction-search-${var.environment}"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TransactionSearchXRayAccess"
        Effect = "Allow"
        Principal = {
          Service = "xray.amazonaws.com"
        }
        Action = "logs:PutLogEvents"
        Resource = [
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:aws/spans:*",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/application-signals/data:*"
        ]
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:aws:xray:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
          }
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Transaction Search Setup (one-time)
#
# There is NO native Terraform resource for:
#   - aws xray update-trace-segment-destination
#   - aws xray update-indexing-rule
# These are account-level settings configured via CLI only.
#
# This null_resource runs the CLI commands once. To re-run, taint it:
#   terraform taint 'null_resource.xray_transaction_search_setup'
# -----------------------------------------------------------------------------
resource "null_resource" "xray_transaction_search_setup" {
  depends_on = [aws_cloudwatch_log_resource_policy.xray_transaction_search]

  triggers = {
    indexing_percentage = var.xray_indexing_percentage
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e

      echo "Configuring X-Ray trace segment destination to CloudWatchLogs..."
      aws xray update-trace-segment-destination \
        --destination CloudWatchLogs \
        --region ${var.aws_region} 2>&1 || \
        echo "Destination already set to CloudWatchLogs, continuing."

      echo "Setting X-Ray indexing rule to ${var.xray_indexing_percentage}%..."
      aws xray update-indexing-rule \
        --name "Default" \
        --rule '{"Probabilistic":{"DesiredSamplingPercentage":${var.xray_indexing_percentage}}}' \
        --region ${var.aws_region}

      echo "Transaction Search setup complete."
    EOT
  }
}
