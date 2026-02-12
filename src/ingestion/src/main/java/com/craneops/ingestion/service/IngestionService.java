package com.craneops.ingestion.service;

import com.azure.identity.DefaultAzureCredentialBuilder;
import com.azure.storage.blob.BlobClient;
import com.azure.storage.blob.BlobContainerClient;
import com.azure.storage.blob.BlobServiceClient;
import com.azure.storage.blob.BlobServiceClientBuilder;
import com.craneops.ingestion.dto.TelemetryEvent;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.annotation.PostConstruct;
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

    // 1. Inject properties directly into fields (Safest method for optional values)
    @Value("${AZURE_STORAGE_CONNECTION_STRING:#{null}}")
    private String connectionString;

    @Value("${AZURE_STORAGE_ACCOUNT:#{null}}")
    private String accountName;

    @Value("${AZURE_CONTAINER_NAME:telemetry-raw}")
    private String containerName;

    private final ObjectMapper objectMapper;
    private BlobContainerClient containerClient;

    private static final DateTimeFormatter DATE_FORMATTER = DateTimeFormatter.ofPattern("yyyy/MM/dd")
            .withZone(ZoneId.of("UTC"));

    // Constructor for Dependency Injection (ObjectMapper only)
    public IngestionService(ObjectMapper objectMapper) {
        this.objectMapper = objectMapper;
    }

    // 2. Initialize logic runs AFTER dependency injection
    @PostConstruct
    public void init() {
        log.info("🚀 IngestionService: Initializing Storage Client...");

        try {
            BlobServiceClient blobServiceClient = null;

            // STRATEGY 1: Connection String (Local Development)
            // We verify it's not null, not empty, AND NOT our "fake" infra override key.
            if (connectionString != null && !connectionString.isEmpty()
                    && !connectionString.contains("AccountKey=fake")) {
                log.info("🔌 Strategy: Using Connection String (Local/Dev Mode)");
                blobServiceClient = new BlobServiceClientBuilder()
                        .connectionString(connectionString)
                        .buildClient();
            }
            // STRATEGY 2: Managed Identity (Production Cloud)
            else if (accountName != null && !accountName.isEmpty()) {
                log.info("☁️ Strategy: Using Managed Identity (Production Mode: {})", accountName);
                String endpoint = String.format("https://%s.blob.core.windows.net", accountName);

                blobServiceClient = new BlobServiceClientBuilder()
                        .endpoint(endpoint)
                        .credential(new DefaultAzureCredentialBuilder().build())
                        .buildClient();
            } else {
                log.error("❌ CRITICAL: No valid Storage configuration found! Check Env Vars.");
                throw new IllegalStateException("Storage Misconfiguration");
            }

            // Initialize the Container Client
            this.containerClient = blobServiceClient.getBlobContainerClient(containerName);

            // 3. Connectivity Check (Fail fast if permissions are wrong)
            if (!this.containerClient.exists()) {
                log.info("📦 Container '{}' does not exist. Attempting creation...", containerName);
                this.containerClient.create();
            }
            log.info("✅ Storage Connection Established: {}", containerName);

        } catch (Exception e) {
            log.error("⚠️ Storage Initialization Warning: {}", e.getMessage());
            // We catch but don't rethrow to ensure the Spring Boot app can START UP.
            // This prevents the "Crash Loop" if Azure permissions take a few seconds to
            // propagate.
        }
    }

    // --------------------------------------------------------------------------------
    // Business Logic
    // --------------------------------------------------------------------------------
    public void processEvent(TelemetryEvent event) {
        if (containerClient == null) {
            throw new IllegalStateException("Storage Client is not initialized. Check startup logs.");
        }

        try {
            String jsonPayload = objectMapper.writeValueAsString(event);
            byte[] data = jsonPayload.getBytes(StandardCharsets.UTF_8);

            // Partitioning Path: yyyy/MM/dd/craneID-timestamp-uuid.json
            String datePath = DATE_FORMATTER.format(event.getTimestamp());
            String fileName = String.format("%s/%s-%s-%s.json",
                    datePath,
                    event.getCraneId(),
                    event.getTimestamp().toEpochMilli(),
                    UUID.randomUUID().toString().substring(0, 8));

            BlobClient blobClient = containerClient.getBlobClient(fileName);
            blobClient.upload(new ByteArrayInputStream(data), data.length, true);

            log.debug("✅ Ingested event for crane: {} to path: {}", event.getCraneId(), fileName);

        } catch (Exception e) {
            log.error("❌ Failed to ingest event for crane: {}", event.getCraneId(), e);
            throw new RuntimeException("Storage Ingestion Failed", e);
        }
    }
}