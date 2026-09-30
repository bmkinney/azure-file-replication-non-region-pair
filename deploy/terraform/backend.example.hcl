resource_group_name  = "rg-terraform-state"
storage_account_name = "stterraformstate0000"
container_name       = "tfstate"
key                  = "azure-files-dr-replication.tfstate"
use_azuread_auth     = true

# For federated pipeline identities, also set use_oidc = true when your pipeline exports OIDC variables.
