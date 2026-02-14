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

# ==========================================
# TERRAFORM REMOTE STATE VARIABLES
# ==========================================
TF_STATE_RG=rg-craneops-tfstate
TF_STATE_STORAGE=stcraneopstfstate7788
TF_STATE_CONTAINER=tfstate
LOCATION=swedencentral

.PHONY: help setup up down logs clean \
        ingest-run ingest-build \
        gen-run gen-flood \
        spark-build prod-up prod-down prod-clean \
        etl-run etl-logs \
        azurite-bronze azurite-gold \
        wait-sql shell-sql sql-query \
        infra-backend infra-init infra-apply infra-destroy \
        db-init-cloud sql-query-cloud sql-check-cloud \
        cloud-etl-run cloud-login

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Targets:'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

setup: ## Copy .env.example to .env
	cp .env.example .env
	@echo "Environment file created"

# ==============================================================================
# INFRASTRUCTURE MANAGEMENT (LOCAL)
# ==============================================================================

up: ## Start infrastructure (development mode)
	@echo "Preparing Spark build context..."
	# Copy the Python script so Docker can find it during build
	cp src/processing/src/etl_job.py infra/spark/
	
	$(DC) up -d --build
	
	# Clean up the temp file
	rm infra/spark/etl_job.py
	
	@echo "Infrastructure starting..."
	@sleep 5
	@echo "Run 'make wait-sql' to check SQL readiness"

down: ## Stop infrastructure
	$(DC) down

logs: ## View infrastructure logs
	$(DC) logs -f

# ==============================================================================
# DATA GENERATION & INGESTION (LOCAL)
# ==============================================================================

gen-run: ## Run Go Telemetry Generator
	cd src/generator && go run main.go

ingest-run: ## Start Spring Boot Ingestion Service
	cd src/ingestion && mvn spring-boot:run

# ==============================================================================
# SPARK ETL (LOCAL HELPER)
# ==============================================================================

SPARK_IMAGE=craneops/spark-azure:3.5.7-v1

spark-build: ## Build production Spark image
	@echo "🔨 Building Spark image..."
	# FIX: Copy file here too
	cp src/processing/src/etl_job.py infra/spark/
	docker build -t $(SPARK_IMAGE) ./infra/spark
	rm infra/spark/etl_job.py
	@echo "Built: $(SPARK_IMAGE)"

# ==============================================================================
# CLOUD INFRASTRUCTURE (PRODUCTION BOOTSTRAP)
# ==============================================================================

cloud-login: ## Authenticate to Azure and lock Subscription ID
	@echo "Opening browser to log into Azure..."
	az login
	@echo "Fetching active Subscription ID..."
	@SUB_ID=$$(az account show --query id -o tsv) && \
	echo "Found Subscription: $$SUB_ID" && \
	grep -v '^ARM_SUBSCRIPTION_ID=' .env > .env.tmp 2>/dev/null || touch .env.tmp && \
	echo "ARM_SUBSCRIPTION_ID=$$SUB_ID" >> .env.tmp && \
	mv .env.tmp .env
	@echo "Azure Subscription locked into .env file. You are ready to deploy!"

cloud-cicd-sp: ## Create Azure Service Principal for GitHub Actions
	@echo "Creating CI/CD Service Principal..."
	@SUB_ID=$$(az account show --query id -o tsv) && \
	az ad sp create-for-rbac --name "sp-craneops-github-cicd" --role contributor --scopes /subscriptions/$$SUB_ID --json-auth
	@echo "COPY THE ENTIRE JSON OUTPUT ABOVE AND ADD IT TO GITHUB SECRETS AS 'AZURE_CREDENTIALS'"

infra-backend: ## Create Remote Terraform State Vault (Run Once)
	@echo "Provisioning Terraform Remote State Vault..."
	az group create --name $(TF_STATE_RG) --location $(LOCATION) -o none
	az storage account create --name $(TF_STATE_STORAGE) --resource-group $(TF_STATE_RG) --sku Standard_LRS --encryption-services blob -o none
	az storage container create --name $(TF_STATE_CONTAINER) --account-name $(TF_STATE_STORAGE) --auth-mode login -o none
	@echo "Remote State Backend successfully provisioned!"

infra-init: ## Initialize Terraform and migrate state to Cloud
	cd infra/terraform && terraform init -upgrade

