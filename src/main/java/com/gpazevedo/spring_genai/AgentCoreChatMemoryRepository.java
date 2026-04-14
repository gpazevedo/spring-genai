package com.gpazevedo.spring_genai;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.chat.memory.ChatMemoryRepository;
import org.springframework.ai.chat.messages.AssistantMessage;
import org.springframework.ai.chat.messages.Message;
import org.springframework.ai.chat.messages.UserMessage;
import software.amazon.awssdk.awscore.exception.AwsServiceException;
import software.amazon.awssdk.services.bedrockagentcore.BedrockAgentCoreClient;
import software.amazon.awssdk.services.bedrockagentcore.model.*;

import java.time.Instant;
import java.util.*;
import java.util.stream.Collectors;

/**
 * ChatMemoryRepository backed by Amazon Bedrock AgentCore short-term memory.
 * Stores conversation history as AgentCore events, keyed by actor and session.
 *
 * <p>The conversationId format is "actorId:sessionId" (from JWT userId + AgentCore sessionId).
 * Each saveAll call creates one AgentCore event containing all new (unsaved) messages.
 * Delta detection avoids duplicating messages already persisted in AgentCore.
 */
class AgentCoreChatMemoryRepository implements ChatMemoryRepository {

    private static final Logger log = LoggerFactory.getLogger(AgentCoreChatMemoryRepository.class);
    static final String EVENT_ID_KEY = "agentcore.eventId";

    private final BedrockAgentCoreClient client;
    private final String memoryId;

    AgentCoreChatMemoryRepository(BedrockAgentCoreClient client, String memoryId) {
        this.client = client;
        this.memoryId = memoryId;
    }

    @Override
    public List<String> findConversationIds() {
        throw new UnsupportedOperationException();
    }

    @Override
    public List<Message> findByConversationId(String conversationId) {
        var actorSession = parse(conversationId);
        var allEvents = new ArrayList<Event>();
        String nextToken = null;

        do {
            var req = ListEventsRequest.builder()
                    .memoryId(memoryId)
                    .actorId(actorSession[0])
                    .sessionId(actorSession[1])
                    .includePayloads(true)
                    .maxResults(100);
            if (nextToken != null) req.nextToken(nextToken);
            var resp = client.listEvents(req.build());
            allEvents.addAll(resp.events());
            nextToken = resp.nextToken();
        } while (nextToken != null);

        // AgentCore returns events newest-first; reverse for chronological order
        Collections.reverse(allEvents);

        return allEvents.stream()
                .flatMap(event -> event.payload().stream().map(p -> toMessage(p, event.eventId())))
                .filter(Objects::nonNull)
                .collect(Collectors.toList());
    }

    @Override
    public void saveAll(String conversationId, List<Message> messages) {
        if (messages == null || messages.isEmpty()) return;

        // Only save messages that haven't been persisted yet (no eventId in metadata)
        var delta = messages.stream()
                .filter(m -> m.getMetadata().get(EVENT_ID_KEY) == null)
                .toList();
        if (delta.isEmpty()) return;

        var payloads = delta.stream()
                .map(this::toPayload)
                .filter(Objects::nonNull)
                .toList();
        if (payloads.isEmpty()) return;

        var actorSession = parse(conversationId);
        var resp = client.createEvent(CreateEventRequest.builder()
                .memoryId(memoryId)
                .actorId(actorSession[0])
                .sessionId(actorSession[1])
                .payload(payloads)
                .eventTimestamp(Instant.now())
                .build());

        String eventId = resp.event().eventId();
        delta.forEach(m -> m.getMetadata().put(EVENT_ID_KEY, eventId));
    }

    @Override
    public void deleteByConversationId(String conversationId) {
        var actorSession = parse(conversationId);
        String nextToken = null;

        do {
            var req = ListEventsRequest.builder()
                    .memoryId(memoryId)
                    .actorId(actorSession[0])
                    .sessionId(actorSession[1])
                    .includePayloads(false)
                    .maxResults(100);
            if (nextToken != null) req.nextToken(nextToken);
            var resp = client.listEvents(req.build());

            resp.events().forEach(event -> {
                try {
                    client.deleteEvent(DeleteEventRequest.builder()
                            .memoryId(memoryId)
                            .actorId(actorSession[0])
                            .sessionId(actorSession[1])
                            .eventId(event.eventId())
                            .build());
                } catch (AwsServiceException ex) {
                    log.warn("Failed to delete event [{}]: {}", event.eventId(), ex.awsErrorDetails().errorMessage());
                }
            });

            nextToken = resp.nextToken();
        } while (nextToken != null);
    }

    private Message toMessage(PayloadType payload, String eventId) {
        var conv = payload.conversational();
        String text = conv.content().text();
        Map<String, Object> meta = Map.of(EVENT_ID_KEY, eventId);
        return switch (conv.role()) {
            case USER -> UserMessage.builder().text(text).metadata(meta).build();
            case ASSISTANT -> AssistantMessage.builder().content(text).properties(meta).build();
            default -> null;
        };
    }

    private PayloadType toPayload(Message message) {
        Role role;
        if (message instanceof UserMessage) role = Role.USER;
        else if (message instanceof AssistantMessage) role = Role.ASSISTANT;
        else return null;

        return PayloadType.builder()
                .conversational(Conversational.builder()
                        .role(role)
                        .content(Content.builder().text(message.getText()).build())
                        .build())
                .build();
    }

    /** Parse "actorId:sessionId" or "actorId" → [actor, session]. */
    private String[] parse(String conversationId) {
        if (conversationId.contains(":")) {
            return conversationId.split(":", 2);
        }
        return new String[]{conversationId, "default-session"};
    }
}
