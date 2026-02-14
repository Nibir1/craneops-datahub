terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
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

  # --- 🚨 NEW: REMOTE STATE BACKEND 🚨 ---
  # This tells Terraform to store its memory in the Azure Cloud,
  # allowing GitHub Actions and your Macbook to share the same state.
  backend "azurerm" {
    resource_group_name  = "rg-craneops-tfstate"
    storage_account_name = "stcraneopstfstate7788"
    container_name       = "tfstate"
    key                  = "prod.terraform.tfstate"
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