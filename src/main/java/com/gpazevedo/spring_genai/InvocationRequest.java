package com.gpazevedo.spring_genai;

public record InvocationRequest(Input input) {

    public record Input(String prompt) {
    }
}
