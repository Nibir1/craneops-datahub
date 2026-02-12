# ==========================================
# CRANEOPS-DATAHUB: PRODUCTION MAKEFILE
# ==========================================

DC=docker-compose -f infra/docker-compose.yml

# Load environment variables from .env file if it exists
ifneq (,$(wildcard ./.env))
    include .env
    export
endif

# Default password if not set in .env
MSSQL_SA_PASSWORD ?= YourStrong!Passw0rd

.PHONY: help setup up down logs clean \
        ingest-run ingest-build \
        gen-run gen-flood \
        spark-build prod-up prod-down prod-clean \
        etl-run etl-logs \
        azurite-bronze azurite-gold \
        wait-sql shell-sql sql-query

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Targets:'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

setup: ## Copy .env.example to .env
	cp .env.example .env
	@echo "✅ Environment file created"

# ==============================================================================
# INFRASTRUCTURE MANAGEMENT
# ==============================================================================

up: ## Start infrastructure (development mode)
	$(DC) up -d
	@echo "🚀 Infrastructure starting..."
	@echo "📊 Spark Master UI: http://localhost:8080"
	@echo "💾 SQL Server: localhost:${MSSQL_PORT}"
	@sleep 5
	@echo "⏳ Run 'make wait-sql' to check SQL readiness"

down: ## Stop infrastructure
	$(DC) down

logs: ## View infrastructure logs
	$(DC) logs -f

prod-up: spark-build ## Build & start production infrastructure
	@echo "🔨 Building production images..."
	$(DC) up -d --build
	@echo "✅ Production stack running"
	@echo "📊 Spark Master: http://localhost:8080"
	@echo "💾 Azurite Blob: http://localhost:10000"

prod-down: ## Stop production stack
	$(DC) down

prod-clean: ## Clean everything (volumes + images)
	@echo "🧹 Cleaning production stack..."
	$(DC) down -v --rmi local
	docker rmi craneops/spark-azure:3.5.7-v1 2>/dev/null || true
	docker volume prune -f
	@echo "✨ Clean complete"

# ==============================================================================
# DATA GENERATION (Go Generator)
# ==============================================================================

gen-run: ## Run Go Telemetry Generator (10 cranes)
	@echo "🎮 Starting Generator (port 8082)..."
	cd src/generator && go run main.go

gen-flood: ## Stress test (100 cranes)
	@echo "⚠️  HIGH LOAD: 100 cranes"
	export CRANE_COUNT=100 && cd src/generator && go run main.go

# ==============================================================================
# JAVA INGESTION SERVICE
# ==============================================================================

ingest-run: ## Start Spring Boot Ingestion Service
	@echo "☕ Starting Ingestion Service (port 8082)..."
	export AZURE_STORAGE_CONNECTION_STRING="DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=http://127.0.0.1:10000/devstoreaccount1 ;" && \
	cd src/ingestion && mvn spring-boot:run

ingest-build: ## Build Ingestion Service JAR
	cd src/ingestion && mvn clean package -DskipTests

# ==============================================================================
# SPARK ETL (PRODUCTION)
# ==============================================================================

SPARK_IMAGE=craneops/spark-azure:3.5.7-v1

spark-build: ## Build production Spark image (Includes MSSQL Driver now)
	@echo "🔨 Building Spark image with MSSQL Driver..."
	docker build -t $(SPARK_IMAGE) ./infra/spark
	@echo "✅ Built: $(SPARK_IMAGE)"

