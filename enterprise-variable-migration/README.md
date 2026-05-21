# Enterprise Variable & Secrets Migration

Migrate **Azure DevOps Variable Groups** (variables and secrets) to GitHub Actions — at the right scope.

Unlike a simple script that dumps everything into one place, this pipeline intelligently maps each ADO Variable Group to the correct GitHub scope:
- **Organization-level** variables/secrets (shared across all repos)
- **Repository-level** variables/secrets (specific to one repo)
- **Environment-level** variables/secrets (e.g. dev, staging, production)

---

## 📋 Table of Contents

1. [How It Works — Big Picture](#how-it-works--big-picture)
2. [Prerequisites](#prerequisites)
3. [Folder Structure](#folder-structure)
4. [Step-by-Step Guide](#step-by-step-guide)
   - [Step 1 — Run Phase 1: Discovery](#step-1--run-phase-1-discovery)
   - [Step 2 — Fill in the JSON Mapping File](#step-2--fill-in-the-json-mapping-file)
   - [Step 3 — Run Phase 2 + Phase 3 Together](#step-3--run-phase-2--phase-3-together)
5. [How to Fill the JSON Mapping File](#how-to-fill-the-json-mapping-file)
   - [JSON Fields Explained](#json-fields-explained)
   - [action: migrate vs skip](#action-migrate-vs-skip)
   - [targetScope: organization vs repository vs environment](#targetscope-organization-vs-repository-vs-environment)
   - [Complete JSON Examples](#complete-json-examples)
6. [Understanding the Pipeline Phases](#understanding-the-pipeline-phases)
7. [Variables vs Secrets — How Each is Handled](#variables-vs-secrets--how-each-is-handled)
8. [Key Vault-Linked Groups](#key-vault-linked-groups)
9. [Re-Running the Pipeline](#re-running-the-pipeline)
10. [Troubleshooting](#troubleshooting)

---

## How It Works — Big Picture

```
 ADO Variable Groups
 ┌────────────────────────────────────────────────────────────┐
 │  group: "MyAppConfig"   Variables: DB_HOST, DB_PORT        │
 │  group: "MyAppSecrets"  Secrets:   DB_PASSWORD, API_KEY    │
 │  group: "kv-app-prod"   KV-Linked: fetched from Key Vault  │
 └────────────────────────────────────────────────────────────┘
                     │
          ┌──────────▼──────────┐
          │   PHASE 1           │
          │   Discovery         │  ← Scans ADO, generates CSV + JSON template
          └──────────┬──────────┘
                     │
          ┌──────────▼──────────┐
          │   YOU               │  ← Edit variable-mappings.json
          │   Fill the JSON     │    Tell the pipeline WHERE each group goes
          └──────────┬──────────┘
                     │
          ┌──────────▼──────────┐
          │   PHASE 2           │  ← Reads JSON → pushes all non-secret
          │   Variables         │    variables to GitHub (Org/Repo/Env)
          └──────────┬──────────┘
                     │
          ┌──────────▼──────────┐
          │   PHASE 3           │  ← Pushes all secrets to GitHub
          │   Secrets           │    (regular + Key Vault-linked groups)
          └─────────────────────┘
                     │
             GitHub Actions
 ┌────────────────────────────────────────────────────────────┐
 │  Org Variables  │  Repo Variables  │  Env Variables        │
 │  Org Secrets    │  Repo Secrets    │  Env Secrets          │
 └────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

### 1. ADO Variable Group: `DevOpsConfig`
Create this variable group in **ADO → Pipelines → Library** with:

| Variable Name | Type   | Value                                      |
|:---|:---|:---|
| `Pat`         | Secret | Your ADO Personal Access Token (PAT)       |
| `Git_pat`     | Secret | Your GitHub Personal Access Token (PAT)    |
| `Organization`| Plain  | ADO Org name (e.g. `YashTech-DevOps`)      |
| `Project`     | Plain  | ADO Project name (e.g. `YASH-DevOps`)      |

### 2. ADO PAT Scopes Required
- `Variable Groups` — **Read**
- `Build` — **Read** (to map pipelines to repos)
- `Pipeline Permissions` — **Read**

### 3. GitHub PAT Scopes Required
- `repo` — full repository access
- `actions:write` — manage Actions secrets & variables
- `admin:org` — manage organization-level secrets & variables

### 4. Register the Pipeline in ADO
1. Go to **ADO → Pipelines → New Pipeline**
2. Select **Azure Repos Git** → choose your repo
3. Select **Existing Azure Pipelines YAML file**
4. Path: `/enterprise-variable-migration/enterprise-variable-migration-pipeline.yml`
5. Save (don't run yet)

---

## Folder Structure

```
enterprise-variable-migration/
│
├── enterprise-variable-migration-pipeline.yml  ← Main pipeline (run this)
│
├── 01-discover/
│   └── discover-variable-usage.ps1             ← Phase 1 script
│
├── config/
│   └── variable-mappings.json                  ← YOU EDIT THIS (the mapping file)
│
├── 03-migrate/
│   └── migrate-variables.ps1                   ← Phase 2 script
│
└── README.md                                   ← This file
```

---

## Step-by-Step Guide

### Step 1 — Run Phase 1: Discovery

Run the pipeline with **only Phase 1 enabled**:

| Parameter | Value |
|:---|:---|
| Run Phase 1: Discovery | ✅ **True** |
| Run Phase 2: Variables | ❌ False |
| Run Phase 3: Secrets   | ❌ False |

**What happens:**
- The script calls the ADO REST API to find every Variable Group
- It checks which pipelines use each group, and which repo each pipeline belongs to
- It outputs two files as pipeline **artifacts** you can download

**Download these two artifacts after the run:**

| Artifact Name | What it Contains |
|:---|:---|
| `VariableGroup-Mapping-CSV` | Spreadsheet showing every group → pipeline → repo mapping |
| `VariableGroup-Mapping-JSON` | Pre-filled JSON template for the next step |

> **Tip:** Open the CSV first to understand your current ADO setup before editing the JSON.

---

### Step 2 — Fill in the JSON Mapping File

1. Download the `VariableGroup-Mapping-JSON` artifact
2. Open `variable-mappings.json` (found in `config/` folder in the repo)
3. For each variable group, decide:
   - Should it be **migrated** or **skipped**?
   - Where should it land — **org**, **repo**, or **environment**?
4. Edit the JSON accordingly (see [How to Fill the JSON Mapping File](#how-to-fill-the-json-mapping-file) below)
5. **Commit** the updated `variable-mappings.json` back to the repo

---

### Step 3 — Run Phase 2 + Phase 3 Together

Run the pipeline with **Phase 2 AND Phase 3 both enabled**:

| Parameter | Value |
|:---|:---|
| Run Phase 1: Discovery | ❌ False |
| Run Phase 2: Variables | ✅ **True** |
| Run Phase 3: Secrets   | ✅ **True** |

**What happens:**
- **Phase 2** reads your `variable-mappings.json` and pushes all non-secret variables to GitHub at the correct scope
- **Phase 3** pushes all secrets (including Key Vault-linked ones) to GitHub Secrets

**After the run, verify in GitHub:**
- Variables: **Repo → Settings → Secrets and Variables → Actions → Variables tab**
- Secrets: **Repo → Settings → Secrets and Variables → Actions → Secrets tab**
- Environment secrets: **Repo → Settings → Environments → [env name] → Secrets**

**Download the `Migration-Dashboard` artifact** — it contains a full table of every variable and its migration status (✅ Success / ❌ Error).

---

## How to Fill the JSON Mapping File

The file `config/variable-mappings.json` is the **single source of truth** for the migration. It tells the pipeline exactly what to do with each ADO variable group.

### JSON Fields Explained

```json
{
  "adoGroupName": "MyAppConfig",
  "action": "migrate",
  "targetScope": "repository",
  "targetRepo": "my-github-repo",
  "targetEnvironment": "",
  "notes": "Optional — explain your decision here"
}
```

| Field | Required | Description |
|:---|:---|:---|
| `adoGroupName` | ✅ Yes | Exact name of the ADO Variable Group (case-sensitive) |
| `action` | ✅ Yes | `"migrate"` to push to GitHub, `"skip"` to ignore |
| `targetScope` | ✅ Yes | Where in GitHub: `"organization"`, `"repository"`, or `"environment"` |
| `targetRepo` | Depends | GitHub repo name (required for `repository` and `environment` scopes) |
| `targetEnvironment` | Depends | GitHub environment name (required for `environment` scope only) |
| `notes` | ❌ No | Optional comment — use it to explain why you made a decision |

---

### `action`: migrate vs skip

| Value | What it does |
|:---|:---|
| `"migrate"` | ✅ This group will be migrated to GitHub |
| `"skip"` | ⏭️ This group will be completely ignored — nothing happens |

**When to use `"skip"`:**
- The group is unused (no pipelines use it)
- The group is a duplicate or test group
- The group's target repo doesn't exist in GitHub yet
- The Key Vault it's linked to is deleted or unreachable

```json
{ "adoGroupName": "OldTestGroup", "action": "skip", "notes": "Unused — no pipelines reference this" }
```

---

### `targetScope`: organization vs repository vs environment

#### `"organization"` — Shared across ALL repos in the GitHub Org
Use this when the variable group is used by **multiple different repositories**.

```json
{
  "adoGroupName": "SharedInfraConfig",
  "action": "migrate",
  "targetScope": "organization",
  "targetRepo": "",
  "targetEnvironment": ""
}
```
→ Variables land in: **GitHub Org → Settings → Secrets and Variables → Actions**

---

#### `"repository"` — Specific to ONE GitHub repo
Use this when the variable group is only used by pipelines in a single repository.

```json
{
  "adoGroupName": "MyAppConfig",
  "action": "migrate",
  "targetScope": "repository",
  "targetRepo": "my-github-repo",
  "targetEnvironment": ""
}
```
→ Variables land in: **my-github-repo → Settings → Secrets and Variables → Actions**

---

#### `"environment"` — Specific to ONE environment inside a repo
Use this when the variable group is environment-specific (e.g. only used in Production pipelines). The GitHub Environment must already exist in the target repo.

```json
{
  "adoGroupName": "MyApp-Prod-Config",
  "action": "migrate",
  "targetScope": "environment",
  "targetRepo": "my-github-repo",
  "targetEnvironment": "production"
}
```
→ Variables land in: **my-github-repo → Settings → Environments → production**

> ⚠️ **Important:** The environment (`production`, `dev`, `staging`, etc.) must already be created in the GitHub repository before running the migration. Go to: **Repo → Settings → Environments → New environment**.

---

### Complete JSON Examples

#### Example 1 — Simple app with dev and prod environments
```json
{
  "_comment": "My App Migration Config",
  "targetGitHubOrg": "MyGitHubOrg",
  "variableGroups": [
    {
      "adoGroupName": "MyApp-Common",
      "action": "migrate",
      "targetScope": "repository",
      "targetRepo": "my-app",
      "targetEnvironment": "",
      "notes": "Common non-env config used by all pipelines"
    },
    {
      "adoGroupName": "MyApp-Dev",
      "action": "migrate",
      "targetScope": "environment",
      "targetRepo": "my-app",
      "targetEnvironment": "dev",
      "notes": "Dev environment variables and secrets"
    },
    {
      "adoGroupName": "MyApp-Prod",
      "action": "migrate",
      "targetScope": "environment",
      "targetRepo": "my-app",
      "targetEnvironment": "production",
      "notes": "Production secrets — KV-linked group"
    },
    {
      "adoGroupName": "OldGroup-DoNotUse",
      "action": "skip",
      "targetScope": "repository",
      "targetRepo": "",
      "targetEnvironment": "",
      "notes": "Deprecated — no pipelines use this anymore"
    }
  ]
}
```

#### Example 2 — Shared infrastructure group (org-level)
```json
{
  "adoGroupName": "GlobalInfraSecrets",
  "action": "migrate",
  "targetScope": "organization",
  "targetRepo": "",
  "targetEnvironment": "",
  "notes": "Used by 5+ repos — goes to org level"
}
```

#### Example 3 — Multiple repos (comma-separated)
If an ADO group is used by two repos and you want to push to both:
```json
{
  "adoGroupName": "SharedApiConfig",
  "action": "migrate",
  "targetScope": "repository",
  "targetRepo": "repo-one, repo-two",
  "targetEnvironment": ""
}
```

---

## Understanding the Pipeline Phases

### Phase 1 — Discovery
**File:** `01-discover/discover-variable-usage.ps1`

| What it does | Detail |
|:---|:---|
| Fetches all Variable Groups | Calls ADO REST API |
| Maps groups to pipelines | Checks pipeline permissions for each group |
| Maps pipelines to repos | Looks up which repo each pipeline belongs to |
| Guesses the right scope | If group is used by 1 repo → suggests `repository`; by multiple → suggests `organization`; if name ends in `-dev`/`-prod` → suggests `environment` |
| Outputs CSV | Full mapping report for your review |
| Outputs JSON template | Pre-filled starting point for `variable-mappings.json` |

> ⚠️ The auto-generated JSON sets all actions to `"skip"` by default for safety. You must manually change the ones you want to `"migrate"`.

---

### Phase 2 — Variable Migration
**File:** `03-migrate/migrate-variables.ps1`

Reads `variable-mappings.json` and for each group marked `"migrate"`:

| Feature | How it works |
|:---|:---|
| Non-secret variables | Pushed to GitHub using `gh variable set` |
| Secrets | Skipped in Phase 2 — handled in Phase 3 |
| Empty values | Skipped automatically |
| Name collisions | If two groups have the same variable name going to the same scope, it prefixes the second one with the group name (e.g. `GroupName_VariableName`) |
| Reserved names | Variables starting with `GITHUB_` are renamed to `GIT_` (GitHub API requirement) |
| Upsert logic | If a variable already exists in GitHub → it is **updated**, not duplicated |
| Dashboard | Generates `Migration-Dashboard.md` and `Migration-Summary.csv` as artifacts |

---

### Phase 3 — Secrets Migration
**File:** `enterprise-variable-migration-pipeline.yml` (Phase 3 stage)

Because the ADO REST API **never exposes secret values**, Phase 3 uses a different approach:
- Each ADO Variable Group is **declared directly in the YAML** as `- group: 'GroupName'`
- The ADO agent **decrypts and injects** the secret values at job runtime
- The PowerShell script reads `$(SECRET_NAME)` and pushes it to GitHub using `gh secret set`

For **Key Vault-linked groups**, the same mechanism applies:
- ADO calls Azure Key Vault using its Service Connection at job start
- The secret value is injected into the job environment
- The script pushes it to GitHub Secrets

> ℹ️ **Why does each group need its own job?**
> ADO has a security requirement: variable groups must be declared in the YAML at **parse time** (before the pipeline runs). They cannot be dynamically loaded at runtime. This is why Phase 3 has one job per variable group — it's a mandatory ADO security architecture, not a design choice.

---

## Variables vs Secrets — How Each is Handled

| Type | ADO Field | Phase 2 (Variables) | Phase 3 (Secrets) |
|:---|:---|:---|:---|
| Plain variable | `isSecret: false` | ✅ Migrated | ⏭️ Skipped |
| Secret variable | `isSecret: true` | ⏭️ Skipped (API hides value) | ✅ Migrated via YAML binding |
| Key Vault secret | KV-linked group | ⏭️ Skipped | ✅ Migrated via KV runtime fetch |
| Empty variable | value = `""` | ⏭️ Skipped | ⏭️ Skipped |

---

## Key Vault-Linked Groups

ADO variable groups can be **linked to Azure Key Vault** — the secrets are stored in Azure Key Vault, not in ADO. When a pipeline runs, ADO fetches the values from Key Vault automatically.

In Phase 3, these groups are handled the same way as regular secrets — declare the group in YAML, and ADO fetches from Key Vault at runtime.

**Common failure: `ENOTFOUND <vaultname>.vault.azure.net`**

This means the Key Vault itself **does not exist** at that DNS address. Possible causes:
- The vault was **deleted** (check Azure Portal → Key Vaults → Deleted vaults for soft-delete recovery)
- The vault was **renamed** — update the variable group in ADO Library to point to the new name
- Wrong **subscription** — the pipeline's service connection may not have access

KV jobs in Phase 3 use `continueOnError: true` — if a vault is unreachable, that job will show as ⚠️ (warning/partially succeeded) without blocking the rest of the stage.

---

## Re-Running the Pipeline

The pipeline is **fully idempotent** — safe to run multiple times:

| Scenario | What happens |
|:---|:---|
| Variable already exists in GitHub | **Updated** with the current ADO value |
| Secret already exists in GitHub | **Overwritten** with the current ADO value |
| New group added to ADO | Run Phase 1 again → update JSON → re-run Phase 2+3 |
| Partial failure on first run | Just re-run — successful items update in place, failed items retry |

**Quick re-run guide:**

| What changed | Run |
|:---|:---|
| New ADO variable groups added | Phase 1 → update JSON → Phase 2 + 3 |
| JSON mapping updated only | Phase 2 + Phase 3 (skip Phase 1) |
| Only secret values rotated in ADO | Phase 3 only |
| Only variable values changed in ADO | Phase 2 only |

---

## Troubleshooting

### ❌ Phase 2 fails — "404 Not Found" for a variable
**Cause:** The GitHub repository name in `variable-mappings.json` doesn't exist or is spelled incorrectly.
**Fix:** Check `targetRepo` matches the exact GitHub repo name (case-sensitive).

### ❌ Phase 2 fails — "422 Unprocessable Entity"
**Cause:** The variable name contains invalid characters (e.g. hyphens). GitHub variable names only allow letters, numbers, and underscores.
**Fix:** The migration script auto-sanitizes names — if you still see this, check for unusual characters in your ADO variable names.

### ❌ Phase 3 fails — Secret shows as empty in GitHub
**Cause:** The ADO agent could not decrypt the secret (permissions issue) or the Key Vault was unreachable.
**Fix:** Ensure the pipeline service account has `Library → Read` permissions in ADO, and the Key Vault service connection has `Key Vault Secrets User` role in Azure.

### ❌ Phase 3 — `ENOTFOUND <vault>.vault.azure.net`
**Cause:** The linked Azure Key Vault does not exist at that URL.
**Fix:**
1. Go to **Azure Portal → Key Vaults** and search for the vault name
2. Check **Deleted vaults** tab — it may be soft-deleted and recoverable
3. If renamed, update the variable group in **ADO → Pipelines → Library**
4. If permanently gone, set the group to `"action": "skip"` in your JSON

### ❌ Environment secrets not appearing in GitHub
**Cause:** The GitHub Environment doesn't exist yet.
**Fix:** Go to **GitHub Repo → Settings → Environments → New environment** and create it before running the migration.

### ⚠️ Variable name collision warning in the dashboard
**Cause:** Two different ADO groups have a variable with the same name being pushed to the same GitHub scope.
**Fix:** This is auto-handled — the second variable is prefixed with the group name. Review the `Migration-Dashboard` artifact to confirm the final names.
