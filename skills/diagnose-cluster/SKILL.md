---
name: diagnose-cluster
description: Diagnose a degraded, error, or unhealthy cloud cluster. Use when a cluster is in an error state, stuck or failing to provision, or behaving unexpectedly. Accepts a cluster name or UID as argument.
---

# Diagnose Cloud Cluster

Perform a structured triage of a Palette cloud cluster. Argument: `$ARGUMENTS` (cluster name or UID — if blank, list clusters and ask the user to pick one).

## Steps

1. **Identify the cluster**
   - If `$ARGUMENTS` is blank: call `read_clusters` and present names + current status. Ask the user which cluster to diagnose.
   - If `$ARGUMENTS` looks like a UID (long alphanumeric string): call `read_clusters` with `uid=$ARGUMENTS` directly to resolve it.
   - If `$ARGUMENTS` looks like a name: call `read_clusters` with `filters={name:{contains:"$ARGUMENTS"}}`. If more than one cluster matches, list the matches (name, project, state) and ask the user to pick before proceeding. Only when exactly one match is found, extract its UID for subsequent calls.

2. **Read cluster status** (requires UID from step 1)
   - Call `read_cluster_status` with the cluster UID and `fields=["status"]`.
   - Surface: overall health, condition messages, last transition time, any error codes.

3. **Triage cluster events** (requires UID from step 1)
   - Call `read_events` with `object_kind="spectrocluster"`, `object_uid=<cluster uid>`, and `limit=20`.
   - Look for events with `severity=Error` and any `reason` beginning with `Failed` — these usually pinpoint the failing reconcile step or pack.
   - Correlate the most recent error events with the condition messages from step 2 to confirm the root cause.
   - **Note:** `read_events` requires a `palette-mcp` binary that exposes the `read_events` tool. If the tool is unavailable in this session, skip this step and rely on the status and observability signals.

4. **Read scan and backup observability** (requires UID from step 1)
   - Call `read_cluster_observability` with the cluster UID and `include=["scans","backup","restore"]`.
   - Surface: compliance scan results (last scan time, pass/fail status), backup status (last backup time, success/failure), restore status if applicable.
   - A failed or overdue scan, or a failed backup, can be a secondary signal of cluster health degradation.

5. **Check attached profiles and packs** (requires UID from step 1)
   - Call `read_attached_profiles_to_cluster` with the cluster UID.
   - Surface: profile names, pack versions, any packs in a failed or pending state.

6. **Synthesise findings**
   - Group findings into: **Blockers** (likely root cause), **Warnings** (contributing factors), **Info** (context).
   - For each blocker, suggest a remediation action based on the error message and pack state.
   - If root cause is unclear, suggest next steps: check cloud account credentials (`read_cloud_accounts`), review pack compatibility.

7. **Ask if user wants to act**
   - If write tools are available in this session, offer to proceed with any applicable remediation.
   - Otherwise, summarise findings and link to relevant Palette docs where applicable.
