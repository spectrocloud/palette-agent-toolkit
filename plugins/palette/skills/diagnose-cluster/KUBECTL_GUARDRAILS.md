<!-- markdownlint-disable-next-line MD041 -->
> [Root](./SKILL.md) → Kubectl Guardrails

# Read-only kubectl guardrail

`diagnose-cluster` can run `kubectl` against a customer's cluster to triage
issues Palette's API doesn't surface directly (pod state, events, logs).

## There is no enforcement hook

An earlier version of this skill shipped an automatic pre-execution hook
that tokenized every `Bash` command and auto-blocked mutating or
secret-reading `kubectl`/`ssh` calls. It was removed: it failed open under ordinary
conditions (missing `python3`, a parse error, a newline-separated compound
command), it was bypassable (`kubectl get --raw`, `kubectl config view
--raw`, `ssh -o ProxyCommand=...`), and — because Claude Code hooks match on
tool name, not on which skill is active — it fired on *every* `Bash` call in
*every* project you had open, not just this one. There is nothing in this
repo that automatically inspects or blocks `kubectl` commands before they
run.

## The real safety boundary: a read-only kubeconfig, minted per session

Kube-tier triage fetches the **admin kubeconfig only transiently**, in
[`SKILL.md`](./SKILL.md)'s K1 step, purely to bootstrap a session-scoped
**read-only** credential via the bundled
[`generate_ro_kubeconfig.sh`](./scripts/generate_ro_kubeconfig.sh). From K3
onward, every `kubectl` command runs against that minted RO kubeconfig
instead — the admin kubeconfig is never touched again, and K1 locks it down
(`chmod 600`) and wipes it (K5) for the short window it does exist.

The RO credential's ServiceAccount is bound to the built-in `view`
ClusterRole (which excludes Secrets by design) plus a narrow supplemental
ClusterRole scoped to exactly the CAPI/Palette resources the kube-tier reads:
`cluster.x-k8s.io`/`infrastructure.cluster.x-k8s.io` (full read), the
specific control-plane kinds under `controlplane.cluster.x-k8s.io`
(`kubeadmcontrolplanes`, `awsmanagedcontrolplanes`, `rosacontrolplanes`),
`spectroclusters` only under `cluster.spectrocloud.com` (not `packs` or
`clusterprofiles`, which can carry secret-shaped fields), and an explicit
`nodes`/`nodes/status` rule under the core API group — deliberately never a
wildcard on the core group, since that's where Secrets live. The bearer
token itself is minted via the TokenRequest API (`kubectl create token
--duration=1h`), so it self-expires and is never written to a persistent
Secret object. Session-unique ServiceAccount/binding names (suffixed with
the cluster UID and a session ID) mean two engineers diagnosing different
clusters — or the same one — concurrently don't collide or revoke each
other's credential, and `--cleanup` (wired into K5/K6's exit paths) tears
the ServiceAccount and bindings back down at the end of a session.

This means **the RO kubeconfig is a real, server-side-enforced boundary now,
not a convention**: a mutating or Secret-reading command run against it is
rejected by the cluster's own RBAC with `Forbidden`, regardless of anything
below in this file.

## Optional layer: `kubectl-readonly.settings.json`

[`kubectl-readonly.settings.json`](./kubectl-readonly.settings.json) is a
plain permission-rule template, restricting `kubectl` to read-only verbs via
**Claude Code's own permission system** — not the skill, not a hook, and not
by trusting the model.

It is **opt-in and does nothing on its own.** Plugins can't auto-apply
`permissions` settings (only hooks can auto-install, which is exactly the
risk that got the hook removed), so this template only takes effect if you
merge its `permissions` block into your own settings:

- `.claude/settings.json` at your project root — shared with your team, safe
  to commit.
- `~/.claude/settings.json` — applies to every project for you personally.

If you already have a `permissions.allow` / `permissions.deny` list, append
these entries to your existing arrays rather than replacing the file. If you
don't merge it in, there is no enforcement at this layer at all — commands
just go through Claude Code's normal permission flow (typically a prompt).

