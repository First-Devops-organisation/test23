**ADO → GitHub Projects**

**Enterprise Migration Master Plan**

100% Fidelity --- Solution Architect Blueprint

|                       |                                                                                            |
|-----------------------|--------------------------------------------------------------------------------------------|
| Projects in Scope     | urvashiEcom \| DistEcom \| DistEcomAI Intelligence Platform \| urvashiEcomDataIntegrations |
| Total Work Items      | 14,478 items across 4 projects                                                             |
| ADO Process Templates | bunzlweb Scrum \| DistEcom Process 2023 \| Scrum -- Inherited \| Basic                     |
| Migration Strategy    | POC-first → Phased Production                                                              |
| Target Fidelity       | 100% --- Every field, state, relationship, custom attribute                                |
| Author                | Senior DevOps Lead --- Migration Architecture                                              |
| Version               | 1.0 --- April 2026                                                                         |

> **1 The 100% Fidelity Problem --- Why Your Current Migration Fails**

Your current migration engine creates GitHub Issues from ADO work items --- but loses everything that makes the ADO data operationally valuable. This section catalogs every gap and its business impact, so you understand exactly what this architecture is solving.

| **Gap**                     | **Root Cause**                                                 | **Business Impact**                               |
|-----------------------------|----------------------------------------------------------------|---------------------------------------------------|
| No parent-child hierarchy   | Migration runs flat --- no top-down pass ordering              | Epics, Features, Stories completely disconnected  |
| Wrong field types           | ADO has 40+ typed fields; GitHub has flat labels only          | Priority, Severity, Story Points lost as metadata |
| No process/state fidelity   | ADO states are per-work-item-type; GitHub has one Status field | BunzlEcom Bug has 9 unique states; collapses to 3 |
| No user identity            | No user-mapping file populated; ADO users ≠ GitHub users       | All 14,478 items become Unassigned                |
| Custom fields not preserved | Value Stream, Value Area, T-Shirt Size, Activity not created   | CXO-level reporting and filtering broken          |
| HTML content broken         | ADO descriptions are rich HTML; not converted to Markdown      | Issue bodies render as garbled code               |
| Test infrastructure lost    | Test Plans/Suites/Cases have no GitHub equivalent mapped       | Entire QA workflow disappears                     |
| Area Paths lost             | Hierarchical area tree not mapped to labels or fields          | Team topology and ownership context gone          |
| Iteration / Sprint history  | Sprint assignments not mapped to milestones                    | Velocity history and sprint reporting broken      |
| Repo & PR references        | Linked commits/PRs in ADO not preserved                        | Engineering traceability broken                   |

> **ℹ** This plan addresses every gap above. Each section maps to a concrete script, config file, or manual setup step.
>
> **2 What You Must Extract from ADO**
>
> **⚠** Before running a single migration script, extract ALL of the following. Missing any one will compromise fidelity.
>
> **2.1 Organisation-Level Data (Run Once)**

| **\#** | **What to Extract**             | **ADO Location**                | **Output File** |
|--------|---------------------------------|---------------------------------|-----------------|
| 1      | All Process Templates           | Org Settings → Process          | processes.json  |
| 2      | All Fields with types           | Org Settings → Process → Fields | all-fields.json |
| 3      | All Work Item Types per Process | Process → Work Item Types       | wit-types.json  |
| 4      | All States per Work Item Type   | Process → WIT → States          | wit-states.json |
| 5      | All Custom Rules                | Process → WIT → Rules           | wit-rules.json  |
| 6      | All Users in Org                | Org Settings → Users            | ado-users.json  |
| 7      | All Groups & Teams              | Org Settings → Teams            | ado-groups.json |

> **2.2 Project-Level Data (Run Per Project)**

Run for each of the 4 projects: urvashiEcom, DistEcom, DistEcomAI Intelligence Platform, urvashiEcomDataIntegrations

| **\#** | **What to Extract**                        | **ADO API Endpoint**                       | **Output File**            |
|--------|--------------------------------------------|--------------------------------------------|----------------------------|
| 1      | All Work Items --- ALL fields expanded     | POST /wit/wiql + POST /wit/workitemsbatch  | workitems-{project}.json   |
| 2      | Work Item Relations (parent/child/related) | Field: System.Links in batch call          | Embedded in workitems JSON |
| 3      | Comments (all revisions)                   | GET /wit/workItems/{id}/comments           | comments-{id}.json         |
| 4      | Attachments                                | GET /wit/workItems/{id}/attachments        | attachments-{id}/          |
| 5      | Area Path Tree                             | GET /wit/classificationnodes/areas         | areas-{project}.json       |
| 6      | Iteration Path Tree                        | GET /wit/classificationnodes/iterations    | iterations-{project}.json  |
| 7      | Board Configuration                        | GET /work/boards                           | boards-{project}.json      |
| 8      | Git Repositories                           | GET /git/repositories                      | repos-{project}.json       |
| 9      | Commit-to-WorkItem Links                   | System.Links where type=Fixed in Changeset | Embedded in workitems JSON |
| 10     | PR-to-WorkItem Links                       | System.Links where type=Pull Request       | Embedded in workitems JSON |

