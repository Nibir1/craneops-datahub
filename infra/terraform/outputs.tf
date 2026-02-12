output "acr_login_server" {
  value = azurerm_container_registry.acr.login_server
}

output "acr_admin_username" {
  value = azurerm_container_registry.acr.admin_username
}

output "acr_admin_password" {
  value = azurerm_container_registry.acr.admin_password
  sensitive = true
}

output "storage_account_name" {
  value = azurerm_storage_account.adls.name
}

output "storage_account_key" {
  value = azurerm_storage_account.adls.primary_access_key
  sensitive = true
}

output "sql_server_fqdn" {
  value = azurerm_mssql_server.sqlserver.fully_qualified_domain_name
}

output "sql_db_name" {
  value = azurerm_mssql_database.sqldb.name
}

output "ingestion_app_url" {
  value = azurerm_container_app.ingestion.latest_revision_fqdn
}