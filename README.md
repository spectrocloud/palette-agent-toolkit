# Palette Agent Toolkit

Connect Claude Code to [Spectro Cloud Palette](https://www.spectrocloud.com/) for cluster management, fleet health checks, and infrastructure operations using natural language.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- A Palette API key for your tenant
- The `palette-mcp` binary on your `PATH`

## Install the MCP binary

Download a versioned release for your platform from [GitHub Releases](https://github.com/spectrocloud/palette-agent-toolkit/releases), then verify it against the matching checksums file:

```bash
VERSION=v0.0.0-rc1

# Choose one:
ASSET=palette-mcp_darwin_arm64.tar.gz  # macOS Apple Silicon
# ASSET=palette-mcp_darwin_amd64.tar.gz  # macOS Intel
# ASSET=palette-mcp_linux_amd64.tar.gz   # Linux amd64

BASE_URL="https://github.com/spectrocloud/palette-agent-toolkit/releases/download/${VERSION}"
CHECKSUMS="palette-mcp_${VERSION#v}_checksums.txt"

curl -LO "${BASE_URL}/${ASSET}"
curl -LO "${BASE_URL}/${CHECKSUMS}"
grep "  ${ASSET}$" "${CHECKSUMS}" | shasum -a 256 -c -

tar xzf "${ASSET}"
sudo mv palette-mcp /usr/local/bin/
```

Supported platforms: `darwin_arm64`, `darwin_amd64`, `linux_amd64`.

> On macOS, clear Gatekeeper quarantine once after download: `xattr -d com.apple.quarantine /usr/local/bin/palette-mcp`

## Configure environment

Export these in your shell profile before launching Claude Code:

```bash
export PALETTE_HOST="your-tenant.spectrocloud.com"
export PALETTE_API_KEY="your-api-key"
# Optional — scope all calls to one project:
export PALETTE_PROJECT_UID="your-project-uid"
```

Your API key and `PALETTE_HOST` must belong to the same tenant.

Verify credentials:

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  -H "ApiKey: $PALETTE_API_KEY" "https://$PALETTE_HOST/v1/users/me"
```

A `200` response means the key is valid.

## Install the Claude plugin

Register the marketplace (one-time):

```
/plugin marketplace add spectrocloud/palette-agent-toolkit
```

Install the plugin:

```
/plugin install palette@palette-agent-toolkit
```

Run `/reload-plugins` after installing. Confirm with `/mcp` — the palette server should show **connected**.

See [plugins/palette/README.md](plugins/palette/README.md) for skills, available MCP tools, and troubleshooting.

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