> **2.3 Relationship Types to Capture**

| **ADO Relation Type** | **Reference Name**                     | **Map To GitHub**               |
|-----------------------|----------------------------------------|---------------------------------|
| Parent                | System.LinkTypes.Hierarchy-Reverse     | Sub-issue (parent field)        |
| Child                 | System.LinkTypes.Hierarchy-Forward     | Sub-issue (child reference)     |
| Related               | System.LinkTypes.Related               | Cross-reference in issue body   |
| Predecessor           | System.LinkTypes.Dependency-Forward    | Cross-reference in issue body   |
| Successor             | System.LinkTypes.Dependency-Reverse    | Cross-reference in issue body   |
| Fixed in Changeset    | ArtifactLink type                      | Linked commit URL in issue body |
| Pull Request          | ArtifactLink type                      | Linked PR URL in issue body     |
| Test Case             | Microsoft.VSTS.Common.TestedBy-Forward | Label tested-by:#{id}           |

> **3 What You Must Set Up Manually in GitHub**
>
> **⚠** Everything in this section cannot be scripted and requires human action in the GitHub UI or GitHub API with an admin PAT before migration scripts run.
>
> **3.1 GitHub Organisation Setup**

- [ ] Create GitHub Organization (or confirm existing)

- [ ] Enable GitHub Projects at org level: Settings → Features → Projects

- [ ] Enable Sub-issues Beta: Settings → Features → Sub-issues ← CRITICAL for hierarchy

- [ ] Create target repositories (one per ADO project OR monorepo with labels)

> **3.2 Four GitHub ProjectV2 Boards**

Create one project per ADO project: urvashiEcom-Board, DistEcom-Board, DistEcomAI-Board, urvashiEcomDataIntegrations-Board. For EACH project, create these custom fields:

| **Field Name**          | **Type**      | **Options / Notes**                                                   |
|-------------------------|---------------|-----------------------------------------------------------------------|
| Status                  | Single Select | See per-project state lists in Section 7                              |
| ADO Status              | Single Select | Exact ADO state names --- for traceability                            |
| ADO ID                  | Text          | Original ADO work item ID                                             |
| Priority                | Single Select | 1-Critical, 2-High, 3-Medium, 4-Low                                   |
| Severity                | Single Select | 1-Critical, 2-High, 3-Medium, 4-Low                                   |
| Story Points            | Number        | ---                                                                   |
| Original Estimate (hrs) | Number        | ---                                                                   |
| Completed Work (hrs)    | Number        | ---                                                                   |
| Remaining Work (hrs)    | Number        | ---                                                                   |
| Value Area              | Single Select | Architectural, Business                                               |
| Value Stream            | Single Select | Per project --- see Section 7                                         |
| Activity                | Single Select | Deployment, Design, Development, Documentation, Requirements, Testing |
| Current Environment     | Single Select | DEV, Local, PROD, QA, UAT                                             |
| T-Shirt Size            | Single Select | XS, S, M, L, XL, XXL                                                  |
| Item Category           | Single Select | PIM, Technical, UX                                                    |
| Item SubCategory        | Text          | Full subcategory value from ADO                                       |
| Area Path               | Text          | Full ADO area path for traceability                                   |
| Iteration Path          | Text          | Sprint / release name                                                 |
| Start Date              | Date          | ---                                                                   |
| Target Date             | Date          | ---                                                                   |
| Risk                    | Single Select | 1-High, 2-Medium, 3-Low                                               |

> **3.3 GitHub Labels**

Create these label groups per repository via setup-github-labels.ps1 (update the script with the full list below):

