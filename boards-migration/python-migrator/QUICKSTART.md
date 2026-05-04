# Quick Start Guide - Enhanced ADO→GHE Migration

## 5-Minute Setup

### 1. Prerequisites
```bash
python --version          # Python 3.8+
pip install -r requirements.txt
```

### 2. Configure Credentials
Create `.env` file in project root:
```env
ADO_ORG=your-ado-organization
ADO_PROJECT=your-ado-project
ADO_PAT=your-ado-personal-token
GITHUB_TOKEN=your-github-personal-token
GITHUB_OWNER=your-github-user-or-org
GITHUB_REPO=your-github-repo
GITHUB_ORG=your-github-org
```

### 3. Run Migration
```bash
# Dry run (preview)
python migrate.py --dry-run

# Full migration
python migrate.py

# Selective features
python migrate.py --skip-attachments --skip-delivery-plans
```

---

## What Gets Migrated

✅ **Work Items** → GitHub Issues
- Titles, descriptions, comments
- Labels (type, state, tags, priority)
- Story points, assignees, created date
- Status (open/closed)

✅ **Relationships** → GitHub Issue Links
- Parent/Child hierarchies
- Dependencies (blocks/blocked-by)
- Related items

✅ **Sprints** → GitHub Milestones
- Sprint names → milestone titles
- Work item assignments → milestone membership
- Sprint dates in milestone description

✅ **Boards** → GitHub Projects v2
- Board columns → custom Status field
- Card placements → project items
- WIP limits → metadata

✅ **Saved Queries** → GitHub Filters
- WIQL conversions to label combinations
- Searchable filter guide (GITHUB_FILTERS.md)
- JSON mapping for automation

✅ **Delivery Plans** → Timeline Exports
- Work item timeline (CSV)
- Visual timeline (Mermaid diagram)
- Roadmap (Markdown)
- Critical path (JSON)

✅ **Attachments** → GitHub Release Assets (optional)
- Files attached to work items
- Linked from GitHub issue descriptions

---

## Step-by-Step Example

### Scenario: Migrate a 500-item backlog with sprints and dependencies

```bash
# Step 1: Dry run (verify everything looks good)
python migrate.py --dry-run --limit 50

# Step 2: Check logs
tail -100 migration.log

# Step 3: Full migration
python migrate.py

# Step 4: Monitor progress
# (watch logs in real-time)
tail -f migration.log

# Step 5: Resume if needed
python migrate.py --resume-from 100
```

---

## Output Files

After migration, you'll find:

| File | Purpose |
|------|---------|
| `migration.log` | Detailed execution log |
| `migration_progress.json` | Resume state & mappings |
| `query_map.json` |  Saved queries mapping |
| `GITHUB_FILTERS.md` |  Search filter guide |
| `timeline.csv` |  Delivery timeline data |
| `timeline.mmd` |  Mermaid gantt chart |
| `ROADMAP.md` |  Markdown roadmap |
| `critical_path.json` |  Critical dependencies |

---

## Verification Checklist

After migration completes:

- [ ] Check `migration.log` for errors
- [ ] Count issues in GitHub (should match ADO)
- [ ] Verify parent/child links (click on issues)
- [ ] Check milestones match sprints
- [ ] Review GitHub Projects status field
- [ ] Test label searches (use GITHUB_FILTERS.md)
- [ ] View timeline.mmd or ROADMAP.md
- [ ] Spot-check critical work items

---

## Common Scenarios

### I only want to migrate issues, not sprints or queries

```bash
python migrate.py --skip-sprints --skip-queries --skip-delivery-plans
```

### I want to test on a small subset first

```bash
python migrate.py --limit 50 --dry-run
```

### I need to re-run part of the migration

```bash
python migrate.py --resume-from 500
```

### I want a visual timeline of my delivery plan

```bash
python migrate.py --skip-boards --skip-relations
# Then view timeline.mmd in your editor with Mermaid preview
```

### I want to export query conversions without migrating issues

