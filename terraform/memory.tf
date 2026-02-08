# AgentCore Memory for Spring AI Extended Chat Client
resource "aws_bedrockagentcore_memory" "agent_memory" {
  name                 = local.unique_memory_name
  description          = "Memory for Spring AI Extended Chat Client"
  event_expiry_duration = 30
}
