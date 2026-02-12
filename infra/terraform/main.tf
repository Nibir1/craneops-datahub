# 1. Resource Group
resource "azurerm_resource_group" "rg" {
  name     = "rg-${var.project_name}-dev"
  location = var.location
}

# 2. Random ID for globally unique names (Storage/ACR)
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# 3. Azure Container Registry (ACR) - Basic SKU (Cheapest)
resource "azurerm_container_registry" "acr" {
  name                = "acr${var.project_name}${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = true # Simplified auth for Phase 8
}

# 4. Azure Data Lake Storage Gen2 (ADLS)
resource "azurerm_storage_account" "adls" {
  name                     = "st${var.project_name}${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS" # Cheapest redundancy
  account_kind             = "StorageV2"
  is_hns_enabled           = true  # Enables Hierarchical Namespace (Data Lake)
}

# Create Containers
resource "azurerm_storage_container" "bronze" {
  name                  = "telemetry-raw"
  storage_account_name  = azurerm_storage_account.adls.name
  container_access_type = "private"
}

resource "azurerm_storage_container" "gold" {
  name                  = "telemetry-gold"
  storage_account_name  = azurerm_storage_account.adls.name
  container_access_type = "private"
}

# 5. Azure SQL Database (Serverless)
resource "azurerm_mssql_server" "sqlserver" {
  name                         = "sql-${var.project_name}-${random_string.suffix.result}"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = azurerm_resource_group.rg.location
  version                      = "12.0"
  administrator_login          = var.sql_admin_username
  administrator_login_password = var.sql_admin_password
}

resource "azurerm_mssql_database" "sqldb" {
  name      = "CraneData"
  server_id = azurerm_mssql_server.sqlserver.id
  collation = "SQL_Latin1_General_CP1_CI_AS"
  
  # Serverless Config: Auto-pause after 1 hour (60 mins) to save money
  sku_name                    = "GP_S_Gen5_1" 
  min_capacity                = 0.5
  auto_pause_delay_in_minutes = 60
}

# Allow Azure Services (Container Apps) to access SQL
resource "azurerm_mssql_firewall_rule" "allow_azure_services" {
  name             = "AllowAzureServices"
  server_id        = azurerm_mssql_server.sqlserver.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# Allow YOUR IP (Local Machine) to query SQL
data "http" "myip" {
  url = "http://ipv4.icanhazip.com"
}

resource "azurerm_mssql_firewall_rule" "allow_local_dev" {
  name             = "AllowLocalDev"
  server_id        = azurerm_mssql_server.sqlserver.id
  start_ip_address = chomp(data.http.myip.response_body)
  end_ip_address   = chomp(data.http.myip.response_body)
}

# 6. Container Apps Environment
resource "azurerm_log_analytics_workspace" "log" {
  name                = "log-${var.project_name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_container_app_environment" "env" {
  name                       = "cae-${var.project_name}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.log.id
}

# ==========================================
# 7. Managed Identity & Roles
# ==========================================
resource "azurerm_user_assigned_identity" "ingest_identity" {
  location            = azurerm_resource_group.rg.location
  name                = "id-${var.project_name}-ingest"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_role_assignment" "blob_contributor" {
  scope                = azurerm_storage_account.adls.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.ingest_identity.principal_id
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.ingest_identity.principal_id
}

# --- NEW: PROPAGATION DELAY ---
# Forces Terraform to wait 60s for RBAC to replicate
resource "time_sleep" "wait_for_rbac" {
  create_duration = "60s"
  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.blob_contributor
  ]
}

# ==========================================
# 8. Azure Container App (Ingestion Service)
# ==========================================
resource "azurerm_container_app" "ingestion" {
  name                         = "ca-${var.project_name}-ingest"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  # Explicitly depend on the timer, not just the role
  depends_on = [time_sleep.wait_for_rbac]

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.ingest_identity.id]
  }

  registry {
    server   = azurerm_container_registry.acr.login_server
    identity = azurerm_user_assigned_identity.ingest_identity.id
  }

  template {
    container {
      name   = "ingestion-service"
      image  = "${azurerm_container_registry.acr.login_server}/craneops-ingestion:latest"
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "AZURE_STORAGE_ACCOUNT_NAME"
        value = azurerm_storage_account.adls.name
      }
      env {
        name  = "AZURE_IDENTITY_ENABLED"
        value = "true" 
      }
      env {
        name  = "SERVER_PORT"
        value = "8082"
      }
    }
  }

  ingress {
    external_enabled = true 
    target_port      = 8082
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }
}