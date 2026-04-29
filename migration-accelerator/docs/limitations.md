# Migration Limitations

## GitHub Enterprise Importer (GEI) Limitations

### Repository Limits
| Limit | Value |
|-------|-------|
| Max repo size | 40 GiB |
| Max file size during migration | 400 MiB |
| Max file size post-migration | 100 MiB |
| Max single commit metadata | 100 MiB |

### What GEI Does NOT Migrate
- **Pipeline definitions** — Use GitHub Actions Importer separately
- **Pipeline run history & logs** — Stays in Azure DevOps permanently
- **Build/release artifacts** — Not migrated; rebuild from GitHub Actions
- **Work items (Boards)** — Custom script required (see migrate-boards.ps1)
- **Wiki pages** — Custom script required (see migrate-wiki.ps1)
- **Test Plans & Test Cases** — Not migrated; use Azure Test Plans integration or third-party
- **Dashboards** — Must be rebuilt in GitHub Projects/Insights
- **Queries (WIQL)** — Must be recreated as GitHub Projects filters/views
- **Service connections** — Must be recreated manually (or use OIDC)
- **Variable groups** — Must be recreated as GitHub Actions secrets/variables
- **Environments** — Must be recreated as GitHub Environments with protection rules
- **Git LFS objects** — NOT included in migration; must push LFS objects separately
- **Azure Artifacts** — NOT migrated; continue using Azure Artifacts or switch to GitHub Packages

### GEI Behavioral Limitations
- **No delta/incremental migration** — Full migration each time
- **No selective history** — Full commit history migrated (all-or-nothing)
- **Mannequin users** — Non-git activity attributed to placeholder accounts
- **Branch policies** — Only repo-scoped policies migrate; user-scoped and cross-repo policies do NOT
- **Forked repos** — Forks are migrated as standalone repos (lose fork relationship)

---

## GitHub Actions Importer Limitations

### Pipeline Logs
- **Historical pipeline run logs DO NOT migrate**
- Only pipeline *definitions* are converted to GitHub Actions YAML
- You get an `audit_summary.md` showing conversion report
- New GitHub Actions runs will generate their own logs going forward
- **Recommendation**: Keep Azure DevOps read-only for historical log access

### Classic Release Pipelines
- Deployment gates → **NOT auto-converted** (manual rework required)
- Pre/post-deployment approvals → GitHub Environment required reviewers (manual setup)
- Variable scoping per stage → GitHub Environment secrets (manual)
- Artifact triggers → `workflow_run` triggers (manual)
- Task groups → Composite actions or reusable workflows (manual)

### Common Unsupported ADO Tasks
| ADO Task | GitHub Actions Equivalent | Auto-Converted? |
|----------|--------------------------|-----------------|
| AzureRmWebAppDeployment | azure/webapps-deploy | Partial |
| AzureKeyVault | azure/login + az commands | No |
| SonarQubePrepare/Analyze | SonarSource/sonarqube-scan-action | No |
| VSBuild | microsoft/setup-msbuild | Partial |
| NuGetCommand | nuget commands | Partial |
| AzureCLI | azure/login + az commands | Yes |
| Docker tasks | docker/ built-in | Yes |
| PublishTestResults | dorny/test-reporter | No |
| DeploymentGroup jobs | self-hosted runners | No |

### What Must Be Manually Recreated
1. **Secrets** — ADO variable groups/key vault refs → GitHub Actions secrets
2. **Service connections** — Recreate as OIDC or GitHub secrets
3. **Self-hosted agents** — Replace with GitHub self-hosted runners
4. **Agent pools** — Replace with runner groups
5. **Deployment groups** — Replace with labeled self-hosted runners
6. **Scheduled triggers** — Cron syntax differs; review and adjust
7. **Resource triggers** — Limited support; may need `workflow_run` or `repository_dispatch`

---

## Boards/Work Items Limitations

### What Is Lost
- **State transition history** — Only current state is migrated
- **Discussion/comment history** — NOT migrated (only visible via ADO URL link)
- **Attachments** — NOT migrated (referenced by ADO URL in issue body)
- **Board column positions** — GitHub Projects use their own layout
- **Sprint capacity** — Not a GitHub concept
- **Custom process templates** — Must be approximated with Projects custom fields
- **Queries** — WIQL does not translate; rebuild as Projects views

### Mapping Gaps
- **ADO Area Paths** → GitHub labels (flat; no hierarchy)
- **ADO Iteration Paths** → GitHub Projects iterations (manual setup)
- **Nested work items (Epic > Feature > Story > Task)** → Sub-issues or task lists
- **Related links between work items** → Cross-reference in issue body

---

## Wiki Limitations
- Page hierarchy may differ (GitHub wiki is essentially flat with sidebar TOC)
- ADO-specific macros (`[[_TOC_]]`, query result widgets) will NOT render
- Mermaid diagram syntax may need adjustment
- Page revision history in Git but not surfaced nicely in GitHub wiki UI

---

## Security & Compliance Considerations (Bank)
- **Secrets in Git history** — MUST be scrubbed BEFORE migration
- **Mannequin reclaim** — Users must accept org invitation; SSO may complicate
- **Audit trail gap** — ADO audit logs don't transfer; new audit trail starts in GitHub
- **IP allow lists** — GEI IPs must be temporarily allowed; remove post-migration
- **SOC 2 continuity** — Ensure audit log streaming configured before migration window

---

## API Rate Limits
- github.com REST API: 5,000 requests/hour per PAT
- Work item migration with 10K+ items may hit limits → script uses rate limiting
- GEI has its own internal throttling; do not run multiple batches simultaneously
