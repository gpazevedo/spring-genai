output "memory_id" {
  description = "AgentCore Memory ID"
  value       = aws_bedrockagentcore_memory.agent_memory.id
}

output "runtime_name" {
  description = "AgentCore Runtime Name"
  value       = aws_bedrockagentcore_agent_runtime.extended_chat.agent_runtime_name
}

output "runtime_arn" {
  description = "ARN of the deployed AgentCore Runtime"
  value       = aws_bedrockagentcore_agent_runtime.extended_chat.agent_runtime_arn
}

output "container_uri" {
  description = "Container URI used for deployment"
  value       = local.container_uri
}

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID for OAuth authentication"
  value       = aws_cognito_user_pool.oauth_users.id
}

output "cognito_client_id" {
  description = "Cognito Client ID for OAuth authentication"
  value       = aws_cognito_user_pool_client.oauth_client.id
}

output "runtime_status" {
  description = "Runtime deployment status"
  value       = "Runtime deployed with OAuth authentication. Test with: ./test.sh"
}

output "xray_group_arn" {
  description = "ARN of the X-Ray group for the extended chat client"
  value       = aws_xray_group.extended_chat.arn
}

output "xray_sampling_rule_name" {
  description = "Name of the X-Ray sampling rule"
  value       = aws_xray_sampling_rule.extended_chat.rule_name
}

output "xray_indexing_percentage" {
  description = "Configured X-Ray Transaction Search indexing percentage"
  value       = var.xray_indexing_percentage
}
