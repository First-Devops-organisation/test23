# Azure DevOps Boards → GitHub Projects Migration Plan

> **Scope**: Work Items (all types), Comments, Attachments, Relationships, Status, Assignments
> **Tool**: Custom PowerShell scripts via ADO REST API + GitHub REST/GraphQL API
> **Target**: GitHub Issues + GitHub ProjectV2 Boards
> **Pipeline**: Azure DevOps YAML Pipeline

---

## Table of Contents

1. [Migration Overview](#1-migration-overview)
2. [What Gets Migrated](#2-what-gets-migrated)
3. [Hierarchy & Mapping Strategy](#3-hierarchy--mapping-strategy)
4. [Pre-Requisites](#4-pre-requisites)
5. [Folder Structure](#5-folder-structure)
6. [Configuration Files](#6-configuration-files)
7. [Step-by-Step Execution Plan](#7-step-by-step-execution-plan)
8. [ADO Pipeline](#8-ado-pipeline)
9. [Validation Checklist](#9-validation-checklist)
10. [Rollback Plan](#10-rollback-plan)
11. [Known Limitations & Edge Cases](#11-known-limitations--edge-cases)

---

## 1. Migration Overview

### The Challenge
Azure DevOps Boards and GitHub Projects have fundamentally different data models:

| Aspect | Azure DevOps | GitHub |
|--------|-------------|--------|
| Work Items | Rich types (Epic, Feature, Story, Task, Bug) | Flat Issues |
| Hierarchy | Native parent-child tree | Sub-issues (Beta) or Task Lists |
| Status | Custom per work-item-type | ProjectV2 single-select field |
| Board Columns | Mapped to states | ProjectV2 Status field options |
| Area Paths | Hierarchical tree | Labels or custom fields |
| Iteration Paths | Sprint structure | Milestones or Iterations field |
| Attachments | Inline in HTML + file attachments | Uploaded to GitHub CDN |
| Comments | Discussion threads with images | Issue comments (markdown) |
| Relationships | Parent/Child, Related, Predecessor | Sub-issues, cross-references |

### Strategy
1. **Discover** all work items and their metadata from ADO
2. **Map** every ADO concept to a GitHub equivalent using JSON config files
3. **Migrate** in hierarchy order (Epics first → Features → Stories → Tasks/Bugs)
4. **Validate** completeness with automated checks
5. **Report** full audit trail for traceability

---

## 2. What Gets Migrated

| ADO Artifact | GitHub Equivalent | How |
|-------------|-------------------|-----|
| Work Item Title | Issue Title | Direct copy |
| Description / Repro Steps | Issue Body (markdown) | HTML → Markdown conversion |
| Acceptance Criteria | Issue Body section | Appended to body |
| State (New/Active/Resolved/etc) | ProjectV2 Status column | Via `status-mappings.json` |
| Work Item Type | GitHub Label | Via `workitem-type-mappings.json` |
| Assigned To | Issue Assignee | Via `user-mappings.json` |
| Tags | GitHub Labels | Prefixed with `tag:` |
| Area Path | GitHub Label | Via `area-path-mappings` in config |
| Iteration Path | GitHub Milestone | Via config |
| Comments (with images) | Issue Comments | Images re-uploaded to GitHub |
| File Attachments | Issue Comment links | Uploaded via GitHub API |
| Parent-Child links | Sub-issues / Task Lists | Hierarchy preserved |
| Related links | Cross-references in body | `#issue_number` references |
| Priority | GitHub Label | `priority:1`, `priority:2`, etc. |
| Severity (Bugs) | GitHub Label | `severity:critical`, etc. |
| Original ADO URL | Issue Comment | Link back for traceability |
| Created Date | Issue Body metadata | Preserved in metadata table |
| Created By | Issue Body metadata | Preserved in metadata table |

---

## 3. Hierarchy & Mapping Strategy

### ADO Hierarchy → GitHub
```
ADO:                          GitHub:
Epic                    →     Issue (label: epic) + ProjectV2
  └── Feature           →     Issue (label: feature) — sub-issue of Epic
       └── User Story   →     Issue (label: user-story) — sub-issue of Feature
            ├── Task    →     Issue (label: task) — sub-issue of Story
            └── Bug     →     Issue (label: bug) — sub-issue of Story
```

### Migration Order (Critical!)
Items are migrated **top-down** to establish parent references:
1. **Pass 1**: Epics (no parents)
2. **Pass 2**: Features (link to parent Epic)
3. **Pass 3**: User Stories (link to parent Feature)
4. **Pass 4**: Tasks, Bugs, Issues (link to parent Story/Feature)
5. **Pass 5**: Test Plans, Test Suites, Test Cases, Impediments

### State Mapping (Customizable)
Default mapping in `config/status-mappings.json`:

| ADO State | GitHub ProjectV2 Status |
|-----------|------------------------|
| New | Todo |
| Active | In Progress |
| Resolved | Done |
| Closed | Done |
| Done | Done |
| Removed | Done |

### Work Item Type → Label + Color
Defined in `config/workitem-type-mappings.json`:

| ADO Type | GitHub Label | Color |
|----------|-------------|-------|
| Epic | `epic` | `#8B5CF6` (purple) |
| Feature | `feature` | `#3B82F6` (blue) |
| User Story | `user-story` | `#10B981` (green) |
| Task | `task` | `#F59E0B` (amber) |
| Bug | `bug` | `#EF4444` (red) |
| Issue | `issue` | `#F97316` (orange) |
| Impediment | `impediment` | `#EC4899` (pink) |
| Test Plan | `test-plan` | `#6366F1` (indigo) |
| Test Suite | `test-suite` | `#8B5CF6` (violet) |
| Test Case | `test-case` | `#A855F7` (purple) |

---

## 4. Pre-Requisites

### 4.1 Access & Permissions

| Requirement | Scopes |
|-------------|--------|
| **ADO PAT** | `Work Items (Read, Write)`, `Project & Team (Read)`, `Identity (Read)` |
| **GitHub PAT (classic)** | `repo`, `project`, `admin:org`, `read:user` |
| **ADO Project Role** | Project Contributor or higher |
| **GitHub Org Role** | Organization Member with project access |

### 4.2 Tools Required

| Tool | Version | Purpose |
|------|---------|---------|
| PowerShell | ≥ 7.0 | Script execution |
| Azure CLI | Latest | `az boards` commands |
| GitHub CLI (`gh`) | ≥ 2.50 | Issue operations |
| `az devops` extension | Latest | ADO API calls |

### 4.3 GitHub Project Setup
- GitHub ProjectV2 must exist **before** migration
- Status field must have the options matching your `status-mappings.json` values
- Create options: Todo, In Progress, Done (or customize)

---

## 5. Folder Structure

```
boards-migration/
├── BOARDS-MIGRATION-PLAN.md              # This document
├── azure-pipelines.yml                    # ADO Pipeline definition
├── run-boards-migration.ps1              # Orchestrator script
├── create_poc_items.ps1                   # POC work item creator (existing)
│
├── config/
│   ├── boards-migration-config.json       # Main config (orgs, projects, filters)
│   ├── user-mappings.json                 # ADO email → GitHub username
│   ├── status-mappings.json               # ADO state → GitHub project status
│   └── workitem-type-mappings.json        # ADO type → GitHub label + config
│
├── 01-discover/
│   ├── discover-workitems.ps1             # Inventory all ADO work items
│   └── analyze-board-structure.ps1        # Analyze hierarchy, fields, states
│
├── 02-prep/
│   ├── validate-mappings.ps1              # Validate config before migration
│   └── setup-github-labels.ps1            # Create labels in GitHub repo
│
├── 03-migrate/
│   └── migrate-workitems.ps1              # Main migration engine
│
├── 04-validate/
│   ├── validate-migration.ps1             # Compare ADO vs GitHub
│   └── generate-report.ps1               # Migration summary report
│
├── helpers/
│   ├── ado-helpers.ps1                    # ADO REST API utilities
│   ├── github-helpers.ps1                 # GitHub REST/GraphQL utilities
│   └── logging.ps1                        # Structured logging
│
├── reports/                               # Generated reports (gitignored)
└── logs/                                  # Migration logs (gitignored)
```

---

## 6. Configuration Files

All mappings are **externalized** in JSON config files so teams can customize without touching code.

### `config/boards-migration-config.json`
Main configuration: source/target orgs, area path filters, migration options.

### `config/user-mappings.json`
Maps ADO user emails → GitHub usernames. Used for assignee mapping.

### `config/status-mappings.json`
Maps ADO work item states → GitHub ProjectV2 status column values.
Supports per-work-item-type overrides.

### `config/workitem-type-mappings.json`
Maps ADO work item types → GitHub labels with colors, migration order, and field handling.

---

## 7. Step-by-Step Execution Plan

### Step 1: Discovery — Inventory Work Items
**Script**: `01-discover/discover-workitems.ps1`

- Queries all work items under configured area paths
- Captures: ID, Title, Type, State, Assigned To, Parent ID, Tags, Comment count
- Outputs: `reports/workitem-inventory.json` and `reports/workitem-inventory.csv`

### Step 2: Discovery — Analyze Board Structure
**Script**: `01-discover/analyze-board-structure.ps1`

- Identifies all unique states, area paths, iteration paths, work item types
- Detects parent-child relationships and depth
- Identifies unmapped users, unknown states
- Outputs: `reports/board-analysis.json`

### Step 3: Preparation — Validate Mappings
**Script**: `02-prep/validate-mappings.ps1`

- Cross-references discovered data against mapping configs
- Flags unmapped users, states, work item types
- Validates GitHub PAT permissions and project access
- Outputs: PASS/FAIL with actionable fix list

### Step 4: Preparation — Setup GitHub Labels
**Script**: `02-prep/setup-github-labels.ps1`

- Creates all work item type labels with colors
- Creates tag-based labels
- Creates priority and severity labels
- Idempotent — skips existing labels

### Step 5: Migration — Migrate Work Items
**Script**: `03-migrate/migrate-workitems.ps1`

- Migrates in hierarchy order (Epics → Features → Stories → Tasks/Bugs)
- For each work item:
  1. Builds issue body from ADO fields (description, acceptance criteria, repro steps)
  2. Downloads and re-uploads inline images and attachments
  3. Creates GitHub Issue with labels and assignee
  4. Adds to GitHub ProjectV2 board
  5. Sets ProjectV2 Status column
  6. Migrates all comments (with embedded images)
  7. Establishes parent-child links (sub-issues)
  8. Closes issue if ADO state is terminal
  9. Tags ADO work item as `copied-to-github`
- Maintains migration log: `reports/migration-log.json` (ADO ID → GitHub Issue URL)
- Supports `--dry-run` mode
- Supports resume (skips already-migrated items)

### Step 6: Validation — Validate Migration
**Script**: `04-validate/validate-migration.ps1`

- Compares work item counts by type and state
- Verifies all comments migrated
- Checks assignee mapping accuracy
- Validates parent-child links
- Outputs: `reports/validation-results.json`

### Step 7: Report — Generate Summary
**Script**: `04-validate/generate-report.ps1`

- Generates human-readable migration report
- Includes: counts, errors, warnings, unmapped items
- Outputs: `reports/migration-summary.md`

---

## 8. ADO Pipeline

The `azure-pipelines.yml` defines a multi-stage pipeline:

1. **Stage: Discover** — Inventory + Analysis
2. **Stage: Prepare** — Validate mappings + Setup labels
3. **Stage: Migrate** — Execute migration (manual approval gate)
4. **Stage: Validate** — Post-migration checks + Report

Variables stored in ADO Variable Group (secrets masked):
- `ADO_PAT` — Azure DevOps Personal Access Token
- `GH_PAT` — GitHub Personal Access Token

---

## 9. Validation Checklist

| # | Check | Method | Pass Criteria |
|---|-------|--------|---------------|
| 1 | Work item count match | ADO WIQL vs GitHub Issues | Counts equal |
| 2 | Comments count per item | ADO API vs GitHub API | Counts equal |
| 3 | Assignee accuracy | Compare mapped users | All mapped correctly |
| 4 | Status mapping | ADO state vs GitHub Status | All mapped per config |
| 5 | Labels present | GitHub API | Type + tag labels exist |
| 6 | Parent-child links | GitHub sub-issues | Hierarchy preserved |
| 7 | Attachments accessible | HTTP HEAD on URLs | All return 200 |
| 8 | Closed state sync | ADO closed → GitHub closed | States match |
| 9 | ADO tagged | ADO tags include `copied-to-github` | Tag present |
| 10 | No duplicates | Migration log | Unique ADO ID per issue |

---

## 10. Rollback Plan

| Scenario | Action |
|----------|--------|
| Migration failed mid-run | Resume from migration log (idempotent) |
| Wrong data migrated | Delete GitHub issues via script. Re-run with corrected config |
| Full rollback | Delete all migrated issues + remove from project. Remove `copied-to-github` tags from ADO |

**ADO work items are NEVER modified** (except adding the `copied-to-github` tag when `--production-run` is set).

---

## 11. Known Limitations & Edge Cases

| # | Limitation | Impact | Mitigation |
|---|-----------|--------|------------|
| 1 | GitHub Issues are flat (no native hierarchy) | Parent-child via sub-issues (Beta) | Use task lists as fallback |
| 2 | Inline images in ADO HTML | Must download + re-upload | Script handles this automatically |
| 3 | ADO rich text (HTML) | GitHub uses Markdown | HTML → Markdown conversion |
| 4 | Custom fields in ADO | No direct equivalent | Stored in issue body metadata |
| 5 | Board column order | ProjectV2 has its own ordering | Status field options control order |
| 6 | ADO @mentions | Different user format | Replaced via user mapping |
| 7 | Work item links (Related) | No native equivalent | Cross-references in issue body |
| 8 | Rate limiting (GitHub API) | 5000 req/hr for REST | Built-in throttle + retry |
| 9 | Rate limiting (GraphQL) | 5000 points/hr | Batched mutations |
| 10 | Test artifacts (Test Plans/Suites/Cases) | GitHub has no test management | Migrated as labeled issues |

---

## Appendix: Script Reference

| Script | Phase | Purpose |
|--------|-------|---------|
| `01-discover/discover-workitems.ps1` | Discovery | ADO WIQL query + full inventory |
| `01-discover/analyze-board-structure.ps1` | Discovery | Hierarchy, state, field analysis |
| `02-prep/validate-mappings.ps1` | Preparation | Config validation |
| `02-prep/setup-github-labels.ps1` | Preparation | GitHub label creation |
| `03-migrate/migrate-workitems.ps1` | Migration | Main migration engine |
| `04-validate/validate-migration.ps1` | Validation | Post-migration comparison |
| `04-validate/generate-report.ps1` | Validation | Summary report generation |
| `helpers/ado-helpers.ps1` | Shared | ADO REST API utilities |
| `helpers/github-helpers.ps1` | Shared | GitHub API utilities |
| `helpers/logging.ps1` | Shared | Logging framework |
| `run-boards-migration.ps1` | Orchestrator | End-to-end coordinator |

## Appendix: Config Files

| File | Purpose |
|------|---------|
| `config/boards-migration-config.json` | Source/target orgs, area paths, project number, options |
| `config/user-mappings.json` | ADO email → GitHub username mapping |
| `config/status-mappings.json` | ADO state → GitHub ProjectV2 status mapping |
| `config/workitem-type-mappings.json` | ADO type → GitHub label, color, migration order |
