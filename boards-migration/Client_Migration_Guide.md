# Azure DevOps Boards → GitHub Migration: Complete Client Guide

> **Version:** 1.0 | **Audience:** Client Stakeholders, Project Managers, DevOps Engineers

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Pipeline Architecture & Flow](#2-pipeline-architecture--flow)
3. [Prerequisites Before Running the Pipeline](#3-prerequisites-before-running-the-pipeline)
4. [Config Files: What to Fill In](#4-config-files-what-to-fill-in)
5. [Token Permissions Required](#5-token-permissions-required)
6. [Step-by-Step Pre-Run Checklist](#6-step-by-step-pre-run-checklist)
7. [Limitations & Known Risks](#7-limitations--known-risks)
8. [What the Pipeline Cannot Do](#8-what-the-pipeline-cannot-do)
9. [Full Feature Comparison: ADO Boards vs GitHub](#9-full-feature-comparison-ado-boards-vs-github)

---

## 1. Executive Summary

This pipeline is an automated, end-to-end migration tool that moves your entire Azure DevOps (ADO) Boards — including all Work Items, hierarchies, comments, attachments, sprints, and custom fields — into GitHub Issues and GitHub Projects V2.

The pipeline is built to be **safe, resumable, and idempotent**. This means:
- If a run is interrupted (network failure, rate limit), you can simply re-run it and it will pick up exactly where it left off without creating duplicates.
- All migrations are logged to `migration-log.json` which acts as the pipeline's memory across runs.
- A Dry Run mode allows you to validate all mappings and see what would happen before any real data is written.

---

## 2. Pipeline Architecture & Flow

The pipeline runs as a **multi-stage Azure DevOps CI/CD pipeline** with 4 stages (6 logical phases):

```
┌──────────────────────────────────────────────────────────────┐
│                    PIPELINE TRIGGER (Manual)                 │
└──────────────────────────┬───────────────────────────────────┘
                           │
           ┌───────────────▼───────────────┐
           │     STAGE 1: DISCOVER         │
           │  Phase 1 – Analyze ADO data   │
           │  • Count all work items       │
           │  • Read all sprints           │
           │  • Read all workflow states   │
           │  • Generate setup guide       │
           └───────────────┬───────────────┘
                           │
           ┌───────────────▼───────────────┐
           │     STAGE 2: PREPARE          │
           │  Phase 2 – Configure GitHub   │
           │  • Create labels (type/prio)  │
           │  • Create milestones (sprints)│
           │  • Validate all mappings      │
           │  • Deploy workflow rules      │
           └───────────────┬───────────────┘
                           │
           ┌───────────────▼───────────────┐
           │   [MANUAL APPROVAL GATE]      │  ← Human reviews
           │  Review reports & approve     │    reports before
           │  before live migration starts │    migration runs
           └───────────────┬───────────────┘
                           │
           ┌───────────────▼───────────────┐
           │     STAGE 3: MIGRATE          │
           │  Phase 3 – Core Migration     │
           │  • Snapshot ADO (backup)      │
           │  • Create GitHub Issues       │
           │  • Migrate comments           │
           │  • Migrate attachments        │
           │  • Link Sub-issues (hierarchy)│
           │  Phase 5 – PR Reconcile       │
           │  • Link existing PRs to issues│
           │  Phase 6 – Enrich             │
           │  • Add Related/Blocked links  │
           │  • Translate saved queries    │
           │  • Generate Roadmap           │
           └───────────────┬───────────────┘
                           │
           ┌───────────────▼───────────────┐
           │     STAGE 4: VALIDATE         │
           │  Phase 4 – Zero-Loss Audit    │
           │  • Compare ADO count vs GH    │
           │  • Validate fields & comments │
           │  • Generate summary report    │
           └───────────────────────────────┘
```

### Resume / Incremental Mode
If the pipeline is interrupted, re-run it with **Resume = true** (default). The pipeline will:
1. Download the `migration-log.json` from the last successful run
2. Skip all work items already present in the log
3. Only migrate new or missing items
4. Re-run the hierarchy linking pass to catch any new parent-child relationships

---

## 3. Prerequisites Before Running the Pipeline

### 3.1 GitHub Side — Must Be Set Up First

| # | What to Create | Where | Why |
| :--- | :--- | :--- | :--- |
| 1 | **GitHub Repository** | `github.com/{org}/{repo}` | All issues will be created here |
| 2 | **GitHub Project V2** | Organization-level (not repo-level) | The agile board where items will be tracked |
| 3 | **GitHub Organization** | Must exist before running | Pipeline creates labels and milestones at org/repo level |
| 4 | **Variable Group** in ADO | ADO → Pipelines → Library → `boards-migration` | Stores the two secret PATs |

### 3.2 Azure DevOps Side — Must Be Available

| # | What Is Needed | Details |
| :--- | :--- | :--- |
| 1 | **ADO Organization URL** | e.g., `https://dev.azure.com/YourOrg` |
| 2 | **ADO Project Name** | The exact project name in ADO |
| 3 | **ADO Area Path** | The area path to migrate (e.g., `MyProject\TeamA`) |
| 4 | **Sprint / Iteration Paths** | List of all sprint names used (e.g., `Sprint 1`, `Sprint 2`) |

### 3.3 Information Needed From Client Team

| # | Information | Format | Example |
| :--- | :--- | :--- | :--- |
| 1 | ADO user emails → GitHub usernames | JSON file | `"john@company.com": "john-gh"` |
| 2 | ADO state → GitHub board column | JSON file | `"Resolved": "Done"` |
| 3 | ADO area path → GitHub label | JSON file | `"Project\\TeamA": "area:team-a"` |
| 4 | ADO sprint path → GitHub milestone name | JSON file | `"Project\\Sprint 1": "Sprint 1"` |

---

## 4. Config Files: What to Fill In

All config files live in the `boards-migration/config/` directory. You must update these before running.

---

### 4.1 `boards-migration-config.json` — Main Config

This is the primary configuration file. Fill in the fields marked **← FILL THIS IN**.

```json
{
  "source": {
    "organization": "YourADOOrg",           ← FILL THIS IN
    "project": "YourADOProject",            ← FILL THIS IN
    "areaPath": "YourProject\\AreaPath",    ← FILL THIS IN (use \\ for backslash)
    "pat": "$(ADO_PAT)"                     ← DO NOT CHANGE (read from Variable Group)
  },
  "target": {
    "organization": "YourGitHubOrg",        ← FILL THIS IN
    "repository": "your-repo-name",         ← FILL THIS IN
    "projectNumber": 1,                     ← FILL THIS IN (the # from the Project URL)
    "projectOwnerType": "organization",     ← "organization" or "user"
    "pat": "$(GH_PAT)"                      ← DO NOT CHANGE (read from Variable Group)
  },
  "migration": {
    "migrateClosedWorkItems": true,         ← false = skip Closed/Resolved items
    "productionRun": true,                  ← false = dry run (no GitHub writes)
    "migrateAttachments": true,             ← false = skip file attachments
    "migrateLinks": true,                   ← false = skip Related/Blocked comments
    "preserveParentChild": true,            ← false = skip hierarchy linking
    "dryRun": false                         ← true = safe test mode
  }
}
```

---

### 4.2 `user-mappings.json` — Map ADO Users → GitHub Users

```json
{
  "john.doe@company.com":    "johndoe-github",
  "jane.smith@company.com":  "janesmith-github",
  "UNASSIGNED":              ""
}
```

> ⚠️ **Important:** If a user is not listed here, the issue will be created **unassigned**. No error will occur, but assignment data will be lost for that user.

---

### 4.3 `status-mappings.json` — Map ADO States → GitHub Board Columns

```json
{
  "statusMappings": {
    "Active":    "In progress",
    "New":       "Todo",
    "Resolved":  "Done",
    "Closed":    "Done",
    "Removed":   "Done",
    "In Review": "In progress"
  }
}
```

> ⚠️ **Important:** GitHub board column names are **case-sensitive**. They must exactly match the column names you created in your GitHub Project V2.

---

### 4.4 `workitem-type-mappings.json` — Map ADO Types → GitHub Labels

```json
{
  "Epic":              { "label": "type:epic",       "color": "8B00FF" },
  "Feature":           { "label": "type:feature",    "color": "0052CC" },
  "User Story":        { "label": "type:user-story", "color": "0075CA" },
  "Bug":               { "label": "type:bug",        "color": "D73A4A" },
  "Task":              { "label": "type:task",        "color": "E4E669" },
  "Impediment":        { "label": "type:impediment", "color": "B60205" }
}
```

---

### 4.5 `field-mappings.json` — Map ADO Custom Fields → GitHub Project Fields

Controls which ADO fields are preserved as custom columns on the GitHub Project board.

```json
{
  "storyPoints":  { "ghFieldName": "Story Points",  "type": "number"       },
  "priority":     { "ghFieldName": "Priority",      "type": "single_select" },
  "severity":     { "ghFieldName": "Severity",      "type": "single_select" },
  "adoStatus":    { "ghFieldName": "ADO Status",    "type": "single_select" },
  "adoId":        { "ghFieldName": "ADO ID",        "type": "text"          }
}
```

---

## 5. Token Permissions Required

### 5.1 Azure DevOps PAT (`ADO_PAT`)

| Scope | Permission | Why It's Needed |
| :--- | :--- | :--- |
| Work Items | **Read** | Fetch work items, comments, attachments |
| Queries | **Read** | Read saved queries for enrichment |
| Code | **Read** | Download attachment binaries from ADO URLs |
| Project and Team | **Read** | Read area paths and iteration paths |
| Identity | **Read** | Resolve user display names |

> **How to create:** ADO → User Settings → Personal Access Tokens → New Token → Select scopes above

---

### 5.2 GitHub PAT (`GH_PAT`)

| Scope | Permission | Why It's Needed |
| :--- | :--- | :--- |
| `repo` | **Full** | Create issues, upload attachments, manage labels |
| `project` | **Full** | Read and write to GitHub Project V2 board |
| `org:write` | **Write** | Create org-level project fields and milestones |
| `admin:org` | **Read** | Validate org membership for user assignments |

> **How to create:** GitHub → Settings → Developer Settings → Personal Access Tokens → Tokens (classic) → Select scopes above

> ⚠️ **Token must be from a user who is an Organization Owner or has admin access to the target repository and project.**

---

## 6. Step-by-Step Pre-Run Checklist

Complete these steps **in order** before triggering the migration pipeline.

### Step 1: GitHub Setup
- [ ] Create the **target GitHub Repository** (can be private)
- [ ] Create a **GitHub Project V2** at the **organization level** (not repo-level)
- [ ] Note down the **Project Number** (visible in the Project URL: `github.com/orgs/{org}/projects/NUMBER`)
- [ ] Add the repository to the GitHub Project

### Step 2: ADO Variable Group Setup
- [ ] In Azure DevOps, go to **Pipelines → Library → Variable Groups**
- [ ] Create a group named exactly: `boards-migration`
- [ ] Add secret variable: `ADO_PAT` (paste your ADO token, mark as secret)
- [ ] Add secret variable: `GH_PAT` (paste your GitHub token, mark as secret)
- [ ] Click **Save**

### Step 3: Fill in Config Files
- [ ] Fill in `boards-migration-config.json` with your org, project, and repo names
- [ ] Fill in `user-mappings.json` with all team member email → GitHub username pairs
- [ ] Fill in `status-mappings.json` ensuring names match your GitHub Project column names exactly
- [ ] Review `workitem-type-mappings.json` and add any custom ADO types your project uses

### Step 4: Run a Dry Run First
- [ ] Trigger the pipeline with **Dry Run = true** and **Phase = discover**
- [ ] Download the `discovery-reports` artifact after the run completes
- [ ] Review `workitem-inventory.json` — confirm the item count matches ADO
- [ ] Review any mapping warnings in the logs
- [ ] If satisfied, proceed to live migration

### Step 5: Live Migration
- [ ] Trigger the pipeline with **Dry Run = false**, **Resume = true**, **Phase = all**
- [ ] Monitor the **Approval Gate** step — a team member must manually approve before migration starts
- [ ] Monitor progress in the pipeline logs (approx. 30 seconds per work item due to rate limits)
- [ ] After completion, download and review the `final-reports` artifact

---

## 7. Limitations & Known Risks

### 7.1 Attachment Size Limit
- **Limit:** GitHub's REST API rejects file uploads larger than **~25 MB**
- **Impact:** Attachments above this size are skipped. The issue itself is always created successfully
- **What the pipeline does:** Logs a `⚠️ WARN` for each skipped file. You can find all skipped files by searching the pipeline log for `"Image migration FAILED"`
- **Manual resolution:** Large files must be uploaded manually to GitHub after migration

### 7.2 GitHub API Rate Limits
- **Limit:** GitHub allows 5,000 REST API requests per hour
- **Impact:** For large migrations (10,000+ items), the pipeline will pause mid-run
- **What the pipeline does:** Automatically detects the `HTTP 403 Secondary Rate Limit` response, pauses with exponential backoff (20s → 40s → 80s → 160s → 320s), then resumes
- **Estimated time for 14,000 items:** Approximately 18–24 hours of continuous running (with natural pauses)

### 7.3 ADO State "New" Not Mapped by Default
- **Issue:** ADO's default initial state `New` has no direct equivalent in many GitHub setups
- **Impact:** The pipeline logs a warning and leaves the status field blank on the GitHub board
- **Fix:** Add `"New": "Todo"` to your `status-mappings.json` before running

### 7.4 Sub-Issue Linking — Beta Feature
- **Risk:** GitHub's Sub-issues API (`addSubIssue` GraphQL mutation) is currently in **Public Beta**
- **Impact:** It may occasionally return errors under heavy API load
- **What the pipeline does:** Logs the error as a warning. The issues are still migrated; only the parent-child link is affected
- **Manual resolution:** Links can be verified and re-created manually after migration

### 7.5 No ADO Work Item History
- The pipeline does **not** migrate the full ADO change history / audit trail
- Only the current field values and comments are migrated

---

## 8. What the Pipeline Cannot Do

| Feature | Reason |
| :--- | :--- |
| ❌ Migrate ADO Test Plans with test execution results | GitHub has no native test plan concept |
| ❌ Migrate ADO Release Pipelines or Build Pipelines | Out of scope (Board items only) |
| ❌ Migrate ADO Wiki pages | Different migration path — not part of boards migration |
| ❌ Migrate files larger than 25 MB automatically | GitHub REST API hard limit |
| ❌ Preserve the original ADO Issue Number as the GitHub Issue Number | GitHub auto-assigns issue numbers sequentially |
| ❌ Migrate ADO Board column swimlane configuration | GitHub Project V2 does not support swimlanes |
| ❌ Migrate ADO Shared Queries as live GitHub Saved Filters | GitHub Project V2 has no saved filter feature; exported as a cheat-sheet document |
| ❌ Keep ADO work item URLs clickable in GitHub | ADO URLs remain in comments as text references |
| ❌ Assign GitHub issues to users who don't have GitHub accounts | User must already exist on GitHub |
| ❌ Migrate ADO Capacity planning per sprint | No GitHub equivalent |

---

## 9. Full Feature Comparison: ADO Boards vs GitHub

### 9.1 Work Item / Issue Types

| Feature | Azure DevOps | GitHub | Migration Outcome |
| :--- | :--- | :--- | :--- |
| Epic | ✅ Dedicated type | ⚠️ No built-in type | Migrated as Issue + `type:epic` label |
| Feature | ✅ Dedicated type | ⚠️ No built-in type | Migrated as Issue + `type:feature` label |
| User Story / PBI | ✅ Dedicated type | ⚠️ No built-in type | Migrated as Issue + `type:user-story` label |
| Task | ✅ Dedicated type | ⚠️ No built-in type | Migrated as Issue + `type:task` label |
| Bug | ✅ Dedicated type | ✅ Built-in `bug` label | Migrated as Issue + `type:bug` label |
| Impediment | ✅ Dedicated type | ⚠️ No built-in type | Migrated as Issue + `type:impediment` label |
| Test Plan | ✅ Full test management | ❌ No equivalent | Migrated as Issue + `type:test-plan` label (no execution) |
| Test Case | ✅ With steps & results | ⚠️ Partial | Migrated as Issue + `type:test-case` label (steps in body) |

### 9.2 Hierarchy & Relationships

| Feature | Azure DevOps | GitHub | Migration Outcome |
| :--- | :--- | :--- | :--- |
| Epic → Feature → Story → Task nesting | ✅ Enforced by system | ⚠️ Via Sub-issues (Beta) | ✅ Migrated via `addSubIssue` API |
| Parent-Child visual tree view | ✅ Full backlog tree | ⚠️ Sub-issues panel only | ✅ Visible on each issue's sidebar |
| Related Links | ✅ Dedicated tab | ❌ No native tab | ⚠️ Added as comment `🔗 Related to #X` |
| Predecessor / Successor | ✅ With timeline | ❌ No equivalent | ⚠️ Added as comment `🚧 Blocked by #X` |
| Duplicate links | ✅ Supported | ❌ No equivalent | ⚠️ Added as comment |

### 9.3 Fields & Custom Data

| Feature | Azure DevOps | GitHub | Migration Outcome |
| :--- | :--- | :--- | :--- |
| Story Points | ✅ Numeric field | ⚠️ Custom number field | ✅ Migrated to `Story Points` Project field |
| Priority (1-4) | ✅ System field | ⚠️ Custom select field | ✅ Migrated to `Priority` Project field (P0/P1/P2) |
| Severity | ✅ System field | ⚠️ Custom select field | ✅ Migrated to `Severity` Project field |
| Value Area | ✅ System field | ⚠️ Custom select field | ✅ Migrated to `Value Area` Project field |
| Description | ✅ Rich HTML field | ✅ Markdown issue body | ✅ Migrated (HTML converted to Markdown) |
| Acceptance Criteria | ✅ Dedicated field | ❌ No dedicated field | ✅ Merged into issue body under `## Acceptance Criteria` header |
| Repro Steps | ✅ Dedicated field | ❌ No dedicated field | ✅ Merged into issue body under `## Repro Steps` header |
| Original ADO ID | ✅ Automatic | ⚠️ Custom text field | ✅ Stored in `ADO ID` Project field for traceability |
| Original ADO State | ✅ Automatic | ⚠️ Custom select field | ✅ Stored in `ADO Status` Project field |
| Tags | ✅ Free-text tags | ✅ Labels | ✅ Migrated as GitHub labels |
| Area Path | ✅ Hierarchical paths | ⚠️ No equivalent | ✅ Mapped to `area:xxx` labels |

### 9.4 Sprints & Planning

| Feature | Azure DevOps | GitHub | Migration Outcome |
| :--- | :--- | :--- | :--- |
| Sprint / Iteration | ✅ Structured iterations | ✅ Milestones | ✅ Each Sprint → GitHub Milestone |
| Sprint dates (start/end) | ✅ Full date ranges | ✅ Milestone due date | ✅ End date migrated as Milestone due date |
| Backlog view | ✅ Full backlog with filtering | ✅ Project Backlog view | ✅ Available in GitHub Project |
| Sprint Board (Kanban) | ✅ Dedicated sprint board | ✅ Project Board view | ✅ Available in GitHub Project |
| Velocity tracking | ✅ Built-in velocity charts | ❌ No built-in charts | ❌ Not available in GitHub |
| Capacity planning per person | ✅ Team capacity input | ❌ No equivalent | ❌ Cannot migrate |
| Burndown charts | ✅ Automatic sprint burndown | ❌ No built-in burndown | ❌ Requires 3rd party tools |

### 9.5 Boards & Views

| Feature | Azure DevOps | GitHub | Migration Outcome |
| :--- | :--- | :--- | :--- |
| Kanban Board | ✅ Full board with swimlanes | ✅ Project Board view | ✅ Board view available |
| Swimlanes | ✅ Configurable swimlanes | ❌ Not supported | ❌ Cannot migrate |
| Backlog view | ✅ Hierarchical backlog | ✅ Project table/backlog | ✅ Available |
| Roadmap view | ✅ Delivery Plans | ✅ Project Roadmap view | ✅ Generated as Roadmap markdown |
| WIP Limits | ✅ Per-column limits | ❌ No enforcement | ❌ Cannot migrate |
| Column policies | ✅ Split columns (active/resolved) | ❌ Simple columns only | ❌ Cannot migrate |

### 9.6 Queries & Saved Filters

| Feature | Azure DevOps | GitHub | Migration Outcome |
| :--- | :--- | :--- | :--- |
| Saved Queries (WIQL) | ✅ Rich query language | ❌ No saved filter feature | ⚠️ Translated to equivalent GitHub filter syntax in `GITHUB_FILTERS.md` |
| Flat list queries | ✅ Full WIQL support | ⚠️ Manual filter in Project | ⚠️ Equivalent filters documented |
| Tree queries (hierarchy) | ✅ Show parent-child tree | ⚠️ Sub-issues only | ⚠️ Partially available via sub-issues |
| Cross-project queries | ✅ Supported | ❌ Not supported | ❌ Cannot migrate |
| Shared queries | ✅ Team-visible | ❌ No shared filters | ❌ Cannot migrate |

### 9.7 Comments & History

| Feature | Azure DevOps | GitHub | Migration Outcome |
| :--- | :--- | :--- | :--- |
| Comments | ✅ Threaded comments | ✅ Issue comments | ✅ All comments migrated with original author + timestamp in header |
| @mentions in comments | ✅ Supported | ✅ Supported | ⚠️ Migrated as plain text (no re-notification) |
| Inline images in comments | ✅ Embedded images | ✅ Embedded images | ✅ Images under 25 MB migrated; larger ones show placeholder |
| Change history / Audit log | ✅ Full field-level history | ❌ No equivalent | ❌ Not migrated |
| Work item revision history | ✅ All revisions | ❌ No equivalent | ❌ Not migrated |

---

*For technical API details, see `API_Reference_Sheet.md`. For pipeline phase deep-dives, see `Pipeline_Phases_Guide.md`.*
