#!/bin/bash
set -e
set -o pipefail
# NOTE: `set -x` intentionally removed — it echoed the SA bearer token to stdout,
# which lands in the Claude/skill transcript. Set DEBUG=1 to re-enable tracing;
# the two commands that handle the bearer token (the TokenRequest call and the
# `config set-credentials --token=` write) suspend xtrace around themselves, so
# DEBUG=1 stays safe to use and never prints the token.
[[ -n "${DEBUG:-}" ]] && set -x

# ============================================================================
# Read-only kubeconfig scoping rationale. Read-only access is enforced
# server-side by the RBAC set up below. Key properties:
#   -  session-unique ClusterRoleBinding names (was a shared name that
#           silently revoked prior sessions on re-run)
#   -  teardown mode (`--cleanup <sa> <ns>`) to delete the objects created
#   - scope the role OFF
#           Secrets. Old role granted get/list/watch on */* → could read every
#           Secret cluster-wide. Now: SA is bound to built-in `view` (excludes
#           secrets by design) PLUS a supplemental ClusterRole scoped only to
#           the CAPI/Palette CRD groups K4 actually reads (cluster.x-k8s.io,
#           infrastructure.cluster.x-k8s.io, controlplane.cluster.x-k8s.io,
#           cluster.spectrocloud.com — narrowed further below), plus an
#           explicit Nodes rule (see below).
#           Confirmed live: `auth can-i get/list secrets` → no,
#           `kubectl get secrets -A` → Forbidden, `auth can-i list pods` →
#           yes, machines.cluster.x-k8s.io readable end-to-end.
#           Gap found + fixed during live verification: `view` deliberately
#           excludes cluster-scoped core resources (same reason it excludes
#           Secrets), so `kubectl get nodes` was Forbidden even with `view` +
#           the CRD-groups role. diagnose-cluster's kube tier needs
#           `kubectl get nodes` (node-tier triage), so the
#           supplemental role now also grants get/list/watch on the explicit
#           resource names `nodes`/`nodes/status` under apiGroup "" — never a
#           `resources:["*"]` wildcard on the core group, since that's where
#           Secrets live. Re-verified after the fix: `kubectl get nodes`
#           returns node data, Secrets access still denied.
#           Second gap found by independent spec review, also fixed +
#           re-verified live: `resources:["*"]` under `cluster.spectrocloud.com`
#           also exposed `packs` (pack `values` blobs can carry a pack-author
#           `oidc-client-secret`-labeled field) and `clusterprofiles`, neither
#           of which K4 ever reads (K4's read set only runs `kubectl get spc -A`).
#           Narrowed to its own rule, resources:["spectroclusters"] only
#           (confirmed exact name via `kubectl api-resources
#           --api-group=cluster.spectrocloud.com`). Re-verified: `kubectl get
#           spc -A` still works, `kubectl get packs -A` → Forbidden.
#           Third gap found by code-quality review, also fixed + re-verified
#           live: same bug class again — `bootstrap.cluster.x-k8s.io`
#           (KubeadmConfig, has `spec.files[].content`/`spec.users[].passwd`)
#           and `addons.cluster.x-k8s.io` (ClusterResourceSet) were on the
#           shared `resources:["*"]` wildcard but K4 never reads either group.
#           Dropped both; only cluster.x-k8s.io, infrastructure.cluster.x-k8s.io,
#           controlplane.cluster.x-k8s.io remain on that wildcard. See
#           create_read_only_cluster_role() for the accepted residual risk
#           this doesn't fully close: `kubeadmcontrolplane` (which K4 DOES
#           need) embeds the same KubeadmConfigSpec inline, and RBAC can't
#           strip a sub-object. Re-verified: `kubectl get spc/machines/nodes`
#           still work, secrets/packs/bootstrap-group/addons-group all
#           Forbidden, no regressions.
#   - switched to
#           `kubectl create token <sa> --duration=1h` (TokenRequest API,
#           self-expiring, no persistent Secret object) instead of the old
#           permanent `kubernetes.io/service-account-token` Secret.
#   - session-scoped the CA cert file
#           (was a fixed /tmp/kube/ca.crt shared across all runs — two
#           concurrent sessions against different clusters would race on it)
#           and added a non-empty check right after extraction so a
#           file-path-only CA reference (no embedded certificate-authority-data
#           in the active context) fails loudly instead of surfacing later as
#           an opaque TLS error.
#   - wipe/`chmod 600` the ADMIN kubeconfig after use.
#   - moved the credential files off a shared `/tmp/kube` into a user-private
#           directory (`$XDG_RUNTIME_DIR` or `$HOME/.cache`, mode 700), and set
#           `umask 077` up front. `/tmp/kube` is owned by whoever creates it
#           first and has no sticky bit, so on a shared host another user could
#           read the RO kubeconfig's bearer token or symlink-swap it during the
#           write — and `chmod 600` only landed after the file was written.
# ============================================================================

