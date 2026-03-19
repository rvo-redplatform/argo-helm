# AWS Cognito SSO Setup for ArgoCD with Okta Federation

This guide documents the complete setup of AWS Cognito SSO for ArgoCD with Okta SAML federation, including the ArgoCD CLI configuration.

## Architecture Overview

```
User Browser/CLI
    │
    ├── Web UI: Browser → ALB (443) → ArgoCD Server → Cognito → Okta (SAML)
    │                                  (confidential client, with secret)
    │
    └── CLI:    argocd login --sso → localhost:8085 → Cognito → Okta (SAML)
                                     (public client, PKCE only, no secret)
```

Two Cognito app clients are required:
- **argocd** (confidential): Used by the ArgoCD server for web UI login. Has a client secret.
- **argocd-cli** (public): Used by the ArgoCD CLI for local SSO login. No secret, secured via PKCE.

## Access Levels

- **argocd-users**: Read-only access to applications, clusters, projects, repositories, and logs
- **argocd-admins**: Full administrative access to all ArgoCD resources

## Prerequisites

- AWS Account with Cognito User Pool
- Okta SAML application configured
- ArgoCD Helm chart deployed on EKS
- AWS ALB Ingress Controller
- External DNS Controller

## Cognito Configuration

### User Pool

Managed via Terraform in `tfe_redplatform-tools/core/production/us-east-1/cognito.tf`:

```hcl
module "rp-tools-prod-cognito" {
  source    = "git@github.com:rvo-redplatform/terraform-aws-cognito.git?ref=v1.0.1"
  pool_name = "rp-tools-prod"

  # Okta SAML Federation
  okta_attach_to_user_pool      = true
  okta_metadata_url             = "https://sso.rvohealth.com/app/<APP_ID>/sso/saml/metadata"
  okta_sso_redirect_binding_uri = "https://sso.rvohealth.com/app/<APP_NAME>/<APP_ID>/sso/saml"

  client_configurations = {
    # Confidential client for ArgoCD web UI (server-side token exchange)
    argocd = {
      name                                 = "argocd"
      allowed_oauth_flows_user_pool_client = true
      allowed_oauth_flows                  = ["code", "implicit"]
      allowed_oauth_scopes                 = ["openid", "email", "profile"]
      generate_secret                      = true
      enable_token_revocation              = true
      callback_urls                        = [
        "https://argocd.rp-tools-prod.rvohealth.com/auth/callback",
        "https://argocd.rp-tools-prod.rvohealth.com/pkce/verify"
      ]
    }
    # Public client for ArgoCD CLI (PKCE, no secret)
    argocd-cli = {
      name                                 = "argocd-cli"
      allowed_oauth_flows_user_pool_client = true
      allowed_oauth_flows                  = ["code"]
      allowed_oauth_scopes                 = ["openid", "email", "profile"]
      generate_secret                      = false
      enable_token_revocation              = true
      callback_urls                        = ["http://localhost:8085/auth/callback"]
    }
  }
}
```

### Why Two Clients?

The ArgoCD CLI exchanges authorization codes directly with Cognito from the local machine using PKCE (no client secret). Cognito confidential clients (with `generate_secret = true`) require the secret on every token exchange. Since the CLI has no access to the secret, a separate public client is needed.

**Source**: ArgoCD source code `cmd/argocd/commands/login.go` - the CLI's `oauth2.Config` has an empty `ClientSecret` field and relies on PKCE (`code_challenge` + `code_verifier`).

## Okta SAML App Configuration

In the Okta admin console, configure the SAML app with:

| Field | Value |
|-------|-------|
| **Single sign-on URL** | `https://<COGNITO_DOMAIN>.auth.<REGION>.amazoncognito.com/saml2/idpresponse` |
| **Use this for Recipient URL and Destination URL** | Checked |
| **Audience URI (SP Entity ID)** | `urn:amazon:cognito:sp:<USER_POOL_ID>` |
| **Default RelayState** | Leave blank |
| **Name ID format** | `Unspecified` |
| **Application username** | `Okta username` |

### Attribute Mapping in Cognito

| User pool attribute | SAML attribute |
|---|---|
| email | `http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress` |
| family_name | `lastName` |
| given_name | `firstName` |

## ArgoCD Helm Values Configuration

In `values/redplatform.yaml`:

```yaml
configs:
  params:
    server.insecure: true  # TLS terminated at ALB

  cm:
    admin.enabled: false
    oidc.config: |
      name: AWS Cognito
      issuer: https://cognito-idp.<REGION>.amazonaws.com/<USER_POOL_ID>
      clientID: <CONFIDENTIAL_CLIENT_ID>
      clientSecret: $oidc.cognito.clientSecret
      cliClientID: <PUBLIC_CLI_CLIENT_ID>
      enablePKCEAuthentication: true
      requestedScopes:
        - openid
        - profile
        - email
      requestedIDTokenClaims:
        cognito:groups:
          essential: true

  rbac:
    scopes: "[cognito:groups]"
    policy.csv: |
      g, argocd-users, role:readonly
      g, argocd-admins, role:admin
```

### Important Notes

