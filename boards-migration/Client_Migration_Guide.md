# Azure DevOps Boards to GitHub Migration: Executive Summary

> **Target Audience:** Senior Leadership, Project Managers, and Engineering Leads.
> **Scope:** High-level overview of the migration strategy, requirements, and platform differences.

---

## 1. Purpose
The purpose of this pipeline is to automate the migration of work items from Azure DevOps (ADO) Boards into GitHub Issues and GitHub Projects V2. 

The tool is designed to securely and accurately transfer your agile data—including descriptions, comments, fields, attachments, and parent-child hierarchies—while minimizing manual effort. It is built to be **idempotent**, meaning if the process is interrupted, it can safely resume exactly where it left off without duplicating data.

---

## 2. Prerequisites
Before initiating the migration, the following must be established:

**Infrastructure Setup:**
- **Target GitHub Repository:** An existing repository where issues will be created.
- **GitHub Project V2:** An Organization-level project board to track the work.

**Authentication & Security:**
- **ADO Personal Access Token (PAT):** Requires "Read" access to Work Items, Queries, Code, and Identities.
- **GitHub Personal Access Token (PAT):** Requires "Admin" or "Owner" access to the target Organization, Repository, and Project.
- **ADO Variable Group:** Both tokens must be securely stored in an ADO pipeline variable group named `boards-migration`.

---

## 3. Configuration Files (What They Do)
To ensure data maps correctly between the two distinct systems, the team must fill out configuration files located in the `config/` folder prior to running:

1. **`boards-migration-config.json` (Main Settings):** Defines the source (ADO org/project) and the target (GitHub org/repo/project). Also controls pipeline behaviors, like whether to do a "Dry Run" or migrate attachments.
2. **`user-mappings.json`:** Maps ADO user email addresses to GitHub usernames. This ensures work items remain assigned to the correct people.
3. **`status-mappings.json`:** Maps ADO workflow states (e.g., "Active", "Resolved") to specific GitHub Board columns (e.g., "In Progress", "Done").
4. **`workitem-type-mappings.json`:** Maps ADO item types (Epic, Bug, Task) to GitHub Labels (e.g., `type:epic`) along with their specific colors.
5. **`field-mappings.json`:** Determines which ADO custom fields (like Story Points or Priority) should be created as custom columns on the GitHub Project board.

---

## 4. Flow of the Pipeline
The automated migration runs in structured, sequential phases:

1. **Discover:** Scans the ADO source to count all work items, sprints, and states. Generates a pre-migration inventory report.
2. **Prepare:** Automatically configures the GitHub environment. It creates necessary labels, milestone (sprints), and custom project fields.
3. **Migrate (Core Engine):** 
   - **Pass 1:** Creates all GitHub issues, copies descriptions, comments, field data, and uploads attachments.
   - **Pass 2:** Reconstructs the Epic → Feature → Story → Task hierarchy by linking the new issues together using GitHub's Sub-issues feature.
4. **Validate:** Automatically compares the item count in ADO against the successfully created items in GitHub to verify zero data loss.
5. **Reconcile & Enrich:** Links any existing open GitHub Pull Requests to the newly migrated issues, and translates ADO "Related/Blocked" links into cross-reference comments.

---

## 5. Limitations of Our Pipeline
While highly automated, the pipeline has strict technical boundaries:

- **Attachment File Size:** GitHub's API enforces a strict ~25 MB limit for automated uploads. Files larger than this will be skipped and must be manually uploaded later (the issue itself will still migrate).
- **Issue Numbering:** GitHub automatically assigns sequential numbers to new issues. The original ADO ID cannot be preserved as the main GitHub Issue ID (it is instead saved in a custom "ADO ID" field for reference).
- **Historical Audit Trail:** The pipeline migrates the *current* state of the item and all its comments. The detailed, field-by-field revision history (e.g., who changed a status 3 months ago) is not migrated.
- **Test Management:** ADO Test Plans and Test Executions do not exist natively in GitHub. Test Cases are migrated as standard issues containing the test steps.

---

## 6. Risks of Migration

- **Rate Limiting Delays:** GitHub enforces an API limit of 5,000 requests per hour. For massive migrations (10,000+ items), the pipeline will hit this limit, automatically pause, and wait. This is safe, but means large migrations can take many hours to complete.
- **Hierarchy API (Beta):** GitHub's Sub-issues API is currently in Public Beta. Under heavy load, API errors may occasionally occur, which could result in a small number of parent-child links needing manual connection post-migration.
- **Unmapped Users:** If a team member is missing from the `user-mappings.json` file, their historical issues will be assigned to a default fallback user, resulting in a loss of precise assignment data.
- **Case-Sensitive Statuses:** If the column names provided in the config files do not *exactly* match the columns in the GitHub Project, the items will migrate but will not appear in the correct board columns.

---

## 7. Differences: Azure Boards vs. GitHub

A quick reference on how concepts translate between the two platforms:

| Feature Area | Azure DevOps Boards | GitHub Issues & Projects |
| :--- | :--- | :--- |
| **Work Item Types** | Strict built-in types (Epic, Feature, Bug, Task). | Everything is an "Issue." Types are denoted by **Labels** (e.g., `type:bug`). |
| **Hierarchy** | Rigid 4-level tree structure. | Flexible nesting using **Sub-issues**. |
| **Custom Data** | Hundreds of built-in system fields. | **Custom Fields** added specifically to the Project V2 view. |
| **Agile Sprints** | Iterations with built-in capacity and burndown. | **Milestones** with due dates (no native capacity tracking). |
| **Board Features** | Native swimlanes and WIP limits. | Highly customizable views, but **no swimlanes or WIP limits**. |
| **Queries** | Powerful, shareable WIQL queries. | **Project Filters** (can be bookmarked, but no complex query language). |
| **Test Plans** | Comprehensive native test suite. | **No native equivalent.** Requires third-party marketplace apps. |
