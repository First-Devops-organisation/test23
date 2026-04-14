# ADO to GitHub Migration

This repository contains tooling and runbooks for migrating Azure DevOps (ADO) assets into GitHub Enterprise Cloud. It includes two related migration paths:

1. `migration-accelerator/` — an end-to-end accelerator for migrating repos, pipelines, boards, wiki, and post-migration GitHub Advanced Security (GHAS) configuration.
2. `repo-migration/` — a focused Git repository migration plan and orchestration flow using GitHub Enterprise Importer (GEI).

> This repo is designed for enterprise/bank migration programs with strict compliance controls, secret scanning, and audit-ready validation.

## What this project includes

- `migration-accelerator/` — complete Azure DevOps → GitHub migration scripts and documentation.
- `repo-migration/` — repository-only migration tooling and a migration plan for Git repos.
- `README.md` — this top-level overview.

## When to use each folder

- Use `migration-accelerator/` when you need a broad migration path for repositories, pipelines, work items, and wiki content.
- Use `repo-migration/` when you only need to migrate Git repositories and want a simpler, repo-focused migration pipeline.

## Folder overview

### `migration-accelerator/`

This folder contains the main migration accelerator and is organized into discovery, preparation, migration, and post-migration stages.

- `00-discovery/`
  - `inventory-assets.ps1` — scan ADO assets and build a migration inventory.
  - `audit-repo-sizes.ps1` — review repo sizes and GEI compatibility.
  - `forecast-usage.ps1` — estimate GitHub usage.
  - `scan-secrets.ps1` — find exposed secrets in ADO Git history.
- `01-prep/`
  - `install-tools.ps1` — install or verify required tools.
  - `scrub-secrets.ps1` — scrub secrets from repository history.
  - `setup-github-org.ps1` — validate GitHub org readiness.
- `02-migrate/`
  - `migrate-repos.ps1` — migrate repos via GEI.
  - `migrate-pipelines.ps1` — convert Azure Pipelines to GitHub Actions.
  - `migrate-boards.ps1` — migrate ADO Boards to GitHub Issues/Projects.
  - `migrate-wiki.ps1` — migrate ADO wiki pages to GitHub wiki.
- `03-post-migrate/`
  - `enable-ghas.ps1` — enable Dependabot, CodeQL, secret scanning, and push protection.
  - `reclaim-mannequins.ps1` — reclaim mannequin accounts created during migration.
  - `set-visibility.ps1` — adjust repository visibility and branch protection.
  - `validate-migration.ps1` — run validation checks after migration.
- `config/`
  - `migration-config.json` — main migration configuration and batch definitions.
  - `team-mappings.json` — ADO team → GitHub team mapping.
  - `user-mappings.csv` — user identity mapping from ADO to GitHub.
  - `workitem-type-mappings.json` — work item type and state mapping.
- `docs/`
  - `compliance-mapping.md` — compliance control mapping from ADO to GitHub.
  - `limitations.md` — limitations and known gaps in migration coverage.
  - `migration-runbook.md` — step-by-step migration runbook.
  - `rollback-plan.md` — rollback guidance.

### `repo-migration/`

This folder is optimized for repository-only migration using GEI and includes audit, preparation, migration, and validation stages.

- `01-discover/`
  - `audit-repo-sizes.ps1` — inspect repository size and GEI limits.
  - `discover-repos.ps1` — enumerate ADO repositories to migrate.
  - `scan-secrets.ps1` — scan repositories for secrets.
- `02-prep/`
  - `install-tools.ps1` — install/verify required tools for repo migration.
  - `scrub-secrets.ps1` — remove secrets from Git history before migration.
- `03-migrate/`
  - `migrate-repos.ps1` — perform repository migration batches with GEI.
- `04-validate/`
  - `reclaim-mannequins.ps1` — reclaim mannequin users created during repo migration.
  - `validate-repos.ps1` — validate migrated repositories.
- `config/`
  - `repo-migration-config.json` — source/target configuration, batches, exclusions, and output settings.
- `REPO-MIGRATION-PLAN.md` — repo migration plan and execution guidance.
- `run-migration.ps1` — orchestrates the full repo migration flow.

## High-level workflow

### `migration-accelerator/` path

1. Discover ADO assets and scan for issues.
2. Prepare by installing tools, scrubbing secrets, and validating GitHub org readiness.
3. Migrate repos, pipelines, boards, and wiki content.
4. Perform post-migration tasks like GHAS enablement, mannequin reclamation, visibility settings, and validation.

### `repo-migration/` path

1. Discover target repos and audit repo size.
2. Prepare by installing tools and scrubbing secrets if needed.
3. Migrate repos in batches using `run-migration.ps1` or `migrate-repos.ps1`.
4. Validate migrated repos and reclaim mannequin accounts.

## Quick start

### For `migration-accelerator/`

1. Open `migration-accelerator/config/migration-config.json` and update your ADO and GitHub settings.
2. Update `migration-accelerator/config/user-mappings.csv`, `team-mappings.json`, and `workitem-type-mappings.json`.
3. Run discovery scripts in `migration-accelerator/00-discovery/`.
4. Run preparation scripts in `migration-accelerator/01-prep/`.
5. Run migration scripts in `migration-accelerator/02-migrate/`.
6. Run post-migration scripts in `migration-accelerator/03-post-migrate/`.

### For `repo-migration/`

1. Open `repo-migration/config/repo-migration-config.json` and update source/target values.
2. Review batch definitions and exclusions.
3. Run the orchestrator:

```powershell
cd repo-migration
.\run-migration.ps1
```

4. Use `-StartFrom discover`, `-StartFrom prep`, `-BatchName <name>`, or `-DryRun` as needed.

## Prerequisites

- PowerShell 7 or later
- `gh` GitHub CLI
- `gh ado2gh` extension
- `gh-actions-importer` extension
- `git-sizer`
- `gitleaks`
- `git-filter-repo`
- ADO Personal Access Token (`ADO_PAT`)
- GitHub PAT (`GH_PAT`) with `repo`, `admin:org`, `workflow`, and related scopes

## Notes

- This repository does not itself contain the migration target environment.
- Sensitive values such as PATs should be injected through environment variables and never checked in.
- Use the `REPO-MIGRATION-PLAN.md` file for a repo-only migration execution plan.
- Use the `migration-accelerator/docs` files for enterprise runbook, compliance, limitations, and rollback planning.

## Recommended next step

Open `migration-accelerator/README.md` for the accelerator workflow, and `repo-migration/REPO-MIGRATION-PLAN.md` for the repository-only migration plan.
