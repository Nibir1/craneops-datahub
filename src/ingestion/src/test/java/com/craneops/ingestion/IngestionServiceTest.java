package com.craneops.ingestion;

import com.azure.storage.blob.BlobClient;
import com.azure.storage.blob.BlobContainerClient;
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
import org.springframework.test.util.ReflectionTestUtils; // Required for Field Injection

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

    // We no longer need BlobServiceClient mock because we inject the
    // ContainerClient directly
    @Mock
    private BlobContainerClient containerClient;

    @Mock
    private BlobClient blobClient;

    private IngestionService ingestionService;
    private ObjectMapper objectMapper;

    @BeforeEach
    void setUp() {
        MockitoAnnotations.openMocks(this);

        // 1. Setup Jackson for Java Time (Instant)
        objectMapper = new ObjectMapper();
        objectMapper.registerModule(new JavaTimeModule());
        objectMapper.disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);

        // 2. Initialize Service using the REAL constructor (only takes ObjectMapper
        // now)
        ingestionService = new IngestionService(objectMapper);

        // 3. Setup Azure SDK Mocks
        // When service asks for a blob client (file), give the mock blob client
        when(containerClient.getBlobClient(anyString())).thenReturn(blobClient);

        // 4. FORCE INJECT THE MOCK (The Magic Fix)
        // Since we removed the test constructor, we use ReflectionTestUtils
        // to set the private 'containerClient' field directly.
        // This bypasses the init() method and complex connection logic.
        ReflectionTestUtils.setField(ingestionService, "containerClient", containerClient);
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
        // This will succeed because 'containerClient' is populated via Reflection above
        assertDoesNotThrow(() -> ingestionService.processEvent(event));

        // Verify that upload was called on the mock blob client
        verify(blobClient, times(1)).upload(any(InputStream.class), anyLong(), eq(true));

        // Verify path generation (Hive Style: 2024/01/01/...)
        ArgumentCaptor<String> fileNameCaptor = ArgumentCaptor.forClass(String.class);
        verify(containerClient).getBlobClient(fileNameCaptor.capture());

        String actualFileName = fileNameCaptor.getValue();
        // Path should start with date partition
        assertTrue(actualFileName.startsWith("2024/01/01/CRANE-TEST"));
    }
}