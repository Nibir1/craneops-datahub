terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      # Bump to a newer version in the 3.x series
      version = ">= 3.100.0" 
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.10.0"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "time" {}