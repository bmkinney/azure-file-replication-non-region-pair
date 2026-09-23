# Infrastructure plan

## Scope

Deploy private, active/passive Azure Files replication across two customer-selected Azure regions. The regions do not need to form an Azure paired-region set. The primary region is authoritative initially, and the secondary region can become authoritative during failover and run reverse synchronization after the primary region returns.

## Topology

- One workload resource group for replication compute and supporting resources.
- One split-horizon Private DNS resource group per region in the greenfield profile.
- One VNet per region with a delegated `default` subnet and a `storage` private endpoint subnet.
- No VNet peering.
- One Azure Files account/share and one blob account/container per region.
- Each VNet has Azure Files private endpoints for both file accounts.
- Each VNet has its own same-named Private DNS zone instance. This split-horizon design prevents an unpeered VNet from resolving the other region's unreachable private endpoint address.
- One internal Container Apps environment and AzCopy job per region. Environment zone redundancy is disabled to reduce regional capacity requirements; resilience is provided by the independent regional workers.
- The greenfield profile uses ZRS for primary storage and LRS for secondary storage. Confirm those SKUs are available in the selected regions before deployment.
- A Premium ACR in the primary region with geo-replication to the secondary region and a private endpoint in each VNet.
- Regional Log Analytics workspaces.
- One shared Azure Monitor email Action Group, two job-failure metric alerts, and one freshness query alert per regional workspace.

## RBAC and service permissions

### Runtime managed identities

The deployment creates a user-assigned managed identity for each regional Container Apps Job. Bicep creates all runtime role assignments; operators do not need to grant them separately.

| Principal | Built-in role | Scope | Reason |
| --- | --- | --- | --- |
| Primary job identity | Storage File Data Privileged Contributor (`69566ab7-960f-475b-8e7c-b3118f30c6bd`) | Primary file storage account | Read or write file data while primary is active or during failback |
| Primary job identity | Storage File Data Privileged Contributor (`69566ab7-960f-475b-8e7c-b3118f30c6bd`) | Secondary file storage account | Write or read file data while primary is active or during failover |
| Secondary job identity | Storage File Data Privileged Contributor (`69566ab7-960f-475b-8e7c-b3118f30c6bd`) | Primary file storage account | Write or read file data while secondary is active or during failback |
| Secondary job identity | Storage File Data Privileged Contributor (`69566ab7-960f-475b-8e7c-b3118f30c6bd`) | Secondary file storage account | Read or write file data while secondary is active or during failover |
| Primary job identity | AcrPull (`7f951dda-4ed3-4680-a7ca-43fe172d538d`) | ACR | Pull the digest-pinned worker image |
| Secondary job identity | AcrPull (`7f951dda-4ed3-4680-a7ca-43fe172d538d`) | ACR | Pull the digest-pinned worker image |

The storage role is a data-plane role. Contributor, Storage Account Contributor, or another management-plane role alone cannot authorize AzCopy file operations. Both job identities intentionally receive the role on both accounts because replication direction changes during failover. The role is assigned at storage-account scope because each account contains the single replication share managed by this solution.

### Deployment principal

The deployment principal performs subscription-scope deployments and creates role assignments. Use one of these models:

| Model | Assignment | Notes |
| --- | --- | --- |
| Simple | Owner at the deployment subscription | Covers resource-group creation, resource deployment, and role assignment creation |
| Separated | Contributor plus Role Based Access Control Administrator at the deployment subscription | Separates resource management from access management; equivalent custom roles are also valid |

At minimum, an equivalent custom deployment role must allow:

- subscription-scope deployments and resource-group creation;
- creation and update of the storage, network, private DNS, managed identity, ACR, Log Analytics, Container Apps, and Azure Monitor resources declared by the selected profile;
- `Microsoft.ManagedIdentity/userAssignedIdentities/assign/action` so the two identities can be attached to the regional jobs;
- `Microsoft.Authorization/roleAssignments/write` and `Microsoft.Authorization/roleAssignments/delete` at each storage-account and ACR scope; and
- read access to every existing resource referenced by the brownfield profile.

The existing-resource profile also executes nested deployments in the resource groups containing the two storage accounts and ACR. The deployment principal therefore needs resource-group deployment permission in those resource groups and role-assignment permission on all three target resources. The current template accepts resource-group names but not subscription IDs, so the workload, storage accounts, network resources, private endpoints, Private DNS zones, and ACR must be in the same subscription.

### Deployment script and ACR

`scripts/deploy.ps1` can either consume a prebuilt digest-pinned image or run an ACR Task build and inspect its manifest:

