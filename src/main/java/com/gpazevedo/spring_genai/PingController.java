package com.gpazevedo.spring_genai;

import java.time.Instant;
import java.util.Map;

import org.springframework.boot.health.actuate.endpoint.HealthEndpoint;
import org.springframework.boot.health.contributor.Status;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class PingController {

    private final HealthEndpoint healthEndpoint;

    public PingController(HealthEndpoint healthEndpoint) {
        this.healthEndpoint = healthEndpoint;
    }

    @GetMapping("/ping")
    public Map<String, Object> ping() {
        Status status = healthEndpoint.health().getStatus();
        String agentCoreStatus = Status.UP.equals(status) ? "Healthy" : "Unhealthy";
        return Map.of(
                "status", agentCoreStatus,
                "time_of_last_update", Instant.now().getEpochSecond());
    }
}