### What it allows

Read-only verbs only: `get`, `describe`, `logs`, `top`, `version`,
`api-resources`, `explain`, `cluster-info`, and `config view` /
`config current-context` / `config get-contexts`.

### What it denies

- **Every mutating verb**: `create`, `apply`, `delete`, `patch`, `edit`,
  `replace`, `scale`, `annotate`, `label`, `cordon`, `drain`, `taint`,
  `rollout`, `set`, `run`, `expose`, `autoscale`.
- **Every escape hatch that isn't a "verb" but still changes or exposes
  cluster state**: `exec`, `cp`, `port-forward`, `proxy`, `attach`, `debug`.
- **Secrets specifically**: `kubectl get secret*`, `kubectl describe
  secret*`, and a broader `kubectl * secret*` catch-all.

Deny always wins over allow in Claude Code's permission system — see
[Configure permissions](https://code.claude.com/docs/en/permissions), section
"Rule precedence."

### Known gap: flag-before-verb

This template matches on the whole command string
(`Bash(kubectl get*)`-style prefix/wildcard matching), not an argv-aware
parse of `kubectl`'s flags. A global flag placed *before* the verb —
`kubectl -n kube-system get secret db-creds` — doesn't start with `kubectl
get secret`, so the literal secrets rule misses it. The broader `kubectl *
secret*` catch-all narrows this for secrets specifically (at the cost of
also blocking reads of anything with "secret" in its name or namespace —
accepted as the safe failure mode), but the same gap applies to the
mutating-verb deny rules with no catch-all: `kubectl -n foo delete pod x`
matches neither the allow list nor a deny rule and falls through to
Claude Code's default behavior (typically a prompt), not a hard deny.

## Honest limitation (this is defense-in-depth, not airtight)

A command-string / settings-based layer is not a substitute for a real RBAC
boundary. Even with the settings template merged in, known ways this
guardrail can still be evaded or produce a false sense of safety:

- **Aliases**: `alias k=kubectl` produces a command whose executable token
  is `k`, not `kubectl` — the literal `kubectl` prefix match misses it.
- **Subshells**: `bash -c "kubectl get secret foo"` puts the real command
  inside a string argument, not a token the matcher inspects directly.
- **kubectl plugins**: `kubectl-neat` or any krew plugin invoked as
  `kubectl <plugin>` isn't distinguished by verb matching at all.
- **False positives**: the secret-name checks match on substrings, so a
  legitimate command whose namespace or `-o jsonpath={...}` output happens
  to contain "secret" can be denied even though it isn't reading a Secret.

None of this is new information relative to when the hook existed — the
hook had its own version of every one of these gaps (see git history on
this file if you want the details). The difference now is that this
guardrail is opt-in rather than auto-applied, and it was never intended to
be the thing actually protecting the cluster. **The read-only kubeconfig
is the real control** — enforced by the cluster's own RBAC, not by string
matching, so it holds even when every layer in this file is bypassed or
simply never enabled.

That RBAC scoping has one accepted residual risk of its own, carried
forward from the script's own review history: the supplemental role grants
read access to `kubeadmcontrolplanes` (which the kube-tier genuinely
needs), and that CRD embeds its `KubeadmConfigSpec` inline —
`spec.files[].content` and `spec.users[].passwd` — so a legitimate read of
a `kubeadmcontrolplane` object can also surface embedded bootstrap file
contents or credentials if a given cluster's spec happens to populate
them. RBAC scopes access to a resource, it can't strip a sub-object out of
it, so this can't be closed without also blocking the `kubeadmcontrolplane`
reads the kube-tier depends on. Given all that — this is defense-in-depth,
not a claim that kube-tier access is airtight — don't try to compensate by
running this skill in an auto-approve/YOLO mode — see
[Running generated commands safely](../../README.md#running-generated-commands-safely)
in the plugin README.
