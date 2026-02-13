package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"
)

// Configuration Defaults
const (
	DefaultApiURL     = "http://localhost:8082/api/v1/telemetry"
	DefaultCraneCount = 10
	DefaultInterval   = 1000 * time.Millisecond // 1 second
)

// TelemetryEvent matches the Java DTO
type TelemetryEvent struct {
	CraneID      string  `json:"crane_id"`
	LiftWeightKg float64 `json:"lift_weight_kg"`
	MotorTempC   float64 `json:"motor_temp_c"`
	Timestamp    string  `json:"timestamp"`
}

func main() {
	// 1. Load Configuration
	// FIX: Changed from API_URL to INGESTION_URL to match the Makefile
	apiURL := getEnv("INGESTION_URL", DefaultApiURL)
	craneCount, _ := strconv.Atoi(getEnv("CRANE_COUNT", strconv.Itoa(DefaultCraneCount)))

	log.Printf("🚀 Starting Telemetry Generator")
	log.Printf("Target: %s", apiURL)
	log.Printf("Simulating %d Cranes...", craneCount)

	var wg sync.WaitGroup

	// 2. Spawn "Cranes" (Goroutines)
	for i := 1; i <= craneCount; i++ {
		wg.Add(1)
		craneID := fmt.Sprintf("CRANE-%03d", i)
		go simulateCrane(craneID, apiURL, &wg)
	}

	wg.Wait()
}

func simulateCrane(craneID string, apiURL string, wg *sync.WaitGroup) {
	defer wg.Done()

	client := &http.Client{
		Timeout: 5 * time.Second,
	}

	for {
		// 3. Generate Random Data
		// Weight: 0 to 5000 kg (occasionally heavy)
		weight := rand.Float64() * 5000

		// Temp: 40 to 120 C (occasionally overheating > 100)
		temp := 40.0 + (rand.Float64() * 80.0)

		event := TelemetryEvent{
			CraneID:      craneID,
			LiftWeightKg: mathRound(weight),
			MotorTempC:   mathRound(temp),
			Timestamp:    time.Now().UTC().Format(time.RFC3339),
		}

		// 4. Send Payload
		if err := sendTelemetry(client, apiURL, event); err != nil {
			log.Printf("[%s] ❌ Error: %v", craneID, err)
		} else {
			log.Printf("[%s] ✅ Sent: %.1fkg @ %.1fC", craneID, event.LiftWeightKg, event.MotorTempC)
		}

		// 5. Sleep with Jitter (0.5s - 1.5s)
		sleepDuration := time.Duration(500+rand.Intn(1000)) * time.Millisecond
		time.Sleep(sleepDuration)
	}
}

func sendTelemetry(client *http.Client, apiURL string, event TelemetryEvent) error {
	jsonData, err := json.Marshal(event)
	if err != nil {
		return err
	}

	resp, err := client.Post(apiURL, "application/json", bytes.NewBuffer(jsonData))
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusAccepted {
		return fmt.Errorf("status %d", resp.StatusCode)
	}

	return nil
}

// Helper: Round to 2 decimal places
func mathRound(val float64) float64 {
	return float64(int(val*100)) / 100
}

func getEnv(key, fallback string) string {
	if value, ok := os.LookupEnv(key); ok {
		return value
	}
	return fallback
}
