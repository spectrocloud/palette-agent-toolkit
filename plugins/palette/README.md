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
| **Custom CA file path** | Optional — CA bundle for a self-hosted Palette behind a private CA |
| **Enable write tools** | Optional — turns on `create_*`/`update_*`/`delete_*` tools. Off by default |
| **Enable direct-SSH edge tools** | Optional — turns on `run_edge_command` and the read-only edge SSH tools. Off by default |

At minimum, set **host** and one of **API key** / **auth token**. The API key and auth token are marked *sensitive*, so Claude Code stores them in your OS credential store — macOS **Keychain**, Windows **Credential Manager**, or the Linux **Secret Service** where available (falling back to `~/.claude/.credentials.json` at mode `0600` on headless Linux) — never in a project file or the repo. Non-sensitive options (host, CA path) live in `~/.claude/settings.json`. For non-interactive / CI provisioning, pass repeatable `--config` flags at install time:

```bash
claude plugin install palette@palette-agent-toolkit \
  --config host=example.spectrocloud.com --config api_key=<your-key>
```

> **Same-tenant rule:** your API key and host must belong to the **same tenant** — a key only authenticates against the tenant it was created in, so a mismatch returns a `401` error.

**Upgrading from an earlier version?** The plugin no longer reads exported `PALETTE_*` shell variables — set your credentials via **Configure options** above. The insecure TLS-skip option was also removed from the plugin; use **Custom CA file path** for a self-hosted private CA.