| **Label Group**    | **Labels**                                                                                                                                                                                                                                                |
|--------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Work Item Types    | type:epic, type:feature, type:user-story, type:product-backlog-item, type:task, type:bug, type:change-request, type:impediment, type:uat-review, type:analysis, type:test-plan, type:test-suite, type:test-case, type:shared-steps, type:idea, type:issue |
| Priority           | priority:1-critical, priority:2-high, priority:3-medium, priority:4-low                                                                                                                                                                                   |
| Severity           | severity:1-critical, severity:2-high, severity:3-medium, severity:4-low                                                                                                                                                                                   |
| State              | state:new, state:active, state:in-progress, state:resolved, state:closed, state:done, state:removed, state:blocked, state:on-hold                                                                                                                         |
| Environment        | env:dev, env:local, env:qa, env:uat, env:prod                                                                                                                                                                                                             |
| Area               | area:urvashiecom, area:distecom, area:distecomai, area:dataintegrations                                                                                                                                                                                   |
| Category           | category:pim, category:technical, category:ux                                                                                                                                                                                                             |
| Hierarchy          | hierarchy:epic, hierarchy:feature, hierarchy:story, hierarchy:task                                                                                                                                                                                        |
| Sprint / Iteration | sprint:release-1.1.x, sprint:release-1.2.x, sprint:platform-sprint-N \... (generate from iteration extraction)                                                                                                                                            |

> **3.4 User Accounts in GitHub**
>
> **✖** This is the \#1 reason migrations fail silently. Every ADO user must have a GitHub account, be invited to and accept org membership, and be mapped in user-mappings.json.

Unique users identified in the dataset (partial list --- run extract-users.ps1 for complete list):

- Stas Ivash, Anthony Giordano, Jamahal Winston, Serkan Nizam, Bryan Alvarez

- Eric Arnquist, Prachi Dahate, Sydney Cucerzan, Tim Tsu, Richard Jung, Don Francis

- sadhana.gupta + all others identified in the 14,478 item extraction

**User action policy --- decide before migration starts:**

- Option A: Create GitHub accounts for all migrated users (requires IT coordination)

- Option B: Assign to migration-bot default user; preserve original name in issue body metadata

- Option C: Map to team owner as default; note original assignee in issue body

> **4 GitHub Structural Limitations & Workarounds**

Understanding these limits prevents designing a migration that is impossible to execute. Every limitation has a documented workaround.

| **ADO Capability**                                                | **GitHub Reality**                                           | **Recommended Workaround**                                                                      |
|-------------------------------------------------------------------|--------------------------------------------------------------|-------------------------------------------------------------------------------------------------|
| 4-level hierarchy: Epic → Feature → Story → Task                  | Sub-issues (Beta) --- only 1 level natively in UI            | Use Sub-issues for direct parent only; embed full ancestry in issue body as metadata block      |
| Per-work-item-type state machines (Bug: 9 states, Task: 5 states) | Single Status field on ProjectV2 --- shared across all types | Create ADO Status custom field with ALL exact states; use Status for simplified Kanban view     |
| Typed custom fields (HTML, Identity, Date, Decimal, Picklist)     | Only Text, Number, Date, Single Select in ProjectV2          | Identity → Text (username); HTML → Markdown in body; Decimal → Number; Picklist → Single Select |
| Acceptance Criteria as separate HTML field                        | No equivalent field in GitHub                                | Embed as \## Acceptance Criteria section in issue body                                          |
| Repro Steps as separate HTML field                                | No equivalent field in GitHub                                | Embed as \## Repro Steps section in issue body                                                  |
| Test Plans / Suites / Cases as first-class objects                | No native test management in GitHub Issues                   | Migrate as issues with type:test-plan/suite/case labels; link via sub-issues for structure      |
| Work Item History --- full audit trail of every field change      | No equivalent in GitHub Issues                               | Store full history JSON as \<details\> collapsed block in a comment                             |
| Area Path as hierarchical org structure                           | No equivalent in GitHub                                      | Flatten to labels + custom text field for full path                                             |
| Timestamps: created_at in the past                                | GitHub API cannot set created_at to a past date              | Preserve original dates in ADO metadata block at bottom of issue body                           |
| 18,000 items at 10 API calls each                                 | 5,000 req/hr GitHub REST rate limit                          | Run parallel pipelines per project; checkpoint-based resume via migration-log.json              |

> **5 Complete Data Model Mapping**
>
> **5.1 Standard Issue Body Structure**

Every GitHub Issue body must contain a standardized ADO metadata block. This ensures traceability without relying on ProjectV2 fields alone.

> \## {Title}
>
> {description_converted_from_html_to_markdown}
>
> \## Acceptance Criteria
>
> {acceptance_criteria_markdown}
>
> \## Repro Steps ← Bug only
>
> {repro_steps_markdown}
>
> \-\--
>
> \<!\-- ADO METADATA --- DO NOT EDIT \--\>
>
> \| Field \| Value \|
>
> \|\-\-\-\-\-\-\-\-\-\-\-\-\-\-\--\|\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-\-\--\|
>
> \| ADO ID \| {id} \|
>
> \| ADO Type \| {work_item_type} \|
>
> \| ADO State \| {state} \|
>
> \| ADO Project \| {team_project} \|
>
> \| Created By \| {created_by} \|
>
> \| Created Date \| {created_date} \|
>
> \| Area Path \| {area_path} \|
>
> \| Iteration Path \| {iteration_path} \|
>
> \| Stack Rank \| {stack_rank} \|
>
> \| ADO URL \| \[View in ADO\]({ado_url}) \|
>
> \<!\-- END ADO METADATA \--\>
>
> **5.2 State Mapping --- urvashiEcom (bunzlweb Scrum)**

