# ==========================================
# ENTERPRISE NETWORK SECURITY (ZERO TRUST)
# ==========================================

# 1. The Virtual Network
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-${var.project_name}-dev"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

# 2. The Container Apps Subnet
# ACA requires a dedicated /23 subnet to inject the serverless infrastructure.
resource "azurerm_subnet" "aca_subnet" {
  name                 = "snet-aca-compute"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.0.0/23"] 

  # Service Endpoints create a secure, direct route to Storage and SQL
  # bypassing the public internet entirely.
  service_endpoints    = ["Microsoft.Storage", "Microsoft.Sql"]

  # Delegate this subnet to Container Apps
  delegation {
    name = "aca-delegation"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}