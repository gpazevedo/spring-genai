package com.gpazevedo.spring_genai;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class JacksonCompatConfig {

	@Bean
	public com.fasterxml.jackson.databind.ObjectMapper objectMapper() {
		return new com.fasterxml.jackson.databind.ObjectMapper();
	}

}
