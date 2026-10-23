# Palette Agent Toolkit

Connect your AI assistant to [Spectro Cloud Palette](https://www.spectrocloud.com/) for cluster management, fleet health checks, and infrastructure operations in natural language. Palette ships as a [Model Context Protocol](https://modelcontextprotocol.io/) (MCP) server, so any MCP-capable client can drive it.

**Before you start:** a Palette API key for your tenant — create one under **User Menu → My API Keys** — and an MCP-capable client.

## Install

Two paths. The plugin is for Claude Code and Claude Desktop, and bundles the binary for you. Everyone else installs the binary directly.

### Plugin (recommended)

The plugin is self-contained — on first use it downloads and checksum-verifies the correct `palette-mcp` binary for your OS and architecture.

#### Claude Code

```
/plugin marketplace add spectrocloud/palette-agent-toolkit
/plugin install palette@palette-agent-toolkit
```

Run `/reload-plugins`, then confirm with `/mcp` — the palette server should show **connected**. Approve the Palette tools when prompted (standard one-time MCP consent). Then set your credentials — see [Credentials](#credentials).

#### Claude Desktop

Marketplace support requires a recent build. Open Settings → Plugins → **Add**, enter `spectrocloud/palette-agent-toolkit`, then install the **palette** plugin from the synced marketplace.

Skills, the full MCP tool list, and troubleshooting live in [plugins/palette/README.md](plugins/palette/README.md).

### Binary (standalone)

For every other MCP client. `install.sh` detects your OS and architecture, downloads the matching release, and verifies its checksum.

```bash
curl -fsSL "https://raw.githubusercontent.com/spectrocloud/palette-agent-toolkit/main/install.sh" | sh
```

On shared or production hosts, read it first:

```bash
REPO="spectrocloud/palette-agent-toolkit"
curl -fsSLO "https://raw.githubusercontent.com/${REPO}/main/install.sh"
less install.sh && sh install.sh
```

`--version vA.B.C` pins the binary; `--bin-dir DIR` changes the install location; `--help` lists the rest. The binary is placed on your `PATH`, which the client configs below assume.

<details>
<summary>Manual install (no script)</summary>

Download the release for your platform and verify it against the checksums file:

```bash
REPO="spectrocloud/palette-agent-toolkit"
BASE_URL="https://github.com/${REPO}/releases/latest/download"

# Choose one:
ASSET=palette-mcp_darwin_arm64.tar.gz  # macOS Apple Silicon
# ASSET=palette-mcp_darwin_amd64.tar.gz  # macOS Intel
# ASSET=palette-mcp_linux_amd64.tar.gz   # Linux amd64
# ASSET=palette-mcp_linux_arm64.tar.gz   # Linux arm64

curl -fLO "${BASE_URL}/${ASSET}"
VERSION=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
  "https://github.com/${REPO}/releases/latest" | grep -o '[^/]*$')
curl -fLO "${BASE_URL}/palette-mcp_${VERSION#v}_checksums.txt"
if command -v sha256sum >/dev/null 2>&1; then
  grep "  ${ASSET}$" "palette-mcp_${VERSION#v}_checksums.txt" | sha256sum -c -
else
  grep "  ${ASSET}$" "palette-mcp_${VERSION#v}_checksums.txt" | shasum -a 256 -c -
fi

tar xzf "${ASSET}"
sudo mv palette-mcp /usr/local/bin/
```

</details>

> **macOS:** if your client cannot launch the binary — usually only when it was downloaded via a browser rather than `curl` — clear the Gatekeeper quarantine: `xattr -d com.apple.quarantine /usr/local/bin/palette-mcp`

### Other MCP clients

`palette-mcp` is a standard stdio MCP server, so any MCP-capable client can run it. Export the variables in [Credentials](#credentials), then register the server:

| Client | Config file | How to register |
|---|---|---|
| Codex CLI | `~/.codex/config.toml` | Use the TOML block below. The `codex mcp add` one-liner also works but writes your expanded key into the file in plaintext. |
| Cursor | `~/.cursor/mcp.json` (global) or project `.cursor/mcp.json` | Use the JSON block below, replacing the env values with `${env:PALETTE_HOST}` / `${env:PALETTE_API_KEY}` — Cursor expands them, keeping the key out of the file. |
| Antigravity CLI | `~/.gemini/config/mcp_config.json` | Use the JSON block below with literal env values — Antigravity does not expand `$VAR`. `chmod 600` the file. |
| Any stdio client | — | `command: palette-mcp`, with the `PALETTE_*` variables in the environment. |

Codex CLI — keeps the key out of the file by forwarding your exported variables by name:

```toml
[mcp_servers.palette]
command = "palette-mcp"
env_vars = ["PALETTE_HOST", "PALETTE_API_KEY"]
```

Cursor and Antigravity CLI:

```json
{
  "mcpServers": {
    "palette": {
      "command": "palette-mcp",
      "env": {
        "PALETTE_HOST": "your-tenant.spectrocloud.com",
        "PALETTE_API_KEY": "your-api-key"
      }
    }
  }
}
```

Reads are tenant-wide — pass a project's UID as the `project_uid` argument on the tools that accept it to scope a read or target a write; there is no startup-level project setting. Every client runs read-only by default; write tools stay disabled unless the binary is launched with `--allow-write`.

## Credentials

**Plugin (Claude Code / Claude Desktop).** Run `/plugin` → **palette** → **Configure options** and set your Palette **host** and **API key**. Secrets are stored in your OS credential store — macOS Keychain, Windows Credential Manager, or Linux Secret Service (falling back to `~/.claude/.credentials.json` at `0600` on headless Linux) — so no shell exports are needed. For CI, pass `--config host=… --config api_key=…` to `claude plugin install`.

> **Upgrading from an earlier plugin version?** The plugin no longer reads exported `PALETTE_*` variables — reconfigure here.

**Binary and other MCP clients.** Export these in your shell profile:

```bash
export PALETTE_HOST="your-tenant.spectrocloud.com"
export PALETTE_API_KEY="your-api-key"
# Optional — authenticate with a JWT instead of an API key:
# export PALETTE_AUTH_TOKEN="your-token"
# Optional — trust a private CA (on-prem Palette):
# export PALETTE_CA_FILE="/path/to/ca.pem"
```

Your API key and `PALETTE_HOST` must belong to the same tenant. Verify:

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  -H "ApiKey: $PALETTE_API_KEY" "https://$PALETTE_HOST/v1/users/me"
```

A `200` response means the key is valid.

## Skills

To use the skills outside the Claude plugin, install them from this repository:

```bash
npx skills add github.com/spectrocloud/palette-agent-toolkit/skills
```

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
