# Azure DevOps to GitHub — Repository Migration Documentation

## Table of Contents

1. [Overview](#overview)
2. [Architecture & Design](#architecture--design)
3. [Prerequisites](#prerequisites)
4. [Configuration](#configuration)
5. [Pipeline Stages — Step by Step](#pipeline-stages--step-by-step)
6. [Secret Scrubbing — How It Works](#secret-scrubbing--how-it-works)
7. [APIs Used](#apis-used)
8. [Tools & Dependencies](#tools--dependencies)
9. [Pipeline Parameters](#pipeline-parameters)
10. [Output Reports & Artifacts](#output-reports--artifacts)
11. [Naming Convention for Secrets](#naming-convention-for-secrets)
12. [Security Considerations](#security-considerations)
13. [Known Limitations](#known-limitations)
14. [Troubleshooting](#troubleshooting)

---

## Overview

This pipeline automates the end-to-end migration of Git repositories from **Azure DevOps (ADO)** to **GitHub Enterprise**, with a strong focus on **zero-secret exposure**. It discovers repositories, scans for secrets across the entire Git history, migrates the code using GitHub's official migration tool (GEI), scrubs all secrets from the Git history on the GitHub side, and validates the migration.

### High-Level Flow

```
ADO Repos ──► Discover & Audit ──► Secret Scan ──► Human Review Gate ──► GEI Migration ──► Scrub Secrets ──► Create GitHub Secrets ──► Validate
```

---

## Architecture & Design

### Why "Migrate Then Scrub"?

The GitHub Enterprise Importer (GEI) is a **server-to-server** tool. When triggered, GitHub's servers connect directly to Azure DevOps and copy the repository data. Your pipeline agent does not upload any files — it simply issues an API command.

Because of this, we **cannot inject a secret scanner into the middle of GEI's transfer**. The pipeline therefore follows a "Scan First → Migrate → Scrub After" approach:

1. **Before migration**: Scan the ADO repo for secrets and record them.
2. **During migration**: GEI migrates the repo (secrets temporarily exist on GitHub).
3. **After migration**: Clone the GitHub repo, rewrite its entire history to remove secrets, and force-push the clean history back.

This approach preserves GEI's ability to migrate Pull Requests, Work Items, and other metadata that a simple `git push` cannot carry.

---

## Prerequisites

### Access & Permissions

| Requirement | Details |
|---|---|
| **Azure DevOps PAT** | Needs `Code (Read)` and `Project & Team (Read)` scopes |
| **GitHub PAT (Classic)** | Needs `repo`, `read:org`, `admin:org` scopes |
| **Azure DevOps Project** | The ADO project containing the repos to migrate |
| **GitHub Organization** | The target GitHub org where repos will land |
| **ADO Pipeline Agent** | Must be a `windows-latest` hosted agent (or self-hosted Windows with PowerShell 7+) |

### Azure DevOps Pipeline Setup

1. Create a **Variable Group** named `ankit-adotogit` (or your chosen name) with the following secrets:
   - `ADO_PAT` — Azure DevOps Personal Access Token
   - `GH_PAT` — GitHub Personal Access Token
   - `ADO_Org` — Azure DevOps organization name (e.g., `YashTech-DevOps`)
   - `ADO_Project` — Azure DevOps project name (e.g., `YASH-DevOps-Serverless`)
   - `GitHub_Org` — GitHub organization name (e.g., `YashTech-DevOps`)
   - `ADO_Repo` — Repository name (for Single mode)
   - `GitHub_Repo` — Target GitHub repo name (optional, defaults to ADO repo name)

2. Install the **PublishHtmlReport** extension from the Azure DevOps Marketplace (for HTML report tabs).

---

## Configuration

### `config/repo-migration-config.json`

This is the central configuration file that controls the migration.

```json
{
  "source": {
    "type": "AzureDevOps",
    "organization": "$(ADO_Org)",
    "project": "$(ADO_Project)",
    "pat": "$(ADO_PAT)"
  },
  "target": {
    "organization": "$(GitHub_Org)",
    "pat": "$(GH_PAT)"
  },
  "migration": {
    "cloneTempDir": "./tmp/clones",
    "singleRepo": "ADO_To_GHAS_Migration",
    "targetRepoVisibility": "private",
    "lockSourceRepo": false,
    "retryCount": 3,
    "retryDelaySeconds": 30
  },
  "batches": [
    {
      "name": "batch-1-pilot",
      "scheduledDate": "2026-04-15",
      "repos": [
        "APIOPS",
        "APIM-Migration",
        "Board_migration"
      ]
    }
  ],
  "exclusions": {
    "repos": [],
    "branches": []
  },
  "output": {
    "reportDir": "./output/reports",
    "logDir": "./output/logs"
  }
}
```

| Field | Description |
|---|---|
| `source.*` | ADO connection settings (tokens are replaced at runtime from pipeline variables) |
| `target.*` | GitHub connection settings |
| `migration.singleRepo` | Default repo for Single mode |
| `migration.targetRepoVisibility` | `private`, `internal`, or `public` |
| `batches` | Named groups of repos for batch migration |
| `exclusions.repos` | Repos to skip even if discovered |

---

## Pipeline Stages — Step by Step

### Stage 1: Discover & Analyse

**Purpose**: Discover all repositories in the ADO project, audit their sizes, and scan for secrets.

#### Step 1.1 — Discover Repos (`discover-repos.ps1`)

- Calls the **Azure DevOps REST API** to list all Git repositories in the project.
- For each repo, collects: name, size, default branch, last commit date, LFS status.
- Flags any repo exceeding GitHub's 40 GB import limit.
- Generates an interactive **HTML Dashboard** with a sortable table of all repos.

**Outputs**:
- `repo-inventory.json` — Machine-readable repo list
- `repo-inventory.csv` — Spreadsheet-friendly format
- `repo-inventory.html` — Visual dashboard

#### Step 1.2 — Scan Secrets (`scan-secrets.ps1`)

- For each repo, performs a **mirror clone** from ADO (captures all branches, tags, and full commit history).
- **Phase 1**: Runs `gitleaks detect` using built-in rules to find well-known secret patterns (AWS keys, GitHub PATs, RSA private keys, etc.).
- **Phase 2**: Runs `gitleaks detect` again with a custom rules file (`custom-gitleaks-rules.toml`) that catches any variable name containing `key`, `secret`, `password`, `token`, `cred`, or `auth` — case-insensitive.
- Both phases scan the **entire Git history**, not just the latest commit.
- Extracts the full variable name (e.g., `AWS_ACCESS_KEY_ID`) and the secret value from each finding.
- Filters out placeholder values like `changeme`, `password`, `dummy`, etc.

**Outputs**:
- `secret-scan-findings.json` — Detailed findings with file, line number, commit, author
- `secret-scan-summary.json` — Per-repo summary
- `secret-scan-report.html` — Visual HTML report

---

### Stage 2: Review Gate

**Purpose**: A mandatory human approval checkpoint.

- The pipeline pauses and waits for a human reviewer to examine the discovery and scan reports.
- The reviewer checks:
  - Which repos to include/exclude
  - Whether any repos exceed GEI's 40 GB limit
  - Whether secrets were found (and therefore need scrubbing)
- The reviewer can **Approve** (proceed to migration) or **Reject** (abort the pipeline).
- Times out after **72 hours** if no action is taken.

---

### Stage 3: Migrate

**Purpose**: Migrate repositories from ADO to GitHub using GEI.

Runs differently based on the migration mode:

#### Single Mode (`migrate-single.ps1`)
- Migrates one specific repository.
- Installs the GitHub CLI (`gh`) and the `gh-ado2gh` extension on the pipeline agent.
- Runs `gh ado2gh migrate-repo` which tells GitHub's servers to connect to ADO and copy the repo (server-to-server).
- Creates the target GitHub repo with the configured visibility (default: `private`).
- Captures audit data: branch count, tag count, PR count, default branch, latest commit hash.

#### Batch Mode (`migrate-batch.ps1`)
- Reads the repo list from the `batches` section in `config.json`.
- Calls `migrate-single.ps1` for each repo, running up to 3 repos in parallel.

---

### Stage 4: Scrub & Create Secrets

**Purpose**: Remove all secrets from the migrated GitHub repo's Git history and provision them as GitHub Secrets.

#### Step 4.1 — Scrub Secrets (`scrub-secrets.ps1`)

1. Reads `secret-scan-findings.json` from Stage 1.
2. For each repo with findings:
   - Clones the GitHub repo (the one just migrated).
   - Builds a `replacements.txt` file mapping each secret value to its placeholder (`${{ secrets.MAIN_DB_PASSWORD }}`).
   - Runs `git-filter-repo` on the clone — this rewrites **every commit in history**, replacing the real secret value with the placeholder string.
   - Verifies the replacement by running `git grep` and `git log -S` to confirm the secret no longer exists.
   - Force-pushes the clean history back to GitHub (`git push --force --all` and `git push --force --tags`).

**Key Detail**: The `replacements.txt` file is written in **UTF-8 without BOM** to prevent `git-filter-repo` (Python) from silently failing on the first entry.

#### Step 4.2 — Create GitHub Secrets (`create-github-secrets.ps1`)

1. Reads `secret-values.json` (the mapping of secret names to their real values).
2. For each secret, uses the **GitHub CLI** (`gh secret set`) to create a repository-level secret on GitHub.
3. This ensures that `${{ secrets.MAIN_DB_PASSWORD }}` in the code actually resolves to the real password when GitHub Actions workflows run.

---

### Stage 5: Validate

**Purpose**: Verify the migration was successful by comparing ADO source and GitHub target.

#### Checks Performed (`validate-migration.ps1`)

| Check | Description |
|---|---|
| **Repo Exists** | Confirms the GitHub repo was created |
| **Branch Count** | ADO branch count matches GitHub |
| **Missing Branches** | Lists any ADO branches not found in GitHub |
| **Default Branch** | ADO default branch matches GitHub |
| **Tag Count** | ADO tag count matches GitHub |
| **PR Count** | Pull request count within ±2 tolerance |
| **Visibility** | GitHub repo visibility matches expected setting |
| **Latest Commit** | Audit commit hash is reachable on GitHub |
| **Branch Protection** | Checks if default branch has protection rules |

**Outputs**:
- `validation-results.json` — Machine-readable results
- `validation-results.csv` — Spreadsheet-friendly format
- `validation-report.html` — Visual HTML dashboard with accuracy percentage
- `validation-summary.md` — ADO pipeline summary tab

---

## Secret Scrubbing — How It Works

### Detection (scan-secrets.ps1)

The scanner uses a two-phase approach:

1. **Phase 1 — Built-in Gitleaks Rules**: Catches well-known patterns like AWS keys (`AKIA...`), Stripe keys (`sk_live_...`), SSH keys, JWT tokens, MongoDB URIs, etc.

2. **Phase 2 — Custom Keyword Rules**: A catch-all regex that flags any line where a variable name contains `key`, `secret`, `password`, `token`, `cred`, or `auth` (case-insensitive), regardless of format (ENV files, JSON, YAML, etc.).

### Scrubbing (scrub-secrets.ps1)

The scrubber uses `git-filter-repo`, a powerful tool that rewrites Git history at the blob level. For every commit ever made in the repository, if a blob contains a secret value, it is replaced with the placeholder string.

### Example

**Before scrubbing** (what appears in Git history):
```
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
DB_PASSWORD=SuperSecret@123
```

**After scrubbing** (what appears in Git history after force-push):
```
AWS_ACCESS_KEY_ID=${{ secrets.MAIN_AWS_ACCESS_KEY_ID }}
DB_PASSWORD=${{ secrets.MAIN_DB_PASSWORD }}
```

The original secret values are stored as GitHub repository-level secrets, so workflows continue to function.

---

## APIs Used

### Azure DevOps REST API (v7.1)

| API | Purpose | Used By |
|---|---|---|
| `GET _apis/git/repositories` | List all repos in the ADO project | `discover-repos.ps1` |
| `GET _apis/git/repositories/{repo}` | Get repo metadata (size, default branch) | `scan-secrets.ps1`, `validate-migration.ps1` |
| `GET _apis/git/repositories/{repo}/refs?filter=heads/` | List all branches | `validate-migration.ps1` |
| `GET _apis/git/repositories/{repo}/refs?filter=tags/` | List all tags | `validate-migration.ps1` |
| `GET _apis/git/repositories/{repo}/pullrequests` | Count pull requests | `validate-migration.ps1` |
| `GET _apis/projects/{project}` | Get project visibility | `validate-migration.ps1` |

### GitHub REST API (via `gh` CLI)

| API / Command | Purpose | Used By |
|---|---|---|
| `gh ado2gh migrate-repo` | Trigger server-to-server repo migration | `migrate-single.ps1` |
| `gh repo view` | Check if repo exists, get default branch, visibility | `validate-migration.ps1` |
| `gh api repos/{owner}/{repo}/branches` | List GitHub branches | `validate-migration.ps1` |
| `gh api repos/{owner}/{repo}/tags` | List GitHub tags | `validate-migration.ps1` |
| `gh api repos/{owner}/{repo}/git/commits/{sha}` | Verify commit reachability | `validate-migration.ps1` |
| `gh api repos/{owner}/{repo}/branches/{branch}/protection` | Check branch protection | `validate-migration.ps1` |
| `gh api search/issues?q=repo:{owner}/{repo}+type:pr` | Count GitHub PRs | `validate-migration.ps1` |
| `gh secret set` | Create repository-level GitHub secrets | `create-github-secrets.ps1` |

### GitHub Enterprise Importer API (internal)

| Endpoint | Purpose |
|---|---|
| Server-to-server migration (triggered by `gh ado2gh`) | Copies Git data, PRs, and metadata from ADO to GitHub |

> **Note**: The GEI migration API is abstracted by the `gh-ado2gh` CLI extension. You do not call it directly.

---

## Tools & Dependencies

| Tool | Version | Purpose | Installed By |
|---|---|---|---|
| **PowerShell 7+** | 7.x | Script execution engine | Pre-installed on `windows-latest` agent |
| **Git** | 2.x | Repository cloning and operations | Pre-installed on agent |
| **Gitleaks** | 8.18.4 | Secret detection engine | Pipeline step (downloaded from GitHub Releases) |
| **git-filter-repo** | Latest | Git history rewriting for secret scrubbing | Pipeline step (`pip install git-filter-repo`) |
| **GitHub CLI (gh)** | 2.52.0 | GitHub API interaction and GEI migration | Pipeline step (downloaded from GitHub Releases) |
| **gh-ado2gh** | Latest | GitHub Enterprise Importer extension | Pipeline step (`gh extension install`) |
| **git-sizer** | 1.5.0 | Repository size analysis | Pipeline step (downloaded from GitHub Releases) |
| **Python 3.x** | 3.x | Required by `git-filter-repo` | Pre-installed on `windows-latest` agent |

---

## Pipeline Parameters

When you run the pipeline, you can configure these options:

| Parameter | Default | Description |
|---|---|---|
| **MigrationMode** | `Single` | `Single` for one repo, `Batch` for multiple repos |
| **ADORepo** | (blank) | ADO repository name (Single mode only) |
| **GHRepo** | (blank) | Target GitHub repo name (defaults to ADORepo if blank) |
| **BatchName** | (blank) | Batch name from config.json (Batch mode — blank = all batches) |
| **SkipAudit** | `false` | Skip branch-level audit (faster, less data) |
| **DryRun** | `false` | Print GEI commands without executing them |
| **RunValidation** | `true` | Run validation checks after migration |

---

## Output Reports & Artifacts

The pipeline produces these artifacts at each stage:

### Stage 1 — Discovery
- `discovery-reports/repo-inventory.json`
- `discovery-reports/repo-inventory.csv`
- `discovery-reports/repo-inventory.html`

### Stage 1 — Secret Scan
- `scan-reports-batch0/secret-scan-findings.json`
- `scan-reports-batch0/secret-scan-summary.json`
- `scan-reports-batch0/secret-scan-report.html`

### Stage 3 — Migration
- `MigrationLogs-Single/` or `BatchMigrationLogs/` — Detailed migration logs
- `MigrationAudit-Single/` or `BatchMigrationAudit/` — Per-repo audit data
- `MigrationDashboard-Single/` or `BatchMigrationDashboards/` — HTML dashboards

### Stage 4 — Scrubbing
- `scrub-reports/secret-values.json` — Secret name-to-value mapping
- `scrub-reports/scrub-migration-report.csv` — Scrubbing status per finding
- `scrub-reports/credential-rotation-checklist.csv` — Credentials that need rotation

### Stage 5 — Validation
- `ValidationReports/validation-results.json`
- `ValidationReports/validation-results.csv`
- `ValidationReports/validation-report.html`
- `ValidationReports/validation-summary.md`

---

## Naming Convention for Secrets

When a secret is detected and scrubbed, the placeholder name follows this convention:

### Format: `BRANCHNAME_FULLSECRETNAME`

The secret placeholder is composed of:
1. **Branch prefix**: The Git branch where the secret was found, sanitized (slashes and special characters replaced with underscores, converted to uppercase).
2. **Full variable name**: The exact variable name extracted from the code (e.g., `AWS_ACCESS_KEY_ID`, `DB_PASSWORD`).

### Examples

| Branch | Variable in Code | Placeholder |
|---|---|---|
| `main` | `DB_PASSWORD` | `${{ secrets.MAIN_DB_PASSWORD }}` |
| `main` | `AWS_ACCESS_KEY_ID` | `${{ secrets.MAIN_AWS_ACCESS_KEY_ID }}` |
| `feature/login` | `API_TOKEN` | `${{ secrets.FEATURE_LOGIN_API_TOKEN }}` |
| `develop` | `STRIPE_SECRET_KEY` | `${{ secrets.DEVELOP_STRIPE_SECRET_KEY }}` |

### Deduplication Rules

| Scenario | Behavior |
|---|---|
| Same name, same value | Deduplicated — only one secret is created |
| Same name, different values | Suffixed: `MAIN_DB_PASSWORD`, `MAIN_DB_PASSWORD_2` |
| Same value across different variables | Deduplicated to the first name encountered |

---

## Security Considerations

1. **Repositories migrate as Private**: The `targetRepoVisibility` is set to `private`, ensuring secrets are never publicly visible even during the brief window between migration and scrubbing.

2. **GEI Bypasses Push Protection**: Because GEI uses backend APIs, GitHub's Push Protection does not block the migration even if secrets are present. Our post-migration scrub handles this.

3. **PAT Least Privilege**: Use dedicated service account PATs with the minimum required scopes. Revoke them immediately after migration.

4. **Credential Rotation**: Since secrets briefly exist on GitHub before scrubbing, all detected credentials should be considered potentially compromised. The pipeline generates a `credential-rotation-checklist.csv` to track which credentials need rotation.

5. **Enable GHAS Before Migration**: Enable GitHub Advanced Security (Secret Scanning) at the organization level before running migrations. This ensures any secrets that land on GitHub are immediately flagged.

---

## Known Limitations

| Limitation | Impact | Workaround |
|---|---|---|
| **GEI is server-to-server** | Cannot scrub secrets before they reach GitHub | Post-migration scrub removes them within seconds |
| **GEI 40 GB limit** | Repos larger than 40 GB cannot be migrated via GEI | Use `git push --mirror` manually for oversized repos |
| **git-filter-repo rewrites SHAs** | All commit hashes change after scrubbing | Expected behavior — PRs and references are preserved by GEI before scrubbing |
| **LFS objects not migrated** | Git LFS data is not transferred by GEI | Manually migrate LFS objects using `git lfs push` |
| **Abandoned PRs not migrated** | GEI only migrates active and completed PRs | By design — abandoned PRs are excluded |

---

## Troubleshooting

### "No repositories identified for scanning"
- **Cause**: In Batch mode, the `SingleRepoName` parameter was set (e.g., a repo name was typed in the ADO Repo field). The script tries to use it as a batch name filter.
- **Fix**: Leave the ADO Repo field blank when running in Batch mode. Or use Single mode for individual repos.

### Secrets still visible in one commit but scrubbed in another
- **Cause**: The old keyword scanner only checked the latest files (HEAD), missing historical commits.
- **Fix**: Already resolved — Phase 2 now uses `gitleaks` which natively scans the entire Git history.

### `git-filter-repo` silently ignores replacements
- **Cause**: The `replacements.txt` file had a UTF-8 BOM (Byte Order Mark) that corrupted the first entry.
- **Fix**: Already resolved — the script explicitly writes files in UTF-8 without BOM.

### Variable name is truncated (e.g., `KEY_ID` instead of `AWS_ACCESS_KEY_ID`)
- **Cause**: The custom gitleaks regex started matching at the keyword, cutting off the prefix.
- **Fix**: Already resolved — the regex now includes an optional prefix to capture the full variable name.

### `$using:keywordPatterns` error
- **Cause**: A variable was removed from the script but its reference in the parallel loop was not cleaned up.
- **Fix**: Already resolved — the unused `$using:keywordPatterns` reference was removed.

---

## Folder Structure

```
repo-migration/
├── 01-discover/
│   ├── discover-repos.ps1          # Stage 1.1 — Repo discovery & audit
│   └── scan-secrets.ps1            # Stage 1.2 — Secret scanning
├── 02-prep/
│   ├── install-tools.ps1           # Tool installation helper
│   └── scrub-secrets.ps1           # Stage 4.1 — Secret scrubbing
├── 03-migrate/
│   ├── migrate-single.ps1          # Stage 3 — Single repo migration
│   ├── migrate-batch.ps1           # Stage 3 — Batch migration orchestrator
│   └── create-github-secrets.ps1   # Stage 4.2 — GitHub secret provisioning
├── 04-validate/
│   ├── validate-migration.ps1      # Stage 5 — Post-migration validation
│   └── reclaim-mannequins.ps1      # Reclaim unmapped user identities
├── config/
│   └── repo-migration-config.json  # Central configuration file
├── azure-pipeline.yaml             # Azure DevOps pipeline definition
└── MIGRATION-DOCUMENTATION.md      # This document
```
