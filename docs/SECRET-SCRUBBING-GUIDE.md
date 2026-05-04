# Secret Scrubbing Guide — ADO to GitHub Migration

## Overview

This document describes the secret scrubbing process used during the Azure DevOps (ADO) to GitHub migration. The goal is to ensure that **no secret values** (API keys, passwords, tokens, certificates) are present in the migrated GitHub repository. All secrets are replaced with GitHub Actions Secret placeholders (`${{ secrets.SECRET_NAME }}`), and the actual values are provisioned as GitHub Repository Secrets.

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                        Azure DevOps Pipeline                                 │
│                                                                              │
│  Stage 1: DISCOVER & PREPARE    Stage 2: REVIEW    Stage 3: MIGRATE         │
│  ┌──────────────────────────┐   ┌──────────────┐   ┌──────────────────────┐ │
│  │ 1.1 Discover repos       │   │ Manual       │   │ 3.1 GEI migrate     │ │
│  │ 1.3 Scan secrets         │──▶│ approval     │──▶│     (fresh from ADO)│ │
│  │ 1.4 Generate replacement │   │ gate         │   │ 3.2 Clone from GH   │ │
│  │     rules (expressions)  │   └──────────────┘   │     git-filter-repo │ │
│  └──────────────────────────┘                      │     Verify + Push   │ │
│                                                    └──────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

### Tools Required

| Tool | Version | Purpose | Install Command |
|------|---------|---------|-----------------|
| **Git** | 2.30+ | Repository cloning and push operations | Pre-installed on Azure DevOps agents |
| **GitHub CLI (`gh`)** | 2.52+ | GitHub API interaction, GEI extension | Installed via portable zip in pipeline |
| **gh-ado2gh** | Latest | GitHub Enterprise Importer extension for `gh` | `gh extension install github/gh-ado2gh` |
| **gitleaks** | 8.18+ | Secret detection in git history | Downloaded as zip in pipeline |
| **git-filter-repo** | 2.38+ | Git history rewriting for secret removal | `pip install git-filter-repo` |
| **Python** | 3.8+ | Required by git-filter-repo | Pre-installed on Azure DevOps agents |
| **PowerShell** | 5.1+ / 7+ | Pipeline scripts (pwsh preferred) | Pre-installed on Azure DevOps agents |

### Access Tokens (PATs)

| Token | Platform | Required Scopes | Used For |
|-------|----------|-----------------|----------|
| **ADO_PAT** | Azure DevOps | `Code (Read)`, `Identity (Read)` | Cloning repos, reading metadata |
| **GH_PAT** | GitHub (Classic PAT only) | `repo` (full), `read:org`, `admin:org` | GEI migration, cloning, force-push, managing secrets |

> **Important:** Fine-grained PATs are NOT supported by `gh ado2gh`. You must use a Classic PAT.

### Azure DevOps Pipeline Variable Group

| Variable | Description | Example |
|----------|-------------|---------|
| `ADO_Org` | ADO organisation name (not URL) | `YashTech-DevOps` |
| `ADO_Project` | ADO project name | `YASH-DevOps-Serverless` |
| `ADO_PAT` | ADO Personal Access Token (secret) | `***` |
| `GitHub_Org` | GitHub organisation name | `YashTech-DevOps` |
| `GH_PAT` | GitHub Personal Access Token (secret) | `***` |
| `ADO_Repo` | Target ADO repository name | `dummy-secret` |
| `REPORT_DIR` | Report output directory | `output/reports` |
| `LOG_DIR` | Log output directory | `output/logs` |
| `CLONE_TEMP_DIR` | Temporary clone directory | `output/tmp/clones` |

---

## Dependencies Between Stages

