package com.craneops.ingestion;

import com.azure.storage.blob.BlobClient;
import com.azure.storage.blob.BlobContainerClient;
import com.azure.storage.blob.BlobServiceClient;
import com.craneops.ingestion.dto.TelemetryEvent;
import com.craneops.ingestion.service.IngestionService;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.MockitoAnnotations;

import java.io.InputStream;
import java.time.Instant;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.*;

class IngestionServiceTest {

    @Mock
    private BlobServiceClient blobServiceClient;

    @Mock
    private BlobContainerClient containerClient;

    @Mock
    private BlobClient blobClient;

    private IngestionService ingestionService;
    private ObjectMapper objectMapper;

    @BeforeEach
    void setUp() {
        MockitoAnnotations.openMocks(this);

        // Configure ObjectMapper to handle Java 8 date/time
        objectMapper = new ObjectMapper();
        objectMapper.registerModule(new JavaTimeModule());
        objectMapper.disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);

        // Mock the Azure SDK hierarchy
        when(blobServiceClient.getBlobContainerClient(anyString())).thenReturn(containerClient);
        when(containerClient.exists()).thenReturn(true);
        when(containerClient.getBlobClient(anyString())).thenReturn(blobClient);

        // Initialize service
        ingestionService = new IngestionService(blobServiceClient, "telemetry-raw", objectMapper);
    }

    @Test
    void processEvent_ShouldUploadToBlobStorage() {
        // Arrange
        TelemetryEvent event = new TelemetryEvent(
                "CRANE-TEST",
                100.0,
                50.0,
                Instant.parse("2024-01-01T12:00:00Z"));

        // Act & Assert
        assertDoesNotThrow(() -> ingestionService.processEvent(event));

        // Verify that upload was called
        verify(blobClient, times(1)).upload(any(InputStream.class), anyLong(), eq(true));

        // Verify path generation (Hive Style: 2024/01/01/...)
        ArgumentCaptor<String> fileNameCaptor = ArgumentCaptor.forClass(String.class);
        verify(containerClient).getBlobClient(fileNameCaptor.capture());

        String actualFileName = fileNameCaptor.getValue();
        // Path should start with date partition
        assertTrue(actualFileName.startsWith("2024/01/01/CRANE-TEST"));
    }
}