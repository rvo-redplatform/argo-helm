#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# bootstrap-namespace.sh
#
# Creates the 'argo-workflows' namespace and applies the Istio ambient mesh label.
#
# Usage:
#   ./create-namespace.sh
#
# What this script does:
#   1. Creates the 'argo-workflows' namespace (idempotent — safe to re-run)
#   2. Labels the namespace with istio.io/dataplane-mode: ambient
#      This is the ONLY label needed for ambient mesh on EKS. ztunnel handles
#      mTLS transparently at the node level with no webhook or sidecar involved.
#
# ⚠️  DO NOT add istio.io/rev to this namespace.
#      That label triggers the sidecar injection webhook
#      (rev.namespace.*.sidecar-injector.istio.io), which will always time out
#      on EKS because the control plane cannot reach the istiod webhook service.
#      Ambient mode does not use sidecars — the rev label is not needed.
#
# Prerequisites:
#   - kubectl configured and pointing at the correct cluster context
#   - Sufficient RBAC permissions to create/label namespaces
#   - Istio ambient mesh deployed on the cluster (managed by platform team)
# -----------------------------------------------------------------------------

set -euo pipefail

# ---------- helpers ----------------------------------------------------------

log() {
  echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"
}

NAMESPACE="argo-workflows"

# ---------- preflight --------------------------------------------------------

if ! command -v kubectl &>/dev/null; then
  echo "Error: kubectl is not installed or not in PATH."
  exit 1
fi

log "Namespace    : ${NAMESPACE}"
log "Ambient mode : enabled (istio.io/dataplane-mode=ambient)"
echo ""

# Show current context so the operator can confirm they're on the right cluster.
CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || echo '<none>')"
log "Current kube context: ${CURRENT_CONTEXT}"
echo ""

read -r -p "Apply to this cluster? [y/N] " confirm
if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
  log "Aborted."
  exit 0
fi

echo ""

# ---------- strip istio.io/rev if it exists ----------------------------------
# If a previous attempt left an istio.io/rev label on the namespace it must be
# removed — that label triggers sidecar injection and will cause pod creation
# to fail with a webhook timeout on EKS.

if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  if kubectl get namespace "${NAMESPACE}" -o jsonpath='{.metadata.labels.istio\.io/rev}' 2>/dev/null | grep -q .; then
    log "Found stale istio.io/rev label — removing it to prevent webhook injection..."
    kubectl label namespace "${NAMESPACE}" istio.io/rev-
    log "Removed."
    echo ""
  fi
fi

# ---------- apply namespace --------------------------------------------------

log "Applying namespace '${NAMESPACE}'..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    # Required: enrolls all pods in this namespace in Istio ambient mesh.
    # ztunnel intercepts traffic at the node level — no sidecar injection,
    # no webhook, no pod restarts needed.
    istio.io/dataplane-mode: ambient
EOF

# ---------- verify -----------------------------------------------------------

echo ""
log "Verifying namespace labels..."
kubectl get namespace "${NAMESPACE}" --show-labels

echo ""
log "Namespace '${NAMESPACE}' is ready."
log "All pods in this namespace will automatically participate in the Istio"
log "ambient mesh with mTLS via ztunnel. No sidecar injection is used."
