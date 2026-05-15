# Variable Secrets Migration

This folder contains Azure DevOps pipelines to migrate **Variable Groups** (variables and secrets) from Azure DevOps to GitHub Repository Variables/Secrets.

---

## 📁 Files

| File | Purpose |
|------|---------|
| `azure-pipelines.yml` | Main pipeline — migrates all non-secret variables from a specific or all ADO variable groups into GitHub Repository Variables |
| `azure-test.yml` | Test pipeline — migrates specific **secrets** from an ADO variable group into GitHub Repository Secrets |

---

## ⚙️ Prerequisites

### 1. ADO Variable Group: `DevOpsConfig`
Create this variable group in **ADO → Pipelines → Library** with the following variables:

| Variable Name | Type | Description |
|---|---|---|
| `Pat` | Secret | Azure DevOps PAT (scopes: Variable Groups - Read) |
| `Git_pat` | Secret | GitHub PAT (scopes: repo, secrets, variables) |
| `Organization` | Plain | ADO Organization name (e.g. `YashTech-DevOps`) |
| `Project` | Plain | ADO Project name (e.g. `YASH-DevOps-Serverless`) |
| `Owner` | Plain | GitHub Org/User name |
| `GH_Repository` | Plain | Default GitHub repo name (used in `All` mode) |

### 2. GitHub PAT Scopes Required
- `repo` — full repository access
- `secrets` — manage repository secrets
- `variables` — manage repository variables (Actions)

---

## 🚀 How to Run & Test

### Step 1 — Register Pipeline in ADO
1. Go to **ADO → Pipelines → New Pipeline**
2. Select **Azure Repos Git** → Choose `ADO_To_GHAS_Migration` repo
3. Select **Existing Azure Pipelines YAML file**
4. Path: `/variable-secrets-migration/azure-pipelines.yml`
5. Save (don't run yet)

### Step 2 — Test with `Specific` Mode (Recommended First Test)

Run the pipeline manually with these parameters:

| Parameter | Value |
|---|---|
| **Migration Strategy** | `Specific` |
| **Library Group Name** | Name of any ADO variable group you want to test (e.g. `group2`) |
| **GitHub Repo Name** | Your GitHub repo name (e.g. `migration`) |

**What to verify after run:**
- Go to **GitHub Repo → Settings → Secrets and Variables → Actions → Variables**
- You should see the non-secret variables from the chosen ADO group appear there

### Step 3 — Test with `All` Mode

Run the pipeline with:

| Parameter | Value |
|---|---|
| **Migration Strategy** | `All` |
| **Library Group Name** | *(ignored in All mode)* |
| **GitHub Repo Name** | *(ignored — uses `GH_Repository` from DevOpsConfig)* |

**What to verify:**
- All non-secret variables from all ADO groups (except `DevOpsConfig`) should appear in GitHub Variables

### Step 4 — Test Secrets Migration (`azure-test.yml`)

1. Register `azure-test.yml` as a separate pipeline
2. Run with:
   - **Library Group Name**: The ADO group that has your secret
   - **secretNames**: List of secret variable names (default: `sec`)
3. Verify in **GitHub Repo → Settings → Secrets and Variables → Actions → Secrets**

---

## 🔍 Expected Pipeline Logs

```
Processing Variable Group: MyGroup
Storing VAR1 as GitHub variable
Stored variable VAR1 in GitHub repository my-repo
Skipping secret SECRET_VAR
Skipped EMPTY_VAR (no value)
```

---

## ⚠️ Known Limitations

- **Secrets are skipped** in the main pipeline (`azure-pipelines.yml`) — use `azure-test.yml` for secrets
- The `DevOpsConfig` group is always excluded from `All` mode migration
- GitHub PAT must have write access to the target repository
