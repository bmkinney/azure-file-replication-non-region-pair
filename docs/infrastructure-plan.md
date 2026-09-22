# Infrastructure plan

## Scope

Deploy a private, active/passive Azure Files replication demonstration across Central US and West US. Central US is authoritative initially. West US can become authoritative during failover and run reverse synchronization after Central US returns.

## Topology

- Workload resource group: `ppl-storagereplication-demo`.
- Regional DNS resource groups: `ppl-storagereplication-demo-cus-dns` and `ppl-storagereplication-demo-wus-dns`.
- One VNet per region with a delegated `default` subnet and a `storage` private endpoint subnet.
- No VNet peering.
- One Azure Files account/share and one blob account/container per region.
- Each VNet has Azure Files private endpoints for both file accounts.
- Each VNet has its own same-named Private DNS zone instance. This split-horizon design prevents an unpeered VNet from resolving the other region's unreachable private endpoint address.
- One internal Container Apps environment and AzCopy job per region. Central US uses zone redundancy; West US does not support it for Container Apps environments.
- A Premium ACR in Central US with West US geo-replication and a private endpoint in each VNet.
- Regional Log Analytics workspaces.

## Replication state

Only one job is scheduled at a time:

| State | Scheduled job | Direction |
| --- | --- | --- |
| Normal | Central US | Central US to West US |
| DR active | West US | West US to Central US |

The schedule starts every 10 minutes. This is a cadence, not a guaranteed RPO. A previous execution can still be running when the next schedule is due; Container Apps Jobs is configured for one replica per execution, and operators must monitor duration.

Destination deletion is disabled. The initial rollout prioritizes recoverability over mirroring source deletions.

## Failover controls

Before changing direction:

1. Fence writes to the authoritative share.
2. Verify neither job has a running execution.
3. Confirm both jobs use the same digest-pinned image.
4. Run a final synchronization when the old source is reachable.
5. Use `scripts/switch-direction.ps1` to enable only the intended regional schedule.
6. Start or observe one execution and validate representative files before releasing writes.

Opposing directions must never run concurrently. Conflict reconciliation remains an operator responsibility if both shares received writes.