package com.gpazevedo.spring_genai;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import software.amazon.awssdk.awscore.exception.AwsServiceException;
import software.amazon.awssdk.core.exception.SdkClientException;

import java.util.Map;

/**
 * Maps AWS SDK and general exceptions to structured HTTP error responses.
 */
@RestControllerAdvice
class GlobalExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(GlobalExceptionHandler.class);

    @ExceptionHandler(AwsServiceException.class)
    ResponseEntity<Map<String, String>> handleAwsService(AwsServiceException ex) {
        HttpStatus status = switch (ex.statusCode()) {
            case 400 -> HttpStatus.BAD_REQUEST;
            case 403 -> HttpStatus.FORBIDDEN;
            case 404 -> HttpStatus.NOT_FOUND;
            case 429 -> HttpStatus.TOO_MANY_REQUESTS;
            case 503 -> HttpStatus.SERVICE_UNAVAILABLE;
            default -> HttpStatus.INTERNAL_SERVER_ERROR;
        };
        log.error("AWS service error [{}]: {}", ex.statusCode(), ex.awsErrorDetails().errorMessage());
        return ResponseEntity.status(status)
                .body(Map.of("error", ex.awsErrorDetails().errorMessage()));
    }

    @ExceptionHandler(SdkClientException.class)
    ResponseEntity<Map<String, String>> handleSdkClient(SdkClientException ex) {
        log.error("AWS SDK client error: {}", ex.getMessage());
        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE)
                .body(Map.of("error", "Upstream AWS service unreachable"));
    }

    @ExceptionHandler(IllegalArgumentException.class)
    ResponseEntity<Map<String, String>> handleBadRequest(IllegalArgumentException ex) {
        return ResponseEntity.status(HttpStatus.BAD_REQUEST)
                .body(Map.of("error", ex.getMessage()));
    }
}
