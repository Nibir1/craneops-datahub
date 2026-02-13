# ==========================================
# 1. AZURE DATA FACTORY
# ==========================================
resource "azurerm_data_factory" "adf" {
  # Removed var.environment and hardcoded 'dev'
  name                = "adf-${var.project_name}-dev-${random_string.suffix.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  # Enable System Assigned Identity (so ADF can authenticate to other Azure services)
  identity {
    type = "SystemAssigned"
  }
}

# ==========================================
# 2. PERMISSIONS (Role Assignment)
# ==========================================
# Give ADF permission to "start" the Container App Job.
# We assign "Container App Contributor" specifically on the Job resource.
resource "azurerm_role_assignment" "adf_job_contributor" {
  scope                = azurerm_container_app_job.spark_etl.id
  role_definition_name = "Contributor" # "Contributor" is easiest for triggering jobs via API
  principal_id         = azurerm_data_factory.adf.identity[0].principal_id
}

# ==========================================
# 3. PIPELINE (Trigger Spark Job)
# ==========================================
resource "azurerm_data_factory_pipeline" "pipeline_etl" {
  name            = "pl_daily_crane_etl"
  data_factory_id = azurerm_data_factory.adf.id

  # We use a "Web Activity" to call the Azure Resource Manager (ARM) API
  # This effectively does "az containerapp job start" but via HTTP
  activities_json = <<JSON
  [
    {
      "name": "TriggerSparkJob",
      "type": "WebActivity",
      "dependsOn": [],
      "policy": {
        "timeout": "0.00:10:00",
        "retry": 0,
        "retryIntervalInSeconds": 30,
        "secureOutput": false,
        "secureInput": false
      },
      "userProperties": [],
      "typeProperties": {
        "url": "https://management.azure.com${azurerm_container_app_job.spark_etl.id}/start?api-version=2024-03-01",
        "method": "POST",
        "authentication": {
          "type": "MSI",
          "resource": "https://management.azure.com/"
        }
      }
    }
  ]
  JSON
}

# ==========================================
# 4. OUTPUTS
# ==========================================
output "adf_name" {
  description = "The name of the Azure Data Factory"
  value       = azurerm_data_factory.adf.name
}