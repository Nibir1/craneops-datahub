# ==========================================
# CRANEOPS-DATAHUB: MAKEFILE
# ==========================================

DC=docker-compose -f infra/docker-compose.yml

.PHONY: help setup up down logs clean shell-sql shell-sql-master wait-sql

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Targets:'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

setup: ## Copy .env.example to .env
	cp .env.example .env
	@echo "Environment file created. Please update .env if needed."

up: ## Start infrastructure (Detach mode)
	$(DC) up -d
	@echo "Infrastructure is spinning up..."
	@echo "Spark Master UI: http://localhost:8080"
	@echo "Waiting for SQL Server to initialize (this may take 30-60 seconds)..."
	@sleep 10
	@echo "Run 'make wait-sql' to check if SQL Server is ready"

down: ## Stop infrastructure
	$(DC) down

logs: ## View infrastructure logs
	$(DC) logs -f

# ==============================================================================
# SQL Server Management
# ==============================================================================

wait-sql: ## Wait for SQL Server to be fully ready
	@echo "Checking SQL Server readiness..."
	@until docker exec craneops-sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P YourStrong!Passw0rd -C -Q "SELECT 1" &>/dev/null; do \
		echo "SQL Server is still starting..."; \
		sleep 2; \
	done
	@echo "SQL Server is ready!"

shell-sql-master: ## Connect to SQL Server master database (fallback)
	docker exec -it craneops-sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P YourStrong!Passw0rd -C -No

shell-sql: ## Connect to CraneData database (after init completes)
	docker exec -it craneops-sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P YourStrong!Passw0rd -d CraneData -C -No

# ==============================================================================
# Data Generation
# ==============================================================================

gen-run: ## Run the Go Telemetry Generator (Simulates 10 Cranes)
	@echo "Starting Generator targeting port 8082..."
	cd src/generator && go run main.go

gen-flood: ## STRESS TEST: Simulate 100 Cranes
	@echo "⚠️  WARNING: High Load ⚠️"
	export CRANE_COUNT=100 && cd src/generator && go run main.go


# ==============================================================================
# Java Ingestion Service
# ==============================================================================

ingest-run: ## Start the Java Ingestion Service (Spring Boot)
	@echo "Starting Ingestion Service on port 8082..."
	export AZURE_STORAGE_CONNECTION_STRING="DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1;" && \
	cd src/ingestion && mvn spring-boot:run

ingest-build: ## Build the Java Ingestion Service (compile & package)
	@echo "Building Ingestion Service..."
	cd src/ingestion && mvn clean package -DskipTests

ingest-test: ## Run unit tests for the Ingestion Service
	@echo "Running Ingestion Service tests..."
	cd src/ingestion && mvn test


# ==============================================================================
# Maintenance & Debugging
# ==============================================================================

clean:
	@echo "Cleaning up ALL Docker resources..."
	$(DC) down -v --remove-orphans
	docker system prune -f
	@echo "Infrastructure and data cleaned."
	@echo "Cleaning Python cache..."
	find . -type d -name "__pycache__" -exec rm -rf {} +
	find . -type f -name "*.pyc" -delete
	find . -type f -name ".coverage" -delete
	@echo "✨ Clean complete."