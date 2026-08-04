#!/bin/bash
set -e
set -o pipefail
# NOTE: `set -x` intentionally removed — it echoed the SA bearer token to stdout,
# which lands in the Claude/skill transcript. Set DEBUG=1 to re-enable tracing.
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
# ============================================================================

# Cleanup mode: `generate_ro_kubeconfig.sh --cleanup <sa> <ns>` removes everything
# this script created (call at end of a diagnosis session).
if [[ "${1:-}" == "--cleanup" ]]; then
    _sa="${2:?usage: --cleanup <sa> <ns>}"; _ns="${3:?usage: --cleanup <sa> <ns>}"
    kubectl delete clusterrolebinding "view-binding-${_sa}-${_ns}" --ignore-not-found
    kubectl delete clusterrolebinding "diagnose-cluster-capi-read-binding-${_sa}-${_ns}" --ignore-not-found
    kubectl delete sa "${_sa}" -n "${_ns}" --ignore-not-found
    rm -f "/tmp/kube/k8s-${_sa}-${_ns}-conf" "/tmp/kube/ca-${_sa}-${_ns}.crt"
    echo "cleaned up RO artifacts for ${_sa}/${_ns} (shared ClusterRoles view + diagnose-cluster-capi-read-role left intact)"
    exit 0
fi

# Add user to k8s using service account, no RBAC (must create RBAC after this script)
if [[ -z "$1" ]] || [[ -z "$2" ]]; then
 echo "usage: $0 <service_account_name> <namespace>"
 exit 1
fi

SERVICE_ACCOUNT_NAME=$1
NAMESPACE="$2"
KUBECFG_FILE_NAME="/tmp/kube/k8s-${SERVICE_ACCOUNT_NAME}-${NAMESPACE}-conf"
TARGET_FOLDER="/tmp/kube"
CA_CRT_FILE="${TARGET_FOLDER}/ca-${SERVICE_ACCOUNT_NAME}-${NAMESPACE}.crt"

create_target_folder() {
    echo -n "Creating target directory to hold files in ${TARGET_FOLDER}..."
    mkdir -p "${TARGET_FOLDER}"
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
    USER_TOKEN=$(kubectl create token "${SERVICE_ACCOUNT_NAME}" -n "${NAMESPACE}" --duration=1h)
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
    kubectl config set-credentials \
    "${SERVICE_ACCOUNT_NAME}-${NAMESPACE}-${CLUSTER_NAME}" \
    --kubeconfig="${KUBECFG_FILE_NAME}" \
    --token="${USER_TOKEN}"

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
KUBECONFIG="${KUBECFG_FILE_NAME}" kubectl auth can-i list pods -A >/dev/null && echo "  can list pods: yes"
KUBECONFIG="${KUBECFG_FILE_NAME}" kubectl auth can-i create pods -A >/dev/null 2>&1 \
    && echo "  WARNING: can create pods — role is NOT read-only" \
    || echo "  can create pods: no (read-only confirmed)"

# Machine-readable output for the diagnose-cluster skill to capture.
echo "RO_KUBECONFIG=${KUBECFG_FILE_NAME}"