```bash
# Manually:
python -c "import queries; queries.configure('org', 'proj', 'pat'); queries.export_query_map()"
```

---

## Troubleshooting

### Migration is slow
- Normal: 10-15 minutes for 1000 items with all features
- Check: Network latency to ADO/GitHub APIs
- Solution: Use `--skip-attachments` to speed up

### Rate limit error
- Check: `migration.log` for "Rate limit low"
- Wait: Script auto-waits for rate limits to reset
- Solution: Run during off-hours for large migrations

### Some work items didn't migrate
- Check: `migration_progress.json` → `migrated` section
- Check: `migration.log` for errors on those items
- Resume: `python migrate.py --resume-from <id>`

### Relations/sprints not showing up
- Verify: In `migration_progress.json` that they're tracked
- Check: GitHub UI for new issue links and milestones
- Verify: ADO has those relationships/sprints configured

---

## Next: Team Setup

1. **Announce migration** - Team should use GitHub issues now
2. **Share GITHUB_FILTERS.md** - Help team find their saved queries
3. **Document ROADMAP.md** - Pin to repo README
4. **Create GitHub views** - Filter by sprint, type, status
5. **Archive ADO project** - Keep as read-only reference

---

## Need More Details?

- See `ENHANCED_FEATURES.md` for complete feature documentation
- See `migrate.py` for all available options
- See `migration.log` for detailed execution flow
- Check module docstrings (relations.py, sprints.py, etc.)

## Token permissions for Projects v2
  Your GITHUB_TOKEN must have the "Projects" permission:
    Fine-grained: Projects → Read & Write
    Classic:      project scope (top-level checkbox)
  Without this, GraphQL project mutations return a 403.

## Resume safety
  migration_progress.json tracks:
    migrated:  {ado_id: gh_issue_number}
    projects:  {ado_board_id: {project_id, title}}
  Re-running skips already-migrated issues and reuses existing projects.
  
## What gets created in GitHub

  For every ADO board a new GitHub Project v2 is created:
    Name:   "{ADO_PROJECT} – {Board Name}"

  Custom fields added to each project:
    Status       (single-select)  — one option per ADO board column
    ADO ID       (text)           — original ADO work item ID
    Sprint       (text)           — iteration path last segment
    Story Points (number)         — effort / story points

  Each migrated GitHub issue is:
    - Added to the matching project
    - Placed in the correct Status column (matching ADO board column)
    - Also tagged with a "board:{column}" label on the issue itself

## ADO Board → GitHub Project mapping

  ADO concept          GitHub Projects v2 equivalent
  ─────────────────────────────────────────────────────────────────
  Board                Project v2
  Column               Status field option (single-select)
  Swimlane             Not directly supported; mapped to a label
  WIP limit            Documented in project description (not enforced)
  Card (work item)     Project item linked to a GitHub Issue
  Area path            Label (area:…) + issue body metadata
  Iteration path       Milestone + Sprint text field

## Why GraphQL?
  GitHub Projects v2 has no REST API. All mutations (create project,
  add field, add item, set field value) must use the GraphQL API at
  https://api.github.com/graphql. The gh_projects.py module handles
  all GraphQL calls so migrate.py stays readable.

## Troubleshooting
  "Cannot resolve node ID for owner"
      → GITHUB_ORG doesn't match any org or user on GitHub
  "GraphQL error: NOT_FOUND on addProjectV2ItemById"
      → issue node_id is stale; REST /issues/{n} returns current node_id
  "403 on createProjectV2"
      → token missing Projects R/W permission
  Empty col_items from get_board_work_items
      → board items preview endpoint unavailable; WIQL fallback used,
        which queries System.BoardColumn. Verify work items have this field.
  "422 on milestone create"
      → milestone already exists, safe to ignore (reused automatically)
---

**Time to migrate:** 5 minutes setup + 10-30 minutes execution (depending on size)

**Questions?** Check the logs and ENHANCED_FEATURES.md troubleshooting section.
