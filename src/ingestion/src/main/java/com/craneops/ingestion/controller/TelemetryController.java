package com.craneops.ingestion.controller;

import com.craneops.ingestion.dto.TelemetryEvent;
import com.craneops.ingestion.service.IngestionService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.Map;

@RestController
@RequestMapping("/api/v1/telemetry")
@RequiredArgsConstructor
@Slf4j
public class TelemetryController {

    private final IngestionService ingestionService;

    @PostMapping
    public ResponseEntity<Map<String, String>> ingestTelemetry(@Valid @RequestBody TelemetryEvent event) {
        log.info("Received telemetry from crane: {}", event.getCraneId());
        
        ingestionService.processEvent(event);
        
        return ResponseEntity.status(HttpStatus.CREATED)
                .body(Map.of("status", "accepted", "id", event.getCraneId()));
    }
    
    @GetMapping("/health")
    public ResponseEntity<String> health() {
        return ResponseEntity.ok("Ingestion Service is Healthy");
    }
}