| **Work Item Type** | **ADO States**                                                                                                                       | **GitHub Status**                                                                                                            |
|--------------------|--------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------|
| Bug                | New, Committed, Assigned, In Progress, In PR, Ready for Testing, In Testing, On Hold, Done                                           | Backlog → Backlog → In Progress → In Progress → In Review → Ready → In Review → On Hold → Done                               |
| Task               | To Do, Blocked, In Progress, In QA, Done, Removed                                                                                    | Backlog → Blocked → In Progress → In Review → Done → Done                                                                    |
| Feature            | New, Assigned, In Progress, Committed, In PR, Dev Done, In QA, QA Complete, In UAT, UAT Complete, On Hold, Done                      | Backlog → Backlog → In Progress → In Progress → In Review → In Review → In Review → Done → In Review → Done → On Hold → Done |
| Epic               | New, In Progress, Done, Removed                                                                                                      | Backlog → In Progress → Done → Done                                                                                          |
| PBI                | New, Committed, Assigned, In Progress, In PR, Ready for Testing, In Testing, On Hold, Dev Testing complete, In Dev Environment, Done | Backlog → Backlog → In Progress → In Progress → In Review → Ready → In Review → On Hold → Done → In Progress → Done          |
| Change Request     | New, Assigned, Committed, In Progress, In PR, Ready for Testing, In Testing, On Hold, Ready for Release, Done, Removed               | Backlog → Backlog → Backlog → In Progress → In Review → Ready → In Review → On Hold → Ready → Done → Done                    |
| UAT Review         | New, Assigned, Committed, In Progress, In PR, In UAT, Done, Removed                                                                  | Backlog → Backlog → Backlog → In Progress → In Review → In Review → Done → Done                                              |
| Analysis           | New, Committed, Done                                                                                                                 | Backlog → In Progress → Done                                                                                                 |
| Impediment         | Open, Closed                                                                                                                         | In Progress → Done                                                                                                           |

> **5.3 State Mapping --- DistEcom**

| **Work Item Type**        | **ADO States**                           | **GitHub Status**                                 |
|---------------------------|------------------------------------------|---------------------------------------------------|
| Epic, Feature, User Story | New, Active, Resolved, Closed, Removed   | Backlog → In Progress → Done → Done → Done        |
| Bug                       | New, PO Review, Active, Resolved, Closed | Backlog → In Progress → In Progress → Done → Done |
| Task                      | New, Active, Resolved, Closed            | Backlog → In Progress → Done → Done               |
| Issue, Idea               | Active/New, Closed                       | In Progress → Done                                |

> **ℹ** The ADO Status custom field in ProjectV2 must contain every unique state across all 4 projects --- approximately 39 distinct states total.
>
> **6 User Mapping Strategy**
>
> **6.1 How to Build the Complete User Map**

| **Step** | **Action**                                                                                                | **Tool / API**                       |
|----------|-----------------------------------------------------------------------------------------------------------|--------------------------------------|
| 1        | Run extract-users.ps1 to get ALL unique AssignedTo and CreatedBy values across all 14,478 items           | 00-extract/extract-users.ps1         |
| 2        | Query ADO for each user profile: get email, display name, alternate email                                 | GET /\_apis/identities/{id}          |
| 3        | For each ADO user, find their GitHub username --- by asking directly, or matching by email via GitHub API | GET /search/users?q={email}+in:email |
| 4        | For users with no GitHub account, apply the user policy decided in Section 3.4                            | Update user-mappings.json            |
| 5        | Validate 100% mapping: run validate-mappings.ps1 --- zero unmapped users allowed                          | 02-prep/validate-mappings.ps1        |

> **6.2 user-mappings.json Structure**
>
> **⚠** The current file only has 7 users. You need to expand it to cover every user across all 14,478 items.
>
> {
>
> \"mappings\": \[
>
> {
>
> \"adoDisplayName\": \"Bryan Alvarez - Bunzl Corporate\",
>
> \"adoEmail\": \"bryan.alvarez@bunzl.com\",
>
> \"adoUniqueName\": \"bryan.alvarez@bunzl.com\",
>
> \"adoAlternateEmails\": \[\],
>
> \"githubUsername\": \"bryan-alvarez-bunzl\",
>
> \"team\": \"platform\",
>
> \"active\": true
>
> }
>
> // \... one entry per unique ADO user
>
> \],
>
> \"defaultGithubUser\": \"migration-bot\",
>
> \"unmappedUserAction\": \"assign-default\",
>
> \"unmappedUserLog\": true
>
> }
>
> **7 Project-by-Project Field & State Inventory**
>
> **7.1 urvashiEcom --- 7,612 items \| bunzlweb Scrum**