The plugin is **self-contained** — it downloads and checksum-verifies the correct `palette-mcp` binary on first use (cached under the plugin's data directory), so no binary install is required. The steps below are only for **non-plugin MCP clients** that need `palette-mcp` on your `PATH`. `install.sh` detects your OS and architecture, downloads the matching release, and verifies its checksum:

```bash
REPO="spectrocloud/palette-agent-toolkit"
curl -fsSLO "https://raw.githubusercontent.com/${REPO}/v0.6.1/install.sh"
less install.sh          # read it before running
sh install.sh            # --version vA.B.C pins the binary; --bin-dir DIR changes the location
```

Or in one line (prefer the read-first form on shared or production hosts):

```bash
curl -fsSL "https://raw.githubusercontent.com/spectrocloud/palette-agent-toolkit/v0.6.1/install.sh" | sh
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

This pre-flight validates API-key auth only. If you use `PALETTE_AUTH_TOKEN`, confirm the token with your normal Palette login flow before launching your client. If you've configured your credentials through `~/.palette/auth_profiles.yaml` instead (see [Multi-profile setup](#multi-profile-setup-advanced) below), skip this check too — `palette-mcp configure` already validates each profile's credential with a real API call before saving it.

### Multi-profile setup (advanced)

The steps above configure one Palette tenant/host — the **default** profile. To target more than one from the same session (dev vs. prod, or a second customer tenant) without restarting your client, add named profiles to `~/.palette/auth_profiles.yaml` and pass `auth_profile: "<name>"` on any tool call. Your plugin **Configure options** (or exported env vars) keep working unchanged as the implicit `default` profile — this is additive, not a replacement.

Add a profile with the binary's own wizard rather than hand-editing YAML:

```bash
palette-mcp configure
```

It prompts for a profile name, host, and one of API key/JWT; validates the credential with one real API call before saving; and writes the entry to `~/.palette/auth_profiles.yaml` at `0600`. This is an operator step run at a terminal, never something an agent does through chat, since it's the one place your API key/JWT is typed in.

`configure` needs `palette-mcp` on your `PATH` — the self-contained plugin install doesn't put it there (it caches the binary internally for its own launcher). Fetch it once via [Manual install](#manual-install) above just to run this command; you don't need to switch your MCP client off the plugin to do so.

```text
$ palette-mcp configure
Profile name (e.g. default, dev, prod-eu): dev
Palette host (e.g. api.spectrocloud.com): dev.spectrocloud.com
API key (leave blank to use a JWT instead): sk-...
CA file path, for a self-hosted install with its own CA (leave blank to inherit PALETTE_CA_FILE / auto-bootstrap):
Validating credential against dev.spectrocloud.com ...
Credential valid.
Saved profile "dev" to /Users/you/.palette/auth_profiles.yaml (0600).
Reconnect your MCP client (/mcp in Claude Code, or restart) to pick it up — no hot-reload.
```

After adding or changing a profile, reconnect (`/mcp` in Claude Code, or restart your client) — there's no hot-reload. Then:

- `list_auth_profiles` — see what's loaded (names + hosts only, never secrets).
- Add `auth_profile: "dev"` to any tool call to target that profile; omit it to keep using `default`.

To use a profiles file at a non-default path (e.g. a shared CI location), set `PALETTE_PROFILES_FILE` before launching your client — the plugin's `.mcp.json` forwards it through.

Profiles written by `configure` are identity only (host + credential) — they don't carry a project. Tools that already take their own `project_uid` argument (e.g. `create_cluster_profile`) work the same way regardless of which `auth_profile` you pass.

**Per-profile CA (two self-hosted installs, different CAs).** `PALETTE_CA_FILE` is one global env var — every profile shares it. That's fine when all your self-hosted/IP installs share one CA, but two *different* self-hosted CAs in the same session need each profile to pin its own: answer the CA-file prompt above with that profile's chain (or add `ca_file: /path/ca.pem` directly to its entry in `auth_profiles.yaml`), and it overrides `PALETTE_CA_FILE` for that profile only — other profiles with no `ca_file` of their own still fall back to the env var, or auto-bootstrap if that's unset too. This has no effect on the `default` profile: the boot-time client is always built directly from `PALETTE_HOST`/`PALETTE_CA_FILE` env vars at startup, never from a profile entry — `configure` warns if you set a CA file on `default`.

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

`diagnose-cluster` can additionally run read-only `kubectl` against a
customer cluster. The real safety boundary there is a read-only kubeconfig,
minted per-session by a bundled script and backed by genuine cluster RBAC —
the admin kubeconfig is fetched only transiently to bootstrap it, never used
for the kube-API commands themselves. An optional, opt-in
`kubectl-readonly.settings.json` permission template is also included; it
only takes effect if you merge it into your own `.claude/settings.json`. See
[KUBECTL_GUARDRAILS.md](skills/diagnose-cluster/KUBECTL_GUARDRAILS.md) for
the full policy and its honest limitations.

## Running generated commands safely

`diagnose-cluster` proposes `kubectl` and `ssh` commands — it doesn't run
them silently. Review and approve each one yourself before it executes.

**Don't run this skill with an auto-approve-everything ("YOLO") mode
enabled** — Claude Code's `--dangerously-skip-permissions` flag, or a
project `permissions` config that auto-allows everything. The `PreToolUse`
hook that used to auto-block dangerous `kubectl`/`ssh` commands has been
removed (see [KUBECTL_GUARDRAILS.md](skills/diagnose-cluster/KUBECTL_GUARDRAILS.md)).
Read-only `kubectl` in the kube tier is still enforced server-side by cluster
RBAC (via the minted read-only credential), but that is the only automatic
backstop — `ssh` commands and anything run outside that credential rely on
your review. Reviewing each proposed command before it runs is what stands
between a mistaken command and a real cluster.

See [Configure permissions](https://code.claude.com/docs/en/permissions)
for how Claude Code's approval flow and `/permissions` command work.

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
- `read_cluster_profiles` — fetch a profile by UID, or list profiles (list mode requires `project_uid`)
- `read_packs` — list available packs
- `read_cloud_accounts` — list configured cloud accounts
- `read_registries` — list registries
- `read_projects` — list projects
- `read_teams` — list teams
- `read_users` — list users
- `run_edge_command` — run a read-only, allowlist-gated command on an edge host over direct SSH (off by default, see below)

**Write tools** (`create_*`, `update_*`, `delete_*` for clusters, profiles, projects, teams, users) are **off by default**. Enable them via `/plugin` → **palette** → **Configure options** → **Enable write tools**. (Non-plugin MCP clients: `args` in the plugin's `.mcp.json` ships `--allow-write=${user_config.allow_write}` and `--allow-direct-ssh=${user_config.allow_direct_ssh}`, which only Claude Code's plugin substitution resolves — a non-plugin client passes them as literal strings and the binary will fail to parse them. Remove both `${user_config.*}` entries first, then add your own flags, keeping the launcher path that is already there — replacing the whole array with just `["--allow-write"]` drops the launcher, and the server won't start.)

**`run_edge_command`** is **off by default**. Enable it via `/plugin` → **palette** → **Configure options** → **Enable direct-SSH edge tools**. (Non-plugin MCP clients: remove the `${user_config.*}` args as above, then add `--allow-direct-ssh`.)

It runs an operator-supplied command on an edge host over direct SSH (host, user, and a private key or password), but every command is checked against a server-side, fail-closed allowlist gate before any connection is attempted — shell metacharacters (pipes, redirects, substitution, globs) are always rejected, and only a fixed set of read-only binaries and subcommands (`kubectl get/describe/logs/...`, `systemctl status/show/...`, `journalctl`, `crictl`, `df`/`du`/`ip`, GET-only `curl`, `openssl` cert checks, `cat`/`grep`/`find`/`bridge`/etc.) is allowed. A denied command never dials the host. This is defense-in-depth, not the security boundary — that's the SSH account's own privileges.

Known residual risk, accepted rather than hidden: `curl`'s SSRF protection only blocks `file://` targets — it does not close network-side SSRF (reaching internal services via `http(s)://`), which needs egress control and is out of scope today. `kubectl`'s `--kubeconfig`/`--context` flags could point at an attacker-preplaced malicious kubeconfig, but that requires a prior foothold on the host and is a lower-likelihood path. `systemctl show`/`systemctl cat` can surface a unit's `Environment=` directives, which may embed secrets for some services — accepted because the output only reaches the calling client/model over this already-authenticated SSH session (no *new* credential leak path is opened), it requires that specific unit to have embedded a secret there to begin with, and `show`/`cat` have real troubleshooting value the KB relies on.

**Claude Code permissions.allow.** Enabling `--allow-direct-ssh` on the server is necessary but not sufficient — Claude Code itself prompts interactively the first time any MCP tool call is made, same as an un-allowlisted `Bash` command. To pre-approve it (for unattended or repeated use), add an entry to the `permissions.allow` array in `settings.json` (project `.claude/settings.json` or user `~/.claude/settings.json`):

```json
{
  "permissions": {
    "allow": ["mcp__palette__run_edge_command"]
  }
}
```

Tool names follow `mcp__<server-name>__<tool-name>`, and the server name here is `palette` (the key in `.mcp.json`'s `mcpServers`, not the binary name `palette-mcp`). To pre-approve every tool this server exposes instead of just this one, use the prefix wildcard `mcp__palette__*`.

## Troubleshooting

**`/mcp` shows palette failed or disconnected**
- Confirm your credentials are set: `/plugin` → **palette** → **Configure options** (host + API key).
- A `401` means the key is invalid/expired, or the key and host belong to different tenants.

**`401` / authorization errors when running a skill**
- The most common cause: the API key and host are for different tenants. A key only works against the tenant it was created in — create a fresh key from that tenant's UI.

**`OperationForbidden` errors**
- Your account lacks tenant-wide access. Pass `project_uid` on the failing call to scope it to a project you can access — most read tools accept a per-call `project_uid` (scoping is per call; there is no default-project setting), and write tools that need one take it as their own argument.
- `read_cloud_accounts`, `read_packs` and `read_registries` are tenant-wide by design and take no `project_uid` — passing one is rejected as an invalid-parameter error, not an authorization error.

**Skills don't appear in `/help`**
- Run `/reload-plugins`, or confirm the install with `claude plugin details palette@palette-agent-toolkit`.