```
Stage 1: Discover & Prepare
    │
    │  Job 1.1: Discover repos → publishes "discovery-reports" artifact
    │
    │  Job 1.3+1.4: Scan secrets + Generate replacement rules
    │    └─ 1.3 scan-secrets.ps1  → finds secrets, saves findings
    │    └─ 1.4 scrub-secrets.ps1 → reads findings, generates expressions file
    │    └─ Publishes "scan-reports" artifact
    │         Contains:
    │           - secret-scan-findings.json
    │           - secret-scan-report.html
    │           - expressions-<reponame>.txt   ← replacement rules for Stage 3
    │           - secret-values.json           ← for GitHub Secrets provisioning
    │           - credential-rotation-checklist.csv
    │
    ▼
Stage 2: Review Gate (manual approval)
    │
    ▼
Stage 3: Migrate ◀── downloads "scan-reports" artifact
    │
    │  Downloads to: output/scrub-artifacts/
    │
    │  Step 3.1: GEI MIGRATION (fresh from ADO → GitHub)
    │    └─ Repo lands on GitHub WITH secrets + PRs/Issues
    │
    │  Step 3.2: POST-MIGRATION SCRUB (on the GitHub repo)
    │    └─ Clone from GitHub
    │    └─ git-filter-repo --replace-text (uses expressions file from Stage 1)
    │    └─ Verify secrets are gone
    │    └─ Force-push clean history back to GitHub
    │    └─ Result: GitHub repo now has placeholders, PRs still intact
```

---

## Detailed Process

### Phase 1: Secret Discovery (`scan-secrets.ps1`)

**Input:** ADO repository (cloned via `git clone --mirror`)  
**Output:** `secret-scan-findings.json`

#### 1.1 — Full Clone
```powershell
git clone --mirror <ADO_REPO_URL> <LOCAL_PATH>
```
- Uses `--mirror` to get ALL branches, ALL tags, ALL history
- Authenticates via `Authorization: Basic` header with ADO_PAT
- LFS files are skipped (`GIT_LFS_SKIP_SMUDGE=1`)

#### 1.2 — Gitleaks Scan
```powershell
gitleaks detect --source <LOCAL_PATH> --report-path <REPORT> --config gitleaks.toml
```
- Scans the entire git history (all commits, all branches)
- Uses custom rules from `config/gitleaks.toml`:

| Rule ID | What it detects | Example |
|---------|----------------|---------|
| `generic-keyword-broad` | Any `KEY=VALUE` pattern | `API_KEY = sk-abc123` |
| `ssh-private-key` | SSH private key blocks | `-----BEGIN RSA PRIVATE KEY-----` |
| `ssh-public-key` | SSH public keys | `ssh-rsa AAAAB3...` |

#### 1.3 — PowerShell Keyword Scan (Fallback)
Catches secrets that gitleaks might miss:
```
Pattern: (password|key|secret|token|auth|InstrumentationKey) = <VALUE>
```
- Handles quoted and unquoted values
- Captures full line for SSH/PEM keys
- Minimum value length: 4 characters

#### 1.4 — Output Format
Each finding in `secret-scan-findings.json`:
```json
{
    "Repo": "dummy-secret",
    "File": "dummy-secrets.txt",
    "LineNumber": 3,
    "Branch": "main",
    "CommitID": "dac8ec9",
    "RuleID": "generic-keyword-broad",
    "SecretName": "AZURE_STORAGE_KEY",
    "SecretValue": "Eby8vdM02xNOcqFeqCnfFm==EXAMPLEKEY==",
    "Match": "AZURE_STORAGE_KEY = Eby8vdM02xNOcqFeqCnfFm==EXAMPLEKEY=="
}
```

---

### Phase 2: Expression File Generation (`scrub-secrets.ps1`)

**Input:** `secret-scan-findings.json`  
**Output:** `expressions-<reponame>.txt`

#### 2.1 — Secret Value Cleaning
For each finding, the secret value is cleaned:
```
Raw:     "  SuperSecret123!  "
Step 1:  "SuperSecret123!"      ← Trim whitespace
Step 2:  "SuperSecret123!"      ← Remove surrounding quotes
Step 3:  "SuperSecret123!"      ← Strip carriage returns (\r)
```

