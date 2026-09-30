# CI/CD pipelines

Example continuous integration and deployment pipelines for GitHub Actions and Azure DevOps. Nothing in the repository deploys automatically: every deployment pipeline runs only when someone starts it by hand, in an environment that can require approval.

| File | Platform | Runs |
| --- | --- | --- |
| `.github/workflows/ci.yml` | GitHub Actions | On pull requests and pushes to `main`: the offline tests |
| `.github/workflows/deploy-bicep.yml` | GitHub Actions | Manually: a Bicep preview, deployment, or direction switch |
| `.github/workflows/deploy-terraform.yml` | GitHub Actions | Manually: a Terraform preview, deployment, or direction switch |
| `pipelines/azure-devops/ci.yml` | Azure Pipelines | On pull requests and pushes to `main`: the offline tests |
| `pipelines/azure-devops/deploy-bicep.yml` | Azure Pipelines | Manually: a Bicep preview, deployment, or direction switch |
| `pipelines/azure-devops/deploy-terraform.yml` | Azure Pipelines | Manually: a Terraform preview, deployment, or direction switch |

## Continuous integration

The CI pipelines run every `tests/test-*.ps1` script and `src/azcopy-job/test-run-sync.ps1`, and ShellCheck on the AzCopy wrapper. The GitHub workflow also runs the tests on Windows, and it runs `terraform fmt -check`, `validate`, and `terraform test` as a separate job. The tests make no Azure calls and need no credentials. To run them locally, see [Tests](../README.md#tests).

## Deployment pipelines

Each deployment pipeline has the same operations:

| Operation | Bicep | Terraform |
| --- | --- | --- |
| `preview` | `scripts/inventory.ps1`, then `scripts/deploy.ps1 -WhatIf` | `deploy/terraform/deploy.ps1 -WhatIf`, which runs `terraform plan` |
| `deploy` | `scripts/deploy.ps1`: the two-stage deployment with the image build | `deploy/terraform/deploy.ps1`: the same, with Terraform |
| `switch-direction` | `scripts/switch-direction.ps1 -ParametersFile` | `scripts/switch-direction.ps1 -TerraformDirectory` |

A direction switch runs only when you also confirm that application writes are fenced. Follow [Switch direction](../README.md#switch-direction) before you start one.

The pipelines keep environment values out of the repository. The complete Bicep parameter file or Terraform variable file is stored as a secret or secure file, written to a git-ignored path for the run, and deleted when the job ends. Terraform runs always use an `azurerm` state backend, because the runner's local state is discarded; the pipeline generates `backend_override.tf` and `backend.hcl` for the run.

### Pipeline identity

The pipelines sign in with workload identity federation, so they store no Azure secret. Use a user-assigned managed identity or an app registration for the pipeline identity, as described in [Create the pipeline identity](../deploy/bicep/README.md#create-the-pipeline-identity), and give it:

- **Contributor** on the deployment subscription. The deployments create resource groups and run at subscription scope. For a narrower set, see [Pipeline identity rights](../README.md#pipeline-identity-rights).
- For Terraform, **Storage Blob Data Contributor** on the state container.

Set `createRoleAssignments = false` in the Bicep parameter file, or `create_role_assignments = false` in the Terraform variable file, so that the pipeline identity doesn't need the right to assign roles. The first `deploy` run stops after it creates the job identities and prints a `grant-access.ps1` command. An access administrator runs it once, and you start the pipeline again. See [Grant the job identities their roles](../README.md#grant-the-job-identities-their-roles).

If Azure Policy in your tenant forces public network access off for storage accounts or registries, use a self-hosted runner or agent with a private network path to the Terraform state account and to the registry during the image build.

## Set up GitHub Actions

1. Create a GitHub environment, such as `production`, and add required reviewers.
2. Add a federated credential to the pipeline identity for the environment. For a user-assigned managed identity:

   ```bash
   az identity federated-credential create --name github-production \
     --identity-name <pipeline-identity> --resource-group <identity-resource-group> \
     --issuer https://token.actions.githubusercontent.com \
     --subject repo:<owner>/<repository>:environment:production \
     --audiences api://AzureADTokenExchange
   ```

   For an app registration, use `az ad app federated-credential create --id <application-id> --parameters <credential.json>` with the same issuer, subject, and audience.

3. Add these to the environment:

   | Name | Kind | Workflows | Value |
   | --- | --- | --- | --- |
   | `AZURE_CLIENT_ID` | Variable | Both | The pipeline identity's client ID |
   | `AZURE_TENANT_ID` | Variable | Both | The tenant ID |
   | `AZURE_SUBSCRIPTION_ID` | Variable | Both | The deployment subscription ID |
   | `BICEP_PARAMETERS` | Secret | Bicep | The complete parameter file, starting with `using './main.bicep'` or `using './existing.bicep'` |
   | `AZURE_LOCATION` | Variable, optional | Bicep | The deployment metadata region; use the primary region |
   | `BICEP_RESOURCE_GROUP_NAME`, `BICEP_SECONDARY_RESOURCE_GROUP_NAME` | Variables, optional | Bicep | The job resource groups, for `switch-direction` |
   | `TERRAFORM_TFVARS` | Secret | Terraform | The complete variable file |
   | `TF_STATE_RESOURCE_GROUP`, `TF_STATE_STORAGE_ACCOUNT`, `TF_STATE_CONTAINER`, `TF_STATE_KEY` | Variables | Terraform | The state backend |

4. Start the workflow from the **Actions** tab, with `operation` set to `preview` first.

## Set up Azure Pipelines

1. Create an Azure Resource Manager service connection that uses workload identity federation, as described in [Connect to Azure with an Azure Resource Manager service connection](https://learn.microsoft.com/azure/devops/pipelines/library/connect-to-azure). Grant the pipeline identity behind it the rights above.
2. Create an environment, such as `production`, and add approvals and checks to it.
3. Upload the parameter file or variable file as a secure file in **Pipelines** > **Library**.
4. Create a variable group, link it to the pipeline, and define:

   | Variable | Pipelines | Value |
   | --- | --- | --- |
   | `serviceConnection` | Both | The service connection name |
   | `parametersSecureFile` | Bicep | The secure file name of the parameter file |
   | `location`, `resourceGroupName`, `secondaryResourceGroupName` | Bicep, optional | As for GitHub Actions |
   | `serviceConnectionId` | Terraform | The service connection ID, which Terraform uses to request federated tokens |
   | `tfvarsSecureFile` | Terraform | The secure file name of the variable file |
   | `tfStateResourceGroup`, `tfStateStorageAccount`, `tfStateContainer`, `tfStateKey` | Terraform | The state backend |

5. Create each pipeline from its YAML file, for example:

   ```bash
   az pipelines create --name azure-files-replication-terraform --repository <repository> \
     --branch main --yml-path pipelines/azure-devops/deploy-terraform.yml --skip-first-run true
   ```

6. Run the pipeline, with `operation` set to `preview` first.

## Forks

The deployment pipelines do nothing in a fork until you configure an environment, variables, and secrets for it, and the CI pipelines need no configuration. You can disable any workflow that you don't use from the fork's **Actions** tab.
