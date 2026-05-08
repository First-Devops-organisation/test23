# ADO → GitHub Boards Migration: Internal Engineering Reference

> **Perspective:** Internal team documentation — what we built, discovered, and how it works.
> **Authors:** Migration Engineering Team
> **Last Updated:** May 2026

---

## Table of Contents

1. [Our Discovery & Analysis](#1-our-discovery--analysis)
2. [Prerequisites](#2-prerequisites)
3. [Manual Steps Before Running the Pipeline](#3-manual-steps-before-running-the-pipeline)
4. [Pipeline Flow & Architecture](#4-pipeline-flow--architecture)
5. [Pipeline Features](#5-pipeline-features)
6. [Risks](#6-risks)
7. [Limitations](#7-limitations)
8. [ADO Boards vs GitHub — Full Comparison](#8-ado-boards-vs-github--full-comparison)

---

## 1. Our Discovery & Analysis

### What We Investigated
Before building the pipeline, we analyzed the ADO project and GitHub target environment to understand the full scope of migration complexity.

### Key Findings

| Area | ADO Reality | GitHub Reality | Our Approach |
| :--- | :--- | :--- | :--- |
| **Item Types** | 17 distinct work item types (Epic, Feature, User Story, PBI, Task, Bug, Impediment, etc.) | Only "Issue" — no type enforcement | Map all types to labels (`type:epic`, `type:bug`, etc.) |
| **Hierarchy** | 4-level enforced tree: Epic → Feature → Story → Task | Flat — no hierarchy by default | Use GitHub's native **Sub-issues API** (Beta) |
| **Fields** | 20+ system fields + custom fields per type | Minimal built-in fields | Create **Custom Project V2 Fields** for all critical fields |
| **Status/State** | Configurable per process template (Agile, Scrum, CMMI) | Only Open / Closed | Map ADO states to GitHub board columns via `status-mappings.json` |
| **Sprints** | First-class iterations with capacity and burndown | Milestones only | Map each ADO Sprint → GitHub Milestone with dates |
| **Area Paths** | Hierarchical classification tree | No equivalent | Map to GitHub `area:xxx` labels |
| **Comments** | HTML-rich with inline images and @mentions | Markdown with inline images | Convert HTML → Markdown, re-host images in the GitHub repo |
| **Attachments** | Up to 60 MB per file, stored in ADO | Max ~25 MB via REST API upload | Auto-migrate files under 25 MB; log failures for manual re-upload |
| **Related/Blocked** | Dedicated relation tabs with typed links | No native relation UI | Inject as formatted comments at bottom of each issue |
| **Saved Queries (WIQL)** | Powerful query language, shareable | No saved filter system | Translate to equivalent GitHub filter syntax, export as markdown cheat sheet |
| **Test Plans** | Full test management suite | No test management | Migrate as issues with steps in body; no execution data |

### ADO Process Templates Discovered
We found the project uses a **mixed process template** — containing both Agile types (User Story) and Scrum types (Product Backlog Item) alongside CMMI types (Change Request, Analysis). This is common in enterprise ADO instances that have evolved over years.

**Effective work item types found:**
`Epic`, `Feature`, `User Story`, `Product Backlog Item`, `Task`, `Bug`, `Change Request`, `Issue`, `Impediment`, `UAT Review`, `Analysis`, `Idea`, `Test Plan`, `Test Suite`, `Test Case`, `Shared Steps`, `Shared Parameter`

### GitHub "Type" Field — Why We Did Not Use It
GitHub has a native "Type" field visible on issues. We investigated using it but chose **not to** because:
1. It requires the client to manually configure allowed types per repo before migration
2. The GraphQL API for this field is in Beta and has unstable IDs that break under load
3. Our **Custom Project V2 Fields + Labels** approach is fully automated, does not require pre-configuration, and scales across all repos without manual steps

---

## 2. Prerequisites

### 2.1 Infrastructure Prerequisites

| # | Requirement | Where | Details |
| :--- | :--- | :--- | :--- |
| 1 | GitHub Organization exists | `github.com/{org}` | Pipeline targets org-level projects |
| 2 | GitHub Repository created | `github.com/{org}/{repo}` | All issues will be created here |
| 3 | GitHub Project V2 created | Organization-level | Must be **org-level**, not repo-level |
| 4 | ADO Pipeline Service exists | ADO → Pipelines | The pipeline itself runs inside ADO |
| 5 | ADO Variable Group `boards-migration` | ADO → Library | Stores the two PAT secrets |

### 2.2 Token Prerequisites

**ADO PAT (`ADO_PAT`)** — Minimum scopes required:

| Scope | Level |
| :--- | :--- |
| Work Items | Read |
| Queries | Read |
| Code | Read |
| Project and Team | Read |
| Identity | Read |

**GitHub PAT (`GH_PAT`)** — Minimum scopes required:

| Scope | Level |
| :--- | :--- |
| `repo` | Full |
| `project` | Read & Write |
| `write:org` | Write |
| `read:org` | Read |

> ⚠️ The GitHub PAT must belong to a user who is an **Organization Owner** or has **Admin** access to the target repository and project.

### 2.3 Config Files — What Each File Does & What to Fill

All files live in `boards-migration/config/`. These **must be reviewed and updated** before any pipeline run.

---

#### 📄 `boards-migration-config.json` — Master Config (Always Required)

This is the single source of truth for the pipeline. It tells the pipeline **where to read from** (ADO) and **where to write to** (GitHub).

```json
{
  "source": {
    "organization": "YourADOOrg",        ← ADO organization name (from dev.azure.com/{THIS})
    "project":      "YourADOProject",    ← Exact ADO project name
    "areaPath":     "Project\\Area",     ← Area path to migrate (use \\ for backslash)
    "pat":          "$(ADO_PAT)"         ← DO NOT CHANGE — reads from Variable Group secret
  },
  "target": {
    "organization":     "YourGitHubOrg",    ← GitHub org name
    "repository":       "your-repo",        ← GitHub repository name
    "projectNumber":    2,                  ← Project number from GitHub URL (/projects/NUMBER)
    "projectOwnerType": "organization",     ← "organization" or "user"
    "pat":              "$(GH_PAT)"         ← DO NOT CHANGE — reads from Variable Group secret
  },
  "migration": {
    "migrateClosedWorkItems": true,   ← false = skip Closed/Resolved items
    "productionRun":          true,   ← false = dry run, no writes to GitHub
    "migrateAttachments":     true,   ← false = skip all file attachments
    "migrateLinks":           true,   ← false = skip Related/Blocked link comments
    "preserveParentChild":    true,   ← false = skip Sub-issue hierarchy linking
    "dryRun":                 false   ← true = safe simulation mode
  }
}
```

---

#### 📄 `user-mappings.json` — ADO User → GitHub Username (Always Required)

Maps each ADO team member to their GitHub account. Every person who has ever been assigned a work item should be listed here.

```json
{
  "mappings": [
    {
      "adoDisplayName":    "John Doe",              ← Exact name shown in ADO
      "adoEmail":          "john.doe@company.com",  ← Primary ADO email
      "adoAlternateEmails": ["john@personal.com"],  ← Any alias emails (can be empty [])
      "githubUsername":    "johndoe-gh"             ← GitHub username (without @)
    }
  ],
  "defaultGithubUser":    "admin-user",       ← Fallback if ADO user not found in list
  "unmappedUserAction":   "assign-default"    ← "assign-default" or "skip" (leave unassigned)
}
```

> **What happens if a user is missing?** The issue is created with the `defaultGithubUser` as assignee. No error is thrown, but assignment fidelity is lost.

---

#### 📄 `status-mappings.json` — ADO State → GitHub Board Column (Always Required)

Maps every ADO workflow state to a GitHub Project V2 board column.  
The pipeline supports two levels: a **default mapping** (applies to all types) and **type-specific overrides** (takes precedence for that type).

```json
{
  "defaultMapping": {
    "New":              "Backlog",       ← ADO state name → GitHub column name (case-sensitive)
    "Active":           "In progress",
    "In Progress":      "In progress",
    "In PR":            "In review",
    "Ready for Testing":"Ready",
    "Resolved":         "Done",
    "Closed":           "Done",
    "Done":             "Done",
    "On Hold":          "On Hold",
    "Blocked":          "Blocked"
  },
  "typeOverrides": {
    "Bug": {
      "New":     "Backlog",             ← Bugs in "New" go to Backlog (not same as default)
      "Active":  "In progress"
    },
    "Impediment": {
      "Open":   "In progress",          ← Impediments only have "Open" and "Closed"
      "Closed": "Done"
    }
  },
  "githubProjectStatusOptions": [       ← These must EXACTLY match your GitHub board columns
    "Backlog", "Ready", "In progress", "In review", "Blocked", "On Hold", "Done"
  ],
  "closedStates": [                     ← Items in these ADO states will be CLOSED in GitHub
    "Done", "Closed", "Resolved", "Removed", "Completed", "Inactive"
  ]
}
```

> **⚠️ Column names are case-sensitive.** If your GitHub board has `"In Progress"` but you write `"In progress"` here, the status field will be blank.

---

#### 📄 `workitem-type-mappings.json` — ADO Work Item Type → GitHub Label (Review Before Running)

Defines how each ADO type is represented in GitHub as a label, including color.

```json
{
  "Epic":           { "label": "type:epic",              "color": "8B00FF" },
  "Feature":        { "label": "type:feature",           "color": "0052CC" },
  "User Story":     { "label": "type:user-story",        "color": "0075CA" },
  "Product Backlog Item": { "label": "type:pbi",         "color": "006B75" },
  "Task":           { "label": "type:task",              "color": "E4E669" },
  "Bug":            { "label": "type:bug",               "color": "D73A4A" },
  "Impediment":     { "label": "type:impediment",        "color": "B60205" },
  "Change Request": { "label": "type:change-request",   "color": "F9D0C4" },
  "Test Plan":      { "label": "type:test-plan",         "color": "0E8A16" },
  "Test Case":      { "label": "type:test-case",         "color": "BFD4F2" }
}
```

> The pipeline **auto-creates** these labels in GitHub during Phase 2. You do not need to create them manually.

---

#### 📄 `field-mappings.json` — ADO Fields → GitHub Project Custom Fields (Optional)

Controls which ADO fields are preserved as custom columns on the GitHub Project V2 board.

```json
{
  "storyPoints": { "ghFieldName": "Story Points", "type": "number"        },
  "priority":    { "ghFieldName": "Priority",     "type": "single_select" },
  "severity":    { "ghFieldName": "Severity",     "type": "single_select" },
  "adoStatus":   { "ghFieldName": "ADO Status",   "type": "single_select" },
  "adoId":       { "ghFieldName": "ADO ID",       "type": "text"          },
  "valueArea":   { "ghFieldName": "Value Area",   "type": "single_select" },
  "size":        { "ghFieldName": "Size",         "type": "single_select" },
  "estimate":    { "ghFieldName": "Estimate",     "type": "number"        },
  "iteration":   { "ghFieldName": "Iteration",    "type": "text"          }
}
```

> All 9 fields are created automatically in the GitHub Project. The `ADO ID` and `ADO Status` fields are critical for traceability — **do not remove them**.

---



## 3. Manual Steps Before Running the Pipeline

Complete these **in order** before triggering any pipeline run.

### Step 1 — Create GitHub Target Environment
1. Create the **target repository** in GitHub (can be empty, private is fine)
2. Create a **GitHub Project V2** at the **Organization level** (`github.com/orgs/{org}/projects`)
3. Note the **project number** from the URL (e.g., `…/projects/2` → number is `2`)
4. Link the repository to the project: Project Settings → Manage Access → Add Repository

### Step 2 — Set Up ADO Variable Group
1. Go to **ADO → Pipelines → Library → Variable Groups**
2. Create a group named exactly: `boards-migration`
3. Add variable `ADO_PAT` — paste the ADO PAT, **mark as secret**
4. Add variable `GH_PAT` — paste the GitHub PAT, **mark as secret**
5. Click **Save** and then **Pipeline Permissions** → allow the migration pipeline to access this group

### Step 3 — Fill Config Files
1. Open `config/boards-migration-config.json` — fill in `organization`, `project`, `areaPath` (source) and `organization`, `repository`, `projectNumber` (target)
2. Open `config/user-mappings.json` — add every team member's ADO email → GitHub username
3. Open `config/status-mappings.json` — add every ADO state name mapped to the exact GitHub column name
4. Review `config/workitem-type-mappings.json` — confirm all ADO types in your project are listed

### Step 4 — Run Discovery First (Phase = discover)
1. Trigger the pipeline with **Phase = discover**, **Dry Run = true**
2. Download the `discovery-reports` artifact after the run
3. Open `workitem-inventory.json` — verify the total count matches what you see in ADO
4. Check for any `⚠️ WARN` entries about unknown user mappings or status mappings
5. Fix any gaps in the config files before proceeding

### Step 5 — Validate Mappings (Phase = prep)
1. Trigger the pipeline with **Phase = prep**, **Dry Run = true**
2. This creates labels and milestones in GitHub without touching work items
3. Verify in GitHub that: labels were created correctly, milestones match ADO sprint names

### Step 6 — Full Dry Run (Phase = all, Dry Run = true)
1. Trigger with **Phase = all**, **Dry Run = true**, **Resume = false**
2. Review logs for any mapping warnings
3. Confirm no errors in field mapping or GraphQL mutations

### Step 7 — Live Migration (Phase = all, Dry Run = false)
1. Trigger with **Phase = all**, **Dry Run = false**, **Resume = true**
2. **Approve the manual gate** when the pipeline pauses for human review
3. Monitor the run — expect ~30–45 seconds per work item due to GitHub rate limits
4. If interrupted, simply re-trigger with **Resume = true** — no duplicates will be created

---

## 4. Pipeline Flow & Architecture

### Stage Overview

```
┌────────────────────────────────────────────────────────────┐
│  STAGE 1: DISCOVER                                         │
│  ├─ [Setup] Install Azure DevOps CLI Extension             │
│  ├─ [Phase 1] Count & List All ADO Work Items              │
│  ├─ [Phase 1] Analyze ADO Board & Sprint Structure         │
│  ├─ [Phase 1] Generate GitHub Project Setup Guide          │
│  ├─ [Phase 1] Read ADO Workflow States & Transitions       │
│  └─ [Artifact] Save Discovery Reports                      │
└────────────────────────────────┬───────────────────────────┘
                                 ▼
┌────────────────────────────────────────────────────────────┐
│  STAGE 2: PREPARE                                          │
│  ├─ [Phase 2] Download Discovery Reports from Phase 1      │
│  ├─ [Phase 2] Validate User, Status & Type Mappings        │
│  ├─ [Phase 2] Create GitHub Labels (type, priority, etc.)  │
│  ├─ [Phase 2] Create GitHub Milestones from ADO Sprints    │
│  ├─ [Phase 2] Deploy GitHub Actions Workflow Rules         │
│  └─ [Artifact] Save Preparation Logs                       │
└────────────────────────────────┬───────────────────────────┘
                                 ▼
┌────────────────────────────────────────────────────────────┐
│  [GATE] Human Approval Required Before Migration Starts    │
│  ← Team member reviews discovery + prep reports, approves │
└────────────────────────────────┬───────────────────────────┘
                                 ▼
┌────────────────────────────────────────────────────────────┐
│  STAGE 3: MIGRATE                                          │
│  ├─ [Phase 3] Download Discovery Reports from Phase 1      │
│  ├─ [Phase 3] Download Previous Migration Log (Resume)     │
│  ├─ [Phase 3] Load Previous Log to Enable Resume Mode      │
│  ├─ [Phase 3] Take Pre-Migration Snapshot of ADO           │
│  ├─ [Phase 3] Migrate ADO Work Items → GitHub Issues       │  ← Core engine
│  │    ├─ PASS 1: Create all issues with fields/comments    │
│  │    └─ PASS 2: Establish Parent-Child Sub-issue links    │
│  ├─ [Phase 3] Inject Items into GitHub Project V2 Board    │
│  ├─ [Phase 5] Link ADO Pull Requests to GitHub Issues      │
│  ├─ [Phase 6] Enrich: Related Links, Saved Queries, Roadmap│
│  ├─ [Artifact] Save Migration Log (migration-log.json)     │
│  └─ [Artifact] Save Verbose Debug Logs                     │
└────────────────────────────────┬───────────────────────────┘
                                 ▼
┌────────────────────────────────────────────────────────────┐
│  STAGE 4: VALIDATE                                         │
│  ├─ [Phase 4] Download Migration Log from Phase 3          │
│  ├─ [Phase 4] Compare ADO Count vs GitHub Issue Count      │
│  ├─ [Phase 4] Generate Final Migration Summary Report      │
│  ├─ [Artifact] Save Final Reports                          │
│  └─ [Phase 4] Pin Summary to Pipeline Overview Tab         │
└────────────────────────────────────────────────────────────┘
```

### Core Migration Engine — Phase 3 Detail

**PASS 1 (Issue Creation):** For each ADO work item, sorted by hierarchy level (Epics first, then Features, then Stories, then Tasks):
1. Build the GitHub issue body by merging Description + Acceptance Criteria + Repro Steps
2. Create the GitHub Issue via REST API
3. Add the issue to the GitHub Project V2 board via GraphQL (`addProjectV2ItemById`)
4. Set all custom fields in a **single batched GraphQL mutation** (`updateProjectV2ItemFieldValue`)
5. Migrate all ADO comments (with author/date header)
6. Migrate all inline images (download from ADO, upload to GitHub repo)
7. Save the mapping `ADO ID → GitHub Issue Number` to `migration-log.json`

**PASS 2 (Hierarchy Linking):** After all issues exist:
1. Read all parent-child relationships from ADO data
2. For each parent-child pair, call `addSubIssue` GraphQL mutation
3. If link already exists (resume run), skip silently — no duplicate error

---

## 5. Pipeline Features

| Feature | Description |
| :--- | :--- |
| **Auto-Resume** | `migration-log.json` tracks every migrated item. Re-running skips already-migrated items. Zero duplicates. |
| **Dry Run Mode** | `dryRun: true` runs all logic but makes **no writes** to GitHub. Safe for validation. |
| **Rate Limit Handling** | Detects GitHub `HTTP 403 Secondary Rate Limit`, retries up to 5 times with exponential backoff (20s→40s→80s→160s→320s) |
| **Manual Approval Gate** | Production migration requires human sign-off. Discovery and prep reports are reviewed before live migration starts. |
| **Batch GraphQL** | All custom field updates (up to 14 fields) are sent in a **single GraphQL mutation** per item — reduces API calls by ~90% |
| **Inline Image Migration** | Detects `<img>` tags in ADO HTML comments, downloads binaries from ADO, uploads to GitHub repo's `migrated-attachments/` folder, rewrites URLs |
| **Sprint Sync** | Before migration starts, syncs all ADO sprints to GitHub milestones. Reuses existing milestones instead of creating duplicates. |
| **Hierarchy Idempotency** | Sub-issue linking treats "duplicate" API errors as success — safe to re-run Pass 2 multiple times |
| **Phase Selector** | Pipeline parameter allows running only specific phases (`discover`, `prep`, `migrate`, `validate`, `all`) |
| **ADO Tagging** | After each successful migration, the original ADO work item is tagged with a comment containing the GitHub issue URL |
| **Validation Report** | Phase 4 generates a Markdown summary comparing ADO source count vs GitHub destination count |
| **Filter Cheat Sheet** | Phase 6 generates `GITHUB_FILTERS.md` — translates ADO saved queries into GitHub Project filter equivalents |

---

## 6. Risks

| Risk | Probability | Impact | Our Mitigation |
| :--- | :--- | :--- | :--- |
| **GitHub Secondary Rate Limit** | High (for large migrations) | Medium — adds hours to run time | Exponential backoff retry built in; migration can be resumed |
| **Sub-issues API Breaking Change** | Medium — it is in Beta | High — hierarchy links lost | Log failure as warning; issue is still created; can be re-linked manually |
| **ADO PAT Expiry Mid-Run** | Low | High — run fails after partial migration | Resume mode recovers; renew PAT and re-trigger |
| **GitHub PAT Insufficient Scope** | Low (if setup correctly) | High — all writes fail | Verify scopes in Step 2 of manual checklist before running |
| **User Not Found in GitHub** | Medium | Low — issue created unassigned | `user-mappings.json` must be fully populated; incomplete mapping = unassigned issues |
| **Config File Encoding Error** | Low | High — pipeline parse failure | Always save config files as **UTF-8 without BOM** |
| **Large Attachment Loss** | High (if client has large files) | Medium — file not in GitHub | Files >25 MB logged with WARN; must be manually uploaded post-migration |
| **Concurrent Pipeline Runs** | Low | High — race condition on migration log | Never run two migration pipelines simultaneously against the same repo |

---

## 7. Limitations

| # | Limitation | Root Cause | Workaround |
| :--- | :--- | :--- | :--- |
| 1 | Attachments > 25 MB cannot be migrated automatically | GitHub REST API Contents endpoint hard limit | Manual upload post-migration |
| 2 | ADO work item original numbers are not preserved in GitHub | GitHub auto-assigns issue numbers sequentially | ADO ID is stored in the `ADO ID` custom Project field |
| 3 | ADO change history / audit trail is not migrated | GitHub has no equivalent field-level history | Current field values and all comments are preserved |
| 4 | ADO @mentions in comments are not re-triggered | Re-notifying users would spam the entire team | Author and date are preserved in comment header |
| 5 | ADO Board swimlanes are not migrated | GitHub Project V2 does not support swimlanes | No equivalent |
| 6 | ADO WIP limits are not migrated | GitHub Project V2 does not enforce WIP limits | No equivalent |
| 7 | ADO Saved Queries are not live filters in GitHub | GitHub has no saved filter feature | Translated to equivalent GitHub syntax in `GITHUB_FILTERS.md` |
| 8 | ADO Test execution results (pass/fail) are not migrated | GitHub has no test management system | Test case steps are preserved in issue body |
| 9 | ADO Delivery Plans are not interactive Roadmaps in GitHub | No exact equivalent | Exported as Roadmap markdown diagram |
| 10 | ADO velocity charts and burndown charts are not migrated | GitHub has no built-in agile charts | Requires third-party tools (ZenHub, Linear, etc.) |
| 11 | ADO Capacity planning per person is not migrated | No GitHub equivalent | No workaround |
| 12 | Cross-repo/cross-project migrations not supported in one run | Pipeline is scoped to one ADO project → one GitHub repo | Run pipeline multiple times with different config files |

---

## 8. ADO Boards vs GitHub — Full Comparison

### Work Item Types

| Feature | ADO | GitHub | Notes |
| :--- | :---: | :---: | :--- |
| Epic | ✅ | ⚠️ | GH: Label `type:epic` |
| Feature | ✅ | ⚠️ | GH: Label `type:feature` |
| User Story | ✅ | ⚠️ | GH: Label `type:user-story` |
| Product Backlog Item | ✅ | ⚠️ | GH: Label `type:product-backlog-item` |
| Task | ✅ | ⚠️ | GH: Label `type:task` |
| Bug | ✅ | ✅ | GH: Built-in `bug` label |
| Impediment | ✅ | ⚠️ | GH: Label `type:impediment` |
| Change Request | ✅ | ⚠️ | GH: Label `type:change-request` |
| Test Plan | ✅ | ❌ | GH: Issue with label only; no execution |
| Test Suite | ✅ | ❌ | GH: Issue with label only |
| Test Case | ✅ | ⚠️ | GH: Steps in issue body |
| Shared Steps | ✅ | ❌ | GH: Issue with label only |

### Hierarchy & Relationships

| Feature | ADO | GitHub | Notes |
| :--- | :---: | :---: | :--- |
| Parent-Child hierarchy (4 levels) | ✅ | ⚠️ | GH: Sub-issues (Beta) |
| Visual hierarchy tree in backlog | ✅ | ⚠️ | GH: Sub-issues panel on each issue |
| Related links | ✅ | ❌ | GH: Comment with `🔗 Related to #X` |
| Predecessor / Successor | ✅ | ❌ | GH: Comment with `🚧 Blocked by #X` |
| Duplicate links | ✅ | ❌ | GH: Comment only |
| Hyperlink (external URL) | ✅ | ✅ | GH: In issue body |

### Fields & Custom Data

| Feature | ADO | GitHub | Notes |
| :--- | :---: | :---: | :--- |
| Story Points | ✅ | ✅ | GH: Custom number field |
| Priority (1–4) | ✅ | ✅ | GH: Custom single-select field |
| Severity | ✅ | ✅ | GH: Custom single-select field |
| Value Area | ✅ | ✅ | GH: Custom single-select field |
| ADO Original Status | ✅ | ✅ | GH: Custom single-select field |
| ADO Original ID | ✅ | ✅ | GH: Custom text field |
| Description (HTML) | ✅ | ✅ | GH: Converted to Markdown in body |
| Acceptance Criteria | ✅ | ⚠️ | GH: Merged into body under `## Acceptance Criteria` |
| Repro Steps | ✅ | ⚠️ | GH: Merged into body under `## Repro Steps` |
| Tags | ✅ | ✅ | GH: Labels |
| Area Path | ✅ | ⚠️ | GH: `area:xxx` labels |
| Iteration Path | ✅ | ✅ | GH: Milestone |
| Assignee | ✅ | ✅ | GH: Requires user mapping |
| Full change history | ✅ | ❌ | Not migrated |
| Custom process fields | ✅ | ⚠️ | GH: Requires custom Project fields |

### Sprints & Planning

| Feature | ADO | GitHub | Notes |
| :--- | :---: | :---: | :--- |
| Sprint / Iteration | ✅ | ✅ | GH: Milestones |
| Sprint start + end dates | ✅ | ⚠️ | GH: Milestone due date only |
| Capacity per person per sprint | ✅ | ❌ | No equivalent |
| Burndown charts | ✅ | ❌ | Requires third-party tools |
| Velocity charts | ✅ | ❌ | Requires third-party tools |
| Cumulative flow diagram | ✅ | ❌ | Not available |

### Boards & Views

| Feature | ADO | GitHub | Notes |
| :--- | :---: | :---: | :--- |
| Kanban Board | ✅ | ✅ | GH: Project Board view |
| Backlog list view | ✅ | ✅ | GH: Project Table view |
| Swimlanes | ✅ | ❌ | Not supported in GitHub |
| WIP limits | ✅ | ❌ | Not supported in GitHub |
| Roadmap / Delivery Plan | ✅ | ✅ | GH: Project Roadmap view |
| Sprint Board | ✅ | ⚠️ | GH: Filter by milestone in Board view |
| Customizable columns | ✅ | ✅ | GH: Full column control |
| Color-coded cards by type | ✅ | ❌ | GH: No card coloring |

### Queries & Automation

| Feature | ADO | GitHub | Notes |
| :--- | :---: | :---: | :--- |
| Saved Queries (WIQL) | ✅ | ❌ | GH: Translated to filter syntax in cheat sheet |
| Cross-project queries | ✅ | ❌ | Not supported |
| Chart from query | ✅ | ❌ | Not available |
| Workflow automation rules | ✅ | ✅ | GH: GitHub Actions workflows |
| Auto-close on PR merge | ✅ | ✅ | GH: `Closes #X` in PR body |
| Auto-assign on state change | ✅ | ⚠️ | GH: Requires GitHub Actions rule |

### Comments & Attachments

| Feature | ADO | GitHub | Notes |
| :--- | :---: | :---: | :--- |
| Threaded comments | ✅ | ✅ | GH: All comments migrated |
| Author + timestamp on comments | ✅ | ⚠️ | GH: Added as header text in comment |
| Inline images in comments | ✅ | ✅ | GH: Re-hosted in repo (< 25 MB) |
| File attachments | ✅ | ⚠️ | GH: Auto-migrated if < 25 MB |
| Large attachments (> 25 MB) | ✅ (up to 60 MB) | ❌ | Manual upload required |
| @mention notifications | ✅ | ⚠️ | GH: Preserved as text, no re-notification |

---

*For API-level details, see `API_Reference_Sheet.md`. For pipeline phase deep-dives, see `Pipeline_Phases_Guide.md`.*