# Credential files go in a user-private directory, never a shared one. A fixed
# /tmp/kube belongs to whichever user creates it first (and, unlike /tmp itself,
# carries no sticky bit) — on a shared host that lets another user read the RO
# kubeconfig, which holds a live bearer token, or symlink-swap it mid-write.
# XDG_RUNTIME_DIR is per-user tmpfs at mode 700 on Linux; $HOME/.cache is the
# portable fallback (macOS sets no XDG_RUNTIME_DIR).
# Deliberately deterministic rather than `mktemp -d`: `--cleanup` runs as a
# separate later invocation and must rebuild these paths from <sa> <ns> alone.
if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    TARGET_FOLDER="${XDG_RUNTIME_DIR}/palette-diag"
elif [[ -n "${HOME:-}" ]]; then
    TARGET_FOLDER="${HOME}/.cache/palette-diag"
else
    echo "ERROR: neither XDG_RUNTIME_DIR nor HOME is set — refusing to write a bearer-token kubeconfig to a shared location. Set HOME or XDG_RUNTIME_DIR to a user-private directory." >&2
    exit 1
fi

# Every file this script creates either holds a credential or protects one. 077
# closes the window between each write and the explicit chmod 600 further down.
umask 077

# Cleanup mode: `generate_ro_kubeconfig.sh --cleanup <sa> <ns>` removes everything
# this script created (call at end of a diagnosis session).
if [[ "${1:-}" == "--cleanup" ]]; then
    _sa="${2:?usage: --cleanup <sa> <ns>}"; _ns="${3:?usage: --cleanup <sa> <ns>}"

    # Remove the local credential files FIRST. They hold a live bearer token
    # and their removal has no cluster dependency, so it must not sit behind
    # kubectl. Previously this line was last in the branch and `set -e` aborted
    # on the first failed delete — `--ignore-not-found` suppresses NotFound,
    # NOT connection errors — so an unreachable cluster left the token on disk.
    # (These are the RO files; the ADMIN kubeconfig the deletes below
    # authenticate with is a different path supplied via $KUBECONFIG.)
    #
    # Sweep EVERY candidate base, not only the one this invocation's env
    # resolves to. --cleanup runs as a separate later process and re-derives
    # TARGET_FOLDER independently, so an env difference between the mint call
    # and this one would otherwise miss the file and leave the bearer token on
    # disk until its 1h TTL. Filenames are fully determined by <sa> and <ns>,
    # so cleanup needs no knowledge of which base was used, and `rm -f` on an
    # absent path is a no-op.
    #
    # The third candidate is the conventional XDG_RUNTIME_DIR value. It is
    # there because the var being *unset here* is precisely the case the first
    # candidate cannot cover: if mint ran with it set and cleanup runs without
    # it, there is no variable left to reconstruct that path from. Sweeping
    # /run/user/<uid> covers that on Linux, where XDG_RUNTIME_DIR is
    # effectively always that value.
    #
    # Residual, deliberately not chased: a *non-conventional* XDG_RUNTIME_DIR
    # that is also unset at cleanup time remains unreachable. Closing that
    # would mean passing the directory in as an argument (8 call sites across
    # both skill twins) or writing a pointer file at a predictable path. Not
    # worth either for a token that self-expires in an hour.
    # Attempt every delete even if an earlier one fails, so one connection
    # error (or, for the local files below, a permission error on a stale
    # candidate dir this invocation doesn't own) cannot strand the remaining
    # cluster-scoped RBAC. Record the failure and exit non-zero: the
    # runbook's "cleanup may have failed … may need manual removal" path
    # depends on a non-zero exit to fire.
    _cleanup_rc=0
    for _base in "${XDG_RUNTIME_DIR:+${XDG_RUNTIME_DIR}/palette-diag}" \
                 "${HOME:+${HOME}/.cache/palette-diag}" \
                 "/run/user/$(id -u)/palette-diag"; do
        [ -n "${_base}" ] || continue
        # rm -f is a no-op on a MISSING path, but still fails (and would abort
        # under set -e) on a path that exists and is unwritable — e.g. a
        # stale or shared candidate dir this invocation never created.
        rm -f "${_base}/k8s-${_sa}-${_ns}-conf" "${_base}/ca-${_sa}-${_ns}.crt" || _cleanup_rc=1
    done

    kubectl delete clusterrolebinding "view-binding-${_sa}-${_ns}" --ignore-not-found || _cleanup_rc=1
    kubectl delete clusterrolebinding "diagnose-cluster-capi-read-binding-${_sa}-${_ns}" --ignore-not-found || _cleanup_rc=1
    kubectl delete sa "${_sa}" -n "${_ns}" --ignore-not-found || _cleanup_rc=1

    # diagnose-cluster-capi-read-role is SHARED — every concurrent session
    # binds its own ClusterRoleBinding (diagnose-cluster-capi-read-binding-*)
    # to this one role. Deleting it unconditionally here (as this script used
    # to) strips CAPI/node read access from any OTHER session still bound to
    # it: session A cleans up mid-way through session B's diagnosis, B's
    # binding survives but the role it points at is gone, and B silently
    # loses `kubectl get nodes`/CAPI access until the next mint recreates the
    # role (which does not repair B's already-broken session). Only delete
    # the role once no other binding for it remains.
    #
    # This is a best-effort ref-count, not an atomic one: a `list` then
    # `delete` is two separate calls, so a binding created by a concurrent
    # mint in between is a real (if narrow) TOCTOU window. Closing that fully
    # needs either a per-credential ClusterRole (no sharing at all) or a
    # server-side ownership mechanism (e.g. an ownerRef/finalizer chain) —
    # out of scope for a cleanup script; flagged as an accepted residual risk
    # rather than silently left as the previous unconditional-delete bug.
    _remaining_bindings=$(kubectl get clusterrolebinding -o name 2>/dev/null | grep -c '^clusterrolebinding\.rbac\.authorization\.k8s\.io/diagnose-cluster-capi-read-binding-' || true)
    if [ "${_remaining_bindings:-0}" -eq 0 ]; then
        kubectl delete clusterrole "diagnose-cluster-capi-read-role" --ignore-not-found || _cleanup_rc=1
        _role_msg="ClusterRole diagnose-cluster-capi-read-role removed too (no other session was bound to it) — the next mint recreates it"
    else
        _role_msg="ClusterRole diagnose-cluster-capi-read-role left in place — ${_remaining_bindings} other session(s) still bound to it"
    fi

    if [ "${_cleanup_rc}" -ne 0 ]; then
        echo "ERROR: one or more cluster-side deletes failed for ${_sa}/${_ns} — ServiceAccount and/or ClusterRoleBindings may still exist and need manual removal. Local credential files were removed regardless." >&2
        exit 1
    fi
    echo "cleaned up RO artifacts for ${_sa}/${_ns} (${_role_msg}; the built-in view ClusterRole is left untouched)"
    exit 0
