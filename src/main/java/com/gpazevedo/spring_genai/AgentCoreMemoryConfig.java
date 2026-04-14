package com.gpazevedo.spring_genai;

import org.springframework.ai.chat.memory.ChatMemory;
import org.springframework.ai.chat.memory.MessageWindowChatMemory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnExpression;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import software.amazon.awssdk.services.bedrockagentcore.BedrockAgentCoreClient;

/**
 * Configures AgentCore-backed conversation memory when AGENTCORE_MEMORY_ID is set.
 * Falls back to Spring AI's default InMemoryChatMemoryRepository otherwise.
 */
@Configuration
@ConditionalOnExpression("!'${agentcore.memory.memory-id:}'.isBlank()")
@EnableConfigurationProperties(AgentCoreMemoryProperties.class)
class AgentCoreMemoryConfig {

    @Bean
    BedrockAgentCoreClient bedrockAgentCoreClient() {
        return BedrockAgentCoreClient.create();
    }

    @Bean
    AgentCoreChatMemoryRepository agentCoreChatMemoryRepository(
            BedrockAgentCoreClient client,
            AgentCoreMemoryProperties props) {
        return new AgentCoreChatMemoryRepository(client, props.memoryId());
    }

    @Bean
    ChatMemory chatMemory(AgentCoreChatMemoryRepository repository) {
        return MessageWindowChatMemory.builder()
                .chatMemoryRepository(repository)
                .build();
    }
}
