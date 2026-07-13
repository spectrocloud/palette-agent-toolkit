# Contributing to palette-agent-toolkit

Thanks for your interest in contributing. This repo hosts binary releases
and Claude Code plugin/skill manifests for `palette-mcp`. The MCP server
source is maintained separately — this repo doesn't take source-code
contributions to the server itself, only to the manifests, skills, and docs
here.

## Before you start

- For anything beyond a small fix (typos, doc corrections), please open an
  issue first to discuss the change — saves everyone a wasted PR.
- Security vulnerabilities should **not** go through a public PR or issue —
  see [SECURITY.md](SECURITY.md).

## Getting set up

```bash
git clone https://github.com/spectrocloud/palette-agent-toolkit
cd palette-agent-toolkit
make install   # currently a no-op; local git hooks are deferred
```

`make install` is the only setup step. This repo has no build step of its
own (it ships manifests and skill definitions, not compiled source), so
`install` is currently a placeholder until local pre-commit/pre-push hooks
are added. CI runs secret scanning and manifest/markdown linting on PRs.

## Making changes

1. Fork the repo and create a branch off `main`.
2. Make your change. Keep PRs small and focused — one logical change per PR.
3. Commit messages should follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)
   (`feat:`, `fix:`, `docs:`, `chore:`, etc.) — this keeps the changelog
   readable for anyone tracking releases.
4. Open a PR against `main`. CI will run a secret scan and a manifest/markdown
   lint automatically — fix anything it flags before requesting review.
5. All PRs require at least one approving review before merge (enforced by
   this repo's branch protection).

## What we're not looking for right now

- Changes to the plugin/marketplace naming or directory structure — that's
  an active internal decision, raise it as an issue first rather than a PR.
- New MCP tools — those live with the server implementation; this repo only
  ships what the server already exposes.

## Code of Conduct

This project follows our [Code of Conduct](CODE_OF_CONDUCT.md). By
participating, you're expected to uphold it.