- **Do NOT include `aws.cognito.signin.user.admin` scope** - Cognito hosted UI rejects it via OAuth flow, returns `invalid_scope`.
- **`cliClientID`** must point to the public client (no secret). Without this, CLI login fails with `invalid_client_secret`.
- **`enablePKCEAuthentication: true`** enables PKCE for both web and CLI flows.

## Client Secret Management

The confidential client secret must be stored in the `argocd-secret` Kubernetes secret:

```bash
# Get the secret from Cognito
SECRET=$(aws cognito-idp describe-user-pool-client \
  --user-pool-id <USER_POOL_ID> \
  --client-id <CONFIDENTIAL_CLIENT_ID> \
  --query 'UserPoolClient.ClientSecret' \
  --output text \
  --region <REGION>)

# Patch the argocd-secret
kubectl patch secret argocd-secret -n argocd \
  --type merge \
  -p "{\"stringData\":{\"oidc.cognito.clientSecret\":\"$SECRET\"}}"
```

ArgoCD references this via `$oidc.cognito.clientSecret` in the OIDC config and looks it up in the `argocd-secret` automatically.

## CLI Login

```bash
# Standard login (behind Zscaler or proxy that breaks HTTP/2, use --grpc-web)
argocd login argocd.rp-tools-prod.rvohealth.com --skip-test-tls --sso --grpc-web

# If gRPC works natively (no proxy interference)
argocd login argocd.rp-tools-prod.rvohealth.com --sso
```

The `--skip-test-tls` flag prevents the CLI from hanging on a TLS connectivity test. The `--grpc-web` flag wraps gRPC in HTTP/1.1 which is needed when a proxy (like Zscaler) strips HTTP/2 ALPN negotiation.

### How CLI SSO Works

1. CLI contacts ArgoCD server to get OIDC config (including `cliClientID`)
2. CLI starts a temporary HTTP server on `localhost:8085`
3. CLI opens browser to Cognito authorize endpoint using the **public client ID**
4. User authenticates via Okta
5. Cognito redirects browser to `http://localhost:8085/auth/callback` with authorization code
6. CLI exchanges code directly with Cognito using **PKCE** (no secret)
7. CLI receives ID token and stores it locally

## Deployment

```bash
# From argo-helm/charts/argo-cd/values directory
helm upgrade argocd .. -n argocd -f redplatform.yaml
```

## Troubleshooting

### `invalid_scope` Error on Login

The `aws.cognito.signin.user.admin` scope is not supported via the Cognito hosted UI OAuth flow. Remove it from `requestedScopes`.

### `invalid_client_secret` Error on CLI Login

The CLI does not send a client secret. If the CLI is using the confidential client ID (the one with `generate_secret = true`), Cognito rejects the request. Fix: set `cliClientID` in the OIDC config to a separate public client.

### `context deadline exceeded` on CLI Login

Multiple possible causes:
1. **gRPC connectivity**: Use `--grpc-web` flag. Proxies like Zscaler break HTTP/2.
2. **TLS test hanging**: Use `--skip-test-tls` flag.
3. **Callback URL not allowed**: Ensure `http://localhost:8085/auth/callback` is in the public client's callback URLs.

### 403 Forbidden on Cognito Hosted UI

- Verify the Okta SAML IdP is associated with the app client
- Check callback URLs match exactly
- Verify OAuth grant types and scopes are configured

### Web UI SSO Works But CLI Fails

This is expected if `cliClientID` is not configured. The web UI uses the confidential client (server-side token exchange with secret), while the CLI exchanges tokens directly without a secret. See "Why Two Clients?" above.

### ALB 464 Error on gRPC

The ALB returns 464 when backend protocol doesn't match. With `server.insecure: true`, ArgoCD serves HTTP/1.1. The gRPC target group protocol version must be set to `GRPC` with `HTTPS` protocol. If using insecure mode, the gRPC target group cannot properly forward gRPC traffic. Use `--grpc-web` to wrap gRPC in HTTP/1.1.

## Cognito Groups

Create groups in the Cognito User Pool to map to ArgoCD roles:

| Cognito Group | ArgoCD Role | Access |
|---|---|---|
| `argocd-users` | `role:readonly` | View applications, clusters, projects, repos, logs |
| `argocd-admins` | `role:admin` | Full access to all ArgoCD resources |

## References

- [ArgoCD OIDC Configuration](https://argo-cd.readthedocs.io/en/stable/operator-manual/user-management/#existing-oidc-provider)
- [ArgoCD TLS Configuration](https://argo-cd.readthedocs.io/en/stable/operator-manual/tls/)
- [ArgoCD Ingress Configuration (ALB)](https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/#aws-application-load-balancers-albs-and-classic-elb-http-mode)
- [ArgoCD CLI Login Reference](https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_login/)
- [ArgoCD RBAC Configuration](https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/)
- [AWS Cognito SAML Federation](https://docs.aws.amazon.com/cognito/latest/developerguide/cognito-user-pools-saml-idp.html)
- [RFC 8252 - OAuth 2.0 for Native Applications](https://datatracker.ietf.org/doc/html/rfc8252)
- [AWS ALB Target Group Protocol Versions](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-target-groups.html#target-group-protocol-version)