fi

# Add user to k8s using service account, no RBAC (must create RBAC after this script)
if [[ -z "$1" ]] || [[ -z "$2" ]]; then
 echo "usage: $0 <service_account_name> <namespace>"
 exit 1
fi

SERVICE_ACCOUNT_NAME=$1
NAMESPACE="$2"
KUBECFG_FILE_NAME="${TARGET_FOLDER}/k8s-${SERVICE_ACCOUNT_NAME}-${NAMESPACE}-conf"
CA_CRT_FILE="${TARGET_FOLDER}/ca-${SERVICE_ACCOUNT_NAME}-${NAMESPACE}.crt"

create_target_folder() {
    echo -n "Creating target directory to hold files in ${TARGET_FOLDER}..."
    # -m applies only when mkdir creates the directory, so tighten an existing
    # one explicitly. chmod also fails if we do not own it — the case to refuse,
    # since a bearer-token kubeconfig is about to be written in there.
    mkdir -p -m 700 "${TARGET_FOLDER}" || { echo "ERROR: cannot create ${TARGET_FOLDER}" >&2; exit 1; }
    chmod 700 "${TARGET_FOLDER}" || { echo "ERROR: cannot secure ${TARGET_FOLDER} (not owned by this user?)" >&2; exit 1; }
    printf "done"
}

