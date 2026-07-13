---
name: diagnose-edge
description: Diagnose a Palette edge cluster or edge host. Use when an edge cluster is offline, not registering, stuck in provisioning, or showing an unhealthy state. Accepts a cluster or edge host name as argument.
---

# Diagnose Edge Cluster

Perform structured triage of a Palette edge deployment. Argument: `$ARGUMENTS` (cluster or edge host name — if blank, list edge hosts and ask the user to pick).

## Steps

1. **Identify the target**
   - If `$ARGUMENTS` is blank: call `read_edge_hosts` (no filters) and present host names, `state` (ready/unpaired/in-use), and `health_state` (healthy/unhealthy). Ask the user which host to diagnose.
   - If `$ARGUMENTS` is provided: call `read_edge_hosts` with `filters.name` set to `$ARGUMENTS` to resolve the target. If more than one host matches, list the matches (name, host_address, state, health_state) and ask the user to pick before proceeding. Only when exactly one match is found, extract `uid`, `health_state`, `state`, `host_address`, `type`, and `in_use_cluster_uids` from the response.

2. **Check edge host status**
   - The response from step 1 already carries the current status fields — no second `read_edge_hosts` call is needed unless UID-mode detail is required.
   - Surface:
     - `state`: `unpaired` means the host has not registered with a cluster; `in-use` means it is assigned; `ready` means registered and available.
     - `health_state`: `unhealthy` indicates the Palette agent on the host is not reporting correctly.
     - `host_address` / `mac_address`: useful for cross-referencing network or firewall rules.
   - **Note:** `read_edge_hosts` does not return heartbeat or last-seen timestamps. Use `health_state` as the connectivity signal — `unhealthy` is the equivalent indicator of a stale or lost agent connection.

3. **Triage edge host events** (requires the host `uid` from step 1)
   - Call `read_events` with `object_kind="edgehost"`, `object_uid=<host uid>`, and `limit=20`.
   - Look for registration failures, heartbeat timeouts, and bootstrap errors — these explain `unpaired` or `unhealthy` states that the status fields alone do not.
   - Prioritise events with `severity=Error` and any `reason` beginning with `Failed`.
   - **Note:** `read_events` requires a `palette-mcp` binary that exposes the `read_events` tool. If the tool is unavailable in this session, skip this step and rely on `health_state` plus the on-host agent checks below.

4. **Check the associated cluster** (only if `in_use_cluster_uids` is non-empty)
   - Use the first UID from `in_use_cluster_uids` as the cluster UID.
   - Call `read_cluster_status` with that cluster UID and `fields=["status"]`.
   - Surface: provisioning state, node readiness, any condition messages specific to edge (e.g. `EdgeHostNotReachable`, `NodeNotReady`).
   - If `in_use_cluster_uids` is empty, skip this step and note that the host is not yet attached to a cluster — likely an unpaired or registration issue.

5. **Check attached profiles** (only if a cluster UID was resolved in step 4)
   - Call `read_attached_profiles_to_cluster` with the cluster UID.
   - Surface: profile names, pack names and versions, any packs in a failed or pending state.
   - Edge clusters are sensitive to pack mismatches — note any packs that do not support the edge Kubernetes version.

6. **Synthesise findings**
   - Group findings into three buckets:

   **Connectivity issues** (`health_state: unhealthy` or `state: unpaired`)
   - Suggests the Palette edge agent on the host is not reachable or has not paired.
   - Recommended actions: verify network connectivity from the host to the Palette endpoint, check firewall rules on the host, confirm the edge agent service is running (`systemctl status palette-edge-agent` or equivalent), re-run the pairing flow if the host was never paired.

   **Provisioning issues** (cluster status errors, pack failures)
   - Surface the specific condition message and the failing pack/version.
   - Suggest checking pack compatibility with the edge Kubernetes version and reviewing the cluster event log.

   **Resource issues** (node pressure reported by `read_cluster_status`)
   - Surface node readiness count vs expected.
   - Suggest reviewing node-level resources if reachable via the Palette console.

7. **Offer next steps**
   - If write tools (`update_cluster`, `delete_cluster`, `create_cluster`) are present in this session, offer to proceed with applicable remediation (e.g. reprovisioning a failed pack, forcing a cluster re-sync).
   - Otherwise, summarise findings and provide manual next-step guidance for the operator to action on the host or via the Palette UI.
