package com.gpazevedo.spring_genai;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties("agentcore.memory")
record AgentCoreMemoryProperties(String memoryId) {}