create_service_account() {
    echo -e "\\nCreating a service account in ${NAMESPACE} namespace: ${SERVICE_ACCOUNT_NAME}"
    # Idempotent: plain `kubectl create sa` errors with AlreadyExists on re-run and
    # aborts under `set -e`. dry-run|apply makes re-running the script safe.
    kubectl create sa "${SERVICE_ACCOUNT_NAME}" --namespace "${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -
}

get_ca_crt_from_context() {
    # TokenRequest tokens (below) aren't attached to a Secret, so there's no
    # Secret to pull ca.crt from anymore — read it straight off the active
    # context instead. Same go-template/base64decode approach as before,
    # avoids the macOS-vs-Linux `base64 -D`/`-d` split.
    # Session-scoped filename (was a fixed "ca.crt" — two concurrent runs
    # against different clusters would race between this write and the read
    # in set_kube_config_values).
    echo -e -n "\\nExtracting cluster CA cert from current context..."
    kubectl config view --raw --minify \
        -o go-template='{{index (index .clusters 0).cluster "certificate-authority-data" | base64decode}}' \
        > "${CA_CRT_FILE}"
    # A kubeconfig using a `certificate-authority` file path instead of
    # embedded `certificate-authority-data` produces an empty file here with
    # no error (set -e doesn't catch it) — fail loud now instead of a
    # confusing TLS error later.
    [[ -s "${CA_CRT_FILE}" ]] || { echo "ERROR: no certificate-authority-data in current context (using a file-path CA reference instead?)" >&2; exit 1; }
    printf "done"
}

get_user_token() {
    # kubectl create token uses the TokenRequest API (k8s 1.24+): self-expiring,
    # no persistent `kubernetes.io/service-account-token` Secret is created at all.
    echo -e -n "\\nRequesting short-lived token (TokenRequest API, --duration=1h)..."
    # Suspend xtrace across the token assignment even under DEBUG=1: tracing this
    # line prints the bearer token itself into the transcript. Restored to whatever
    # it was immediately after (see the DEBUG note at the top of the file).
    { _xtrace_was_on=""; case "$-" in *x*) _xtrace_was_on=1 ;; esac; set +x; } 2>/dev/null
    USER_TOKEN=$(kubectl create token "${SERVICE_ACCOUNT_NAME}" -n "${NAMESPACE}" --duration=1h)
    [[ -n "${_xtrace_was_on}" ]] && set -x
    printf "done"
}

