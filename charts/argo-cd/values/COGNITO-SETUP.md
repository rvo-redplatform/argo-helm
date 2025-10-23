# AWS Cognito SSO Setup for ArgoCD

This guide walks you through setting up AWS Cognito for SSO authentication with ArgoCD, including RBAC configuration for read-only users and admin users.

## Overview

The configuration creates two access levels:
- **argocd-users**: Read-only access to applications, clusters, projects, repositories, and logs
- **argocd-admins**: Full administrative access to all ArgoCD resources

## Prerequisites

- AWS Account with access to Cognito
- ArgoCD Helm chart deployed
- Your ArgoCD domain configured (already set: `argocd.rp-tools-prod.rvohealth.com`)

## Step 1: Create AWS Cognito User Pool

1. Navigate to **AWS Cognito Console**
2. Click **Create user pool**
3. Configure sign-in options:
   - Select **Email** as sign-in option
   - Enable **Also allow sign in with preferred username**
4. Configure security requirements as needed
5. Configure sign-up experience (optional)
6. Configure message delivery (use Cognito defaults or SES)
7. **Important**: Add custom attributes or leave as default
8. Give your user pool a name (e.g., `argocd-users`)
9. Create the user pool

## Step 2: Configure App Client

1. In your User Pool, go to **App integration** tab
2. Click **Create app client**
3. Configure the app client:
   - **App client name**: `argocd`
   - **Authentication flows**: Select **ALLOW_USER_PASSWORD_AUTH** and **ALLOW_REFRESH_TOKEN_AUTH**
   - **App client secret**: Generate a client secret (you'll need this later)
4. Under **Hosted UI settings**:
   - **Allowed callback URLs**: 
     ```
     https://argocd.rp-tools-prod.rvohealth.com/auth/callback
     https://argocd.rp-tools-prod.rvohealth.com/pkce/verify
     ```
   - **Allowed sign-out URLs**: 
     ```
     https://argocd.rp-tools-prod.rvohealth.com
     ```
   - **Identity providers**: Select **Cognito user pool**
   - **OAuth 2.0 grant types**: Select **Authorization code grant**
   - **OpenID Connect scopes**: Select:
     - `openid`
     - `profile`
     - `email`
     `
5. Click **Create app client**

## Step 3: Create Cognito Groups

1. In your User Pool, go to the **Groups** tab
2. Create two groups:

   **Group 1: argocd-users (Read-only)**
   - Group name: `argocd-users`
   - Description: `ArgoCD read-only users`
   - Precedence: `1`
   
   **Group 2: argocd-admins (Full Admin)**
   - Group name: `argocd-admins`
   - Description: `ArgoCD administrators`
   - Precedence: `0` (lower number = higher precedence)

## Step 4: Create Users and Assign to Groups

1. In your User Pool, go to the **Users** tab
2. Click **Create user**
3. Enter user details:
   - Email address
   - Set temporary password or send invitation
4. Click **Create user**
5. After creating users, click on each user
6. Click **Add user to group**
7. Select either `argocd-users` or `argocd-admins`

## Step 5: Get Required Configuration Values

You'll need these values from your Cognito setup:

1. **User Pool ID**: 
   - Found in User Pool overview page
   - Format: `us-east-1_aBcD1234`

2. **AWS Region**: 
   - The region where your User Pool is created
   - Example: `us-east-1`

3. **App Client ID**:
   - Go to **App integration** > **App clients**
   - Copy the **Client ID**
   - Format: `1a2b3c4d5e6f7g8h9i0j1k2l3m`

4. **App Client Secret**:
   - In the same App client details page
   - Click **Show client secret**
   - Copy the secret value

5. **Issuer URL**:
   - Format: `https://cognito-idp.<REGION>.amazonaws.com/<USER_POOL_ID>`
   - Example: `https://cognito-idp.us-east-1.amazonaws.com/us-east-1_aBcD1234`

## Step 6: Update ArgoCD Values File

Update your `values/redplatform.yaml` file with your Cognito values:

```yaml
configs:
  cm:
    oidc.config: |
      name: AWS Cognito
      issuer: https://cognito-idp.<YOUR_AWS_REGION>.amazonaws.com/<YOUR_USER_POOL_ID>
      clientID: <YOUR_APP_CLIENT_ID>
      clientSecret: $oidc.cognito.clientSecret
      requestedScopes:
        - openid
        - profile
        - email
        - aws.cognito.signin.user.admin
      requestedIDTokenClaims:
        cognito:groups:
          essential: true
  
  secret:
    extra:
      oidc.cognito.clientSecret: <YOUR_COGNITO_APP_CLIENT_SECRET>
  
  rbac:
    scopes: "[cognito:groups]"
    policy.csv: |
      # Define the readonly role with read-only permissions
      p, role:readonly, applications, get, */*, allow
      p, role:readonly, applications, list, */*, allow
      p, role:readonly, clusters, get, *, allow
      p, role:readonly, clusters, list, *, allow
      p, role:readonly, projects, get, *, allow
      p, role:readonly, projects, list, *, allow
      p, role:readonly, repositories, get, *, allow
      p, role:readonly, repositories, list, *, allow
      p, role:readonly, logs, get, *, allow
      
      # Define the admin role with full permissions
      p, role:admin, applications, *, */*, allow
      p, role:admin, applicationsets, *, */*, allow
      p, role:admin, clusters, *, *, allow
      p, role:admin, projects, *, *, allow
      p, role:admin, repositories, *, *, allow
      p, role:admin, logs, *, *, allow
      p, role:admin, exec, *, */*, allow
      p, role:admin, accounts, *, *, allow
      p, role:admin, gpgkeys, *, *, allow
      p, role:admin, certificates, *, *, allow
      
      # Map Cognito groups to roles
      g, argocd-users, role:readonly
      g, argocd-admins, role:admin
```

**Important**: Replace the placeholders with your actual values:
- `<YOUR_AWS_REGION>` - e.g., `us-east-1`
- `<YOUR_USER_POOL_ID>` - e.g., `us-east-1_aBcD1234`
- `<YOUR_APP_CLIENT_ID>` - e.g., `1a2b3c4d5e6f7g8h9i0j1k2l3m`
- `<YOUR_COGNITO_APP_CLIENT_SECRET>` - The client secret value

## Step 7: Configure External DNS for ALB

The configuration includes External DNS annotations that will automatically create a Route53 DNS record pointing to your ALB:

```yaml
annotations:
  # External DNS Configuration
  external-dns.alpha.kubernetes.io/hostname: argocd.rp-tools-prod.rvohealth.com
  external-dns.alpha.kubernetes.io/ttl: "300"
```

**How External DNS Works:**
1. When the ArgoCD Ingress is created, the AWS ALB Controller provisions an Application Load Balancer
2. The External DNS controller watches for Ingress resources with `external-dns.alpha.kubernetes.io/hostname` annotation
3. It automatically creates an A record (or ALIAS record) in Route53 pointing to the ALB DNS name
4. The TTL of 300 seconds (5 minutes) controls DNS caching duration

**Prerequisites:**
- AWS External DNS Controller must be deployed in your cluster
- The External DNS service account must have IAM permissions to manage Route53 records:
  - `route53:ChangeResourceRecordSets`
  - `route53:ListResourceRecordSets`
  - `route53:GetHostedZone`
  - `route53:ListHostedZones`

## Step 8: Deploy ArgoCD with Updated Configuration

```bash
# Navigate to the chart directory
cd charts/argo-cd

# Install or upgrade ArgoCD with your custom values
helm upgrade --install argocd . \
  --namespace argocd \
  --create-namespace \
  -f values/redplatform.yaml
```

After deployment, verify the DNS record was created:

```bash
# Check External DNS logs
kubectl logs -n kube-system -l app.kubernetes.io/name=external-dns

# Verify Route53 record (replace with your hosted zone ID)
aws route53 list-resource-record-sets --hosted-zone-id <YOUR_HOSTED_ZONE_ID> \
  --query "ResourceRecordSets[?Name=='argocd.rp-tools-prod.rvohealth.com.']"
```

## Step 9: Test SSO Login

1. Navigate to `https://argocd.rp-tools-prod.rvohealth.com`
2. You should see a **LOGIN VIA AWS COGNITO** button
3. Click the button and sign in with your Cognito credentials
4. After successful authentication, you'll be redirected back to ArgoCD

## Verify RBAC Permissions

### For Read-Only Users (argocd-users group):
- Can view applications, clusters, projects, and repositories
- Can view logs
- **Cannot** create, update, or delete resources
- **Cannot** sync applications
- **Cannot** access exec terminal

### For Admin Users (argocd-admins group):
- Full access to all ArgoCD resources
- Can create, update, and delete applications
- Can manage clusters, projects, and repositories
- Can sync applications
- Can access exec terminal
- Can manage accounts, GPG keys, and certificates

## Troubleshooting

### SSO Button Not Appearing
- Check that the OIDC configuration is properly set in the ConfigMap
- Verify the ArgoCD server pods have restarted after configuration changes
- Check ArgoCD server logs: `kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server`

### Authentication Fails
- Verify the callback URL in Cognito matches your ArgoCD domain exactly
- Check that the client ID and client secret are correct
- Ensure the user pool ID and region are correct in the issuer URL
- Verify the OAuth scopes include `aws.cognito.signin.user.admin`

### User Has Wrong Permissions
- Verify the user is in the correct Cognito group (`argocd-users` or `argocd-admins`)
- Check the ArgoCD RBAC ConfigMap: `kubectl get cm argocd-rbac-cm -n argocd -o yaml`
- Verify the group name in Cognito matches exactly with the policy.csv configuration
- The scope configuration must be `[cognito:groups]` to read groups from Cognito

### Groups Not Being Passed from Cognito
- Ensure `aws.cognito.signin.user.admin` scope is requested
- Verify `requestedIDTokenClaims` includes `cognito:groups: essential: true`
- Check that the app client has access to the groups scope in Cognito

## Security Best Practices

1. **Use AWS Secrets Manager**: Instead of storing the client secret in the values file, consider using AWS Secrets Manager or Kubernetes External Secrets
2. **Enable MFA**: Enable multi-factor authentication in Cognito for admin users
3. **Regular Audits**: Regularly review group memberships and permissions
4. **Least Privilege**: Start with read-only access and grant admin access only as needed
5. **Monitor Access**: Enable CloudTrail logging for Cognito authentication events

## Advanced Configuration

### Adding More Custom Roles

You can create additional roles with specific permissions. For example, a "developer" role with deployment permissions but no cluster management:

```yaml
# Add to policy.csv
p, role:developer, applications, get, */*, allow
p, role:developer, applications, sync, */*, allow
p, role:developer, applications, override, */*, allow
p, role:developer, logs, get, *, allow
g, argocd-developers, role:developer
```

Then create an `argocd-developers` group in Cognito.

### Project-Specific Permissions

Restrict access to specific ArgoCD projects:

```yaml
# Allow role:team-a only to access team-a project
p, role:team-a, applications, *, team-a/*, allow
p, role:team-a, repositories, get, *, allow
g, argocd-team-a, role:team-a
```

## External DNS Troubleshooting

### DNS Record Not Created
- Check External DNS logs: `kubectl logs -n kube-system -l app.kubernetes.io/name=external-dns`
- Verify the External DNS controller is running and has proper IAM permissions
- Ensure the hostname annotation is correctly formatted
- Check that the Route53 hosted zone exists and matches your domain

### DNS Record Points to Wrong Target
- External DNS creates an ALIAS record pointing to the ALB DNS name
- Verify the ALB was created successfully: `kubectl get ingress -n argocd`
- Check ALB status in AWS Console

## References

- [ArgoCD RBAC Documentation](https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/)
- [ArgoCD SSO Configuration](https://argo-cd.readthedocs.io/en/stable/operator-manual/user-management/)
- [ArgoCD Ingress Configuration](https://argo-cd.readthedocs.io/en/latest/operator-manual/ingress/)
- [AWS Cognito Documentation](https://docs.aws.amazon.com/cognito/)
- [OIDC Configuration Guide](https://argo-cd.readthedocs.io/en/stable/operator-manual/user-management/#oidc)
- [External DNS Documentation](https://kubernetes-sigs.github.io/external-dns/)
- [External DNS AWS Tutorial](https://kubernetes-sigs.github.io/external-dns/v0.15.0/docs/tutorials/aws/)
- [AWS Load Balancer Controller Documentation](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
- [Setting Up ArgoCD with HTTPS on Kubernetes Using AWS ALB](https://medium.com/@tanmoysantra67/setting-up-argocd-with-https-on-kubernetes-using-aws-alb-d29e58b80d72)

