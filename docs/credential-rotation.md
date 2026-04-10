# Credential Rotation Guide

Tracks all credentials with expiration dates and rotation procedures.

---

## Expiring Credentials (~April 2027)

All three were created 2026-04-10 with 365-day expiration.

| Credential | 1Password Item | Used By | Expires |
|---|---|---|---|
| GitHub Org PAT | `Github-Org-PAT` | Terraform CI, git push in workflows | ~2027-04-10 |
| Renovate PAT | `Renovate-Org-PAT` | Renovate Bot PRs | ~2027-04-10 |
| HCP Terraform token | `Terraform-Cloud-Token` | `github-admin` CI — `TF_TOKEN_app_terraform_io` | ~2027-04-10 |

---

## Rotation Procedures

### Github-Org-PAT

1. Go to github.com/settings/personal-access-tokens → find `Github-Org-PAT`
2. Click **Regenerate** (or create new with same permissions)
3. **Resource owner:** `vollminlab`
4. **Permissions:** Actions, Administration, Contents, Deployments, Environments, Pull requests, Workflows — all Read/Write
5. **Expiration:** 365 days (org-owned fine-grained PATs cannot be set to no expiration)
6. Update value in 1Password: `Homelab` vault → `Github-Org-PAT` → `password` field
7. CI picks it up automatically via 1Password — no other changes needed

### Renovate-Org-PAT

1. Go to github.com/settings/personal-access-tokens → find `Renovate-Org-PAT`
2. Click **Regenerate**
3. **Resource owner:** `vollminlab`
4. **Permissions:** Actions, Contents, Issues, Pull requests, Workflows — all Read/Write
5. **Expiration:** 365 days
6. Update value in 1Password: `Homelab` vault → `Renovate-Org-PAT` → `password` field
7. Re-seal the Renovate k8s secret:
   ```bash
   # Get new token value
   NEW_TOKEN=$(op read "op://Homelab/Renovate-Org-PAT/password")
   
   # Create new sealed secret
   kubectl create secret generic renovate-token \
     --from-literal=RENOVATE_TOKEN=$NEW_TOKEN \
     --namespace renovate \
     --dry-run=client -o yaml | \
   kubeseal --controller-namespace sealed-secrets \
     --controller-name sealed-secrets \
     --format yaml > \
   /c/git/k8s-vollminlab-cluster/clusters/vollminlab-cluster/renovate/renovate/app/renovate-token-sealedsecret.yaml
   
   # Commit and push
   cd /c/git/k8s-vollminlab-cluster
   git add clusters/vollminlab-cluster/renovate/renovate/app/renovate-token-sealedsecret.yaml
   git commit -m "chore: rotate Renovate PAT"
   git push
   ```

### Terraform-Cloud-Token (HCP Terraform)

1. Go to app.terraform.io → User Settings → Tokens → find `github-admin CI`
2. Delete old token, create new one named `github-admin CI`
3. Update value in 1Password: `Homelab` vault → `Terraform-Cloud-Token` → `credential` field
4. Update local `~/.terraformrc` (or `%APPDATA%\terraform.rc` on Windows) with new token value:
   ```powershell
   $TOKEN = op read "op://Homelab/Terraform-Cloud-Token/credential"
   @"
   credentials "app.terraform.io" {
     token = "$TOKEN"
   }
   "@ | Out-File -FilePath "$env:APPDATA\terraform.rc" -Encoding utf8
   ```
5. CI picks it up automatically via 1Password — no other changes needed

---

## GitHub Apps (no expiration, but track installation)

| App | Owner | Installed On | Purpose |
|---|---|---|---|
| `gha-arc-vollminlab-app` | vollminlab org | All repositories | ARC self-hosted runners |
| `flux-sync-app` | vollminlab org | k8s-vollminlab-cluster only | Flux GitOps sync |

If either app loses access or needs reinstallation:
- Go to `github.com/organizations/vollminlab/settings/installations`
- Click **Configure** on the relevant app

---

## Notes

- Fine-grained PATs owned by an org cannot be set to no expiration — 365 days is the maximum
- GitHub will send email warnings before PAT expiration
- Set a calendar reminder for ~2027-03-10 (1 month before expiry) to rotate all three