| **Work Item Type**   | **Count** | **Unique States**                                                                                                                    |
|----------------------|-----------|--------------------------------------------------------------------------------------------------------------------------------------|
| Bug                  | 2,500     | New, Committed, Assigned, In Progress, In PR, Ready for Testing, In Testing, On Hold, Done                                           |
| Task                 | 3,190     | To Do, Blocked, In Progress, In QA, Done, Removed                                                                                    |
| Product Backlog Item | 966       | New, Committed, Assigned, In Progress, In PR, Ready for Testing, In Testing, On Hold, Dev Testing complete, In Dev Environment, Done |
| Change Request       | 557       | New, Assigned, Committed, In Progress, In PR, Ready for Testing, In Testing, On Hold, Ready for Release, Done, Removed               |
| Feature              | 153       | New, Assigned, In Progress, Committed, In PR, Dev Done, In QA, QA Complete, In UAT, UAT Complete, On Hold, Done                      |
| Test Suite           | 60        | In Planning, In Progress, Completed                                                                                                  |
| Test Case            | 105       | Design, Ready, Closed                                                                                                                |
| Test Plan            | 6         | Active, Inactive                                                                                                                     |
| UAT Review           | 19        | New, Assigned, Committed, In Progress, In PR, In UAT, Done, Removed                                                                  |
| Epic                 | 37        | New, In Progress, Done, Removed                                                                                                      |
| Analysis             | 12        | New, Committed, Done                                                                                                                 |
| Impediment           | 6         | Open, Closed                                                                                                                         |
| Shared Steps         | 1         | Active, Closed                                                                                                                       |

**Custom Fields --- urvashiEcom**

| **Field Name**      | **Type** | **Values**                                                                                                                                                                                                                                     |
|---------------------|----------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Current Environment | Picklist | DEV, Local, PROD, QA, UAT                                                                                                                                                                                                                      |
| Severity            | Picklist | 1-Critical, 2-High, 3-Medium, 4-Low                                                                                                                                                                                                            |
| Item Category       | Picklist | PIM, Technical, UX                                                                                                                                                                                                                             |
| Item SubCategory    | Picklist | PIM-Audit, PIM-PIM Issues, PIM-Recategorization, PIM-Search, Technical-Engineering, Technical-Performance, Technical-Tech Errors, Technical-Translations, UX-Admin, UX-Order Approvals, UX-Order History, UX-Orders, UX-PDP, UX-PLP, UX-Search |
| Value Area          | Picklist | Architectural, Business                                                                                                                                                                                                                        |
| Activity            | Picklist | Deployment, Design, Development, Documentation, Requirements, Testing                                                                                                                                                                          |

> **7.2 DistEcom --- 6,679 items \| DistEcom Process 2023**

| **Work Item Type** | **Count** | **Unique States**                        |
|--------------------|-----------|------------------------------------------|
| Task               | 3,607     | New, Active, Resolved, Closed            |
| User Story         | 2,130     | New, Active, Resolved, Closed, Removed   |
| Bug                | 708       | New, PO Review, Active, Resolved, Closed |
| Feature            | 158       | New, Active, Resolved, Closed, Removed   |
| Epic               | 34        | New, Active, Resolved, Closed, Removed   |
| Test Suite         | 8         | In Planning, In Progress, Completed      |
| Test Plan          | 2         | Active, Inactive                         |
| Test Case          | 10        | Design, Ready, Closed                    |
| Issue              | 14        | Active, Closed                           |
| Idea               | 7         | New, Active, Closed                      |
| Shared Parameter   | 1         | Active, Inactive                         |

**Custom Fields --- DistEcom**

| **Field Name**      | **Type** | **Values**                                                                                                               |
|---------------------|----------|--------------------------------------------------------------------------------------------------------------------------|
| Value Stream        | Picklist | Architecture, Business, Business Request, Compliance, Functional, Idea, Operational, Release Management, User Experience |
| Risk                | Picklist | 1-High, 2-Medium, 3-Low                                                                                                  |
| Automation Status   | Picklist | Not Automated, Planned                                                                                                   |
| Activity            | Picklist | Deployment, Design, Development, Documentation, Requirements, Testing                                                    |
| Current Environment | Picklist | DEV, Local, PROD, QA, UAT                                                                                                |
| Value Area          | Picklist | Architectural, Business                                                                                                  |

> **7.3 DistEcomAI Intelligence Platform --- 186 items \| Scrum -- Inherited**

