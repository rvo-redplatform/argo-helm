#!/usr/bin/env bash
# bootstrap-sso-secret.sh
#
# Creates the argo-server-sso Kubernetes secret required for Argo Workflows SSO.
# Prompts interactively for the Cognito client ID and secret.
#
# Prerequisites:
#   - kubectl configured against the target cluster

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[bootstrap]${NC} $*"; }
warn() { echo -e "${YELLOW}[bootstrap]${NC} $*"; }
die()  { echo -e "${RED}[bootstrap] ERROR:${NC} $*" >&2; exit 1; }

command -v kubectl &>/dev/null || die "kubectl not found."

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || echo '<none>')"
log "Current kube context: ${CURRENT_CONTEXT}"
echo ""

read -r -p "Namespace [argo-workflows]: " NAMESPACE
NAMESPACE="${NAMESPACE:-argo-workflows}"

read -r -p "Cognito client ID: " CLIENT_ID
[[ -z "$CLIENT_ID" ]] && die "Client ID cannot be empty."

read -r -s -p "Cognito client secret: " CLIENT_SECRET
echo ""
[[ -z "$CLIENT_SECRET" ]] && die "Client secret cannot be empty."

echo ""
log "Namespace : $NAMESPACE"
log "Client ID : $CLIENT_ID"
log "Secret    : (set)"
echo ""

read -r -p "Apply to this cluster? [y/N] " confirm
[[ "${confirm}" != "y" && "${confirm}" != "Y" ]] && { log "Aborted."; exit 0; }

echo ""

# ---------------------------------------------------------------------------
# Create / update the secret
# ---------------------------------------------------------------------------

log "Creating/updating secret 'argo-server-sso' in namespace '$NAMESPACE'..."

kubectl create secret generic argo-server-sso \
  --namespace "$NAMESPACE" \
  --from-literal=client-id="$CLIENT_ID" \
  --from-literal=client-secret="$CLIENT_SECRET" \
  --save-config \
  --dry-run=client -o yaml | kubectl apply -f -

log "Done. Secret 'argo-server-sso' is ready in namespace '$NAMESPACE'."
