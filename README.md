# 🔄 GitHub Mannequin Reclaim Automation

This repository contains the automated pipeline for reclaiming "Mannequins" (unclaimed identity placeholders) generated during an Azure DevOps (ADO) to GitHub migration using the GitHub Enterprise Importer (GEI).

## 📋 Overview

During a migration, GitHub attributes ADO history (commits, PRs, comments) to placeholder accounts called mannequins. This pipeline automates the process of mapping those ADO identities to real GitHub users and sending bulk reclaim invitations.

**Key Features:**
- 🧠 **Smart Mapping**: Automatically matches users based on email, username, display name, or email prefix.
- 🛡️ **Safe Execution**: Includes a Dry-Run mode and a manual Review Gate to preview mappings before sending invites.
- ⚡ **Bulk Processing**: Uses GEI's CSV bulk processing to efficiently invite hundreds of users simultaneously.

---

## 🏗️ Pipeline Architecture

The pipeline (`azure-pipeline-reclaim.yaml`) is divided into three distinct stages:

### 1. 🔍 Stage 1: Discover & Map
- Fetches all current mannequins from the target GitHub organization.
- Cleans and parses the `user-mappings.csv` file.
- Applies the matching algorithm to pair mannequins with target GitHub users.
- Generates a visual Markdown preview and a prepared `reclaim-input.csv`.

### 2. 🛑 Stage 2: Review Gate
- Pauses pipeline execution (if run in `Execute` mode).
- Displays the generated mapping table in the Azure DevOps **Summary Tab**.
- Waits for an Administrator to review the mappings and click **Approve** or **Reject**.

### 3. 🚀 Stage 3: Execute Reclaim
- Downloads the validated `reclaim-input.csv`.
- Executes the `gh ado2gh reclaim-mannequin --csv` command.
- Sends official GitHub email invitations to all successfully mapped users.

---

## 🛠️ Prerequisites

Before running the pipeline, ensure the following requirements are met:

1. **Target Users Must Be Members**: The mapped `GitHubUsername` **MUST** belong to a user who has already accepted an invitation to the target GitHub Organization.
2. **Permissions**: The Service Connection / PAT (`GH_PAT`) requires `admin:org` permissions to list mannequins and send invites.
3. **Configuration File**: The `user-mappings.csv` file must exist and be properly formatted.

---

## 🗺️ The Mapping Logic

The script uses a highly forgiving, 4-way matching engine to pair ADO mannequins with GitHub users. 

For every mannequin found, it checks `user-mappings.csv` in this order:
1. **Exact Email**: Matches `ADOEmail` (e.g., `user@company.com`).
2. **Exact Username**: Matches `ADOUsername` (e.g., `user.name`).
3. **Display Name**: Matches `ADODisplayName` (e.g., `User Name`).
4. **Email Prefix (Smart Match)**: Splits `ADOEmail` at the `@` and matches the prefix (e.g., `user.name` matches `user.name@company.com`).

*All matches ignore leading/trailing whitespace and are case-insensitive.*

---

## 📝 Configuration (`user-mappings.csv`)

File path: `repo-migration/config/user-mappings.csv`

The file must contain the following columns. Empty rows are safely ignored.

| ADOEmail | ADOUsername | ADODisplayName | GitHubUsername |
| :--- | :--- | :--- | :--- |
| `jane.doe@company.com` | `jane.doe` | `Jane Doe` | `janedoe-gh` |
| `john.smith@company.com`| `john.smith` | `John Smith` | `johnsmith99` |

> ⚠️ **CRITICAL:** The `GitHubUsername` column is where the invitation will be sent. It must be a 100% exact match to their actual GitHub handle.

---

## 🚀 How to Run

1. **Update Mappings**: Ensure `repo-migration/config/user-mappings.csv` is up to date.
2. **Trigger Pipeline**: Run `azure-pipeline-reclaim.yaml` from Azure DevOps.
3. **Select Mode**:
   - `DryRun`: Will only run Stage 1 and show you the table. No invites will be sent.
   - `Execute`: Will run Stage 1, pause at Stage 2, and execute Stage 3 after approval.
4. **Review**: Check the **Extensions / Summary** tab in the pipeline run to see the Markdown table.
   - Look for any ❌ `*** NO MAPPING ***` warnings.
5. **Approve**: If everything looks good, approve the Manual Validation task to send the invites.

---

## 🆘 Troubleshooting

### Error: `Target must be a member of the organization`
GitHub rejects the invitation because the user is not recognized as an active member.
- **Fix**: Verify the `GitHubUsername` has no typos. Ensure the user has logged into GitHub and *accepted* their organization invite.

### Error: `*** NO MAPPING ***` in preview
The script could not find the mannequin's name in your CSV.
- **Fix**: Check the pipeline logs for `[DEBUG] No match found for mannequin: 'NAME'`. Copy that exact `NAME` and paste it into the `ADOUsername` column of your `user-mappings.csv` for that user.

### Users not receiving emails
- **Check**: Did you use the `--force` flag? (The pipeline uses it by default). 
- **Check**: The invitation is sent to the primary email linked to their GitHub account, which might be their personal email. Tell them to check their GitHub notifications (bell icon).
