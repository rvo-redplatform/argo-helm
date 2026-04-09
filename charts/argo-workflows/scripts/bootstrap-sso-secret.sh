#!/usr/bin/env bash
# bootstrap-sso-secret.sh
#
# Creates the argo-server-sso Kubernetes secret required for Argo Workflows SSO.
# Uses the dedicated argo-workflows Cognito app client — NOT the argocd client.
#
# The client secret is fetched directly from AWS Cognito so it never has to be
# copy-pasted or stored in plaintext locally.
#
# Prerequisites:
#   - aws CLI configured with credentials that can call cognito-idp
#   - kubectl configured against the target cluster/namespace
#
# Usage:
#   ./bootstrap-sso-secret.sh
#   NAMESPACE=my-namespace ./bootstrap-sso-secret.sh
#   DRY_RUN=true ./bootstrap-sso-secret.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Config — update CLIENT_ID when the argo-workflows Cognito app client is
# created in Terraform (separate from the argocd client 59iua2rsejtdhbna06qr6fbn4m)
# ---------------------------------------------------------------------------
USER_POOL_ID="${USER_POOL_ID:-us-east-1_VAPDmmfVL}"
CLIENT_ID="${CLIENT_ID:-REPLACE_WITH_ARGO_WORKFLOWS_CLIENT_ID}"
REGION="${REGION:-us-east-1}"
NAMESPACE="${NAMESPACE:-argo-workflows}"
SECRET_NAME="argo-server-sso"
DRY_RUN="${DRY_RUN:-false}"

# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[bootstrap]${NC} $*"; }
warn() { echo -e "${YELLOW}[bootstrap]${NC} $*"; }
die()  { echo -e "${RED}[bootstrap] ERROR:${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

[[ "$CLIENT_ID" == "REPLACE_WITH_ARGO_WORKFLOWS_CLIENT_ID" ]] && \
  die "CLIENT_ID is not set. Update the variable in this script or export CLIENT_ID=<id> before running."

command -v aws    &>/dev/null || die "aws CLI not found. Install it and configure credentials."
command -v kubectl &>/dev/null || die "kubectl not found."

# ---------------------------------------------------------------------------
# Fetch client secret from Cognito
# ---------------------------------------------------------------------------

log "Fetching client secret from Cognito..."
log "  User pool : $USER_POOL_ID"
log "  Client ID : $CLIENT_ID"
log "  Region    : $REGION"

CLIENT_SECRET=$(aws cognito-idp describe-user-pool-client \
  --user-pool-id "$USER_POOL_ID" \
  --client-id "$CLIENT_ID" \
  --query 'UserPoolClient.ClientSecret' \
  --output text \
  --region "$REGION")

[[ -z "$CLIENT_SECRET" || "$CLIENT_SECRET" == "None" ]] && \
  die "No client secret returned. Confirm this is a confidential client (generate_secret = true in Terraform)."

log "Client secret fetched successfully."

# ---------------------------------------------------------------------------
# Create / update the secret
# ---------------------------------------------------------------------------

if [[ "$DRY_RUN" == "true" ]]; then
  warn "DRY_RUN=true — printing the kubectl command without executing it."
  echo ""
  echo "kubectl create secret generic $SECRET_NAME \\"
  echo "  --namespace $NAMESPACE \\"
  echo "  --from-literal=client-id=$CLIENT_ID \\"
  echo "  --from-literal=client-secret=<redacted> \\"
  echo "  --dry-run=client -o yaml"
  exit 0
fi

log "Creating/updating secret '$SECRET_NAME' in namespace '$NAMESPACE'..."

kubectl create secret generic "$SECRET_NAME" \
  --namespace "$NAMESPACE" \
  --from-literal=client-id="$CLIENT_ID" \
  --from-literal=client-secret="$CLIENT_SECRET" \
  --save-config \
  --dry-run=client -o yaml | kubectl apply -f -

log "Done. Secret '$SECRET_NAME' is ready in namespace '$NAMESPACE'."
log ""
log "Next steps:"
log "  1. Add the argo-workflows callback URL to the Cognito app client in Terraform:"
log "       https://<argo-workflows-hostname>/oauth2/callback"
log "  2. Update server.sso.redirectUrl in values.yaml to match the hostname."
log "  3. Update server.httproute.hostnames and annotations to match the hostname."
