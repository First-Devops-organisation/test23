# Enterprise Variable & Secrets Migration Guide

This document provides a high-level overview of the automated pipeline built to discover, map, and migrate Azure DevOps (ADO) Variable Groups and Secrets to GitHub Actions.

---

## 🔑 Prerequisites

Before running the migration pipeline, ensure the following requirements are met:

### 1. Security & Token Permissions
*   **ADO Personal Access Token (PAT)**: Requires **Read** access for *Variable Groups*, *Builds* (to discover pipeline definitions), and *Pipeline Permissions*.
*   **GitHub Personal Access Token (PAT)**: Requires write access for **Repos**, **Actions** (to manage variables and secrets), and **Admin Org** (if migrating to Organization-level scopes).
*   **ADO DevOpsConfig Group**: A variable group named `DevOpsConfig` must exist in ADO containing:
    *   `Pat` (ADO Secret PAT)
    *   `Git_pat` (GitHub Secret PAT)
    *   `Organization` (ADO Org Name)
    *   `Project` (ADO Project Name)

### 2. Infrastructure
*   **Target Repositories**: All destination GitHub repositories specified in the configuration mapping must already be created in your GitHub organization.
*   **Target Environments**: If migrating secrets or variables to specific environments (e.g., `dev`, `production`), those environments must be manually created in the respective GitHub repositories before running the migration.

---

## 📂 Folder Structure

```
enterprise-variable-migration/
│
├── enterprise-variable-migration-pipeline.yml   # The main ADO Orchestrator pipeline
│
├── 01-discover/
│   └── discover-variable-usage.ps1              # Phase 1: Scans ADO and suggests mappings
│
├── config/
│   └── variable-mappings.json                   # Single Source of Truth mapping configuration
│
└── 03-migrate/
    └── migrate-variables.ps1                    # Phase 2: Variable migration script
```

---

## 🔄 High-Level Pipeline Workflow

The migration runs in **three distinct phases** within a single pipeline:

```
  ┌────────────────────────┐
  │   Phase 1: Discovery   │  ← Scans ADO and suggests repo mappings
  └───────────┬────────────┘
              ▼
  ┌────────────────────────┐
  │   Review & Configure   │  ← Commit mapping selections to JSON
  └───────────┬────────────┘
              ▼
  ┌────────────────────────┐
  │   Phase 2: Variables   │  ← Migrates plain variables to GitHub (Org/Repo/Env)
  └───────────┬────────────┘
              ▼
  ┌────────────────────────┐
  │    Phase 3: Secrets    │  ← Decrypts and pushes secrets to GitHub
  └────────────────────────┘
```

1.  **Phase 1 (Discovery)**: Identifies all ADO variable groups, maps which ADO pipelines and repos utilize them, and compiles a CSV report and a JSON template.
2.  **Phase 2 (Variables)**: Reads your JSON config and creates or updates non-secret variables in GitHub at the specified target scope (Organization, Repository, or Environment).
3.  **Phase 3 (Secrets)**: Leverages ADO runtime bindings to decrypt secrets and securely uploads them as encrypted secrets to GitHub. Key Vault-linked groups are automatically held and bypassed with clear warnings.

---

## 📝 How to Map the JSON Configuration

After running Phase 1, download the generated CSV report and JSON template. 

### 1. Using the CSV Report to Plan
The CSV spreadsheet (`VariableGroup-Usage-Report.csv`) lists:
*   Every variable group name.
*   Which pipeline runs utilize it.
*   Which repositories those pipelines belong to.

Use this usage information to determine where each group should land in GitHub.

### 2. Filling out `variable-mappings.json`
For each group in the JSON array, configure the following keys:

| Key | Expected Values | Description |
| :--- | :--- | :--- |
| **`action`** | `"migrate"`, `"skip"`, `"keyvault-hold"` | `"migrate"` processes the group. `"skip"` ignores it. Key Vault groups are marked `"keyvault-hold"`. |
| **`targetScope`** | `"organization"`, `"repository"`, `"environment"` | Scope level in GitHub. |
| **`targetRepo`** | Repo name (e.g., `my-app`) | Target repository (can be a comma-separated list for multiple repos). Leave blank for Organization scope. |
| **`targetEnvironment`** | Environment name (e.g., `production`) | Target environment name (only required if `targetScope` is set to `"environment"`). |

---

## 📊 Verification and Auditing

Once the migration run (Phase 2 and 3) completes, you can verify success using:

1.  **Migration Dashboard (`Migration-Dashboard.md`)**: A pipeline summary artifact listing every variable name, target scope, destination repository, and migration status (✅ Success or ⚠️ Warning).
2.  **Summary CSV (`Migration-Summary.csv`)**: A spreadsheet version of the dashboard for record keeping.
3.  **GitHub Settings UI**:
    *   **Org Scope**: Org Settings ➔ Secrets and variables ➔ Actions.
    *   **Repo Scope**: Repo Settings ➔ Secrets and variables ➔ Actions.
    *   **Env Scope**: Repo Settings ➔ Environments ➔ Choose Environment.
