---
name: health-overview
description: Morning standup / fleet health check — use for "how's the fleet?", "is anything broken?", "what's degraded right now?", "tenant health check". Breadth-first scan across ALL clusters and edge hosts in the tenant; surfaces everything in error or unhealthy state. Not a single-cluster deep dive — for root cause on one cluster use diagnose-cluster, for one edge host use diagnose-edge. Takes no arguments.
---

# Fleet Health Overview

Scan the entire tenant for clusters and edge hosts that are unhealthy, in error, or stuck. This is a breadth-first scan — it tells you *what* is wrong, not *why*. For root cause on a single resource, use `diagnose-cluster` or `diagnose-edge`.

## Steps

1. **Scan clusters in Error** (the "something is broken" signal)
   - Call `read_cluster_status` with `filters={states:{in:["Error"]}}` and `fields=["metadata","status.state"]`.
   - Check the response for `listmeta.continue`. If present, call again with `continue=<token>` and repeat until `listmeta.continue` is absent or empty. Collect all pages before proceeding.
   - These clusters have a failed lifecycle operation — highest priority.

2. **Scan clusters with in-progress operations** (informational, not failures)
   - Call `read_cluster_status` with `filters={states:{in:["Pending","Provisioning","Deleting"]}}` and `fields=["metadata","status.state"]`. Paginate via `listmeta.continue` if present.
   - These are mid-operation, NOT failures — report them in a separate "in progress" bucket so they don't read as problems. A cluster normally passes through Pending/Provisioning on create and Deleting on teardown.

3. **Scan clusters that are unhealthy** (independent of lifecycle state)
   - Call `read_cluster_status` with `filters={health_state:{eq:"UnHealthy"}}` and `fields=["metadata","status.state"]`. Paginate via `listmeta.continue` if present.
   - ⚠ The value is `UnHealthy` (capital H) — wrong casing returns an empty set silently.
   - A cluster can be `Running` AND `UnHealthy` — keep these two axes separate when reporting.

4. **Scan unhealthy edge hosts**
   - Call `read_edge_hosts` with `filters={health_state:"unhealthy"}`.
   - ⚠ Edge-host health values are lowercase (`unhealthy`), unlike clusters (`UnHealthy`).

5. **Scan unpaired edge hosts**
   - Call `read_edge_hosts` with `filters={state:"unpaired"}`.
   - Unpaired hosts have registered hardware but never completed pairing — a common silent fleet gap.

6. **Synthesise the fleet report**
   - Group findings into:
     - 🔴 **Clusters in Error** — name, project, last state. Highest priority.
     - 🟡 **Clusters Running-but-Unhealthy** — name, project. Degraded but live.
     - 🟡 **Edge hosts unhealthy** — name, project, in_use_cluster_uids.
     - 📌 **Edge hosts unpaired** — name, project. Onboarding gap.
     - 📌 **In-progress operations** — clusters in Pending/Provisioning/Deleting. Context only, not problems.
   - If every problem scan returns empty: report "fleet is healthy — no clusters in error/unhealthy state, all edge hosts paired and healthy."
   - For each problem cluster, suggest: "run /diagnose-cluster <name> for root cause." For each problem edge host: "run /diagnose-edge <name>."

## Notes
- **Clusters are filtered server-side** — `read_cluster_status` filters at the API, so the result set is bounded to only the matching resources and works on fleets larger than the 50-item page limit. If a single filter exceeds 50 results, paginate via `continue` (rare for the degraded set).
- ⚠ **Edge hosts are filtered CLIENT-side** — `read_edge_hosts` fetches the full tenant edge-host list and filters inside the MCP server. On very large edge fleets this transfers the whole list over the wire even though only the degraded subset is returned. Acceptable for v1; note it if a tenant has thousands of edge hosts.
- Strictly read-only. It never offers remediation — that belongs to the diagnose-* skills which have the per-resource context.
