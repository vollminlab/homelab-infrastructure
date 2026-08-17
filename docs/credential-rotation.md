# Credential Rotation Guide

Tracks all credentials with expiration dates and rotation procedures.

---

## Expiring Credentials (~April 2027)

All three were created 2026-04-10 with 365-day expiration.

| Credential | 1Password Item | Used By | Expires |
|---|---|---|---|
| GitHub Org PAT | `Github-Org-PAT` | **Not referenced by any workflow in the org** — interactive use only (`gh` CLI, GitHub MCP) | ~2027-04-10 |
| GitHub Admin token | `Github-Admin-Token` | `github-admin` CI — `GITHUB_TOKEN` in `plan.yml` / `apply.yml`, and the Terraform `github_token` variable | not tracked here |
| Renovate PAT | `Renovate-Org-PAT` | Renovate Bot PRs, via the `renovate-token` ExternalSecret | ~2027-04-10 |
| HCP Terraform token | `Terraform-Cloud-Token` | `github-admin` CI — `TF_TOKEN_app_terraform_io` | ~2027-04-10 |

**The credential that breaks Terraform CI is `Github-Admin-Token`, not `Github-Org-PAT`.** Both
`github-admin/.github/workflows/plan.yml:23` and `apply.yml:23` resolve
`op://Homelab/Github-Admin-Token/password`; a search across every workflow in the org returns no
reference to `Github-Org-PAT` at all. Rotating the Org PAT will not affect CI, and rotating only
the Org PAT will not fix a CI auth failure.

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
7. **No Kubernetes step.** Updating 1Password is the whole rotation.

   The cluster consumes this PAT through `renovate-token-externalsecret.yaml`, an ExternalSecret
   that External Secrets Operator resolves from 1Password on a `refreshInterval: 24h`. There is
   nothing to re-seal, commit, or push — the new value propagates on the next refresh.

   To take effect immediately rather than within 24h:
   ```bash
   kubectl annotate externalsecret renovate-token -n renovate \
     force-sync="$(date +%s)" --overwrite
   kubectl get externalsecret renovate-token -n renovate   # expect READY=True, SecretSynced
   ```

   > This step previously described a `kubeseal` re-seal into
   > `renovate-token-sealedsecret.yaml`. The Sealed Secrets controller was removed on 2026-05-31
   > and no such file exists; running that procedure now would produce a manifest nothing
   > reconciles.

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
