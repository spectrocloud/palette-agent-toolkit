<!-- markdownlint-disable-next-line MD041 -->
> [Root](./SKILL.md) → Kubectl Guardrails

# Read-only kubectl guardrail

`diagnose-cluster` can run `kubectl` against a customer's cluster to triage
issues Palette's API doesn't surface directly. There is no automatic hook
that inspects or blocks these commands — nothing here auto-enforces
anything.

The real safety boundary is a **read-only kubeconfig**, minted per session
via a bundled script once triage escalates to the kube-API tier. The admin
kubeconfig is fetched only transiently, in [`SKILL.md`](./SKILL.md)'s K1
step, to bootstrap that credential — it's never used for the kube-API
commands themselves. **The RO credential is backed by genuine cluster
RBAC** (the built-in `view` ClusterRole plus a narrow supplemental role
scoped to only the CAPI/Palette resources this skill reads), enforced
server-side by the cluster itself — a real boundary, not a convention.

[`kubectl-readonly.settings.json`](./kubectl-readonly.settings.json) is an
**optional, opt-in** permission template on top of that. Merging its
`permissions` block into your own `.claude/settings.json` (project) or
`~/.claude/settings.json` (personal) makes Claude Code's own permission
system restrict `kubectl` to read-only verbs (`get`, `describe`, `logs`,
`top`, `version`, `api-resources`, `explain`, `cluster-info`, `config
view`/`current-context`/`get-contexts`), deny every mutating verb and escape
hatch (`create`, `apply`, `delete`, `patch`, `edit`, `replace`, `scale`,
`annotate`, `label`, `cordon`, `drain`, `taint`, `rollout`, `set`, `run`,
`expose`, `autoscale`, `exec`, `cp`, `port-forward`, `proxy`, `attach`,
`debug`), and specifically deny reading Secrets. If you don't merge it in,
there's no enforcement at this layer either — don't assume it's protecting
you just because the file exists in this directory.

This is a whole-command string match, not an argv-aware parser, so it has
gaps (a flag placed before the verb, aliases, subshells, kubectl plugins) —
see the longer writeup at
[`plugins/palette/skills/diagnose-cluster/KUBECTL_GUARDRAILS.md`](https://github.com/spectrocloud/palette-agent-toolkit/blob/main/plugins/palette/skills/diagnose-cluster/KUBECTL_GUARDRAILS.md)
for the full "Honest limitation" section, including the RO kubeconfig's own
accepted residual risk (`kubeadmcontrolplane` embeds bootstrap file/user
data inline, which RBAC scoping can't strip back out). That doc's bottom
line applies here too: this is defense-in-depth, not a claim that kube-tier
access is airtight.

Given that, review and approve every proposed `kubectl`/`ssh` command
yourself — don't run this skill with an auto-approve/YOLO mode enabled. See
[Running generated commands safely](https://github.com/spectrocloud/palette-agent-toolkit/blob/main/plugins/palette/README.md#running-generated-commands-safely)
in the plugin README.