set_kube_config_values() {
    context=$(kubectl config current-context)
    echo -e "\\nSetting current context to: $context"

    # Read cluster name + server straight from the current context via --minify,
    # instead of the fragile `get-contexts | awk '{print $3}' | tail -1` parse
    # (the current-context `*` marker shifts columns; tail may grab the wrong row).
    CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
    echo "Cluster name: ${CLUSTER_NAME}"

    ENDPOINT=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
    echo "Endpoint: ${ENDPOINT}"

    # Set up the config
    echo -e "\\nPreparing k8s-${SERVICE_ACCOUNT_NAME}-${NAMESPACE}-conf"
    echo -n "Setting a cluster entry in kubeconfig..."
    kubectl config set-cluster "${CLUSTER_NAME}" \
    --kubeconfig="${KUBECFG_FILE_NAME}" \
    --server="${ENDPOINT}" \
    --certificate-authority="${CA_CRT_FILE}" \
    --embed-certs=true

    echo -n "Setting token credentials entry in kubeconfig..."
    # Same reason as the token request above: --token= expands the bearer token on
    # the traced command line, so keep xtrace off across this one call only.
    { _xtrace_was_on=""; case "$-" in *x*) _xtrace_was_on=1 ;; esac; set +x; } 2>/dev/null
    kubectl config set-credentials \
    "${SERVICE_ACCOUNT_NAME}-${NAMESPACE}-${CLUSTER_NAME}" \
    --kubeconfig="${KUBECFG_FILE_NAME}" \
    --token="${USER_TOKEN}"
    [[ -n "${_xtrace_was_on}" ]] && set -x

    echo -n "Setting a context entry in kubeconfig..."
    kubectl config set-context \
    "${SERVICE_ACCOUNT_NAME}-${NAMESPACE}-${CLUSTER_NAME}" \
    --kubeconfig="${KUBECFG_FILE_NAME}" \
    --cluster="${CLUSTER_NAME}" \
    --user="${SERVICE_ACCOUNT_NAME}-${NAMESPACE}-${CLUSTER_NAME}" \
    --namespace="${NAMESPACE}"

    echo -n "Setting the current-context in the kubeconfig file..."
    kubectl config use-context "${SERVICE_ACCOUNT_NAME}-${NAMESPACE}-${CLUSTER_NAME}" \
    --kubeconfig="${KUBECFG_FILE_NAME}"
}

