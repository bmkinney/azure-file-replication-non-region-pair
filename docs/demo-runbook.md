# Replication demo runbook

This runbook walks through a live demonstration of the Azure Files replication solution:

- The deployed services.
- The replication state in the Azure portal and the Azure CLI.
- A live replication.
- Alerts for stale replication and for a failed run.

Each step uses `scripts/demo.ps1`. It runs in Azure Cloud Shell (PowerShell) or in any PowerShell 7 session with the Azure CLI, and it works with both deployment profiles.

Run the demo against a demonstration or nonproduction deployment. The stale-replication scenario stops scheduled replication for about an hour, so the replica falls behind the source during that time.

## At a glance

| Segment | What you show | Time | Commands |
| --- | --- | --- | --- |
| Before the session | Pause replication so the stale-replication alert fires before you start | 45-60 minutes ahead | `pause` |
| 1. Inventory | The deployed services and the existing resources they use | 5 min | `inventory` |
| 2. Replication state | Direction, schedule, run history, freshness, and the portal views | 10 min | `status` |
| 3. Stale replication | The Sev 2 alert and email, then resuming replication | 5 min | `alerts`, `resume` |
| 4. Live replication | A new file written to the source and replicated to the replica | 15 min | `seed`, `files`, `replicate` |
| 5. Failed run | The Sev 1 alert and email for a failed execution | 10 min | `fail-run`, `alerts` |
| 6. Standby readiness (optional) | A reverse-direction dry run from the standby region | 5 min | `standby-check` |
| After the session | Remove the demo files and confirm that the alerts resolved | 5 min | `cleanup`, `status`, `alerts` |

## How the demo script works

- It finds the replication jobs by their `Workload=azure-files-dr-replication` tag and identifies each job's region role from its failed-execution alert rule. Nothing needs to be configured except the resource group.
- The job with a schedule is the active job. The other job is the standby job.
- Commands that read or write the shares start one execution with a command override (`/bin/sh -c <script>`). The override applies to that execution only; the job definition doesn't change. The script runs inside the job's Container Apps environment with the job's managed identity and network path, which is why it works when the storage accounts deny public network access.
- Helper executions never print `AZURE_FILES_REPLICATION_SUCCEEDED`, so they can't satisfy the freshness alert. They always exit with code 0, so they can't raise the failed-execution alert.
- The script never starts the standby job without a command override, so it can't run a reverse replication.

| Command | What it changes | Runs on |
| --- | --- | --- |
| `status`, `inventory`, `alerts` | Nothing; read-only Azure CLI calls | Your shell |
| `files` | Nothing; lists the demo folder in both shares | Standby job |
| `standby-check` | Nothing; runs `azcopy sync --dry-run` for the reverse direction | Standby job |
| `seed` | Writes one file to `replication-demo/` in the source share | Active job |
| `replicate` | Starts a normal replication run, the same as a scheduled run | Active job |
| `fail-run` | Starts one execution that fails on purpose; nothing is copied or deleted | Active job |
| `pause`, `resume` | Changes the active job's schedule and records the original in a job tag | Active job |
| `cleanup` | Deletes `replication-demo/` from both shares | Standby job |

`seed`, `fail-run`, `pause`, and `cleanup` ask for confirmation; add `-Force` to skip the prompt. Every command that changes something supports `-WhatIf`.

## Prerequisites

- A deployment of either profile that runs the AzCopy image, not the placeholder image, and has an active direction (`activeRegion=primary` or `secondary`). `status` shows both.
- Azure Cloud Shell in PowerShell mode, or PowerShell 7 and the Azure CLI on a workstation, with this repository cloned. Run the commands from the repository root.
- The subscription that contains the deployment, selected with `az account set --subscription <subscription-id>`.
- For the existing-resource profile, the replication resource group in an environment variable, so you don't have to pass `-ResourceGroupName` to every command:

  ```powershell
  $env:REPLICATION_DEMO_RESOURCE_GROUP = '<replication-resource-group>'
  ```

