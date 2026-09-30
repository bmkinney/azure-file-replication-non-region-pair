terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.81"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }

  # Uncomment to use remote state with deploy/terraform/backend.example.hcl copied to backend.hcl.
  # backend "azurerm" {}
}