etl-run: ## Execute Medallion Architecture ETL
	@echo "🚀 Running ETL: Bronze → Silver → Gold → SQL"
	docker exec -e MSSQL_SA_PASSWORD="$(MSSQL_SA_PASSWORD)" craneops-spark-master /opt/spark/bin/spark-submit \
		--master spark://spark-master:7077 \
		--name "CraneOps-ETL" \
		--conf spark.executor.extraClassPath=/opt/spark/jars/azure/* \
		--conf spark.driver.extraClassPath=/opt/spark/jars/azure/* \
		/opt/spark/work-dir/etl_job.py

etl-logs: ## View Spark ETL logs
	docker logs -f craneops-spark-master

# ==============================================================================
# AZURITE STORAGE INSPECTION
# ==============================================================================

azurite-bronze: ## List Bronze layer (raw telemetry)
	@echo "📦 BRONZE LAYER (Raw JSON):"
	docker exec craneops-spark-master ls -la /data/__blobstorage__/ 2>/dev/null | head -20 || echo "No data"

azurite-gold: ## List Gold layer (aggregated KPIs)
	@echo "🏆 GOLD LAYER (Aggregated Data):"
	@echo "\n📁 Parquet files:"
	docker exec craneops-spark-master ls -la /data/telemetry-gold/daily_stats/ 2>/dev/null || echo "No Gold data yet"
	@echo "\n📁 JSON files:"
	docker exec craneops-spark-master ls -la /data/telemetry-gold/daily_stats_json/ 2>/dev/null || echo "No JSON export"

# ==============================================================================
# SQL SERVER
# ==============================================================================

wait-sql: ## Wait for SQL Server ready
	@echo "⏳ Waiting for SQL Server..."
	@until docker exec craneops-sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P '$(MSSQL_SA_PASSWORD)' -C -Q "SELECT 1" &>/dev/null; do \
		echo "   SQL Server still starting..."; sleep 3; \
	done
	@echo "✅ SQL Server ready"

shell-sql: ## Connect to CraneData database interactively
	@echo "🔌 Connecting to SQL Server (CraneData)..."
	docker exec -it craneops-sqlserver /opt/spark/bin/sqlcmd -S localhost -U sa -P '$(MSSQL_SA_PASSWORD)' -d CraneData -C -No

sql-query: ## Query DailyStats table directly
	@echo "📊 Querying DailyStats table..."
	docker exec craneops-sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P '$(MSSQL_SA_PASSWORD)' -d CraneData -C -Q "SELECT * FROM DailyStats;" -y 30 -Y 30

sql-count: ## Count records in DailyStats
	@echo "📊 Counting records..."
	docker exec craneops-sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P '$(MSSQL_SA_PASSWORD)' -d CraneData -C -Q "SELECT COUNT(*) as TotalRecords FROM DailyStats;"


# ==========================================
# CLOUD INFRASTRUCTURE (Terraform)
# ==========================================

infra-init: ## Initialize Terraform
	cd infra/terraform && terraform init

infra-plan: ## Plan Terraform deployment
	cd infra/terraform && terraform plan -var="sql_admin_password=$(MSSQL_SA_PASSWORD)"

infra-apply: ## Apply Terraform (Provision Azure Resources)
	cd infra/terraform && terraform apply -auto-approve -var="sql_admin_password=$(MSSQL_SA_PASSWORD)"
	@echo "✅ Azure Infrastructure Provisioned!"

infra-destroy: ## Destroy Azure Resources (Save Money)
	cd infra/terraform && terraform destroy -auto-approve -var="sql_admin_password=$(MSSQL_SA_PASSWORD)"
	@echo "🔥 Azure Infrastructure Destroyed."


# ==========================================
# CLOUD CONFIGURATION (From Terraform Outputs)
# ==========================================
# ⚠️  REPLACE THESE WITH YOUR ACTUAL VALUES
ACR_NAME=acrcraneopseinda8
ACR_LOGIN_SERVER=acrcraneopseinda8.azurecr.io

# Image Tags
TAG_INGEST=$(ACR_LOGIN_SERVER)/craneops-ingestion:latest
TAG_SPARK=$(ACR_LOGIN_SERVER)/craneops-spark:latest


# ==========================================
# CLOUD DELIVERY (CD)
# ==========================================

cloud-login: ## Log Docker into Azure Container Registry
	@echo "🔑 Logging into Azure..."
	az acr login --name $(ACR_NAME)

cloud-build: ## Build Docker images for Cloud (amd64/linux)
	@echo "📦 Building Ingestion Service..."
	# We use Buildx to ensure compatibility with Cloud (Linux/AMD64)
	docker build --platform linux/amd64 -t $(TAG_INGEST) ./src/ingestion
	
	@echo "📦 Building Spark Processing Engine..."
	docker build --platform linux/amd64 -t $(TAG_SPARK) ./infra/spark

cloud-push: cloud-build ## Push images to Azure Container Registry
	@echo "🚀 Pushing Ingestion Service..."
	docker push $(TAG_INGEST)
	
	@echo "🚀 Pushing Spark Engine..."
	docker push $(TAG_SPARK)
	
	@echo "✅ Images deployed to $(ACR_LOGIN_SERVER)"


# ==========================================
# CLOUD DATABASE (Azure SQL)
# ==========================================

# Variables required for Cloud SQL
CLOUD_SQL_HOST=$(shell cd infra/terraform && terraform output -raw sql_server_fqdn)
CLOUD_SQL_USER=craneadmin
# We reuse the same password from .env used in Terraform
CLOUD_SQL_PASS=$(MSSQL_SA_PASSWORD)

db-init-cloud: ## Run Schema Init on Azure SQL
	@echo "🚀 Initializing Cloud Database Schema at $(CLOUD_SQL_HOST)..."
	@echo "   (This uses the local SQL Server container to connect to Azure)"
	docker exec craneops-sqlserver /opt/mssql-tools18/bin/sqlcmd \
		-S $(CLOUD_SQL_HOST) \
		-U $(CLOUD_SQL_USER) \
		-P '$(CLOUD_SQL_PASS)' \
		-d CraneData \
		-C \
		-i /tmp/sql/cloud_init.sql \
		|| echo "⚠️  Failed? Ensure 'make up' is running so we can use the local container client."

sql-query-cloud: ## Query DailyStats on Azure SQL
	@echo "☁️  Querying Azure SQL Database..."
	docker exec craneops-sqlserver /opt/mssql-tools18/bin/sqlcmd \
		-S $(CLOUD_SQL_HOST) \
		-U $(CLOUD_SQL_USER) \
		-P '$(CLOUD_SQL_PASS)' \
		-d CraneData \
		-C \
		-Q "SELECT TOP 10 * FROM DailyStats;" \
		-y 30 -Y 30

sql-check-cloud: ## Connectivity Check
	@echo "🔌 Checking connection to Azure SQL..."
	docker exec craneops-sqlserver /opt/mssql-tools18/bin/sqlcmd \
		-S $(CLOUD_SQL_HOST) \
		-U $(CLOUD_SQL_USER) \
		-P '$(CLOUD_SQL_PASS)' \
		-d CraneData \
		-C \
		-Q "SELECT @@VERSION as SQLVersion;"

# ==============================================================================
# TESTING & QUALITY ASSURANCE
# ==============================================================================

venv-setup: ## Create Python venv and install dependencies
	cd src/processing && \
	python3.11 -m venv .venv && \
	source .venv/bin/activate && \
	pip install --upgrade pip && \
	pip install -e . && \
	pip install pytest && \
	echo "✅ Python virtual environment ready"

venv-test: ## Run Python tests in venv
	cd src/processing && \
	source .venv/bin/activate && \
	pytest tests/

test-java: ## Run Java unit tests (Maven)
	@echo "☕ Running Java tests..."
	cd src/ingestion && mvn test

test-python: venv-setup ## Setup venv and run Python tests
	@echo "🐍 Running Python tests..."
	cd src/processing && \
	source .venv/bin/activate && \
	pytest tests/

test-all: test-python test-java ## Run all tests (Python + Java)
	@echo "✅ All tests completed successfully!"

ci-test: ## CI/CD test command (no venv setup, assumes ready)
	cd src/processing && source .venv/bin/activate && pytest tests/
	cd src/ingestion && mvn test

# ==============================================================================
# MAINTENANCE
# ==============================================================================

clean: ## Clean all Docker resources
	@echo "🧹 Cleaning..."
	$(DC) down -v --remove-orphans
	docker system prune -f
	find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete 2>/dev/null || true
	@echo "✨ Clean complete"