#### 2.2 — False Positive Filtering
Skipped values:
- Common placeholders: `changeme`, `password`, `example`, `placeholder`, `xxx`
- File paths: `/usr/local/...`, `https://...`
- Short values: anything less than 4 characters
- Control characters (except `\r\n`)

#### 2.3 — Secret Name Assignment
```
Secret Value: "SuperSecret123!"
Key Context:  "MYSQL_PASSWORD = SuperSecret123!"
Secret Name:  MYSQL_PASSWORD  ← Extracted from the assignment
```

Rules:
- Uppercased, non-alphanumeric characters replaced with `_`
- `GITHUB_` prefix renamed to `GH_` (GitHub reserves this prefix)
- Maximum length: 100 characters
- Collision handling: `KEY`, `KEY_2`, `KEY_3`, etc.

#### 2.4 — Expression File Format
Each line in `expressions-<reponame>.txt`:
```
<SECRET_VALUE>==><PLACEHOLDER>
```

Example file:
```
mongodb://testuser:fakepassword@localhost:27017/mydb==>${{ secrets.MONGO_URI }}
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.FAKEPAYLOAD.FAKESIGNATURE==>${{ secrets.JWT_SECRET }}
Eby8vdM02xNOcqFeqCnfFm==EXAMPLEKEY====>${{ secrets.AZURE_STORAGE_KEY }}
sk-1234567890abcdefghijklmnopqrstuvwxYZ==>${{ secrets.OPENAI_API_KEY }}
SuperSecret123!==>${{ secrets.MYSQL_PASSWORD }}
admin==>${{ secrets.MYSQL_USER }}
```

