# Migration Runbook: Azure DevOps → GitHub

## Overview
This runbook provides step-by-step instructions for migrating from Azure DevOps to GitHub Enterprise Cloud using the migration accelerator scripts.

---

## Pre-Flight Checklist

### Tooling
- [ ] GitHub CLI installed (`gh --version`)
- [ ] GEI extension installed (`gh ado2gh --help`)
- [ ] Actions Importer installed (`gh actions-importer --help`)
- [ ] git-sizer installed
- [ ] gitleaks installed
- [ ] git-filter-repo installed (`pip install git-filter-repo`)
- [ ] Docker Desktop running (required by Actions Importer)
- [ ] Run `01-prep/install-tools.ps1` to verify all tools

### Access
- [ ] ADO PAT created with scopes: Code(R), Build(R+E), Release(R), WorkItems(R), Project(R), Graph(R)
- [ ] GitHub PAT created with scopes: repo, admin:org, workflow, read:enterprise
- [ ] GitHub Enterprise Cloud org created
- [ ] SAML SSO configured on GitHub org (for bank SSO integration)

### Configuration
- [ ] `config/migration-config.json` populated with source/target details
- [ ] `config/user-mappings.csv` populated with ADO→GitHub identity map
- [ ] `config/team-mappings.json` populated with team structure
- [ ] `config/workitem-type-mappings.json` reviewed and customized

---

## Phase 0: Discovery (Run Once)

### Step 1 — Full Asset Inventory
```powershell
.\00-discovery\inventory-assets.ps1 `
    -OrgUrl "https://dev.azure.com/YOUR_ORG" `
    -Pat $env:ADO_PAT
```
**Output**: `output/inventory/inventory-*.json`, `output/inventory/repo-summary.csv`
**Review**: Check total counts, identify large repos, disabled repos

### Step 2 — Repo Size Audit
```powershell
.\00-discovery\audit-repo-sizes.ps1 `
    -InventoryFile "./output/inventory/inventory-LATEST.json" `
    -Pat $env:ADO_PAT
```
**Output**: `output/sizing/repo-sizing-*.csv`
**Action**: Any repo >40 GB is a GEI BLOCKER — requires cleanup before migration

### Step 3 — Secret Scan
```powershell
.\00-discovery\scan-secrets.ps1 `
    -InventoryFile "./output/inventory/inventory-LATEST.json" `
    -Pat $env:ADO_PAT
```
**Output**: `output/secrets/secret-scan-summary-*.csv` + per-repo JSON reports
**Action**: ALL repos with findings MUST be scrubbed before migration

### Step 4 — Pipeline Audit
```powershell
.\00-discovery\audit-pipelines.ps1 `
    -AdoOrg "YOUR_ORG" `
    -AdoPat $env:ADO_PAT `
    -GitHubPat $env:GH_PAT
```
**Output**: `output/pipeline-audit/audit_summary.md`
**Review**: Note unsupported tasks and manual effort estimates

### Step 5 — Usage Forecast
```powershell
.\00-discovery\forecast-usage.ps1 `
    -AdoOrg "YOUR_ORG" `
    -AdoPat $env:ADO_PAT `
    -GitHubPat $env:GH_PAT
```
**Output**: `output/forecast/forecast_report.md`
**Review**: Estimate GitHub Actions runner costs

---

## Phase 1: Preparation

### Step 6 — Scrub Secrets (dry-run first)
```powershell
# Dry run
.\01-prep\scrub-secrets.ps1 `
    -SecretScanDir "./output/secrets" `
    -Pat $env:ADO_PAT `
    -DryRun

# Live run (after reviewing dry-run output)
.\01-prep\scrub-secrets.ps1 `
    -SecretScanDir "./output/secrets" `
    -Pat $env:ADO_PAT
```
**Post-step**: Re-run `scan-secrets.ps1` on scrubbed repos to verify clean

### Step 7 — GitHub Org Setup
```powershell
.\01-prep\setup-github-org.ps1 `
    -GitHubOrg "YOUR_GH_ORG" `
    -GitHubPat $env:GH_PAT `
    -GitHubEnterprise "YOUR_ENTERPRISE"
```
**Follow the checklist** in the script output

---

## Phase 2: Migration (Per Batch)

### Step 8 — Migrate Repos (GEI)
```powershell
# Single batch
.\02-migrate\migrate-repos.ps1 `
    -ConfigFile "./config/migration-config.json" `
    -BatchName "batch-01-pilot"

# Dry run (generates scripts without executing)
.\02-migrate\migrate-repos.ps1 `
    -ConfigFile "./config/migration-config.json" `
    -BatchName "batch-01-pilot" `
    -DryRun
```

### Step 9 — Migrate Pipelines
```powershell
# Dry run first
.\02-migrate\migrate-pipelines.ps1 `
    -ConfigFile "./config/migration-config.json" `
    -AdoProject "ProjectA" `
    -Mode "dry-run"

# Migrate (creates PRs with workflow files)
.\02-migrate\migrate-pipelines.ps1 `
    -ConfigFile "./config/migration-config.json" `
    -AdoProject "ProjectA" `
    -Mode "migrate"
```

### Step 10 — Migrate Boards
```powershell
# Dry run
.\02-migrate\migrate-boards.ps1 `
    -ConfigFile "./config/migration-config.json" `
    -AdoProject "ProjectA" `
    -GitHubRepo "project-a" `
    -DryRun

# Live
.\02-migrate\migrate-boards.ps1 `
    -ConfigFile "./config/migration-config.json" `
    -AdoProject "ProjectA" `
    -GitHubRepo "project-a"
```

### Step 11 — Migrate Wiki (Optional)
```powershell
.\02-migrate\migrate-wiki.ps1 `
    -AdoOrgUrl "https://dev.azure.com/YOUR_ORG" `
    -AdoProject "ProjectA" `
    -AdoPat $env:ADO_PAT `
    -GitHubOrg "YOUR_GH_ORG" `
    -GitHubRepo "project-a" `
    -GitHubPat $env:GH_PAT
```

---

## Phase 3: Post-Migration (Per Batch)

### Step 12 — Reclaim Mannequins
```powershell
.\03-post-migrate\reclaim-mannequins.ps1 `
    -GitHubOrg "YOUR_GH_ORG" `
    -GitHubPat $env:GH_PAT
```

### Step 13 — Set Visibility & Branch Protection
```powershell
.\03-post-migrate\set-visibility.ps1 `
    -GitHubOrg "YOUR_GH_ORG" `
    -GitHubPat $env:GH_PAT
```

### Step 14 — Enable GHAS
```powershell
.\03-post-migrate\enable-ghas.ps1 `
    -GitHubOrg "YOUR_GH_ORG" `
    -GitHubPat $env:GH_PAT `
    -All
```

### Step 15 — Validate Migration
```powershell
.\03-post-migrate\validate-migration.ps1 `
    -ConfigFile "./config/migration-config.json" `
    -BatchName "batch-01-pilot"
```
**Output**: `output/validation/validation-report-*.csv`
**Gate**: All checks must PASS before proceeding to next batch

---

## Post-Migration Hardening

- [ ] Configure audit log streaming (Settings → Log streaming → your SIEM)
- [ ] Set up IP allow list (if applicable)
- [ ] Remove GEI IPs from allow list
- [ ] Revoke temporary PATs
- [ ] Set ADO repos to read-only
- [ ] Conduct developer training
- [ ] Establish incident response for GitHub
