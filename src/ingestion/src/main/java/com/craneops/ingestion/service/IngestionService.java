package com.craneops.ingestion.service;

import com.azure.storage.blob.BlobContainerClient;
import com.azure.storage.blob.BlobServiceClient;
import com.azure.storage.blob.BlobClient;
import com.craneops.ingestion.dto.TelemetryEvent;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.UUID;

@Service
@Slf4j
public class IngestionService {

    private final BlobContainerClient containerClient;
    private final ObjectMapper objectMapper;
    
    // Formatter for partitioning data: year/month/day
    private static final DateTimeFormatter DATE_FORMATTER = DateTimeFormatter.ofPattern("yyyy/MM/dd")
            .withZone(ZoneId.of("UTC"));

    public IngestionService(BlobServiceClient blobServiceClient, 
                            @Value("${spring.cloud.azure.storage.blob.container-name}") String containerName,
                            ObjectMapper objectMapper) {
        this.objectMapper = objectMapper;
        
        // Initialize container client and ensure container exists (Lazy Initialization)
        this.containerClient = blobServiceClient.getBlobContainerClient(containerName);
        if (!containerClient.exists()) {
            log.info("Container {} does not exist. Creating...", containerName);
            containerClient.create();
        }
    }

    public void processEvent(TelemetryEvent event) {
        try {
            // 1. Serialize payload to JSON
            String jsonPayload = objectMapper.writeValueAsString(event);
            byte[] data = jsonPayload.getBytes(StandardCharsets.UTF_8);

            // 2. Generate Partitioned File Path (Hive Style: year/month/day/filename)
            // Example: 2024/02/20/CRANE01-1708453221-uuid.json
            String datePath = DATE_FORMATTER.format(event.getTimestamp());
            String fileName = String.format("%s/%s-%s-%s.json",
                    datePath,
                    event.getCraneId(),
                    event.getTimestamp().toEpochMilli(),
                    UUID.randomUUID().toString().substring(0, 8));

            // 3. Upload to Blob Storage
            BlobClient blobClient = containerClient.getBlobClient(fileName);
            blobClient.upload(new ByteArrayInputStream(data), data.length, true);

            log.debug("Ingested event for crane: {} to path: {}", event.getCraneId(), fileName);

        } catch (Exception e) {
            log.error("Failed to ingest event for crane: {}", event.getCraneId(), e);
            throw new RuntimeException("Storage Ingestion Failed", e);
        }
    }
}