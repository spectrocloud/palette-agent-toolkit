# Configure Palette MCP with an AI assistant

This page gives you a prompt that you can give to Claude Code. Claude then sets up the
Palette MCP on your machine. The setup uses one MCP server and named profiles for each
tenant. It replaces older setups that use one MCP server for each environment.

Claude Code and the `palette-mcp` binary are the supported combination for this flow. The
plugin and the standalone binary both register a server named `palette`, so disable the
plugin before you start (step 5 of the prompt does this for you).

## What you need

- Claude Code, version 2.1 or later.
- A Palette API key. Create it under **User Menu → My API Keys**.
- Your Palette endpoint. Example: `dev.spectrocloud.com` or `palette.example.spectrocloud.com`.
- The UID of your default project. It is the value after `/projects/` in the Palette URL.
- One endpoint and one API key for each tenant that you want to use.

## The prompt

Copy this text and give it to Claude Code:

```text
Configure the Palette MCP from https://github.com/spectrocloud/palette-agent-toolkit for me. Use the current profile pattern (one `palette` server plus named profiles), not one server per environment.

Step 1 — ask me these questions first and wait for my answers:
1. Palette endpoint? Example: `dev.spectrocloud.com` or `palette.example.spectrocloud.com`. Give the host only, with no `https://` and no path.
2. Palette API key? Create it under User Menu → My API Keys. It is a long base64 string.
3. Default project UID? Take the ID after `/projects/` in the Palette URL. Example: `6afe12a18d540ff5cc592d47`.
4. Which environments do you want? For example dev, stage, prod. Ask for a host and key for each one.

Step 2 — set it up:
5. Run `claude mcp list`. Remove every existing palette MCP server with `claude mcp remove <name> -s user`. If the palette plugin is installed, disable it, because it also registers a server named `palette`. Keep all other servers.
6. Read https://raw.githubusercontent.com/spectrocloud/palette-agent-toolkit/main/install.sh, then run it. On Windows, run it inside WSL. Confirm with `palette-mcp -version`.
7. Run `palette-mcp configure` once per environment. Use AWS-style profile names such as `acme-dev`, `acme-stage`, `acme-prod`. Enter the host, the API key, then press Enter for the CA path. It validates the key and writes `~/.palette/auth_profiles.yaml` at mode 0600.
8. Create a `default` profile for the tenant you use most, so the server starts without flags.
9. Add one MCP server: `claude mcp add-json palette '{"type":"stdio","command":"palette-mcp","args":[],"env":{"PALETTE_PROFILES_FILE":"'"$HOME"'/.palette/auth_profiles.yaml"}}' -s user`.
10. Restart Claude Code or open a new conversation. Run `/mcp` and confirm `palette` shows connected.

Step 3 — verify and remember:
11. Call `list_auth_profiles`, then `read_projects` with each `auth_profile`. Show me every project name and UID.
12. Save my default project UID for each profile in memory. Pass `project_uid` on every Palette tool call that accepts it; the server keeps no default project.
13. If TLS fails with `certificate is valid for X, not Y`, retry with the exact hostname in the certificate. Drop a UI prefix such as `palette.`.
```

## What Claude asks you

1. **Endpoint.** Give the host name only. Remove `https://` and the path.
2. **API key.** Paste the key from **User Menu → My API Keys**.
3. **Default project UID.** Copy it from the Palette URL.
4. **Environments.** Name each tenant that you use. Claude creates one profile for each tenant.

The API key is sensitive. `palette-mcp configure` writes it to `~/.palette/auth_profiles.yaml`
at mode `0600`. If the key must not appear in the chat transcript, run `palette-mcp configure`
yourself in a terminal when Claude asks, and give Claude only the profile name.

## What Claude changes

- Removes old palette MCP servers from the user scope.
- Installs or updates `palette-mcp` from the latest release.
- Creates one profile for each tenant in `~/.palette/auth_profiles.yaml`.
- Adds one MCP server named `palette`. The server reads the profiles file and keeps no
  credentials of its own.

## Verify the setup

1. Run `/mcp` and confirm that `palette` shows **connected**.
2. Ask: "List the auth profiles." Claude calls `list_auth_profiles` and shows the names
   and hosts.
3. Ask: "List the projects in each profile." Claude calls `read_projects` with each
   `auth_profile` and shows the project names and UIDs.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Server exits with `no default profile` | No `default` profile in the profiles file and no `PALETTE_HOST` | Create a `default` profile with `palette-mcp configure`. |
| `certificate is valid for X, not Y` | The endpoint does not match the certificate name | Use the host name from the certificate. Remove a UI prefix such as `palette.`. |
| Server is not in `/mcp` | Claude Code started before the config change | Restart Claude Code. |
| Tools fail with `PALETTE_FORBIDDEN` | The API key has no permission for the tenant scope | Pass `project_uid` to scope the call to a project. Use a key with more permissions for tenant-wide reads. |
| `palette-mcp` exits with code 137 after an upgrade | macOS kept the signature of the old binary | Run `codesign --force --sign - "$(command -v palette-mcp)"`. |
| Profile changes do not apply | MCP servers load at startup | Reconnect with `/mcp`, or restart the client. |

## Manual setup

If you do not want an assistant to make these changes, run the steps in
[Multi-profile setup](README.md#multi-profile-setup-advanced) by hand, then add the server:

```bash
claude mcp add-json palette '{"type":"stdio","command":"palette-mcp","args":[],"env":{"PALETTE_PROFILES_FILE":"'"$HOME"'/.palette/auth_profiles.yaml"}}' -s user
```
