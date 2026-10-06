# Terraform deployment

This folder provides the Terraform option for the greenfield deployment. It creates the same Azure Files disaster-recovery replication foundation as `../bicep/main.bicep`: private storage, private DNS, private endpoints, Azure Container Apps Jobs, managed identities, ACR, and Azure Monitor alerts. Existing-resource deployments are Bicep-only for now; see `../bicep/README.md`.

Architecture and operations background:

- [Architecture](../../README.md#architecture)
- [Design](../../README.md#design)
- [Prerequisites](../../README.md#prerequisites)
- [Network requirements for server-side copy](../../README.md#network-requirements-for-server-side-copy)
- [RBAC requirements](../../README.md#rbac-requirements)
- [Replication job settings](../../README.md#replication-job-settings)
- [Monitoring and alerts](../../README.md#monitoring-and-alerts)
- [Switch direction](../../README.md#switch-direction)
- [Troubleshooting](../../README.md#troubleshooting)
- Other deployment options: [Bicep](../bicep/README.md), the [Azure portal guide](../portal/README.md), and the [example CI/CD pipelines](../../pipelines/README.md)

## Prerequisites

- Terraform >= 1.9
- Azure CLI with the Container Apps extension
- PowerShell 7.2 or later (`pwsh`)
- `az login` to the target subscription
- Registered resource providers:

```powershell
az provider register --namespace Microsoft.App
az provider register --namespace Microsoft.ContainerRegistry
az provider register --namespace Microsoft.Insights
az provider register --namespace Microsoft.ManagedIdentity
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.OperationalInsights
az provider register --namespace Microsoft.Storage
```

Rights: Owner, or Contributor plus Role Based Access Control Administrator, or Contributor-only with `create_role_assignments = false` and an administrator running `scripts/grant-access.ps1`.

## Files

- `main.tf`, `variables.tf`, `outputs.tf`, `providers.tf`, `versions.tf` - root module
- `modules/` - network, regional DNS, private endpoints, storage, registry, replication, monitoring
- `deploy.ps1` - two-phase deployment helper
- `terraform.tfvars.example` - committed placeholder configuration
- `backend.example.hcl` - remote state placeholder configuration
- `tests/*.tftest.hcl` - offline Terraform tests with mocked providers

## Configure

Copy the example and edit real values in the git-ignored file:

```powershell
Copy-Item deploy/terraform/terraform.tfvars.example deploy/terraform/terraform.tfvars
```

Key variables:

| Variable | Purpose |
| --- | --- |
| `resource_group_name` | Workload resource group. |
| `primary_dns_resource_group_name`, `secondary_dns_resource_group_name` | Optional DNS resource group overrides; default to `<rg>-primary-dns` and `<rg>-secondary-dns`. |
| `primary_location`, `secondary_location` | Non-paired replication regions. |
| `environment_name` | Short token used in deterministic names. |
| `active_region` | `none`, `primary`, or `secondary`; use `none` before activation. |
| `container_image` | Digest-pinned AzCopy image after build. |
| `acr_public_network_access_enabled` | Open only during bootstrap image build. |
| `alert_email_addresses` | Required action group receivers. |
| `create_role_assignments` | Set `false` when a separate admin grants job identity roles. |
| `tags` | Keep `Workload = "azure-files-dr-replication"` because scripts discover jobs by this tag. |

## State

Local state is the default. For remote state, copy `backend.example.hcl` to `backend.hcl`, uncomment the `backend "azurerm" {}` block in `versions.tf`, then run:

```powershell
terraform -chdir=deploy/terraform init -backend-config=backend.hcl
```

The backend example uses Entra ID authentication. If Azure Policy in your tenant forces storage public network access off, the state storage account needs a private network path from the runner. Pipeline identities can add `use_oidc = true` when their environment exports OIDC variables.

## Deploy

Preview first:

```powershell
pwsh ./deploy/terraform/deploy.ps1 -WhatIf
```

Run the deployment:

```powershell
pwsh ./deploy/terraform/deploy.ps1
```

The script initializes Terraform, validates, plans, applies with `active_region = "none"`, builds and pins the ACR image, then applies with `active_region = "primary"` and ACR public access disabled. Record the final `active_region`, `container_image`, and `acr_public_network_access_enabled` values in `terraform.tfvars`.

## Manual Terraform flow

```powershell
terraform -chdir=deploy/terraform init
terraform -chdir=deploy/terraform validate
terraform -chdir=deploy/terraform apply -var-file=terraform.tfvars -var active_region=none -var acr_public_network_access_enabled=true
az acr build --registry <registry-name> --image azure-files-dr-azcopy:10.30.1 ./src/azcopy-job
$digest = az acr manifest show-metadata <login-server>/azure-files-dr-azcopy:10.30.1 --registry <registry-name> --query digest -o tsv
terraform -chdir=deploy/terraform apply -var-file=terraform.tfvars -var "container_image=<login-server>/azure-files-dr-azcopy@$digest" -var active_region=primary -var acr_public_network_access_enabled=false
```

## Pipeline identity

Set `create_role_assignments = false` when the pipeline cannot create role assignments. After the bootstrap apply, an administrator grants the required roles:

```powershell
pwsh ./scripts/grant-access.ps1 -TerraformDirectory ./deploy/terraform
```

## Switch direction

Fence application writes, then switch the active schedule:

```powershell
pwsh ./scripts/switch-direction.ps1 -ActiveRegion secondary -WritesFenced -TerraformDirectory ./deploy/terraform
```

Verify before allowing writes again: [verify a deployment](../../README.md#verify-a-deployment).

## Differences from Bicep

- Terraform uses SHA-256 name tokens, so it creates separate resources from the Bicep greenfield deployment. Do not manage the same environment with both tools.
- `ManagedBy` defaults to `Terraform`.
- Freshness alerts use `time_static` so changing `active_region` or `container_image` starts a grace period before stale-replication alerts can fire.
- Switching a Container Apps Job between manual and schedule trigger modes may require replacement depending on the AzureRM provider/API behavior; keep state backed up and review the plan.
- AzureRM 4.x uses management-plane storage share/container resources (`storage_account_id`), so no storage keys or SAS tokens are needed.

## Tests

```powershell
pwsh ./tests/test-terraform.ps1
pwsh ./tests/test-terraform-scripts.ps1
```

## Destroy

Destroying removes private endpoints, jobs, identities, registries, storage accounts, shares, and containers. This deletes replication data and backup artifacts in the created storage accounts:

```powershell
terraform -chdir=deploy/terraform destroy -var-file=terraform.tfvars
```
