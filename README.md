# Palette Agent Toolkit

Connect your AI assistant to [Spectro Cloud Palette](https://www.spectrocloud.com/) for cluster management, fleet health checks, and infrastructure operations using natural language.

## Prerequisites

- An MCP-capable client — [Claude Code](https://docs.anthropic.com/en/docs/claude-code), Claude Desktop, Codex CLI, Antigravity CLI, or Cursor
- A Palette API key for your tenant
- The `palette-mcp` binary on your `PATH` — **only for non-plugin clients** (Codex, Cursor, Antigravity). The Claude Code / Claude Desktop plugin fetches it automatically; see [Install the plugin](#install-the-plugin-claude-code--claude-desktop).

## Install the MCP binary

> **Claude Code / Claude Desktop plugin users can skip this section.** The plugin bundles a launcher that downloads and checksum-verifies the correct binary automatically on first run. This section is for **other MCP clients** (Codex, Cursor, Antigravity) that run the `palette-mcp` binary directly.

`install.sh` detects your OS and architecture, downloads the matching release, and verifies its checksum. Fetch it, read it, then run it:

```bash
REPO="spectrocloud/palette-agent-toolkit"
curl -fsSLO "https://raw.githubusercontent.com/${REPO}/v0.4.2/install.sh"
less install.sh          # read it before running
sh install.sh            # --version vA.B.C pins the binary; --bin-dir DIR changes the location
```

Or in one line (prefer the read-first form on shared or production hosts):

```bash
curl -fsSL "https://raw.githubusercontent.com/spectrocloud/palette-agent-toolkit/v0.4.2/install.sh" | sh
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

> On macOS, if your client fails to launch the binary (usually only when downloaded via a browser rather than `curl`), clear the Gatekeeper quarantine: `xattr -d com.apple.quarantine /usr/local/bin/palette-mcp`

## Configure environment (non-plugin clients)

> **Claude Code / Claude Desktop plugin** users configure credentials in-app (see **Install the plugin** below) and can skip this section.

For other MCP clients (and the standalone binary), export these in your shell profile before launching the client:

```bash
export PALETTE_HOST="your-tenant.spectrocloud.com"
export PALETTE_API_KEY="your-api-key"
# Optional — scope all calls to one project:
export PALETTE_PROJECT_UID="your-project-uid"
# Optional — authenticate with a JWT instead of an API key:
# export PALETTE_AUTH_TOKEN="your-token"
# Optional — trust a private CA (on-prem Palette):
# export PALETTE_CA_FILE="/path/to/ca.pem"
```

Your API key and `PALETTE_HOST` must belong to the same tenant.

Verify credentials:

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  -H "ApiKey: $PALETTE_API_KEY" "https://$PALETTE_HOST/v1/users/me"
```

A `200` response means the key is valid.

## Install the plugin (Claude Code & Claude Desktop)

Both Claude Code and Claude Desktop install from the same marketplace.

**Claude Code** — register the marketplace (one-time), then install the plugin:

```
/plugin marketplace add spectrocloud/palette-agent-toolkit
/plugin install palette@palette-agent-toolkit
```

The plugin is **self-contained** — on first use it automatically downloads and checksum-verifies the correct `palette-mcp` binary for your OS/architecture (cached under the plugin's data directory for later sessions). No separate binary install is required.

> **Note:** the plugin caches the binary in Claude Code's plugin data dir, not on your `PATH`. Only [`install.sh`](#install-the-mcp-binary) puts `palette-mcp` on `PATH` (for non-plugin clients).

**Configure credentials** — run `/plugin` → **palette** → **Configure options** and set your Palette **host** and **API key** (create one under User Menu → My API Keys). Sensitive fields are stored by Claude Code in your OS credential store — macOS Keychain, Windows Credential Manager, or Linux Secret Service (falling back to `~/.claude/.credentials.json` at `0600` on headless Linux) — so you don't need the shell exports above for the plugin. **Upgrading?** The plugin no longer reads exported `PALETTE_*` variables; reconfigure via **Configure options**. For CI, pass `--config host=… --config api_key=…` to `claude plugin install`.

Run `/reload-plugins` after installing. Confirm with `/mcp` — the palette server should show **connected**. Approve the Palette tools when prompted (standard one-time MCP consent).

**Claude Desktop** (marketplace support requires a recent Desktop build) — open Settings → Plugins → **Add**, enter `spectrocloud/palette-agent-toolkit`, then install the **palette** plugin from the synced marketplace.

See [plugins/palette/README.md](plugins/palette/README.md) for skills, available MCP tools, and troubleshooting.

## Use with other MCP clients

`palette-mcp` is a standard stdio MCP server, so any MCP-capable client can run
it. Install the binary and export the environment variables as above, then
register the server with your client. The examples reference your exported shell
variables where the client supports it, so your API key isn't written to a
config file in plaintext.

### Codex CLI

Two ways to register the server — pick one:

**Quick, writes your key to `~/.codex/config.toml` in plaintext:**

```bash
codex mcp add palette \
  --env PALETTE_HOST="$PALETTE_HOST" \
  --env PALETTE_API_KEY="$PALETTE_API_KEY" \
  -- palette-mcp
```

**Keeps the key out of the config file** — edit `~/.codex/config.toml` directly
and forward your already-exported shell variables by name instead:

```toml
[mcp_servers.palette]
command = "palette-mcp"
env_vars = ["PALETTE_HOST", "PALETTE_API_KEY", "PALETTE_PROJECT_UID"]
```

### Antigravity CLI

Add to `~/.gemini/config/mcp_config.json`. Antigravity does not currently
expand `$VAR` references in `env` blocks (a known regression from Gemini
CLI) — use literal values, and restrict the file's permissions since your
key is stored in plaintext:

```json
{
  "mcpServers": {
    "palette": {
      "command": "palette-mcp",
      "env": {
        "PALETTE_HOST": "your-tenant.spectrocloud.com",
        "PALETTE_API_KEY": "your-api-key",
        "PALETTE_PROJECT_UID": "your-project-uid"
      }
    }
  }
}
```

```bash
chmod 600 ~/.gemini/config/mcp_config.json
```

### Cursor

Add to `~/.cursor/mcp.json` (global) or project-scoped `.cursor/mcp.json`.
Cursor expands `${env:VAR}` references from your environment:

```json
{
  "mcpServers": {
    "palette": {
      "command": "palette-mcp",
      "env": {
        "PALETTE_HOST": "${env:PALETTE_HOST}",
        "PALETTE_API_KEY": "${env:PALETTE_API_KEY}",
        "PALETTE_PROJECT_UID": "${env:PALETTE_PROJECT_UID}"
      }
    }
  }
}
```

Cursor asks you to approve a new MCP server before it loads — approve **palette**
when prompted, or enable it from Cursor's MCP settings.

`PALETTE_PROJECT_UID` is optional in every client — set it to scope all calls to
one project. Every client runs read-only by default; write tools stay disabled
unless the binary is launched with `--allow-write`.

## Skills (standalone install)

If you use skills outside the Claude plugin, install from this repository:

```bash
npx skills add github.com/spectrocloud/palette-agent-toolkit/skills
```

Bundled skills:

| Skill | Use when |
|-------|----------|
| `diagnose-cluster` | Cloud cluster in error or degraded state |
| `diagnose-edge` | Edge host offline or not registering |
| `health-overview` | Fleet-wide health across your tenant |
| `access-review` | Review teams, users, and pending activations |

## Security

Do not commit API keys or tokens. Report vulnerabilities privately — see [SECURITY.md](SECURITY.md).

## License

Apache License 2.0 — see [LICENSE](LICENSE).