- With `-ContainerImage`, no image build or manifest lookup is performed. The deployment principal still needs the management-plane and role-assignment permissions above.
- Without `-ContainerImage`, the principal must be able to queue an ACR Task build, push the resulting image, and read repository manifest metadata. For a registry that does not use repository-scoped ABAC, assign AcrPush on the registry in addition to the required management-plane access. Network access to the private registry must also be available from the command environment.

### Operational access

- `scripts/switch-direction.ps1` performs another subscription deployment. The failover operator therefore needs the same deployment and role-assignment permissions described above.
- A user who only runs a controlled job test does not need storage data access because the job uses its own managed identity. That user needs job read access plus `Microsoft.App/jobs/start/action` and `Microsoft.App/jobs/stop/action` on the relevant Container Apps Jobs.
- Users investigating failures need read access to the Container Apps Jobs, alert resources, and Log Analytics workspaces. Querying workspace data also requires a Log Analytics data-query role, such as Log Analytics Reader, at the workspace or a parent scope.

### Integrations without additional runtime RBAC

- Container Apps sends logs to Log Analytics using workspace credentials configured by Bicep. No role is assigned to either job identity for this path.
- Azure Monitor metric and scheduled-query alerts invoke the Action Group through the platform alerting service. No managed identity or additional role assignment is used.
- Email receivers do not require Azure RBAC, but recipients should confirm and test delivery before production use.
- Private endpoint and Private DNS access is controlled by network configuration rather than data-plane RBAC. RBAC does not compensate for missing endpoint approval, routes, or DNS records.

### Verify assignments

After deployment, resolve the two job identity principal IDs and verify that each has the two storage assignments and one registry assignment:

```powershell
az identity list --resource-group <replication-resource-group> --query "[].{name:name, principalId:principalId}" --output table

az role assignment list --scope "/subscriptions/<subscription-id>/resourceGroups/<primary-storage-rg>/providers/Microsoft.Storage/storageAccounts/<primary-storage-account>" --include-inherited --output table
az role assignment list --scope "/subscriptions/<subscription-id>/resourceGroups/<secondary-storage-rg>/providers/Microsoft.Storage/storageAccounts/<secondary-storage-account>" --include-inherited --output table
az role assignment list --scope "/subscriptions/<subscription-id>/resourceGroups/<acr-rg>/providers/Microsoft.ContainerRegistry/registries/<acr-name>" --include-inherited --output table
```

## Replication state

Only one job is scheduled at a time:

| State | Scheduled job | Direction |
| --- | --- | --- |
| Normal | Primary region | Primary to secondary |
| DR active | Secondary region | Secondary to primary |

The schedule starts every 10 minutes. This is a cadence, not a guaranteed RPO. A previous execution can still be running when the next schedule is due; Container Apps Jobs is configured for one replica per execution, and operators must monitor duration.

Destination deletion is disabled. The initial rollout prioritizes recoverability over mirroring source deletions.

## Monitoring state

Job failure and replication freshness are separate signals:

- Each Container Apps Job has a Sev 1 metric alert over the native `Executions` metric filtered to `state=Failed`. Both rules remain enabled so a failed manual execution in the standby region is observable.
- Each Log Analytics workspace has a Sev 2 scheduled query rule that looks for `AZURE_FILES_REPLICATION_SUCCEEDED` in consecutive 10-minute windows. The number of required missing windows is derived from the configured 20-, 30-, or 60-minute lag threshold.
- Scheduled-query validation is skipped when the alert resources are created because a new workspace does not contain `ContainerAppConsoleLogs_CL` until its first Container Apps log ingestion. Runtime evaluation uses the table normally after it is materialized.
- Freshness represents elapsed time since the last completed successful AzCopy run. It does not compare individual file timestamps or guarantee a per-file RPO.
- All rules use stateful auto-mitigation and notify the same email Action Group with Common Alert Schema.

Freshness follows the active/passive state:

| `activeRegion` | Primary failure | Secondary failure | Primary freshness | Secondary freshness |
| --- | --- | --- | --- | --- |
| `none` | Enabled | Enabled | Disabled | Disabled |
| `primary` | Enabled | Enabled | Enabled | Disabled |
| `secondary` | Enabled | Enabled | Disabled | Enabled |

Direction changes use a full Bicep deployment, so the freshness-rule state changes with the job schedules. No separate alert toggle or DNS change is required.

## Failover controls

Before changing direction:

1. Fence writes to the authoritative share.
2. Verify neither job has a running execution.
3. Confirm both jobs use the same digest-pinned image.
4. Run a final synchronization when the old source is reachable.
5. Use `scripts/switch-direction.ps1` to enable only the intended regional schedule.
6. Start or observe one execution and validate representative files before releasing writes.
7. Confirm the new active direction's freshness alert is enabled and the prior direction's alert is disabled.

Opposing directions must never run concurrently. Conflict reconciliation remains an operator responsibility if both shares received writes.