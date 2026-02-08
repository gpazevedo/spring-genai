variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "memory_name" {
  description = "Base name for AgentCore memory"
  type        = string
  default     = "extendedChatClientMemory"
}


variable "xray_indexing_percentage" {
  description = "Percentage of X-Ray traces indexed for Transaction Search (1% is free tier)"
  type        = number
  default     = 100
}
