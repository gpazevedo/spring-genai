package com.gpazevedo.spring_genai;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;
import software.amazon.awssdk.auth.credentials.AwsCredentialsProvider;
import software.amazon.awssdk.core.exception.SdkException;

@Component
public class AwsCredentialsCheck {

    private static final Logger log = LoggerFactory.getLogger(AwsCredentialsCheck.class);

    private final AwsCredentialsProvider credentialsProvider;

    public AwsCredentialsCheck(AwsCredentialsProvider credentialsProvider) {
        this.credentialsProvider = credentialsProvider;
    }

    @EventListener(ApplicationReadyEvent.class)
    public void checkCredentials() {
        try {
            var credentials = credentialsProvider.resolveCredentials();
            if (credentials.accessKeyId() == null || credentials.accessKeyId().isBlank()) {
                log.warn("AWS credentials resolved but access key is empty. "
                        + "Bedrock API calls will fail. "
                        + "Set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY environment variables "
                        + "or configure ~/.aws/credentials");
            } else {
                log.info("AWS credentials available (access key: {}...)",
                        credentials.accessKeyId().substring(0, Math.min(4, credentials.accessKeyId().length())));
            }
        } catch (SdkException e) {
            log.warn("AWS credentials not found: {}. "
                    + "Bedrock API calls will fail. "
                    + "Set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY environment variables "
                    + "or configure ~/.aws/credentials", e.getMessage());
        }
    }
}
