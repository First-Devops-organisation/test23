# SOC 2 Compliance Mapping: Azure DevOps → GitHub

## Overview
This document maps SOC 2 Trust Service Criteria controls from Azure DevOps to their GitHub equivalents, ensuring compliance continuity during and after migration.

---

## CC6: Logical and Physical Access Controls

| Control | Azure DevOps | GitHub Enterprise Cloud |
|---------|-------------|----------------------|
| SSO/Identity | Azure AD + Conditional Access | SAML SSO (enforced) + SCIM |
| MFA | Azure AD MFA | Required via SSO provider or org setting |
| PAT Management | Organization policies | Fine-grained PATs + PAT policies |
| IP Restrictions | Conditional Access | IP allow lists (org level) |
| RBAC | Project-level permissions | Org roles + Team permissions + CODEOWNERS |

### Actions Required
- [ ] Enforce SAML SSO on GitHub org
- [ ] Configure SCIM provisioning for auto user lifecycle
- [ ] Enable 2FA requirement on org
- [ ] Set IP allow list (if using conditional access today)
- [ ] Map ADO project roles to GitHub team permissions

---

## CC7: System Operations — Change Management

| Control | Azure DevOps | GitHub Enterprise Cloud |
|---------|-------------|----------------------|
| Branch Policies | Branch policies (min reviewers, build validation) | Branch protection rules / Rulesets |
| Code Reviews | Required reviewers | Required pull request reviews |
| Build Validation | Build policy on PR | Required status checks |
| Approval Gates | Release pipeline gates | Environment protection rules |
| Audit Trail | Activity log | Audit log (API + streaming) |

### Actions Required
- [ ] Configure branch protection rules on all repos (run `set-visibility.ps1`)
- [ ] Set up CODEOWNERS files for mandatory team reviews
- [ ] Create GitHub Environments with required reviewers for production
- [ ] Configure required status checks (CI must pass)

---

## CC8: Change Management — Code Security

| Control | Azure DevOps | GitHub Enterprise Cloud |
|---------|-------------|----------------------|
| Dependency Scanning | Azure Artifacts advisories / third-party | Dependabot alerts + security updates |
| Static Analysis | SonarQube / third-party | CodeQL code scanning |
| Secret Detection | Third-party / manual | Secret scanning + push protection |
| Container Scanning | Azure Container Registry | Dependabot container scanning |
| License Compliance | Third-party | Dependency graph + SBOM export |

### Actions Required
- [ ] Enable GHAS on all repos (run `enable-ghas.ps1 -All`)
- [ ] Enable Dependabot alerts and security updates
- [ ] Configure CodeQL default setup or custom workflow
- [ ] Enable secret scanning with push protection
- [ ] Set up Dependabot auto-merge for patch updates

---

## CC9: Processing Integrity — Build & Deploy

| Control | Azure DevOps | GitHub Enterprise Cloud |
|---------|-------------|----------------------|
| Build Integrity | Pipeline definitions in YAML | GitHub Actions workflows (YAML) |
| Artifact Signing | Pipeline tasks | GitHub Actions + Sigstore |
| Deployment Approval | Release gates + approvals | Environment protection rules |
| Immutable Artifacts | Azure Artifacts | GitHub Packages + immutable tags |
| Deployment Audit | Release history | Actions workflow run logs |

### Actions Required
- [ ] Ensure all pipelines are converted to GitHub Actions
- [ ] Set up GitHub Environments for staging/production
- [ ] Configure deployment branch policies
- [ ] Enable deployment logs retention (90 days default)

---

## Audit Log & Monitoring

### Azure DevOps Audit
- Organization audit log (90 days retention in ADO)
- Activity logs per project

### GitHub Enterprise Cloud Audit
- Organization audit log (indefinite for GHEC)
- **Audit log streaming** to external SIEM (Splunk, Datadog, S3, Azure EventHub)
- API access to audit events
- Git events audit (push, clone)

### Actions Required
- [ ] Configure audit log streaming BEFORE migration: Org Settings → Audit log → Log streaming
- [ ] Verify SIEM integration receives events
- [ ] Document audit log gap period (ADO stop → GitHub start)
- [ ] Retain ADO access read-only for historical audit evidence

---

## Evidence Collection Checklist

| Evidence Type | Source | Retention |
|---------------|--------|-----------|
| Access reviews | GitHub org member list + team membership | Quarterly review |
| Change approvals | PR approval history | Indefinite in Git |
| Security scan results | Dependabot + CodeQL alerts | API accessible |
| Build/deploy logs | GitHub Actions workflow runs | 90 days default (configurable) |
| Audit events | Audit log stream to SIEM | Per SIEM retention policy |
| Secret rotation | Secret scanning alerts + rotation dates | GitHub alert history |
| Incident response | GitHub Security advisories | Indefinite |

---

## Migration Period Controls

During the migration window (when both ADO and GitHub are active):

1. **Dual audit logging** — Both ADO and GitHub audit logs are active
2. **Access synchronization** — Same users in both systems; permissions may differ
3. **Change freeze coordination** — Batch-level freezes documented per runbook
4. **Rollback capability** — ADO repos remain read-only (not deleted)
5. **Incident handling** — Defined escalation path for both systems