create_read_only_cluster_role() {
# Was apiGroups:["*"] resources:["*"] — granted get/list/watch on Secrets
# cluster-wide. Now scoped to only the CAPI/Palette CRD groups K4 needs to
# read; the built-in `view` ClusterRole (bound separately below) covers most
# of the rest of the read-only surface (pods, deployments, etc.) and already
# excludes Secrets by design. Never add resources:["*"] under the "" (core)
# group here — that's where Secrets live.
#
# `view` deliberately excludes cluster-scoped core resources (Nodes,
# PersistentVolumes, Namespaces list) by k8s design — live-verified on
# a test cluster: `kubectl get nodes` was Forbidden under `view` alone.
# diagnose-cluster's kube tier reads `kubectl get nodes` directly
# (node-tier triage), so Nodes are granted here too — as
# an explicit named resource, not a core-group wildcard, since core also
# holds Secrets.
#
# cluster.spectrocloud.com is pulled into its own rule, resources:
# ["spectroclusters"] only (confirmed via `kubectl api-resources
# --api-group=cluster.spectrocloud.com` — short name `spc`), not
# resources:["*"]. That group also contains `packs`, whose `values` blob can
# carry a pack-author-supplied `oidc-client-secret`-labeled field — and
# K4's read-set only ever runs `kubectl get spc -A` (the kube tier's read set), never touches `packs` or
# `clusterprofiles`, so there's no reason to grant them.
#
# Only 3 CAPI groups stay resources:["*"]: cluster.x-k8s.io,
# infrastructure.cluster.x-k8s.io, controlplane.cluster.x-k8s.io. The CRD
# kinds under them (cluster, machinedeployment, machine, kubeadmcontrolplane,
# awscluster, awsmachine) ARE what K4 reads (live-tested).
# Full audit of every kind in all 3 groups on a test cluster (`kubectl explain
# <kind>.spec --recursive` for all 21 kinds returned by `kubectl api-resources
# --api-group=<group>`, after this bug class recurred repeatedly): every secret-shaped field found is a reference pointer,
# not an embedded value — Machine/MachineSet/MachineDeployment/MachinePool's
# `bootstrap.dataSecretName` (a Secret name, not its contents),
# AWSClusterStaticIdentity's `secretRef` (name only, holds
# AccessKeyID/SecretAccessKey/SessionToken keys but not their values here),
# AWSClusterRoleIdentity's `roleARN` (an ARN, not a credential),
# ROSAControlPlane's `credentialsSecretRef.name` and
# `oidcClients[].clientSecret.name` (both name-only refs),
# AWSManagedControlPlane's `tokenMethod` (a config enum, not a token). The
# ONE exception found — the only kind across all 3 groups that embeds actual
# secret-shaped content instead of a reference — is
# KubeadmControlPlane/KubeadmControlPlaneTemplate, disclosed below as an
# accepted residual risk (RBAC can't scope around it since K4 needs the rest
# of that same object).
# `bootstrap.cluster.x-k8s.io` (KubeadmConfig/KubeadmConfigTemplate) and
# `addons.cluster.x-k8s.io` (ClusterResourceSet/ClusterResourceSetBinding)
# were dropped from the wildcard list: K4 never reads either group (the kube tier never reads either group). Same bug class as the
# packs/oidc-client-secret finding: an unused group happens to carry
# secret-shaped fields. `KubeadmConfigSpec` has `spec.files[].content`
# (arbitrary inline plaintext — commonly TLS material, registry auth, or
# other bootstrap credentials) and `spec.users[].passwd` (a literal
# password). ClusterResourceSet objects are lower-stakes (only reference
# Secrets/ConfigMaps by name, no embedded values) but still unused — no
# reason to keep an unused grant.
#
# controlplane.cluster.x-k8s.io is also pulled into its own rule, resources:
# ["kubeadmcontrolplanes","awsmanagedcontrolplanes","rosacontrolplanes"] —
# the 3 per-cluster control-plane instance kinds K4's cloud-type routing
# reads (kubeadm-based CAPI / EKS-managed / ROSA) — excluding
# `kubeadmcontrolplanetemplates`. A Template is a class-level object, never
# the per-cluster control plane K4 diagnoses, so it's unused by the same
# "K4 never reads this kind" standard applied to bootstrap/addons above, AND
# it carries the identical `files[].content`/`users[].passwd`/
# `bootstrapTokens[].token` fields as KubeadmControlPlane — same bug class,
# 4th instance. Dropping it is a small marginal win (KubeadmControlPlane
# itself, kept below, already carries the identical risk), but there's no
# reason to keep an unused grant that adds nothing.
#
# Residual risk, NOT fixable via RBAC: `kubeadmcontrolplane` IS genuinely
# needed by K4 (this is the one that can't be dropped), and
# `KubeadmControlPlaneSpec` embeds a full `KubeadmConfigSpec` inline — the
# same `files[].content`/`users[].passwd` fields, plus
# `bootstrapTokens[].token`/`tlsBootstrapToken` — and RBAC has no
# field-level granularity to strip just that sub-object. Accepted as-is.
# Live-checked on a test cluster:
# `spec.kubeadmConfigSpec.files[]` IS populated — /etc/kubernetes/
# audit-policy.yaml, /etc/kubernetes/pod-security-standard.yaml,
# /etc/sysctl.d/90-kubelet.conf. Inspected all three: cluster bootstrap
# config (audit policy, pod-security admission config, sysctl tuning), not
# credential material, on this cluster. `users[]` is empty/absent here. So
# this is a live, populated field, just not one holding a secret on
# a test cluster today — a differently-configured cluster (or a future
# kubeadm config change on this one) could put real credentials in
# `files[].content` or `users[].passwd`, and this RBAC grant would expose
# them with no further code change needed. Flagging, not fixing — there is
# no RBAC-only fix.
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: diagnose-cluster-capi-read-role
rules:
- apiGroups:
  - cluster.x-k8s.io
  - infrastructure.cluster.x-k8s.io
  resources: ["*"]
  verbs: ["get","list","watch"]
- apiGroups: ["controlplane.cluster.x-k8s.io"]
  resources: ["kubeadmcontrolplanes", "awsmanagedcontrolplanes", "rosacontrolplanes"]
  verbs: ["get","list","watch"]
- apiGroups: ["cluster.spectrocloud.com"]
  resources: ["spectroclusters"]
  verbs: ["get","list","watch"]
- apiGroups: [""]
  resources: ["nodes", "nodes/status"]
  verbs: ["get","list","watch"]
EOF
}