- Access to a mailbox that receives the action group's email, so you can show the notifications.

The presenter needs these permissions. The helper executions use the job's managed identity, so the presenter doesn't need data access to the file shares.

| Task | Permission |
| --- | --- |
| `status`, `alerts`, and `inventory` | Reader on the replication resource group, which includes log queries against its workspaces. `inventory` also reads the storage, network, and registry resources that the jobs use. |
| Start executions: `seed`, `files`, `replicate`, `fail-run`, `standby-check`, `cleanup` | `Microsoft.App/jobs/start/action` on both jobs, for example **Container Apps Jobs Operator** |
| `pause` and `resume` | `Microsoft.App/jobs/write` and `Microsoft.Resources/tags/write` on the active job, for example **Container Apps Jobs Contributor** and **Tag Contributor** |
| `inventory -ParametersFile` | The deployment permissions that what-if needs; see [RBAC requirements](../README.md#rbac-requirements) |

Treat the start permission as privileged: an execution with a command override can read, write, and delete data in both shares as the job's managed identity.

## The day before

1. Run `./scripts/demo.ps1 status`. Confirm the direction, a `Healthy` freshness state, recent `Succeeded` replication runs, and no open alerts.
2. Run `./scripts/demo.ps1 alerts`. Confirm that the active direction's stale-replication rule is enabled, and note its threshold (30 minutes by default).
3. Test email delivery. In the portal, open the replication action group (`ag-replication-*`) and select **Test action group**.
4. Rehearse segments 4 and 5, then run `./scripts/demo.ps1 cleanup`. The failed-run alert resolves about 10 minutes after the rehearsal.

A shorter threshold makes staging easier. In a demonstration deployment, you can redeploy with a 20-minute threshold. Pass the values that the deployment scripts set as overrides, so that only the threshold changes:

```powershell
$image = az containerapp job show --name <active-job> --resource-group <replication-resource-group> --query "properties.template.containers[0].image" --output tsv
az deployment sub create --location <deployment-location> --parameters <parameter-file> --parameters activeRegion=<active-region> "containerImage=$image" replicationLagThresholdMinutes=20
```

For the greenfield profile, also add `acrPublicNetworkAccess=Disabled`. To confirm that nothing else would change, run `./scripts/demo.ps1 inventory -ParametersFile <parameter-file>` first.

## Before the session: stage the stale-replication alert

The stale-replication rule evaluates every 10 minutes. It fires when the active direction has no successful run within the threshold. Pause replication early enough for the alert to fire before you reach segment 3:

| Threshold | Pause at least this far ahead of segment 3 |
| --- | --- |
| 20 minutes | 35 minutes |
| 30 minutes (default) | 45 minutes |
| 60 minutes | 75 minutes |

```powershell
./scripts/demo.ps1 pause
```

The command records the job's schedule in a `ReplicationDemoOriginalCron` tag. It then changes the schedule to a single yearly run about six months away, and prints when the alert should fire. A run that's already in progress finishes and resets the clock. About 10 minutes before the session, confirm that the alert fired:

```powershell
./scripts/demo.ps1 alerts
```

To start the session with a healthy state instead, run `pause` right after segment 4 and present segment 3 at the end. With a 20-minute threshold, the alert fires 20-35 minutes after the last successful run.

Before you start:

- Open browser tabs for the replication resource group, the active job's **Execution history**, the active region's Log Analytics workspace **Logs**, **Monitor** > **Alerts**, and the mailbox.
- Open Cloud Shell in PowerShell mode at the repository root, and confirm the subscription with `az account show`.
- Cloud Shell disconnects after 20 minutes without interaction. The script keeps no local state, so reconnect and continue.

## Segment 1: Services inventory

```powershell
./scripts/demo.ps1 inventory
```

- The first table lists every resource that this solution deployed, found by its `Workload` tag: the Container Apps jobs and environments, managed identities, Log Analytics workspaces, alert rules, and the action group. The greenfield profile also lists its storage, networking, registry, and DNS resources.
- The second table lists existing resources that the jobs use but this solution doesn't manage: the storage accounts and shares, the VNets and subnets, and the registry. It is empty for the greenfield profile.
- Optionally, add `-ParametersFile <parameter-file>` for the prerequisite checks and a what-if drift report. `Exists` on every template resource means the environment matches the templates. The command passes the deployed direction, image, and registry network access as parameter overrides, so that they aren't reported as changes. What-if takes a few minutes, so you can run it before the session.

In the portal:

- Open the replication resource group and select **Resource visualizer** to show how the jobs, environments, identities, and workspaces connect.
- Open **Azure Resource Graph Explorer** and run:

  ```kusto
  resources
  | where tags['Workload'] == 'azure-files-dr-replication'
  | project name, type, resourceGroup, location
  | order by type asc
  ```

## Segment 2: Replication state

```powershell
./scripts/demo.ps1 status
```

- **Direction** and **Schedule**: one job has a schedule, and the other is a standby job with a manual trigger. After the staged pause, status shows `PAUSED` and the original schedule.
- **Jobs**: both jobs run the same digest-pinned image. `scripts/switch-direction.ps1` refuses to run if they differ.
- **Recent executions**: replication runs and any demo helper executions, labeled by kind.
- **Replication freshness**: the last successful run, its duration, and the recovery point, which is the start time of that run. Changes after the recovery point might not be in the replica yet. The state is `Healthy` or `STALE`, compared with the alert threshold.
- **Open alerts** and **Portal** links for the resource group and both jobs.

In the portal:

1. Open the active job. **Overview** shows the schedule trigger, the cron expression, and the image.
2. Select **Execution history**. It lists the status, start time, and end time of recent executions, up to the 100 most recent. Open an execution's console logs and find `AZURE_FILES_REPLICATION_SUCCEEDED startedAt=... durationSeconds=...`.
3. Select **Metrics**. Choose the **Job Executions** metric with the **Sum** aggregation, select **Apply splitting** by `state`, and set the time range to the last 24 hours. This metric drives the Sev 1 alert.
4. Open the active region's Log Analytics workspace, select **Logs**, and run:

   ```kusto
   ContainerAppConsoleLogs_CL
   | where Log_s contains "AZURE_FILES_REPLICATION_"
   | extend Result = extract(@"(AZURE_FILES_REPLICATION_[A-Z_]+)", 1, Log_s),
       StartedAt = todatetime(extract(@"startedAt=(\S+)", 1, Log_s)),
       DurationSeconds = toint(extract(@"durationSeconds=(\d+)", 1, Log_s))
   | where Result in ("AZURE_FILES_REPLICATION_SUCCEEDED", "AZURE_FILES_REPLICATION_FAILED")
   | project TimeGenerated, Job = column_ifexists("ContainerJobName_s", ""), Result, StartedAt, DurationSeconds
   | order by TimeGenerated desc
   ```

   The stale-replication alert uses this signal. To show the minutes since the last success:

   ```kusto
   ContainerAppConsoleLogs_CL
   | where Log_s contains "AZURE_FILES_REPLICATION_SUCCEEDED"
   | summarize LastSuccess = max(TimeGenerated)
   | extend MinutesSinceLastSuccess = datetime_diff('minute', now(), LastSuccess)
   ```

The same history is available from the Azure CLI:

```powershell
az containerapp job execution list --name <active-job> --resource-group <replication-resource-group> `
    --query "[].{name:name, status:properties.status, start:properties.startTime, end:properties.endTime}" --output table
```

## Segment 3: Stale-replication alert

Show:

- **Monitor** > **Alerts**, with the fired Sev 2 `alert-replication-stale-<region>-*` alert. Open it to show the condition: no success marker within the threshold, evaluated every 10 minutes.
- The email notification.
- `./scripts/demo.ps1 alerts`, which lists both rule types, the masked notification address, and the fired and resolved alerts.

This alert catches failures that never produce a failed execution: a disabled or changed schedule, a deleted job, executions that never start, or logs that stop arriving.

Resume replication:

```powershell
./scripts/demo.ps1 resume
```

The next scheduled run starts at the next schedule boundary, and segment 4 runs one immediately. The alert resolves about 30 minutes after the first successful run, after three evaluations without the condition. You can show the resolved alert at the end of the session.

## Segment 4: Live replication

```powershell
./scripts/demo.ps1 seed        # Write replication-demo/demo-<time>.txt to the source share.
./scripts/demo.ps1 files       # The file is in the source share, not yet in the replica.
./scripts/demo.ps1 replicate   # Run replication now instead of waiting for the schedule.
./scripts/demo.ps1 files       # The file is in both shares.
```

Each command takes 2-5 minutes. The execution starts within seconds and finishes in about a minute, and its console output reaches Log Analytics a few minutes later. Meanwhile, show the new execution in the job's **Execution history**.

- The storage accounts deny public network access, so the portal's file share browser can't list the files from your browser. The demo lists them from inside the job's network, with the job's identity, which is the same path that replication uses.
- `replicate` starts the same execution that the schedule starts. It prints the success marker and the AzCopy summary of transferred files, bytes, and failures.
- If a replication run is already in progress, `replicate` follows it instead of starting a second copy into the same destination.
- A scheduled run can copy the file before you run `replicate`. If the first `files` already shows the file in both shares, point out that the schedule replicated it, and continue.

## Segment 5: Failed-run alert

```powershell
./scripts/demo.ps1 fail-run
```

1. The script starts one execution of the active job with `SOURCE_FILE_URL` pointed at a share that doesn't exist, and with `DELETE_DESTINATION=false`. Nothing is copied or deleted, and the job definition and schedule don't change.
2. AzCopy fails with `ShareNotFound`, and the wrapper prints `AZURE_FILES_REPLICATION_FAILED` and exits with a nonzero code. The job retries the replica twice, then marks the execution `Failed`, after 2-3 minutes.
3. The **Job Executions** metric records the failed execution. The Sev 1 rule evaluates every minute and usually fires within 5 minutes. The script waits and reports when the alert fires.
4. The action group sends the email.

In the portal, show the failed execution in **Execution history**, its console log with the AzCopy error and the failure marker, the failed execution in **Metrics**, the fired Sev 1 alert in **Monitor** > **Alerts**, and the email.

The alert resolves automatically about 10 minutes later, after three one-minute evaluations without a failure, and the action group sends a resolved notification. The alert is stateful: while it's firing, another failure raises no new alert or email, so run `fail-run` once and wait for the alert to resolve before you repeat it.

A real outage follows the same path. An unreachable share, a DNS or network break, or a missing role assignment makes AzCopy exit with a nonzero code, which fails the execution. The alert uses the platform metric rather than the log, so it also fires when the container can't start, for example when the image can't be pulled.

## Segment 6: Standby readiness (optional)

```powershell
./scripts/demo.ps1 standby-check
```

The standby job runs `azcopy sync --dry-run` in the reverse direction. The run shows that the standby region's image pull, managed identity, DNS, and network path to both shares work, without writing data. The counts show what a reverse run would copy. Expect most files, because replicated files are newer than their source copies, so plan for a full-share copy after a direction switch.

Failover uses `scripts/switch-direction.ps1` after application writes are fenced. See [Switch direction](../README.md#switch-direction). Don't switch direction during the demo unless the environment is disposable.

## After the session

```powershell
./scripts/demo.ps1 cleanup   # Delete replication-demo/ from both shares.
./scripts/demo.ps1 status    # The schedule is restored and no alerts are open.
./scripts/demo.ps1 alerts    # Both alerts show a resolved time.
```

- If you skipped segment 3, run `./scripts/demo.ps1 resume`.
- Alerts resolve on their own. To remove them from the default portal view, change their alert state to **Closed**.
- The helper executions stay in the execution history, which keeps the 100 most recent executions.
- If you shortened the threshold, redeploy with the original value.

## Command reference

Run each command as `./scripts/demo.ps1 <command> [parameters]`. Without a command, the script runs `status`.

| Command | Purpose | Parameters |
| --- | --- | --- |
| `status` | Direction, jobs, recent executions, freshness, open alerts, and portal links | |
| `inventory` | Deployed and referenced resources; with a parameter file, prerequisites and a what-if drift report | `-ParametersFile` |
| `seed` | Write a timestamped demo file to the source share | `-DemoFolder`, `-Force` |
| `files` | List the demo folder in both shares and compare them | `-DemoFolder` |
| `replicate` | Start a replication run now, or follow one that's running, and summarize the result | `-NoWait`, `-Force` to run while paused |
| `fail-run` | Start one failing execution and wait for the Sev 1 alert | `-NoWait`, `-Force` |
| `pause` | Stop scheduled replication and estimate when the stale-replication alert fires | `-Force` |
| `resume` | Restore the recorded schedule | `-CronExpression` for a job without the pause tag |
| `alerts` | Alert rules, notification targets, and alert history | `-TimeRange 1h`, `1d`, `7d`, or `30d` |
| `standby-check` | Dry run of the reverse direction from the standby job | `-NoWait` |
| `cleanup` | Delete the demo folder from both shares | `-DemoFolder`, `-Force` |

These parameters apply to every command:

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-ResourceGroupName` | `$env:REPLICATION_DEMO_RESOURCE_GROUP`, then `rg-azure-files-replication-demo` | The replication resource group |
| `-TimeoutMinutes` | `15` | How long to wait for an execution or an alert |
| `-NoWait` | Off | Return after starting an execution |
| `-WhatIf` | Off | Show what would change without changing it |

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| `No Container Apps jobs tagged Workload=...` | The resource group or subscription is wrong. Pass `-ResourceGroupName`, set `REPLICATION_DEMO_RESOURCE_GROUP`, or run `az account set`. |
| `still runs the placeholder image` | The deployment hasn't finished. Deploy the AzCopy image first. |
| `The execution output hasn't reached Log Analytics yet` | Log ingestion can take several minutes. Open the execution in **Execution history**, or rerun the command. |
| `seed` or `files` shows AzCopy `403` errors | The job identity is missing Storage File Data Privileged Contributor, or DNS or a firewall routes the request to a public endpoint. See [Troubleshooting](../README.md#troubleshooting). |
| `The helper execution did not succeed` | The container couldn't start. Check the execution's system logs for image pull or registry errors. |
| The stale-replication alert hasn't fired | In `alerts`, confirm that the active direction's rule is enabled. In `status`, check the last successful run; a run in progress when you paused resets the clock. Allow the threshold plus 15 minutes. |
| The failed-run alert hasn't fired after 15 minutes | Check **Metrics** for a failed execution, confirm that the rule is enabled, and rerun `alerts`. |
| No email arrives | Check junk mail and the action group's email receivers, and use **Test action group**. |
| `replicate` refuses to run | Scheduled replication is paused. Run `resume`, or pass `-Force` to run once while paused; the successful run resets the stale-replication clock. |
| Cloud Shell disconnected | Reconnect and rerun `status`. The pause tag on the job keeps the original schedule. |

## Safety notes

- Pausing stops replication, so the replica falls behind until you resume. Use a demonstration deployment or a maintenance window.
- The script never starts the standby job without a command override. Don't select **Run now** on the standby job in the portal, because that runs a real reverse replication.
- `fail-run` changes only the source URL of one execution and forces `DELETE_DESTINATION=false`, so the replica isn't touched.
- Helper executions don't print the success marker, so they can't hide stale replication.
- `pause` records the original schedule before it changes the schedule. A redeployment of the templates also restores the schedule.
- An execution with a command override runs as the job's managed identity, which can read, write, and delete data in both shares. Grant `Microsoft.App/jobs/start/action` only to replication operators.