**Critical details:**
- Sorted **longest-first** (prevents partial replacements — e.g., `SuperSecret123!` must be replaced before `Secret123`)
- Written in **BOM-less UTF-8** using `[System.IO.File]::WriteAllLines()` (Windows PowerShell's `Set-Content -Encoding UTF8` adds a BOM that breaks git-filter-repo)
- Backslashes escaped: `\` becomes `\\` (git-filter-repo treats `\` as escape character)

---

### Phase 3: GEI Migration + Post-Migration Scrub (`migrate-single.ps1`)

#### Step 3.1 — GEI Migration

```powershell
gh ado2gh migrate-repo `
    --ado-org          $ADOOrg `
    --ado-team-project $ADOProject `
    --ado-repo         $ADO_Repo `
    --github-org       $GHOrg `
    --github-repo      $GitHub_Repo `
    --target-repo-visibility private
```

**What GEI does internally:**
1. Connects to ADO API with `ADO_PAT`
2. Creates an export archive (git bundle + PR/Issue metadata)
3. Uploads archive to GitHub Migration API
4. GitHub processes the archive server-side
5. Creates the repository with all branches, PRs, Issues, Wiki

**After this step:** GitHub repo exists with all metadata BUT secrets are still in the code.

#### Step 3.2 — Post-Migration Scrub

**3.2.1 — Locate Expressions File**
```
Search order:
  1. EXPRESSIONS_DIR environment variable (set by pipeline artifact download)
  2. Local reportDir (fallback)
```
The pipeline downloads the `scrub-reports` artifact to `output/scrub-artifacts/`. The script searches this directory for `expressions-<reponame>.txt`.

**3.2.2 — Clone from GitHub**
```powershell
$encodedPat = [uri]::EscapeDataString($ghPat)  # Handle special chars in PAT
$ghRemote = "https://x-access-token:$encodedPat@github.com/$GHOrg/$GitHub_Repo.git"
git clone --mirror $ghRemote $ghClonePath
```

**3.2.3 — Run git-filter-repo**
```powershell
git filter-repo --replace-text "expressions-dummy-secret.txt" --force
```

What this does:
- Walks through **every commit** in **every branch**
- For each file in each commit, performs string replacement
- `Eby8vdM02xNOcqFeqCnfFm==EXAMPLEKEY==` → `${{ secrets.AZURE_STORAGE_KEY }}`
- Creates new commit objects with the cleaned content
- Old commit hashes are replaced with new ones

**3.2.4 — Verify Scrub**
```powershell
git log --all -p --format="" | Select-String -SimpleMatch $checkSecret -Quiet
```
- Searches the ENTIRE history (all branches, all commits) for the first secret
- If found → **CRITICAL ERROR**, push is aborted
- If not found → **PASSED**, safe to push

**3.2.5 — Handle Branch Protection**
```powershell
# Check if default branch is protected
gh api "repos/$GHOrg/$GitHub_Repo/branches/$defaultBranch/protection"

# If protected, temporarily remove (force-push would be blocked otherwise)
gh api "repos/$GHOrg/$GitHub_Repo/branches/$defaultBranch/protection" -X DELETE
```

**3.2.6 — Force-Push Clean History**
```powershell
git push --force --mirror $ghRemote
```
- Replaces ALL refs (branches, tags) on GitHub with the scrubbed versions
- Old commits (with secrets) are overwritten
- PRs and Issues are preserved (they're GitHub database records, not git objects)

---

## Security Considerations

### Temporary Secret Exposure Window

```
Timeline:
  T=0 min    GEI completes      → Secrets ARE on GitHub
  T=1 min    Clone completes    → Local copy ready
  T=2 min    Scrub completes    → Local copy clean
  T=3 min    Force-push done    → GitHub is clean
```

- Secrets exist on GitHub for approximately **2-5 minutes**
- GitHub Secret Scanning may create alerts during this window
- Alerts auto-resolve after the force-push removes the secrets
- This is the **only** way to preserve PRs/Issues while scrubbing

### Why Push Protection Doesn't Block GEI

| Operation | Mechanism | Push Protection Applies? |
|-----------|-----------|--------------------------|
| GEI import | GitHub Migration API | ❌ No |
| Force-push (clean code) | `git push` | ✅ Yes, but code is clean — no secrets to detect |

### Post-Migration Actions

After migration completes:
1. **Verify** the GitHub repo shows placeholders instead of secret values
2. **Check** GitHub Security tab — any secret scanning alerts should auto-close
3. **Re-enable** branch protection if it was temporarily removed
4. **Rotate** all discovered credentials (use `credential-rotation-checklist.csv`)
5. **Provision** GitHub Secrets via `create-github-secrets.ps1` (uses `secret-values.json`)

---

## File Reference

| File | Location | Purpose |
|------|----------|---------|
| `gitleaks.toml` | `config/` | Custom secret detection rules |
| `scan-secrets.ps1` | `01-discover/` | Scans ADO repos for secrets |
| `scrub-secrets.ps1` | `02-prep/` | Generates replacement rules |
| `migrate-single.ps1` | `03-migrate/` | GEI migration + post-migration scrub |
| `create-github-secrets.ps1` | `03-migrate/` | Provisions GitHub Secrets from `secret-values.json` |
| `azure-pipeline.yaml` | Root | Orchestrates all stages |
| `repo-migration-config.json` | `config/` | Pipeline configuration |

---

## Troubleshooting

### Expressions file not found in migration stage
- **Cause:** Artifact download path mismatch
- **Fix:** Check `EXPRESSIONS_DIR` env var points to `output/scrub-artifacts/`
- **Verify:** Look for "Validate expressions file exists" step in pipeline logs

### git-filter-repo not found
- **Cause:** Python or pip not available on build agent
- **Fix:** Ensure `pip install git-filter-repo` runs in the "Install GitHub CLI" step

### Force-push rejected
- **Cause:** Branch protection rules on the GitHub repo
- **Fix:** Script auto-disables protection; check if PAT has `admin:org` scope

### Secrets still visible after migration
- **Cause:** Expressions file was empty or not found (scrub was skipped)
- **Fix:** Check ScrubSecrets stage logs for "No secrets found" or "No actionable secrets"

### BOM encoding issues
- **Cause:** Windows PowerShell adds BOM to UTF-8 files
- **Fix:** Already handled — uses `[System.IO.File]::WriteAllLines()` instead of `Set-Content`