create_read_only_cluster_role_binding() {
# Session-unique binding names (was a shared `get-allkind-role-binding`, which
# `apply` overwrote on every run — silently revoking any prior session's SA).
# Two bindings because a ClusterRoleBinding only supports one roleRef: one to
# the built-in `view` role, one to the supplemental CAPI/Palette role above.
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: view-binding-${SERVICE_ACCOUNT_NAME}-${NAMESPACE}
subjects:
- kind: ServiceAccount
  name: ${SERVICE_ACCOUNT_NAME}
  namespace: ${NAMESPACE}
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
EOF
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: diagnose-cluster-capi-read-binding-${SERVICE_ACCOUNT_NAME}-${NAMESPACE}
subjects:
- kind: ServiceAccount
  name: ${SERVICE_ACCOUNT_NAME}
  namespace: ${NAMESPACE}
roleRef:
  kind: ClusterRole
  name: diagnose-cluster-capi-read-role
  apiGroup: rbac.authorization.k8s.io
EOF
}

create_target_folder
create_service_account
get_ca_crt_from_context
get_user_token
create_read_only_cluster_role
create_read_only_cluster_role_binding
set_kube_config_values

chmod 600 "${KUBECFG_FILE_NAME}"

# Sanity check: the RO credential can list pods (read verb) but must NOT create.
echo -e "\\nVerifying read-only access..."
# `&& echo` alone would swallow a negative/failed result: `set -e` does not
# abort on a failing left-hand side of &&, so the line silently vanished and
# the script still printed RO_KUBECONFIG= and exited 0 — handing K3 a
# credential that cannot read anything (RBAC propagation lag, or a grant that
# genuinely did not take).
if KUBECONFIG="${KUBECFG_FILE_NAME}" kubectl auth can-i list pods -A >/dev/null 2>&1; then
  echo "  can list pods: yes"
else
  echo "  WARNING: cannot list pods with the minted credential — it may not be usable yet (RBAC propagation) or the grant failed. Re-check before relying on it." >&2
fi
# `kubectl auth can-i` exits non-zero for BOTH an explicit "no" AND for
# execution errors (connection refused, API error, expired token), so exit
# status alone cannot tell "write is denied" apart from "we could not find
# out". The previous form discarded the output and printed
# "read-only confirmed" on any non-zero status — i.e. an API error was
# reported as proof of read-only. Inspect the printed answer instead, and
# fail closed on anything inconclusive: emitting RO_KUBECONFIG= after a
# check that never proved denial hands K3 a credential on false assurance.
WRITE_ANSWER=$(KUBECONFIG="${KUBECFG_FILE_NAME}" kubectl auth can-i create pods -A 2>/dev/null || true)
case "${WRITE_ANSWER}" in
  no)
    echo "  can create pods: no (read-only confirmed)"
    ;;
  yes)
    echo "ERROR: the minted credential CAN create pods — it is NOT read-only. Removing it rather than handing it on." >&2
    rm -f "${KUBECFG_FILE_NAME}" "${CA_CRT_FILE}"
    exit 1
    ;;
  *)
    echo "ERROR: could not determine whether the minted credential can create pods (got '${WRITE_ANSWER:-<no output>}'). Refusing to report a credential as read-only when that was never proven. Removing it." >&2
    rm -f "${KUBECFG_FILE_NAME}" "${CA_CRT_FILE}"
    exit 1
    ;;
esac

# Machine-readable output for the diagnose-cluster skill to capture.
echo "RO_KUBECONFIG=${KUBECFG_FILE_NAME}"
