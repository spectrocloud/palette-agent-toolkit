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

Configure your Palette credentials through Claude Code's plugin configuration — no shell exports, no `.env` files. After enabling the plugin, run `/plugin` → **palette** → **Configure options** and set:

| Option | Notes |
|--------|-------|
| **Palette host** | Your tenant URL, e.g. `example.spectrocloud.com` |
| **Palette API key** | Create under **User Menu → My API Keys** |
| **Palette auth token** | JWT alternative — provide an API key **or** an auth token, not both |
| **Default project UID** | Optional — scope all calls to one project; omit for tenant-wide access |
| **Custom CA file path** | Optional — CA bundle for a self-hosted Palette behind a private CA |

At minimum, set **host** and one of **API key** / **auth token**. The API key and auth token are marked *sensitive*, so Claude Code stores them in your OS credential store — macOS **Keychain**, Windows **Credential Manager**, or the Linux **Secret Service** where available (falling back to `~/.claude/.credentials.json` at mode `0600` on headless Linux) — never in a project file or the repo. Non-sensitive options (host, project, CA path) live in `~/.claude/settings.json`. For non-interactive / CI provisioning, pass repeatable `--config` flags at install time:

```bash
claude plugin install palette@palette-agent-toolkit \
  --config host=example.spectrocloud.com --config api_key=<your-key>
```

> **Same-tenant rule:** your API key and host must belong to the **same tenant** — a key only authenticates against the tenant it was created in, so a mismatch returns a `401` error.

**Upgrading from an earlier version?** The plugin no longer reads exported `PALETTE_*` shell variables — set your credentials via **Configure options** above. The insecure TLS-skip option was also removed from the plugin; use **Custom CA file path** for a self-hosted private CA.

The plugin is **self-contained** — it downloads and checksum-verifies the correct `palette-mcp` binary on first use (cached under the plugin's data directory), so no binary install is required. The steps below are only for **non-plugin MCP clients** that need `palette-mcp` on your `PATH`. `install.sh` detects your OS and architecture, downloads the matching release, and verifies its checksum:

```bash
REPO="spectrocloud/palette-agent-toolkit"
curl -fsSLO "https://raw.githubusercontent.com/${REPO}/v0.4.1/install.sh"
less install.sh          # read it before running
sh install.sh            # --version vA.B.C pins the binary; --bin-dir DIR changes the location
```

Or in one line (prefer the read-first form on shared or production hosts):

```bash
curl -fsSL "https://raw.githubusercontent.com/spectrocloud/palette-agent-toolkit/v0.4.1/install.sh" | sh
```

### Manual install

Prefer not to run a script? Download the release for your platform and verify it against the checksums file:

```bash
REPO="spectrocloud/palette-agent-toolkit"
BASE_URL="https://github.com/${REPO}/releases/latest/download"

# Choose one:
ASSET=palette-mcp_darwin_arm64.tar.gz  # macOS Apple Silicon
# ASSET=palette-mcp_darwin_amd64.tar.gz  # macOS Intel
# ASSET=palette-mcp_linux_amd64.tar.gz   # Linux amd64
# ASSET=palette-mcp_linux_arm64.tar.gz   # Linux arm64

# Download the latest binary:
curl -fLO "${BASE_URL}/${ASSET}"

# Download the matching checksums and verify:
VERSION=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
  "https://github.com/${REPO}/releases/latest" | grep -o '[^/]*$')
curl -fLO "${BASE_URL}/palette-mcp_${VERSION#v}_checksums.txt"
grep "  ${ASSET}$" "palette-mcp_${VERSION#v}_checksums.txt" | shasum -a 256 -c -

tar xzf "${ASSET}"
sudo mv palette-mcp /usr/local/bin/
```

Supported platforms: `darwin_arm64`, `darwin_amd64`, `linux_amd64`, `linux_arm64`.

> On macOS, a browser-downloaded binary may be quarantined by Gatekeeper and fail to launch silently (a `curl` download usually isn't). If that happens, clear the flag: `xattr -d com.apple.quarantine /usr/local/bin/palette-mcp`.

**Migrating from manual setup?** Remove the existing `palette` entry from your client MCP config (`~/.claude.json` or equivalent) before installing this plugin to avoid duplicate server registration.

### Verify your credentials (recommended)

> For **non-plugin clients** that use exported environment variables (the binary path above). Claude Code plugin users configure via **Configure options** and can skip this.

With `PALETTE_HOST` and `PALETTE_API_KEY` exported, confirm they're valid and matched — this turns a confusing in-session auth error into a clear pass/fail:

```bash
if [ -z "$PALETTE_HOST" ] || [ -z "$PALETTE_API_KEY" ]; then
  echo "Set PALETTE_HOST and PALETTE_API_KEY first"
else
  curl -s -o /dev/null -w "HTTP %{http_code}\n" -H "ApiKey: $PALETTE_API_KEY" "https://$PALETTE_HOST/v1/users/me"
fi
```

- `HTTP 200` — credentials are valid; proceed to install.
- `HTTP 401` — key is invalid/expired, or key and host belong to different tenants. Create a fresh key from the `PALETTE_HOST` tenant's UI.
- `Set PALETTE_HOST and PALETTE_API_KEY first` — the env vars aren't exported in this shell; export both and retry.

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

Once the plugin is installed and configured, the following Palette tools are available in your session:

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
- Confirm your credentials are set: `/plugin` → **palette** → **Configure options** (host + API key).
- A `401` means the key is invalid/expired, or the key and host belong to different tenants.

**`401` / authorization errors when running a skill**
- The most common cause: the API key and host are for different tenants. A key only works against the tenant it was created in — create a fresh key from that tenant's UI.

**`OperationForbidden` errors**
- Your account lacks tenant-wide access. Set **Default project UID** in Configure options to scope to a project you can access.

**Skills don't appear in `/help`**
- Run `/reload-plugins`, or confirm the install with `claude plugin details palette@palette-agent-toolkit`.
