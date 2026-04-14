package com.gpazevedo.spring_genai;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.ai.chat.messages.AssistantMessage;
import org.springframework.ai.chat.messages.Message;
import org.springframework.ai.chat.messages.UserMessage;
import software.amazon.awssdk.services.bedrockagentcore.BedrockAgentCoreClient;
import software.amazon.awssdk.services.bedrockagentcore.model.*;

import java.util.List;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

class AgentCoreChatMemoryRepositoryTest {

    private BedrockAgentCoreClient client;
    private AgentCoreChatMemoryRepository repository;

    @BeforeEach
    void setUp() {
        client = mock(BedrockAgentCoreClient.class);
        repository = new AgentCoreChatMemoryRepository(client, "mem-123");
    }

    // ── findByConversationId ──────────────────────────────────────────────────

    @Test
    void findByConversationId_returnMessagesInChronologicalOrder() {
        // AgentCore returns events newest-first; repository must reverse them
        var event1 = event("evt-1", Role.USER, "hello");
        var event2 = event("evt-2", Role.ASSISTANT, "hi there");
        stubListEvents(List.of(event2, event1), null); // newest first

        List<Message> messages = repository.findByConversationId("alice:sess-1");

        assertEquals(2, messages.size());
        assertInstanceOf(UserMessage.class, messages.get(0));
        assertEquals("hello", messages.get(0).getText());
        assertInstanceOf(AssistantMessage.class, messages.get(1));
        assertEquals("hi there", messages.get(1).getText());
    }

    @Test
    void findByConversationId_stampsEventIdOnEachMessage() {
        stubListEvents(List.of(event("evt-42", Role.USER, "ping")), null);

        List<Message> messages = repository.findByConversationId("alice:sess-1");

        assertEquals("evt-42", messages.get(0).getMetadata().get(AgentCoreChatMemoryRepository.EVENT_ID_KEY));
    }

    @Test
    void findByConversationId_paginatesThroughAllPages() {
        var page1Event = event("evt-1", Role.USER, "page1");
        var page2Event = event("evt-2", Role.ASSISTANT, "page2");

        when(client.listEvents(any(ListEventsRequest.class))).thenAnswer(inv -> {
            ListEventsRequest req = inv.getArgument(0);
            if (req.nextToken() == null) {
                return ListEventsResponse.builder().events(page1Event).nextToken("tok").build();
            }
            return ListEventsResponse.builder().events(page2Event).build();
        });

        List<Message> messages = repository.findByConversationId("alice:sess-1");

        assertEquals(2, messages.size());
        verify(client, times(2)).listEvents(any(ListEventsRequest.class));
    }

    @Test
    void findByConversationId_skipsUnknownRoles() {
        var event = event("evt-1", Role.UNKNOWN_TO_SDK_VERSION, "ignored");
        stubListEvents(List.of(event), null);

        List<Message> messages = repository.findByConversationId("alice:sess-1");

        assertTrue(messages.isEmpty());
    }

    @Test
    void findByConversationId_parsesConversationIdWithoutColonAsActorOnly() {
        stubListEvents(List.of(), null);

        repository.findByConversationId("actor-only");

        verify(client).listEvents(argThat((ListEventsRequest r) ->
                "actor-only".equals(r.actorId()) && "default-session".equals(r.sessionId())));
    }

    // ── saveAll ───────────────────────────────────────────────────────────────

    @Test
    void saveAll_persistsNewMessagesAndStampsEventId() {
        stubCreateEvent("evt-new");

        var msg = UserMessage.builder().text("hello").build();
        repository.saveAll("alice:sess-1", List.of(msg));

        verify(client).createEvent(any(CreateEventRequest.class));
        assertEquals("evt-new", msg.getMetadata().get(AgentCoreChatMemoryRepository.EVENT_ID_KEY));
    }

    @Test
    void saveAll_onlySavesMessagesMissingEventId() {
        stubCreateEvent("evt-new");

        var already = UserMessage.builder().text("old")
                .metadata(java.util.Map.of(AgentCoreChatMemoryRepository.EVENT_ID_KEY, "evt-old"))
                .build();
        var fresh = UserMessage.builder().text("new").build();

        repository.saveAll("alice:sess-1", List.of(already, fresh));

        verify(client, times(1)).createEvent(argThat((CreateEventRequest r) ->
                r.payload().size() == 1 &&
                "new".equals(r.payload().get(0).conversational().content().text())));
    }

    @Test
    void saveAll_doesNothingForEmptyList() {
        repository.saveAll("alice:sess-1", List.of());
        verifyNoInteractions(client);
    }

    @Test
    void saveAll_skipsNonUserNonAssistantMessages() {
        // System messages (not UserMessage/AssistantMessage) → toPayload returns null → nothing saved
        var systemMsg = new org.springframework.ai.chat.messages.SystemMessage("be helpful");
        repository.saveAll("alice:sess-1", List.of(systemMsg));
        verifyNoInteractions(client);
    }

    @Test
    void saveAll_usesCorrectActorAndSession() {
        stubCreateEvent("evt-1");
        repository.saveAll("bob:session-99", List.of(UserMessage.builder().text("hi").build()));

        verify(client).createEvent(argThat((CreateEventRequest r) ->
                "bob".equals(r.actorId()) && "session-99".equals(r.sessionId())));
    }

    // ── deleteByConversationId ────────────────────────────────────────────────

    @Test
    void deleteByConversationId_deletesAllEventsForConversation() {
        var e1 = eventShell("evt-1");
        var e2 = eventShell("evt-2");
        when(client.listEvents(any(ListEventsRequest.class)))
                .thenReturn(ListEventsResponse.builder().events(e1, e2).build());

        repository.deleteByConversationId("alice:sess-1");

        verify(client).deleteEvent(argThat((DeleteEventRequest r) -> "evt-1".equals(r.eventId())));
        verify(client).deleteEvent(argThat((DeleteEventRequest r) -> "evt-2".equals(r.eventId())));
    }

    @Test
    void deleteByConversationId_paginatesBeforeDeleting() {
        var e1 = eventShell("evt-1");
        var e2 = eventShell("evt-2");

        when(client.listEvents(any(ListEventsRequest.class))).thenAnswer(inv -> {
            ListEventsRequest req = inv.getArgument(0);
            if (req.nextToken() == null) {
                return ListEventsResponse.builder().events(e1).nextToken("tok").build();
            }
            return ListEventsResponse.builder().events(e2).build();
        });

        repository.deleteByConversationId("alice:sess-1");

        verify(client, times(2)).deleteEvent(any(DeleteEventRequest.class));
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    private Event event(String eventId, Role role, String text) {
        var payload = PayloadType.builder()
                .conversational(Conversational.builder()
                        .role(role)
                        .content(Content.builder().text(text).build())
                        .build())
                .build();
        return Event.builder().eventId(eventId).payload(payload).build();
    }

    private Event eventShell(String eventId) {
        return Event.builder().eventId(eventId).build();
    }

    private void stubListEvents(List<Event> events, String nextToken) {
        var resp = ListEventsResponse.builder().events(events).nextToken(nextToken).build();
        when(client.listEvents(any(ListEventsRequest.class))).thenReturn(resp);
    }

    private void stubCreateEvent(String eventId) {
        var event = Event.builder().eventId(eventId).build();
        when(client.createEvent(any(CreateEventRequest.class)))
                .thenReturn(CreateEventResponse.builder().event(event).build());
    }
}