| **Work Item Type** | **Count** | **Custom Fields**                           |
|--------------------|-----------|---------------------------------------------|
| Task               | 108       | Severity, Resolved Reason, Risk, Value Area |
| User Story         | 48        | Severity, Resolved Reason, Risk, Value Area |
| Feature            | 22        | Severity, Resolved Reason, Risk, Value Area |
| Epic               | 7         | Severity, Resolved Reason, Risk, Value Area |
| Bug                | 1         | Severity, Resolved Reason, Risk, Value Area |

**Resolved Reason values (DistEcomAI):**

- As Designed, Cannot Reproduce, Copied to Backlog, Deferred, Duplicate

- Fixed, Fixed and verified, Obsolete, Will not Fix

> **8 Migration Pipeline Architecture**
>
> **8.1 Enhanced Folder Structure**
>
> boards-migration/
>
> ├── config/
>
> │ ├── boards-migration-config.json \# Main config (update per project)
>
> │ ├── status-mappings.json \# Full per-project/per-type state maps
>
> │ ├── user-mappings.json \# Complete user map (ALL item authors)
>
> │ ├── workitem-type-mappings.json \# WIT → label mappings
>
> │ ├── field-mappings.json \# ← NEW: Custom field → GitHub field maps
>
> │ ├── area-path-mappings.json \# ← NEW: Area tree → label maps
>
> │ └── iteration-mappings.json \# ← NEW: Sprint → milestone maps
>
> ├── 00-extract/ \# ← NEW PHASE: Full ADO extraction
>
> │ ├── extract-all-fields.ps1 \# Get all process fields with types
>
> │ ├── extract-workitems-full.ps1 \# All work items with ALL fields
>
> │ ├── extract-relationships.ps1 \# Parent/child/related links
>
> │ ├── extract-users.ps1 \# All unique users
>
> │ └── extract-iterations.ps1 \# Full sprint/iteration tree
>
> ├── 01-discover/ (existing --- enhanced)
>
> ├── 02-prep/
>
> │ ├── setup-github-labels.ps1 \# Existing --- update label list
>
> │ ├── setup-github-fields.ps1 \# ← NEW: Create all ProjectV2 custom fields
>
> │ └── setup-github-milestones.ps1 \# ← NEW: Create milestones from iterations
>
> ├── 03-migrate/
>
> │ ├── migrate-workitems.ps1 \# Existing --- major enhancements needed
>
> │ ├── link-hierarchy.ps1 \# ← NEW: Second pass --- wire sub-issues
>
> │ ├── migrate-comments.ps1 \# ← NEW: Separate comments phase
>
> │ └── migrate-attachments.ps1 \# ← NEW: Separate attachments phase
>
> └── 04-validate/ (existing --- enhanced)
>
> **8.2 Key Script Fixes Required**

**Fix 1: Hierarchy --- Two-Pass Migration**

- Pass 1: Create all GitHub issues with no parent linking. Store ADO_ID → GitHub_Issue_Number in migration-log.json

- Pass 2 (link-hierarchy.ps1): For every item with a parent in ADO, call GitHub Sub-issues API using the migration log to link child to parent issue

**Fix 2: HTML Body Conversion (Pandoc Required on Agent)**

