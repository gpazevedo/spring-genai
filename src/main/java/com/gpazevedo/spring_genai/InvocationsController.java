package com.gpazevedo.spring_genai;

import org.springframework.ai.chat.client.ChatClient;
import org.springframework.ai.chat.client.advisor.MessageChatMemoryAdvisor;
import org.springframework.ai.chat.memory.ChatMemory;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;
import reactor.core.publisher.Flux;

@RestController
public class InvocationsController {

    private final ChatClient chatClient;
    private final JwtUtil jwtUtil;

    public InvocationsController(ChatClient.Builder chatClientBuilder, ChatMemory chatMemory, JwtUtil jwtUtil) {
        this.jwtUtil = jwtUtil;
        this.chatClient = chatClientBuilder
                .defaultSystem("You are a helpful assistant.")
                .defaultAdvisors(MessageChatMemoryAdvisor.builder(chatMemory).build())
                .build();
    }

    @PostMapping(value = "/invocations", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
    public Flux<String> invoke(
            @RequestBody InvocationRequest request,
            @RequestHeader(value = "Authorization", required = false) String authorization,
            @RequestHeader(value = "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id",
                    required = false) String sessionId) {

        var prompt = chatClient.prompt()
                .user(request.input().prompt());

        // Extract user identity from JWT token in Authorization header
        String userId = extractUserId(authorization);
        String conversationId = buildConversationId(userId, sessionId);

        if (conversationId != null) {
            prompt.advisors(a -> a.param(ChatMemory.CONVERSATION_ID, conversationId));
        }

        return prompt.stream().content();
    }

    private String extractUserId(String authorization) {
        if (authorization == null || !authorization.startsWith("Bearer ")) {
            return null;
        }
        return jwtUtil.extractUserId(authorization.substring(7));
    }

    private String buildConversationId(String userId, String sessionId) {
        if (userId != null && sessionId != null) {
            return userId + ":" + sessionId;
        }
        if (sessionId != null) {
            return sessionId;
        }
        return userId;
    }
}
