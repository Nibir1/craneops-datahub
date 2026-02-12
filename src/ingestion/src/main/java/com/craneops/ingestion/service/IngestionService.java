package com.craneops.ingestion.service;

import com.azure.identity.DefaultAzureCredentialBuilder;
import com.azure.storage.blob.BlobClient;
import com.azure.storage.blob.BlobContainerClient;
import com.azure.storage.blob.BlobServiceClient;
import com.azure.storage.blob.BlobServiceClientBuilder;
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

    private static final DateTimeFormatter DATE_FORMATTER = DateTimeFormatter.ofPattern("yyyy/MM/dd")
            .withZone(ZoneId.of("UTC"));

    // --------------------------------------------------------------------------------
    // CONSTRUCTOR 1: Spring Boot (Production)
    // Handles the "Connection String vs Managed Identity" decision
    // --------------------------------------------------------------------------------
    public IngestionService(
            @Value("${spring.cloud.azure.storage.blob.connection-string:}") String connectionString,
            @Value("${spring.cloud.azure.storage.blob.container-name}") String containerName,
            @Value("${AZURE_STORAGE_ACCOUNT_NAME:}") String accountName,
            ObjectMapper objectMapper) {

        // Delegate to the helper to create the client, then pass to the main logic
        // constructor
        this(createClient(connectionString, accountName), containerName, objectMapper);
    }

    // --------------------------------------------------------------------------------
    // CONSTRUCTOR 2: Testing (Unit Tests)
    // Allows injecting a Mock BlobServiceClient directly
    // --------------------------------------------------------------------------------
    public IngestionService(BlobServiceClient blobServiceClient, String containerName, ObjectMapper objectMapper) {
        this.objectMapper = objectMapper;
        this.containerClient = blobServiceClient.getBlobContainerClient(containerName);

        // Ensure container exists (Idempotent)
        if (!containerClient.exists()) {
            log.info("Container {} does not exist. Creating...", containerName);
            containerClient.create();
        }
    }

    // Helper to determine which authentication method to use
    private static BlobServiceClient createClient(String connectionString, String accountName) {
        if (connectionString != null && !connectionString.isEmpty()) {
            log.info("🔌 Using Connection String for Blob Storage");
            return new BlobServiceClientBuilder()
                    .connectionString(connectionString)
                    .buildClient();
        } else if (accountName != null && !accountName.isEmpty()) {
            log.info("☁️ Using Managed Identity for Blob Storage");
            String endpoint = String.format("https://%s.blob.core.windows.net", accountName);
            return new BlobServiceClientBuilder()
                    .endpoint(endpoint)
                    .credential(new DefaultAzureCredentialBuilder().build())
                    .buildClient();
        } else {
            throw new IllegalStateException("Misconfiguration: Neither Connection String nor Account Name provided.");
        }
    }

    // --------------------------------------------------------------------------------
    // Business Logic
    // --------------------------------------------------------------------------------
    public void processEvent(TelemetryEvent event) {
        try {
            String jsonPayload = objectMapper.writeValueAsString(event);
            byte[] data = jsonPayload.getBytes(StandardCharsets.UTF_8);

            String datePath = DATE_FORMATTER.format(event.getTimestamp());
            String fileName = String.format("%s/%s-%s-%s.json",
                    datePath,
                    event.getCraneId(),
                    event.getTimestamp().toEpochMilli(),
                    UUID.randomUUID().toString().substring(0, 8));

            BlobClient blobClient = containerClient.getBlobClient(fileName);
            blobClient.upload(new ByteArrayInputStream(data), data.length, true);

            log.debug("Ingested event for crane: {} to path: {}", event.getCraneId(), fileName);

        } catch (Exception e) {
            log.error("Failed to ingest event for crane: {}", event.getCraneId(), e);
            throw new RuntimeException("Storage Ingestion Failed", e);
        }
    }
}