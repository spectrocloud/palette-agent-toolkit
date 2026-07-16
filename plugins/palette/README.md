# Palette Claude Plugin

Connect your AI assistant to Palette — query clusters, diagnose issues, and manage infrastructure using natural language.

Requires a recent `palette-mcp` binary that includes the cluster, edge-host, and profile read tools (`read_cluster_observability`, `read_edge_hosts`, `read_attached_profiles_to_cluster`). Confirm your binary exposes these via `/mcp` once the plugin is loaded (see [Test](#test)).

## Distribution

The plugin and skills are distributed via the public [palette-agent-toolkit](https://github.com/spectrocloud/palette-agent-toolkit) marketplace.

**Claude Code** — register the marketplace and install:

```
/plugin marketplace add spectrocloud/palette-agent-toolkit
/plugin install palette@palette-agent-toolkit
```

## Prerequisites

Export these in your shell profile (`~/.zshrc` or `~/.bashrc`) before launching your AI client:

```bash
export PALETTE_HOST="your-tenant.spectrocloud.com"
export PALETTE_API_KEY="your-api-key"
```

Instead of an API key, you may authenticate with a JWT by exporting `PALETTE_AUTH_TOKEN="your-token"` (use either `PALETTE_API_KEY` or `PALETTE_AUTH_TOKEN`, not both). For on-prem Palette behind a private CA, set `PALETTE_CA_FILE` to your CA bundle path.

The plugin operates at **tenant scope** by default — all projects are visible. If you want to scope the session to a single project, also export `PALETTE_PROJECT_UID="your-project-uid"` and the server will restrict all calls to that project.

> **Important:** your API key and `PALETTE_HOST` must belong to the **same tenant**. A key only authenticates against the tenant it was created in — a mismatch produces a `401` error.

Ensure `palette-mcp` binary is installed and in your `PATH`. Download a versioned release for your platform from [palette-agent-toolkit GitHub Releases](https://github.com/spectrocloud/palette-agent-toolkit/releases), then verify it against the matching checksums file:

```bash
VERSION=v0.4.0

# Choose one:
ASSET=palette-mcp_darwin_arm64.tar.gz  # macOS Apple Silicon
# ASSET=palette-mcp_darwin_amd64.tar.gz  # macOS Intel
# ASSET=palette-mcp_linux_amd64.tar.gz   # Linux amd64
# ASSET=palette-mcp_linux_arm64.tar.gz   # Linux arm64

BASE_URL="https://github.com/spectrocloud/palette-agent-toolkit/releases/download/${VERSION}"
CHECKSUMS="palette-mcp_${VERSION#v}_checksums.txt"

curl -LO "${BASE_URL}/${ASSET}"
curl -LO "${BASE_URL}/${CHECKSUMS}"
grep "  ${ASSET}$" "${CHECKSUMS}" | shasum -a 256 -c -

tar xzf "${ASSET}"
sudo mv palette-mcp /usr/local/bin/
```

Supported platforms: `darwin_arm64`, `darwin_amd64`, `linux_amd64`, `linux_arm64`.

> On macOS, downloaded binaries are quarantined by Gatekeeper and your client may fail to launch them silently. Clear the flag once: `xattr -d com.apple.quarantine /usr/local/bin/palette-mcp`.

**Migrating from manual setup?** Remove the existing `palette` entry from your client MCP config (`~/.claude.json` or equivalent) before installing this plugin to avoid duplicate server registration.

### Verify your credentials (recommended)

Before launching your client, confirm the host and API key are valid and matched — this turns a confusing in-session auth error into a clear pass/fail:

```bash
[ -z "$PALETTE_HOST" ] || [ -z "$PALETTE_API_KEY" ] && echo "Set PALETTE_HOST and PALETTE_API_KEY first" || \
  curl -s -o /dev/null -w "HTTP %{http_code}\n" -H "ApiKey: $PALETTE_API_KEY" "https://$PALETTE_HOST/v1/users/me"
```

- `HTTP 200` — credentials are valid; proceed to install.
- `HTTP 401` — key is invalid/expired, or key and host belong to different tenants. Create a fresh key from the `PALETTE_HOST` tenant's UI.
- `Set PALETTE_HOST and PALETTE_API_KEY first` — the env vars aren't exported in this shell; run the `export` commands above and retry.

This pre-flight validates API-key auth only. If you use `PALETTE_AUTH_TOKEN`, confirm the token with your normal Palette login flow before launching the plugin.

## Install

Installing is a two-step process: first register the Spectro Cloud marketplace, then install the plugin.

**Step 1 — Add the marketplace** (one-time):

```
/plugin marketplace add spectrocloud/palette-agent-toolkit
```

**Step 2 — Install the plugin:**

```
/plugin install palette@palette-agent-toolkit
```

> The `@palette-agent-toolkit` suffix is the **marketplace name** (declared in `marketplace.json`).

Run `/reload-plugins` after installing to activate it in your current session.

## Skills

| Skill | Invoke | Use when |
|-------|--------|----------|
| `diagnose-cluster` | `/palette:diagnose-cluster [name]` | Cloud cluster in error/degraded state |
| `diagnose-edge` | `/palette:diagnose-edge [name]` | Edge host offline, not registering, losing heartbeat |
| `health-overview` | `/palette:health-overview` | Fleet-wide health check — "what's broken across my tenant?" |
| `access-review` | `/palette:access-review [name]` | Who's on which team, who's pending activation, any orphaned accounts |

## Test

After installing, verify the plugin loaded and the MCP server connected:

```
/help                  → "palette" skills appear (diagnose-cluster, diagnose-edge, health-overview, access-review)
/mcp                   → palette server shows "connected"
List all my clusters   → returns real data from your tenant
```

`/mcp` showing **connected** is the key signal that the MCP server started and authenticated successfully.

## Available MCP Tools

Once the plugin is installed and environment variables are set, the following Palette tools are available in your session:

- `read_clusters` — list all clusters with status
- `read_cluster_status` — detailed health and conditions for a cluster UID
- `read_cluster_observability` — compliance scan, backup, and restore status for a cluster UID
- `read_attached_profiles_to_cluster` — profiles and pack versions for a cluster UID
- `read_events` — recent events for a resource (optional; requires a binary that exposes it)
- `read_edge_hosts` — list edge hosts with registration and connectivity status
- `read_cluster_profiles` — list cluster profiles
- `read_packs` — list available packs
- `read_cloud_accounts` — list configured cloud accounts
- `read_registries` — list registries
- `read_projects` — list projects
- `read_teams` — list teams
- `read_users` — list users

**Write tools** (`create_*`, `update_*`, `delete_*` for clusters, profiles, projects, teams, users) are **off by default**. To enable them, start `palette-mcp` with the `--allow-write` flag — add it to `args` in the plugin's `.mcp.json` (`"args": ["--allow-write"]`).

## Troubleshooting

**`/mcp` shows palette failed or disconnected**
- Confirm `PALETTE_HOST` and `PALETTE_API_KEY` are exported in the shell that launched your client (the server reads them at startup).
- Run the credential pre-flight above — a `401` means the key is invalid/expired or the key and host belong to different tenants.

**`401` / authorization errors when running a skill**
- The most common cause: the API key and `PALETTE_HOST` are for different tenants. A key only works against the tenant it was created in. Create a fresh key from the `PALETTE_HOST` tenant's UI.

**`OperationForbidden` errors**
- Your account lacks tenant-wide access. Export `PALETTE_PROJECT_UID` to scope the session to a project you have access to.

**Skills don't appear in `/help`**
- Run `/reload-plugins`, or confirm the install with `claude plugin details palette@palette-agent-toolkit`.
