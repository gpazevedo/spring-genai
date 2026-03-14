terraform {
  required_version = ">= 1.14.4"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.36.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Get current AWS account ID
data "aws_caller_identity" "current" {}

locals {
  memory_name_clean  = "extendedChatClientMemory"
  unique_memory_name = "${local.memory_name_clean}_${data.aws_caller_identity.current.account_id}"
  runtime_name       = "spring_genai_${data.aws_caller_identity.current.account_id}"
  service_name       = "spring-genai"

  container_uri = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/spring-genai-${data.aws_caller_identity.current.account_id}:latest"

  # AgentCore appends a random suffix to runtime_name to form the runtime_id.
  # Update var.runtime_id_suffix if the runtime is ever destroyed and recreated.
  runtime_id           = "${local.runtime_name}-${var.runtime_id_suffix}"
  runtime_arn          = "arn:aws:bedrock-agentcore:${var.aws_region}:${data.aws_caller_identity.current.account_id}:runtime/${local.runtime_id}"
  # Endpoint ARN is what cloud.resource_id must use for the AgentCore agents dashboard
  runtime_endpoint_arn = "${local.runtime_arn}/runtime-endpoint/DEFAULT"
  native_log_group     = "/aws/bedrock-agentcore/runtimes/${local.runtime_id}-DEFAULT"
}

# Cognito User Pool for OAuth authentication
resource "aws_cognito_user_pool" "oauth_users" {
  name = "spring-genai-users-${data.aws_caller_identity.current.account_id}"

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
    require_uppercase = true
  }

  auto_verified_attributes = ["email"]
  
  tags = {
    Environment = var.environment
    Purpose     = "Spring AI Extended Chat Client OAuth"
  }
}

# Cognito User Pool Client
resource "aws_cognito_user_pool_client" "oauth_client" {
  name         = "spring-genai-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.oauth_users.id

  generate_secret = false
  
  explicit_auth_flows = [
    "ADMIN_NO_SRP_AUTH",
    "USER_PASSWORD_AUTH"
  ]
}

# IAM Role for AgentCore Runtime
resource "aws_iam_role" "agentcore_runtime" {
  name = "ExtendedChatClientRuntimeRole-${data.aws_caller_identity.current.account_id}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "bedrock-agentcore.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:aws:bedrock-agentcore:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      }
    ]
  })
}

# IAM Policy for runtime
resource "aws_iam_role_policy" "agentcore_execution" {
  name = "AgentCoreExecutionPolicy"
  role = aws_iam_role.agentcore_runtime.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:*"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "cloudwatch:PutMetricData"
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "bedrock-agentcore"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "logs:DescribeLogStreams",
          "logs:DescribeLogGroups"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

# AgentCore Runtime with OAuth authentication
resource "aws_bedrockagentcore_agent_runtime" "extended_chat" {
  depends_on = [aws_bedrockagentcore_memory.agent_memory]
  
  agent_runtime_name = local.runtime_name
  role_arn          = aws_iam_role.agentcore_runtime.arn

  agent_runtime_artifact {
    container_configuration {
      container_uri = local.container_uri
    }
  }

  network_configuration {
    network_mode = "PUBLIC"
  }

  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.oauth_users.id}/.well-known/openid-configuration"
      allowed_clients = [aws_cognito_user_pool_client.oauth_client.id]
    }
  }

  request_header_configuration {
    request_header_allowlist = [
      "Authorization",
      "X-Amzn-Bedrock-AgentCore-Runtime-Custom-Test"
    ]
  }

  environment_variables = {
    AGENTCORE_MEMORY_ID    = aws_bedrockagentcore_memory.agent_memory.id
    SPRING_PROFILES_ACTIVE = "production"

    # Required for GenAI Observability dashboard to identify this as an AgentCore agent
    OTEL_RESOURCE_ATTRIBUTES = join(",", [
      "service.name=${local.service_name}",
      "aws.log.group.names=${local.native_log_group}",
      "cloud.resource_id=${local.runtime_endpoint_arn}",
    ])

    OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf"

    # Traces → X-Ray OTLP endpoint (SigV4-signed by ADOT agent)
    OTEL_TRACES_EXPORTER               = "otlp"
    OTEL_EXPORTER_OTLP_TRACES_ENDPOINT = "https://xray.${var.aws_region}.amazonaws.com/v1/traces"

    # Logs → CloudWatch Logs OTLP endpoint → native AgentCore log group
    OTEL_LOGS_EXPORTER             = "otlp"
    OTEL_EXPORTER_OTLP_LOGS_ENDPOINT = "https://logs.${var.aws_region}.amazonaws.com/v1/logs"
    OTEL_EXPORTER_OTLP_LOGS_HEADERS  = "x-aws-log-group=${local.native_log_group},x-aws-log-stream=otel-rt-logs"

    # Metrics: no direct CloudWatch OTLP endpoint
    OTEL_METRICS_EXPORTER = "none"

    # Disable Application Signals to avoid duplicate instrumentation
    OTEL_AWS_APPLICATION_SIGNALS_ENABLED = "false"
  }
}
