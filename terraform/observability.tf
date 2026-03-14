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
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/spans:*",
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
resource "aws_cloudwatch_log_group" "otel_logs" {
  name              = "/aws/bedrock-agentcore/runtimes/${local.runtime_name}"
  retention_in_days = 30

  tags = {
    Environment = var.environment
    Service     = local.service_name
  }
}

resource "aws_cloudwatch_log_stream" "otel_logs" {
  name           = "runtime-logs"
  log_group_name = aws_cloudwatch_log_group.otel_logs.name
}

# -----------------------------------------------------------------------------
# AgentCore Vended Log Delivery: APPLICATION_LOGS
#
# Registers the runtime as a log delivery source so AgentCore can write
# structured request/response payload logs to CloudWatch Logs.
# This populates the "Logs" tab in the GenAI Observability agents dashboard.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "vended_app_logs" {
  name              = "/aws/vendedlogs/bedrock-agentcore/${aws_bedrockagentcore_agent_runtime.extended_chat.agent_runtime_id}"
  retention_in_days = 30

  tags = {
    Environment = var.environment
    Service     = local.service_name
  }
}

resource "aws_cloudwatch_log_delivery_source" "runtime_app_logs" {
  name         = "${local.service_name}-${var.runtime_id_suffix}-app-logs"
  log_type     = "APPLICATION_LOGS"
  resource_arn = aws_bedrockagentcore_agent_runtime.extended_chat.agent_runtime_arn
}

resource "aws_cloudwatch_log_delivery_destination" "runtime_app_logs" {
  name = "${local.service_name}-${var.runtime_id_suffix}-app-logs"

  delivery_destination_configuration {
    destination_resource_arn = aws_cloudwatch_log_group.vended_app_logs.arn
  }
}

resource "aws_cloudwatch_log_delivery" "runtime_app_logs" {
  delivery_source_name     = aws_cloudwatch_log_delivery_source.runtime_app_logs.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.runtime_app_logs.arn
}

# -----------------------------------------------------------------------------
# AgentCore Vended Log Delivery: TRACES
#
# Registers the runtime as a trace delivery source to X-Ray.
# This is the programmatic equivalent of "Enable Tracing" in the AgentCore
# console (Agents → select agent → Tracing pane → Enable).
# Spans appear in the aws/spans log group via Transaction Search.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_delivery_source" "runtime_traces" {
  name         = "${local.service_name}-${var.runtime_id_suffix}-traces"
  log_type     = "TRACES"
  resource_arn = aws_bedrockagentcore_agent_runtime.extended_chat.agent_runtime_arn
}

resource "aws_cloudwatch_log_delivery_destination" "runtime_traces" {
  name                      = "${local.service_name}-${var.runtime_id_suffix}-traces"
  delivery_destination_type = "XRAY"
}

resource "aws_cloudwatch_log_delivery" "runtime_traces" {
  delivery_source_name     = aws_cloudwatch_log_delivery_source.runtime_traces.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.runtime_traces.arn

  # Sequential creation required to avoid concurrency issues with deliveries
  depends_on = [aws_cloudwatch_log_delivery.runtime_app_logs]
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