> function Convert-HtmlToMarkdown {
>
> param(\[string\]\$Html)
>
> if (\[string\]::IsNullOrEmpty(\$Html)) { return \'\' }
>
> \$tmpIn = \[System.IO.Path\]::GetTempFileName() + \'.html\'
>
> \$tmpOut = \[System.IO.Path\]::GetTempFileName() + \'.md\'
>
> \$Html \| Set-Content -Path \$tmpIn -Encoding UTF8
>
> & pandoc -f html -t gfm \--wrap=none -o \$tmpOut \$tmpIn
>
> \$md = Get-Content \$tmpOut -Raw -Encoding UTF8
>
> Remove-Item \$tmpIn, \$tmpOut -Force
>
> return \$md
>
> }

**Fix 3: Custom Fields via GraphQL Mutation**

After creating each issue and adding it to the project, call this mutation for every custom field:

> mutation {
>
> updateProjectV2ItemFieldValue(input: {
>
> projectId: \"{projectId}\"
>
> itemId: \"{itemId}\"
>
> fieldId: \"{fieldId}\"
>
> value: { singleSelectOptionId: \"{optionId}\" }
>
> }) { projectV2Item { id } }
>
> }
>
> **⚠** Pre-load ALL field IDs and option IDs at migration start. Fetching them per-item will exhaust your rate limit.

**Fix 4: Rate Limiting at 14k Items**

| **API**        | **Limit**            | **Estimate at 14k items**        | **Strategy**                                              |
|----------------|----------------------|----------------------------------|-----------------------------------------------------------|
| GitHub REST    | 5,000 req/hr         | \~145,000 calls total (\~30 hrs) | Checkpoint resume via migration-log.json; run per-project |
| GitHub GraphQL | 5,000 points/hr      | \~1 point per field update       | Batch field updates; pre-load all field/option IDs        |
| ADO REST       | 200 items/WIQL batch | \~73 WIQL batches                | Already handled in existing scripts                       |

> **9 Phase-by-Phase Execution Plan**

| **Phase**                        | **Description**                                                                                          | **Duration**          | **Output**                          |
|----------------------------------|----------------------------------------------------------------------------------------------------------|-----------------------|-------------------------------------|
| Phase 0 --- POC                  | 50-item proof of concept from urvashiEcom; validate 100% fidelity before touching full dataset           | 1--2 weeks            | Validated pipeline + fixed scripts  |
| Phase 1 --- Infra Setup          | Create GitHub org, repos, boards, labels, fields, milestones, user accounts                              | 3--5 days             | Fully configured GitHub environment |
| Phase 2 --- Full Extraction      | Extract all ADO data across 4 projects (work items, relations, comments, attachments, areas, iterations) | 2--3 days             | 14,478 items in data/ directory     |
| Phase 3 --- Dry Run              | Run full migration pipeline with dryRun: true; fix all unmapped users/states/fields                      | 1 day                 | Clean dry-run log, zero errors      |
| Phase 4 --- Production Migration | Migrate in order: DataIntegrations (1) → DistEcomAI (186) → DistEcom (6679) → urvashiEcom (7612)         | 2--3 days per project | 14,478 GitHub Issues created        |
| Phase 5 --- Validation           | Automated count checks + manual spot-check of 20 items across all types and states                       | 1--2 days             | Full audit report                   |

> **9.1 POC Item Selection (Phase 0)**

Pick 50 items from urvashiEcom that cover all edge cases:

- 2 Epics with Feature children

- 5 Features with PBI children

- 10 PBIs with Task children

- 20 Tasks (mix of all states including Blocked, Removed)

- 10 Bugs (including Done, Removed, all severity levels)

- 3 Test items (1 Test Plan, 1 Test Suite with Test Case)

- At least 5 items with comments containing images

- At least 5 items with file attachments

- At least 3 items with Related and Predecessor links

- Items covering all custom fields (CurrentEnvironment, ItemCategory, SubCategory)

> **10 POC Setup: Step-by-Step**

| **Step** | **Action**                                                                               | **Config / Script**                                                                     |
|----------|------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------|
| 1        | Create POC ADO project using bunzlweb Scrum process; create 50 representative test items | Manual --- ADO UI                                                                       |
| 2        | Confirm GitHub repo ado-migration-poc and ProjectV2 \#2 exist                            | config/boards-migration-config.json                                                     |
| 3        | Add ALL custom fields from Section 3.2 to the GitHub project                             | Manual --- GitHub UI → Project Settings                                                 |
| 4        | Update user-mappings.json: add all users from the 50 test items                          | config/user-mappings.json                                                               |
| 5        | Update field-mappings.json with all custom fields and their option values                | config/field-mappings.json (new file)                                                   |
| 6        | Run Stage 1: extract all 50 items with full field expansion                              | 00-extract/extract-workitems-full.ps1                                                   |
| 7        | Run Stage 2: discover workflows and generate state/field report                          | 01-discover/discover-ado-workflows.ps1                                                  |
| 8        | Run Stage 3: create labels, custom fields, milestones in GitHub                          | 02-prep/setup-github-labels.ps1 → setup-github-fields.ps1 → setup-github-milestones.ps1 |
| 9        | Run Stage 4: validate-mappings.ps1 --- verify zero unmapped entries                      | 02-prep/validate-mappings.ps1                                                           |
| 10       | Run Stage 5 Pass 1: migrate all 50 issues (no hierarchy)                                 | 03-migrate/migrate-workitems.ps1                                                        |
| 11       | Run Stage 5 Pass 2: link all parent-child relationships                                  | 03-migrate/link-hierarchy.ps1                                                           |
| 12       | Run Stage 5 Pass 3: migrate all comments                                                 | 03-migrate/migrate-comments.ps1                                                         |
| 13       | Run Stage 5 Pass 4: migrate all attachments                                              | 03-migrate/migrate-attachments.ps1                                                      |
| 14       | Run Stage 6: generate full audit report                                                  | 04-validate/generate-report.ps1                                                         |
| 15       | Manually verify all 50 items against POC Validation Checklist in Section 12              | Manual review                                                                           |

> **11 Known Limitations & Hard Decisions**

These require decisions from the project lead before migration starts. There is no technical workaround that eliminates the need to choose.

| **Limitation**                                                                                     | **Decision Required**                                                                                                                                    | **Recommended**                                                             |
|----------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------|
| Test Plan hierarchy --- ADO has Test Plans → Suites → Cases. GitHub has no native test management. | Option A: Migrate as Issues with sub-issue hierarchy. Option B: Accept loss of test infra, document in body. Option C: Evaluate GitHub\'s test features. | Option A --- preserves structure; loses test-specific execution tracking    |
| Shared Steps --- one step referenced by 100 Test Cases. GitHub has no shared/reusable concept.     | Migrate Shared Step as standalone issue; add cross-reference link in each Test Case body.                                                                | Accept the duplication --- cross-reference links maintain traceability      |
| Work Item History --- full audit trail of every field change with author + date.                   | No equivalent in GitHub. Preserve as \<details\> collapsed JSON block in a comment.                                                                      | Preserve history in collapsed comment --- accessible but not surfaced in UI |
| ADO original timestamps --- GitHub API cannot set created_at to a past date.                       | All issues appear as created at migration time.                                                                                                          | Preserve original dates in ADO metadata block. Accept the limitation.       |
| Removed items (1,229 items in Removed state)                                                       | Include them (label: state:removed) to maintain referential integrity, or exclude and accept broken parent-child links.                                  | Include all Removed items                                                   |
| 18,000 item org-wide scale --- full migration \~36 hours at safe API rate                          | Run in parallel pipelines per project, or request GitHub Enterprise rate limit increase.                                                                 | Parallel per-project pipelines with checkpoint resume                       |

> **12 Validation Checklist**
>
> **Pre-Migration**

- [ ] All 4 GitHub repos created

- [ ] All 4 ProjectV2 boards created with all 20+ custom fields

- [ ] All labels created in all repos (type, priority, severity, state, env, area, hierarchy, sprint)

- [ ] All milestones created from iteration path extraction

- [ ] User mappings: 100% of unique ADO users mapped in user-mappings.json

- [ ] State mappings: 100% of unique ADO states mapped (39 unique states)

- [ ] Field mappings: all custom fields and their options mapped

- [ ] Area path mappings: full tree mapped to labels

- [ ] Pandoc installed on pipeline agent

- [ ] ADO PAT has Read permissions: Work Items, Code, Graph, Identity

- [ ] GitHub PAT has: repo, read:org, project, write:discussion

> **Post-Migration Item Counts**

- [ ] urvashiEcom: 7,612 GitHub issues created

- [ ] DistEcom: 6,679 GitHub issues created

- [ ] DistEcomAI: 186 GitHub issues created

- [ ] DataIntegrations: 1 GitHub issue created

- [ ] Total: 14,478 GitHub issues

> **Post-Migration Quality Checks**

- [ ] All Epics have correct Feature sub-issues

- [ ] All Features have correct User Story / PBI sub-issues

- [ ] All Tasks / Bugs linked to parent Story or Feature

- [ ] Zero orphaned items (items whose parent failed to migrate)

- [ ] Spot-check 50 items: all ProjectV2 custom fields populated

- [ ] Zero items with null or unmapped Status

- [ ] Zero items with empty ADO ID field

- [ ] All closed ADO items are closed (state: done) in GitHub

- [ ] Total comment count matches ADO comment count

- [ ] All image attachments in comments are accessible --- no 404 errors

- [ ] All file attachments re-uploaded and links updated in issue body

> **13 Rollback Strategy**

| **Scenario**                                                 | **Recovery Action**                                                                                                                                      |
|--------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------|
| Migration failed mid-run                                     | migration-log.json tracks every migrated ADO ID → GitHub Issue number. Re-run with -Resume flag. Script skips already-migrated items automatically.      |
| Data quality issues discovered post-migration                | Run cleanup-github-issues.ps1 (uses migration-log.json to get issue numbers). Fix the mapping or script issue. Re-run from scratch.                      |
| GitHub Project fields are wrong                              | Write a targeted fix script that reads migration-log, re-reads ADO data, and updates only the affected GraphQL field values. No need to recreate issues. |
| Hierarchy links are missing                                  | link-hierarchy.ps1 (Pass 2) is idempotent --- re-running it on an existing migration re-attempts linking without creating duplicate issues.              |
| Need to migrate only new items added after initial migration | Use the -Resume flag plus a date filter in the WIQL query. Items already in migration-log.json are skipped.                                              |

ADO → GHA Migration Master Plan \| Version 1.0 \| April 2026

Tool Stack: PowerShell 7 \| ADO REST API v7.1 \| GitHub REST v3 \| GitHub GraphQL v4 \| Pandoc
