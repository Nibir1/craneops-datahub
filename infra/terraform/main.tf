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

# --- 🚨 MOVED: Local IP Lookup (Needed for Zero Trust) 🚨 ---
data "http" "myip" {
  url = "http://ipv4.icanhazip.com"
}

# 3. Azure Container Registry (ACR) - Basic SKU
resource "azurerm_container_registry" "acr" {
  name                = "acr${var.project_name}${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = true
}

# 4. Azure Data Lake Storage Gen2 (ADLS)
resource "azurerm_storage_account" "adls" {
  name                     = "st${var.project_name}${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  is_hns_enabled           = true # Enables Data Lake Gen2

  # --- 🚨 NEW: ZERO TRUST FIREWALL 🚨 ---
  network_rules {
    default_action             = "Deny"
    ip_rules                   = [chomp(data.http.myip.response_body)] # Allow your Macbook
    virtual_network_subnet_ids = [azurerm_subnet.aca_subnet.id]        # Allow the Container Apps
  }
}

# Create Containers (The Medallion Architecture)
resource "azurerm_storage_container" "bronze" {
  name                  = "telemetry-raw"
  storage_account_id    = azurerm_storage_account.adls.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "silver" {
  name                  = "telemetry-silver"
  storage_account_id    = azurerm_storage_account.adls.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "gold" {
  name                  = "telemetry-gold"
  storage_account_id    = azurerm_storage_account.adls.id
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

  sku_name                    = "GP_S_Gen5_1"
  min_capacity                = 0.5
  auto_pause_delay_in_minutes = 60
}

# --- 🚨 NEW: VNET RULE FOR SQL 🚨 ---
resource "azurerm_mssql_virtual_network_rule" "sql_vnet_rule" {
  name      = "sql-vnet-rule"
  server_id = azurerm_mssql_server.sqlserver.id
  subnet_id = azurerm_subnet.aca_subnet.id
}

# Allow Local IP (So your Macbook can still run queries)
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

  # --- 🚨 NEW: VNET INJECTION 🚨 ---
  infrastructure_subnet_id = azurerm_subnet.aca_subnet.id
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

# Forces Terraform to wait 60s for RBAC to replicate
resource "time_sleep" "wait_for_rbac" {
  create_duration = "60s"
  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.blob_contributor
  ]
}

# ==========================================
# 8. Production Ingestion Service (Always-On)
# ==========================================
resource "azurerm_container_app" "ingestion" {
  name                         = "ca-${var.project_name}-ingest"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

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
    # --- PRODUCTION SCALING (No Cold Start) ---
    min_replicas = 1
    max_replicas = 10

    container {
      name   = "ingestion-service"
      image  = "${azurerm_container_registry.acr.login_server}/craneops-ingestion:v2"
      cpu    = 0.5
      memory = "1.0Gi"

      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.ingest_identity.client_id
      }
      env {
        name  = "AZURE_STORAGE_ACCOUNT"
        value = azurerm_storage_account.adls.name
      }
      env {
        name  = "AZURE_CONTAINER_NAME"
        value = "telemetry-raw"
      }
      env {
        name  = "SERVER_PORT"
        value = "8080"
      }
    }
  }

  ingress {
    external_enabled = true
    target_port      = 8080
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }
}

# ==========================================
# 9. Serverless Spark Job (ETL Engine)
# ==========================================
resource "azurerm_container_app_job" "spark_etl" {
  name                         = "job-${var.project_name}-etl"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = azurerm_resource_group.rg.location

  replica_timeout_in_seconds = 1800
  replica_retry_limit        = 0

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

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
      name   = "spark-etl"
      image  = "${azurerm_container_registry.acr.login_server}/craneops-spark:latest"
      cpu    = 2.0
      memory = "4Gi"

      command = [
        "/bin/bash",
        "-c",
        "/opt/spark/bin/spark-submit --master local[*] /opt/spark/work-dir/etl_job.py"
      ]

      env {
        name  = "AZURE_STORAGE_ACCOUNT"
        value = azurerm_storage_account.adls.name
      }
      env {
        name        = "AZURE_STORAGE_KEY"
        secret_name = "storage-key"
      }
      env {
        name  = "SQL_SERVER_HOST"
        value = azurerm_mssql_server.sqlserver.fully_qualified_domain_name
      }
      env {
        name  = "SQL_SERVER_USER"
        value = var.sql_admin_username
      }
      env {
        name        = "SQL_SERVER_PASSWORD"
        secret_name = "sql-password"
      }
    }
  }

  secret {
    name  = "storage-key"
    value = azurerm_storage_account.adls.primary_access_key
  }
  secret {
    name  = "sql-password"
    value = var.sql_admin_password
  }
}

# ==========================================
# 10. Outputs for Makefile Automation
# ==========================================
output "acr_name" {
  value = azurerm_container_registry.acr.name
}

output "acr_login_server" {
  value = azurerm_container_registry.acr.login_server
}

output "storage_account_name" {
  value = azurerm_storage_account.adls.name
}

output "sql_server_fqdn" {
  value = azurerm_mssql_server.sqlserver.fully_qualified_domain_name
}

output "ingestion_app_url" {
  value = azurerm_container_app.ingestion.ingress[0].fqdn
}