infra-apply: ## 100% Automated Production Bootstrap (Phased)
	@echo "PHASE 1: Provisioning Registry & Storage..."
	cd infra/terraform && terraform apply -target=azurerm_container_registry.acr -target=azurerm_storage_account.adls -auto-approve -var="sql_admin_password=$(MSSQL_SA_PASSWORD)"
	
	@echo "PHASE 2: Docker Authentication & Image Push..."
	@# Use Shell variables ($$) so they run AFTER Phase 1 finishes
	@cd infra/terraform && \
	ACR_NAME=$$(terraform output -raw acr_name) && \
	ACR_SERVER=$$(terraform output -raw acr_login_server) && \
	echo "Detected ACR: $$ACR_NAME" && \
	az acr login --name $$ACR_NAME && \
	cd ../.. && \
	echo "Building & Pushing Production Images (v2)..." && \
	cp ./src/processing/src/etl_job.py ./infra/spark/ && \
	docker build --platform linux/amd64 -t $$ACR_SERVER/craneops-ingestion:v2 ./src/ingestion && \
	docker build --platform linux/amd64 -t $$ACR_SERVER/craneops-spark:latest ./infra/spark && \
	docker push $$ACR_SERVER/craneops-ingestion:v2 && \
	docker push $$ACR_SERVER/craneops-spark:latest && \
	rm ./infra/spark/etl_job.py
	
	@echo "Provisioning Compute, Networking & SQL..."
	cd infra/terraform && terraform apply -auto-approve -var="sql_admin_password=$(MSSQL_SA_PASSWORD)"
	@echo "Production Infrastructure is 100% Ready!"

infra-destroy: ## Destroy Azure Resources
	cd infra/terraform && terraform destroy -auto-approve -var="sql_admin_password=$(MSSQL_SA_PASSWORD)"
	@echo "Azure Infrastructure Destroyed."

# ==========================================
# CLOUD DATABASE (Azure SQL)
# ==========================================

CLOUD_SQL_HOST=$(shell cd infra/terraform && terraform output -raw sql_server_fqdn 2>/dev/null)
CLOUD_SQL_USER=craneadmin
CLOUD_SQL_PASS=$(MSSQL_SA_PASSWORD)

db-init-cloud: ## Run Schema Init on Azure SQL
	@echo "Initializing Cloud Database Schema..."
	docker exec craneops-sqlserver /opt/mssql-tools18/bin/sqlcmd \
		-S $(CLOUD_SQL_HOST) -U $(CLOUD_SQL_USER) -P '$(CLOUD_SQL_PASS)' \
		-d CraneData -C -i /tmp/sql/cloud_init.sql

sql-query-cloud: ## Query DailyStats on Azure SQL
	@echo "Querying Azure SQL Database..."
	docker exec craneops-sqlserver /opt/mssql-tools18/bin/sqlcmd \
		-S $(CLOUD_SQL_HOST) -U $(CLOUD_SQL_USER) -P '$(CLOUD_SQL_PASS)' \
		-d CraneData -C -Q "SELECT TOP 10 * FROM DailyStats;" -y 30 -Y 30

show-sql-creds: ## Show Azure SQL credentials for Power BI
	@echo "Azure SQL Credentials for Power BI:"
	@echo "-------------------------------------------------"
	@echo "Server:   $$(cd infra/terraform && terraform output -raw sql_server_fqdn)"
	@echo "Database: CraneData"
	@echo "Username: $(CLOUD_SQL_USER)"
	@echo "Password: $(CLOUD_SQL_PASS)"
	@echo "-------------------------------------------------"

# ==========================================
# CLOUD ETL (Serverless Spark)
# ==========================================

RG_NAME=rg-craneops-dev
JOB_NAME=job-craneops-etl

cloud-etl-run: ## Trigger the Spark ETL Job in Azure
	@echo "Triggering Serverless Spark Job..."
	az containerapp job start --name $(JOB_NAME) --resource-group $(RG_NAME)
	@echo "Job started! Run 'az containerapp job execution list' to check status."

# ==========================================
# ENTERPRISE ORCHESTRATION (ADF) & LOAD TESTING
# ==========================================

gen-cloud: ## Run Go Generator against Azure Cloud App
	@echo "Pumping telemetry to Azure Cloud..."
	@APP_URL=$$(cd infra/terraform && terraform output -raw ingestion_app_url) && \
	cd src/generator && INGESTION_URL="https://$$APP_URL/api/v1/telemetry" go run main.go

cloud-adf-run: ## Trigger the Azure Data Factory Pipeline
	@echo "Triggering ADF Pipeline (pl_daily_crane_etl)..."
	@ADF_NAME=$$(cd infra/terraform && terraform output -raw adf_name 2>/dev/null) && \
	az datafactory pipeline create-run \
		--resource-group $(RG_NAME) \
		--factory-name $$ADF_NAME \
		--name pl_daily_crane_etl
	@echo "Pipeline triggered! The Spark Job will start shortly."


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