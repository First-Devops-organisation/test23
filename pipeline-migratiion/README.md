# Azure DevOps → GitHub Migration Accelerator

End-to-end accelerator for migrating Azure DevOps (Cloud) to GitHub Enterprise Cloud, designed for enterprise/bank environments with SOC 2 compliance requirements.

## What Gets Migrated

| Component | Tool | Automated? |
|-----------|------|-----------|
| **Git Repos** (history, branches, PRs) | GitHub Enterprise Importer (GEI) | Yes |
| **Teams** | GEI `--all` flag | Yes |
| **Pipelines** (YAML & Classic → GitHub Actions) | GitHub Actions Importer | Semi-auto |
| **Work Items** (Boards → GitHub Issues/Projects) | Custom script | Yes |
| **Wiki** | Custom script | Yes |

## What Does NOT Migrate

- Pipeline run history & logs (stays in ADO)
- Build/release artifacts
- Test Plans
- Dashboards & Queries
- Service connections, variable groups
- Azure Artifacts
- Git LFS objects (separate push)

See [docs/limitations.md](docs/limitations.md) for the full list.

## Quick Start

### 1. Install tools
```powershell
.\01-prep\install-tools.ps1
```

### 2. Configure
Edit these files before running any migration:
- `config/migration-config.json` — Source/target orgs, batches, options
- `config/user-mappings.csv` — ADO-to-GitHub user identity map
- `config/team-mappings.json` — Team structure mapping
- `config/workitem-type-mappings.json` — Work item type/state/field mappings

### 3. Discover
```powershell
# Full inventory
.\00-discovery\inventory-assets.ps1 -OrgUrl "https://dev.azure.com/YOUR_ORG" -Pat $env:ADO_PAT

# Repo sizing (GEI compatibility check)
.\00-discovery\audit-repo-sizes.ps1 -InventoryFile ./output/inventory/inventory-LATEST.json -Pat $env:ADO_PAT

# Secret scan (MANDATORY for bank migration)
.\00-discovery\scan-secrets.ps1 -InventoryFile ./output/inventory/inventory-LATEST.json -Pat $env:ADO_PAT

# Pipeline conversion readiness
.\00-discovery\audit-pipelines.ps1 -AdoOrg "YOUR_ORG" -AdoPat $env:ADO_PAT -GitHubPat $env:GH_PAT
```

### 4. Prepare
```powershell
# Scrub secrets (dry-run first, then live)
.\01-prep\scrub-secrets.ps1 -SecretScanDir ./output/secrets -Pat $env:ADO_PAT -DryRun

# Validate GitHub org readiness
.\01-prep\setup-github-org.ps1 -GitHubOrg "YOUR_GH_ORG" -GitHubPat $env:GH_PAT
```

### 5. Migrate (per batch)
```powershell
# Repos (GEI)
.\02-migrate\migrate-repos.ps1 -ConfigFile ./config/migration-config.json -BatchName "batch-01-pilot"

# Pipelines
.\02-migrate\migrate-pipelines.ps1 -ConfigFile ./config/migration-config.json -AdoProject "ProjectA" -Mode "migrate"

# Boards → Issues
.\02-migrate\migrate-boards.ps1 -ConfigFile ./config/migration-config.json -AdoProject "ProjectA" -GitHubRepo "project-a"

# Wiki
.\02-migrate\migrate-wiki.ps1 -AdoOrgUrl "https://dev.azure.com/YOUR_ORG" -AdoProject "ProjectA" -AdoPat $env:ADO_PAT -GitHubOrg "YOUR_GH_ORG" -GitHubRepo "project-a" -GitHubPat $env:GH_PAT
```

### 6. Post-Migration
```powershell
# Reclaim mannequin users
.\03-post-migrate\reclaim-mannequins.ps1 -GitHubOrg "YOUR_GH_ORG" -GitHubPat $env:GH_PAT

# Set visibility & branch protection
.\03-post-migrate\set-visibility.ps1 -GitHubOrg "YOUR_GH_ORG" -GitHubPat $env:GH_PAT

# Enable GHAS (Dependabot, CodeQL, Secret Scanning, Push Protection)
.\03-post-migrate\enable-ghas.ps1 -GitHubOrg "YOUR_GH_ORG" -GitHubPat $env:GH_PAT -All

# Validate everything
.\03-post-migrate\validate-migration.ps1 -ConfigFile ./config/migration-config.json
```

## Folder Structure

```
migration-accelerator/
├── 00-discovery/          # Asset inventory, sizing, secret scanning, pipeline audit
├── 01-prep/               # Secret scrubbing, org setup, tool installation
├── 02-migrate/            # GEI repos, Actions Importer pipelines, Boards, Wiki
├── 03-post-migrate/       # Mannequins, visibility, GHAS, validation
├── config/                # Migration config, user/team mappings, type mappings
├── docs/                  # Runbook, limitations, compliance mapping, rollback plan
├── output/                # Generated reports (gitignored)
├── logs/                  # Migration logs (gitignored)
└── tmp/                   # Temporary working directory (gitignored)
```

## Documentation

- [Migration Runbook](docs/migration-runbook.md) — Step-by-step execution guide
- [Limitations](docs/limitations.md) — Full list of what doesn't migrate and workarounds
- [Compliance Mapping](docs/compliance-mapping.md) — SOC 2 ADO→GitHub control mapping
- [Rollback Plan](docs/rollback-plan.md) — How to revert if issues arise

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| GitHub CLI | GEI + Actions Importer host | `winget install GitHub.cli` |
| gh-ado2gh | GEI extension | `gh extension install github/gh-ado2gh` |
| gh-actions-importer | Pipeline converter | `gh extension install github/gh-actions-importer` |
| Docker Desktop | Required by Actions Importer | `winget install Docker.DockerDesktop` |
| git-sizer | Repo size analysis | [github.com/github/git-sizer](https://github.com/github/git-sizer/releases) |
| gitleaks | Secret detection | `winget install Gitleaks.Gitleaks` |
| git-filter-repo | Secret scrubbing | `pip install git-filter-repo` |

## Token Scopes Required

**ADO PAT**: Code (Read), Build (Read+Execute), Release (Read), Work Items (Read), Project & Team (Read), Graph (Read)

**GitHub PAT**: `repo`, `admin:org`, `workflow`, `read:enterprise`

## Key Limits

- Max repo size: **40 GiB** (GEI limit)
- Max file during migration: **400 MiB**
- Max file post-migration: **100 MiB**
- No delta/incremental migration
- Pipeline logs do NOT migrate
- Work item state history is lost
