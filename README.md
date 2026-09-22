# PPL Azure Files DR replication

Bicep and Azure CLI deployment for private Azure Files replication between Central US and West US. Two regional Azure Container Apps Jobs run a pinned AzCopy image in active/passive mode.

## Design

- No VNet peering or public storage access.
- Both file accounts have a private endpoint in each VNet so either regional job can reach both shares.
- Regional split-horizon Azure Private DNS zones prevent cross-region private endpoint DNS ambiguity.
- Managed identities authenticate to Azure Files; no storage keys or SAS tokens are used.
- Central US synchronizes forward by default. West US is a manual standby with the reverse direction preconfigured.
- The requested regional blob accounts and private containers are provisioned for application/demo use; they are not part of the Azure Files transfer path.

See [docs/infrastructure-plan.md](docs/infrastructure-plan.md) for topology and failover controls.

## Prerequisites

- Azure CLI with the Bicep and Container Apps extensions.
- Subscription Owner or equivalent rights to create resource groups, resources, and role assignments.
- PowerShell 7.
- Sufficient Premium ACR, Container Apps environment, private endpoint, and regional storage quota.

Review the active subscription before deployment:

```powershell
az account show --output table
az account set --subscription 23b04b55-570a-4728-8de2-bcac0c43edb6
```

## Validate

```powershell
az bicep build --file infra/main.bicep
az deployment sub validate --location centralus --parameters infra/main.bicepparam
az deployment sub what-if --location centralus --parameters infra/main.bicepparam
pwsh ./src/azcopy-job/test-run-sync.ps1
```

## Deploy

The script validates and previews changes, creates the private foundation, builds AzCopy in ACR, pins the deployed image by digest, disables ACR public access, and activates the Central US schedule.

```powershell
pwsh ./scripts/deploy.ps1 -WhatIf
pwsh ./scripts/deploy.ps1
```

Deployment changes Azure resources and is intentionally not run automatically from this repository.

## Switch direction

After fencing application writes and validating the target:

```powershell
# Fail over: West US becomes authoritative and syncs back to Central US.
pwsh ./scripts/switch-direction.ps1 -ActiveRegion secondary -WritesFenced -WhatIf
pwsh ./scripts/switch-direction.ps1 -ActiveRegion secondary -WritesFenced

# Fail back after reconciliation: Central US resumes forward sync.
pwsh ./scripts/switch-direction.ps1 -ActiveRegion primary -WritesFenced
```

The switch script refuses to proceed while either job is running or when the deployed images differ or are not digest-pinned.