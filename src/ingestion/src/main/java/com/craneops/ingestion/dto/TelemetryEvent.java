package com.craneops.ingestion.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;
import jakarta.validation.constraints.Pattern;
import lombok.Data;
import lombok.NoArgsConstructor;
import lombok.AllArgsConstructor;

import java.time.Instant;

@Data
@NoArgsConstructor
@AllArgsConstructor
public class TelemetryEvent {

    @NotNull(message = "Crane ID is required")
    @Pattern(regexp = "^[A-Z0-9-]+$", message = "Crane ID must be alphanumeric/dashes")
    @JsonProperty("crane_id")
    private String craneId;

    @Positive(message = "Lift weight must be positive")
    @JsonProperty("lift_weight_kg")
    private Double liftWeightKg;

    @NotNull(message = "Motor temperature is required")
    @JsonProperty("motor_temp_c")
    private Double motorTempC;

    @NotNull(message = "Timestamp is required")
    @JsonProperty("timestamp")
    private Instant timestamp;
}