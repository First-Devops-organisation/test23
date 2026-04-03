# Azure DevOps → GitHub Repository Migration Plan

> **Scope**: Git repositories only (no Boards, Pipelines, Wiki)
> **Tool**: GitHub Enterprise Importer (GEI) via `gh ado2gh` CLI extension
> **Target**: GitHub Enterprise Cloud
> **Environment**: Bank / Regulated (SOC 2)

---

## Table of Contents

1. [What Gets Migrated](#1-what-gets-migrated)
2. [What Does NOT Get Migrated](#2-what-does-not-get-migrated)
3. [GEI Limits & Constraints](#3-gei-limits--constraints)
4. [Pre-Requisites](#4-pre-requisites)
5. [Step-by-Step Execution Plan](#5-step-by-step-execution-plan)
6. [Validation Checklist](#6-validation-checklist)
7. [Rollback Plan](#7-rollback-plan)
8. [Known Limitations & Risks](#8-known-limitations--risks)
9. [Timeline](#9-timeline)
10. [RACI Matrix](#10-raci-matrix)

---

## 1. What Gets Migrated

| Asset | Migrated by GEI | Notes |
|-------|:---:|-------|
| Git source code (all branches) | ✅ | Full commit history preserved |
| Tags | ✅ | All tags included |
| Pull requests | ✅ | Includes comments, reviews, statuses |
| PR attachments | ✅ | Files attached to PR conversations |
| Work item links on PRs | ✅ | Links preserved as references |
| Branch policies (repo-scoped) | ✅ | Only repo-level policies |
| Teams (with `--all` flag) | ✅ | Team structure migrated |

## 2. What Does NOT Get Migrated

| Asset | Reason | Workaround |
|-------|--------|------------|
| Git LFS objects | GEI limitation | Push LFS objects separately post-migration |
| Branch policies (user-scoped/cross-repo) | GEI limitation | Recreate manually via branch protection rules |
| Commit-linked work items | Only PR-linked items migrate | Reference only; Boards migration is separate |
| Repository permissions (granular) | Different permission model | Configure GitHub team permissions post-migration |
| Service hooks / webhooks | Not in scope | Recreate as GitHub webhooks |
| Build status checks on commits | Not migrated | New checks from GitHub Actions going forward |
| Forked repo relationships | GEI limitation | Fork manually post-migration if needed |

## 3. GEI Limits & Constraints

| Constraint | Limit | Impact |
|------------|-------|--------|
| Maximum repository size | **40 GiB** | Repos exceeding this will fail; must trim history first |
| Maximum single file during migration | **400 MiB** | Large binaries in history can block migration |
| Maximum file size post-migration | **100 MiB** | GitHub hard limit; use LFS for large files |
| Delta/incremental migration | **Not supported** | Must freeze source repo during migration window |
| Concurrent migrations per org | **Varies** | GitHub may throttle; batch accordingly |
| Mannequin users | All non-Git authors become placeholders | Must reclaim post-migration; users need to accept invite |
| API rate limits | 5,000 requests/hour (PAT) | Impacts validation scripts; use retry with backoff |

---

## 4. Pre-Requisites

### 4.1 Access & Permissions

| Requirement | Detail |
|-------------|--------|
| **ADO PAT** | Scopes: `Code (Read)`, `Identity (Read)`, `Project & Team (Read)`, `Member Entitlement Management (Read)` |
| **GitHub PAT (classic)** | Scopes: `repo`, `admin:org`, `workflow`, `read:packages` |
| **GitHub Org Role** | Organization Owner (required for GEI) |
| **ADO Project Role** | Project Administrator or Collection Administrator |
| **Network** | GitHub GEI IP ranges whitelisted if IP allow-list is enabled |

### 4.2 Tools Required

| Tool | Version | Purpose |
|------|---------|---------|
| `git` | ≥ 2.40 | Git operations |
| `gh` (GitHub CLI) | ≥ 2.50 | GitHub API interactions |
| `gh ado2gh` | Latest | GEI CLI extension for migration |
| `git-sizer` | Latest | Repository size analysis |
| `gitleaks` | ≥ 8.0 | Secret detection in git history |
| `git-filter-repo` | Latest | Secret scrubbing from history |
| PowerShell | ≥ 7.0 | Script execution |

### 4.3 Environment Setup

```powershell
# Install tools
.\repo-migration\02-prep\install-tools.ps1

# Set credentials (never hardcode)
$env:ADO_PAT = Read-Host -AsSecureString "ADO PAT" | ConvertFrom-SecureString
$env:GH_PAT  = Read-Host -AsSecureString "GitHub PAT" | ConvertFrom-SecureString
```

---

## 5. Step-by-Step Execution Plan

### Step 1: Discovery — Inventory All Repositories
**Script**: `01-discover/discover-repos.ps1`
**Duration**: ~15 minutes
**Prerequisite**: ADO PAT configured

```powershell
.\repo-migration\01-discover\discover-repos.ps1
```

**What it does**:
- Calls ADO REST API to list all repos in the configured project
- Captures: repo name, default branch, size (bytes), branch count, PR count, last commit date
- Identifies disabled/archived repos
- Outputs: `reports/repo-inventory.json` and `reports/repo-inventory.csv`

**Decision gate**: Review inventory. Confirm which repos to include/exclude. Update `config/repo-migration-config.json` batches and exclusions.

---

### Step 2: Discovery — Audit Repository Sizes
**Script**: `01-discover/audit-repo-sizes.ps1`
**Duration**: ~5-30 minutes depending on repo count
**Prerequisite**: Step 1 completed

```powershell
.\repo-migration\01-discover\audit-repo-sizes.ps1
```

**What it does**:
- Clones each repo to temp directory
- Runs `git-sizer` to analyze: total size, largest blob, largest file path, LFS usage
- Flags repos exceeding GEI limits (40 GiB repo, 400 MiB file)
- Flags repos with LFS objects (require separate handling)
- Outputs: `reports/repo-sizes.json` with per-repo analysis

**Decision gate**: Any repos flagged as OVER_LIMIT must be remediated (trim history, remove large files, or split repo) before proceeding.

---

### Step 3: Discovery — Scan for Secrets
**Script**: `01-discover/scan-secrets.ps1`
**Duration**: ~10-60 minutes depending on repo sizes
**Prerequisite**: Step 1 completed (can run parallel with Step 2)

```powershell
.\repo-migration\01-discover\scan-secrets.ps1
```

**What it does**:
- Runs `gitleaks detect --no-git` on each cloned repo
- Scans full git history for: API keys, connection strings, passwords, tokens, certificates
- Categorizes findings by severity (Critical, High, Medium, Low)
- Outputs: `reports/secret-scan-results.json` with per-repo findings

**Decision gate**: **MANDATORY for bank environment**. Any repo with Critical/High findings MUST have secrets scrubbed before migration. No exceptions.

---

### Step 4: Preparation — Scrub Secrets from Git History
**Script**: `02-prep/scrub-secrets.ps1`
**Duration**: ~15-60 minutes per repo with findings
**Prerequisite**: Step 3 completed with findings

```powershell
.\repo-migration\02-prep\scrub-secrets.ps1
```

**What it does**:
- For each repo with detected secrets:
  - Creates backup of current state
  - Runs `git-filter-repo` to remove/replace secret values across all history
  - Force-pushes cleaned history back to ADO
- Generates credential rotation checklist
- Outputs: `reports/scrub-results.json`

**Decision gate**: 
1. Verify scrubbed repos pass a re-scan (`scan-secrets.ps1` re-run)
2. Credential rotation completed and verified by security team
3. Sign-off from InfoSec before proceeding

**⚠️ WARNING**: This rewrites git history. All developers must re-clone after scrubbing. Coordinate timing with teams.

---

### Step 5: Preparation — Validate GitHub Org Readiness
**Script**: `02-prep/install-tools.ps1` (tool check portion)
**Duration**: ~5 minutes
**Prerequisite**: GitHub org created, SSO configured

**Manual checklist**:
- [ ] GitHub Enterprise Cloud org created
- [ ] SAML SSO configured and tested (if applicable)
- [ ] SCIM provisioning enabled (if applicable)
- [ ] GEI IP ranges added to IP allow-list (if enabled)
- [ ] Organization owner PAT created with required scopes
- [ ] Teams created or ready for auto-creation via GEI `--all`

---

### Step 6: Preparation — Configure Migration Settings
**Duration**: ~30 minutes
**Prerequisite**: Steps 1-5 completed

**Actions**:
1. Edit `config/repo-migration-config.json`:
   - Set `source.organization` to your ADO org URL
   - Set `source.project` to your ADO project name
   - Set `target.organization` to your GitHub org name
   - Define batches with actual repo names and scheduled dates
   - Set exclusions for repos not migrating
2. Populate `config/user-mappings.csv`:
   - Map each ADO user to their GitHub username
   - This is used for mannequin reclamation post-migration

---

### Step 7: Pilot Migration — Batch 1 (3-5 repos)
**Script**: `03-migrate/migrate-repos.ps1`
**Duration**: ~30-120 minutes depending on repo sizes
**Prerequisite**: Steps 1-6 completed, pilot batch defined

```powershell
# Dry run first (generates script without executing)
.\repo-migration\03-migrate\migrate-repos.ps1 -BatchName "batch-1-pilot" -DryRun

# Review the generated migration script, then execute
.\repo-migration\03-migrate\migrate-repos.ps1 -BatchName "batch-1-pilot"
```

**What it does**:
1. Reads batch config from `repo-migration-config.json`
2. For each repo in the batch:
   - Calls `gh ado2gh migrate-repo` with configured options
   - Monitors migration status via `gh ado2gh wait-for-migration`
   - Logs migration ID, status, duration
   - Retries on failure (up to configured `retryCount`)
3. Locks source repo in ADO (sets to read-only) if `lockSourceRepo: true`
4. Outputs: `logs/migration-batch-1-pilot.json` with per-repo results

**GEI command executed per repo**:
```
gh ado2gh migrate-repo \
  --ado-org "YOUR_ADO_ORG" \
  --ado-team-project "YOUR_ADO_PROJECT" \
  --ado-repo "repo-name" \
  --github-org "YOUR_GITHUB_ORG" \
  --github-repo "repo-name" \
  --target-repo-visibility internal \
  --queue-only
```

**Decision gate**: Validate pilot repos before proceeding to remaining batches (Step 8).

---

### Step 8: Validate Pilot Migration
**Script**: `04-validate/validate-repos.ps1`
**Duration**: ~15 minutes
**Prerequisite**: Step 7 completed

```powershell
.\repo-migration\04-validate\validate-repos.ps1 -BatchName "batch-1-pilot"
```

**What it does**:
- For each migrated repo, compares source (ADO) vs target (GitHub):

| Check | Method |
|-------|--------|
| Branch count match | ADO API vs GitHub API |
| Default branch correct | Compare default branch names |
| Tag count match | `git tag -l` on both |
| PR count match | ADO API vs GitHub API |
| Commit count on default branch | `git rev-list --count` |
| Repo visibility | GitHub API check (should be `internal`) |
| Teams assigned | GitHub API check |
| Last commit SHA | Compare HEAD on default branch |

- Outputs: `reports/validation-batch-1-pilot.json` with PASS/FAIL per check

**Decision gate**: 
- All checks PASS → proceed to remaining batches
- Any FAIL → investigate, remediate, re-migrate if needed
- Dev team sign-off on pilot repos

---

### Step 9: Production Migration — Remaining Batches
**Script**: `03-migrate/migrate-repos.ps1`
**Duration**: ~2-4 hours per batch (weekend windows recommended)
**Prerequisite**: Step 8 pilot validation passed

```powershell
# Each batch on its scheduled date
.\repo-migration\03-migrate\migrate-repos.ps1 -BatchName "batch-2"
.\repo-migration\04-validate\validate-repos.ps1 -BatchName "batch-2"

# Repeat for all batches...
```

**Per-batch procedure**:
1. **T-24h**: Notify team. Confirm no in-flight PRs
2. **T-0**: Start migration script
3. **T+1h**: Run validation
4. **T+2h**: Reclaim mannequins
5. **T+4h**: Dev team verifies clone/push/PR workflow
6. **T+24h**: Lock ADO repo to read-only (if not auto-locked)

---

### Step 10: Post-Migration — Reclaim Mannequins
**Script**: `04-validate/reclaim-mannequins.ps1`
**Duration**: ~15 minutes (execution) + days (user acceptance)
**Prerequisite**: Repos migrated, `user-mappings.csv` populated

```powershell
.\repo-migration\04-validate\reclaim-mannequins.ps1
```

**What it does**:
- Lists all mannequin (placeholder) users in the GitHub org
- Matches against `config/user-mappings.csv`
- Sends reclamation invitations via GitHub API
- Users must accept the invitation to claim their history
- Outputs: `reports/mannequin-status.json`

**⚠️ Limitation**: Users who don't accept invitations will retain mannequin attribution. Follow up individually.

---

### Step 11: Post-Migration — Configure Branch Protection
**Duration**: ~30 minutes per batch
**Prerequisite**: Repos migrated and validated

**Manual or scripted** — configure for each repo:
- Required PR reviews (approve count)
- Required status checks
- Restrict who can push to protected branches
- Require signed commits (if applicable)
- Dismiss stale reviews on new pushes

---

### Step 12: Post-Migration — Lock ADO & Notify
**Duration**: ~15 minutes
**Prerequisite**: All batches migrated and validated

**Actions**:
1. Set all migrated ADO repos to **read-only** (disabled)
2. Update ADO repo descriptions: `"MIGRATED → github.com/YOUR_GITHUB_ORG/repo-name"`
3. Send migration completion email to all developers
4. Archive migration logs and reports

---

## 6. Validation Checklist

Run after **every batch**:

| # | Check | Method | Pass Criteria |
|---|-------|--------|---------------|
| 1 | Branch count | API comparison | Counts match |
| 2 | Tag count | API comparison | Counts match |
| 3 | Default branch | API comparison | Names match |
| 4 | HEAD commit SHA | git comparison | SHAs match |
| 5 | PR count | API comparison | Counts match |
| 6 | Repo visibility | GitHub API | `internal` |
| 7 | Clone test | `git clone` from GitHub | Succeeds |
| 8 | Push test | Create test branch, push | Succeeds |
| 9 | Secret re-scan | `gitleaks` on GitHub repo | Zero findings |
| 10 | Teams assigned | GitHub API | Teams present |

---

## 7. Rollback Plan

Since GEI does **not** modify the source, rollback is straightforward:

| Scenario | Action |
|----------|--------|
| Migration failed mid-batch | Delete partially created GitHub repos. Retry migration |
| Data mismatch found | Delete GitHub repo. Fix source. Re-migrate |
| Full rollback needed | Delete all GitHub repos from batch. Unlock ADO repos. Resume using ADO |
| Post-validation failure | Keep ADO as primary. Delete GitHub copy. Investigate root cause |

**ADO repos are NEVER deleted** — kept read-only for:
- Historical reference
- Audit trail (SOC 2)
- Pipeline log retention
- Rollback safety net

**Retention period**: Minimum 12 months read-only before any ADO decommission discussion.

---

## 8. Known Limitations & Risks

### GEI Limitations

| # | Limitation | Impact | Mitigation |
|---|-----------|--------|------------|
| 1 | No delta/incremental migration | Must freeze repo during migration window | Schedule weekend windows; lock repos |
| 2 | No Git LFS object migration | LFS files will be pointers only | Push LFS objects separately post-migration |
| 3 | Mannequin attribution | Non-git activity shows placeholder users | Reclaim mannequins; users must accept invite |
| 4 | 40 GiB repo limit | Large repos will fail | Trim history or split repos pre-migration |
| 5 | 400 MiB file limit during migration | Large binary files block migration | Remove from history with git-filter-repo |
| 6 | User-scoped branch policies lost | Per-user policies not migrated | Recreate manually via branch protection |
| 7 | Cross-repo branch policies lost | Policies spanning repos not migrated | Recreate manually |
| 8 | No fork relationship migration | Forks not re-linked | Fork manually post-migration |
| 9 | Disabled repos skip silently | GEI skips disabled repos | Enable before migration or exclude explicitly |

### Bank-Specific Risks

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|-----------|--------|------------|
| 1 | Secret exposure during migration | Medium | Critical | Mandatory scrubbing + rotation pre-migration |
| 2 | Regulatory audit during transition | Low | High | Both systems operational; document dual-state |
| 3 | Developer disruption | High | Medium | Weekend windows; clear communication; training |
| 4 | Network/firewall blocking GEI | Medium | High | Pre-validate GEI IP ranges in allow-list |
| 5 | SSO/SCIM mapping failures | Medium | Medium | Pre-validate user mapping; test with pilot |
| 6 | Mannequin reclaim delays | High | Low | Follow up individually; set 2-week deadline |

---

## 9. Timeline

```
Week 1-2: Discovery & Assessment
├── Day 1-2:   Inventory repos (Step 1)
├── Day 3-4:   Size audit + secret scan (Steps 2-3)
└── Day 5-10:  Secret scrubbing + credential rotation (Step 4)

Week 3: Preparation
├── Day 1-2:   GitHub org setup + tool validation (Step 5)
├── Day 3:     Configure migration settings (Step 6)
└── Day 4-5:   Pilot dry run + review

Week 4: Pilot Migration
├── Weekend:   Execute pilot batch (Step 7)
├── Mon:       Validate pilot (Step 8)
├── Tue-Fri:   Dev team verification + sign-off
└── Fri:       Go/No-Go for production batches

Week 5-8: Production Batches (one batch per weekend)
├── Each Sat:  Execute batch (Step 9)
├── Each Sun:  Validate + reclaim mannequins (Steps 8, 10)
├── Each Mon:  Dev team verification
└── Each Fri:  Next batch Go/No-Go

Week 9: Hardening
├── Day 1-2:   Branch protection configuration (Step 11)
├── Day 3:     Lock ADO repos (Step 12)
├── Day 4-5:   Final validation + documentation
```

**Total duration**: ~9 weeks (conservative, for bank environment)

---

## 10. RACI Matrix

| Activity | Migration Lead | Dev Team Lead | InfoSec | Platform Admin |
|----------|:---:|:---:|:---:|:---:|
| Discovery & inventory | R | C | I | I |
| Secret scanning | R | I | A | I |
| Secret scrubbing | R | C | A | I |
| Credential rotation | I | R | A | C |
| GitHub org setup | C | I | C | R |
| Pilot migration | R | C | I | C |
| Pilot validation | R | A | I | C |
| Production batches | R | C | I | C |
| Mannequin reclaim | R | A | I | I |
| Branch protection | R | A | I | C |
| Developer training | C | R | I | I |
| ADO lockdown | R | I | A | C |

**R** = Responsible, **A** = Accountable, **C** = Consulted, **I** = Informed

---

## Appendix: Script Reference

| Script | Phase | Purpose |
|--------|-------|---------|
| `01-discover/discover-repos.ps1` | Discovery | ADO API repo inventory |
| `01-discover/audit-repo-sizes.ps1` | Discovery | git-sizer analysis + GEI limit check |
| `01-discover/scan-secrets.ps1` | Discovery | gitleaks secret detection |
| `02-prep/install-tools.ps1` | Preparation | Tool installation & validation |
| `02-prep/scrub-secrets.ps1` | Preparation | git-filter-repo secret removal |
| `03-migrate/migrate-repos.ps1` | Migration | GEI batch execution + monitoring |
| `04-validate/validate-repos.ps1` | Validation | Source vs target comparison |
| `04-validate/reclaim-mannequins.ps1` | Validation | Mannequin user reclamation |
| `run-migration.ps1` | Orchestrator | End-to-end flow coordinator |

---

## Appendix: Config Files

| File | Purpose |
|------|---------|
| `config/repo-migration-config.json` | Source/target orgs, batches, migration options |
| `config/user-mappings.csv` | ADO email → GitHub username mapping for mannequin reclaim |
