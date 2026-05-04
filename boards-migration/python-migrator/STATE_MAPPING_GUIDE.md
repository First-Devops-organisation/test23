# ADO State to GitHub Mapping Guide

## The Issue

**ADO Work Item States:**
- New
- Active
- In Progress
- Closed
- Resolved
- Done
- Removed

**GitHub Issue States:**
- Open
- Closed

GitHub has only 2 states, while ADO has 7+. Here's how we handle this:

---

## Current Implementation

### 1. GitHub Issue State (open/closed)
```python
if st in CLOSED_STATES:  # Closed, Resolved, Done, Removed
    state = "closed"
else:  # New, Active, In Progress
    state = "open"
```

✅ **Works:** Closed ADO items → Closed GitHub issues  
✅ **Works:** Active ADO items → Open GitHub issues

### 2. Detailed State Preservation (Labels)
```
ADO State "Active"        → GitHub label "state:active"
ADO State "In Progress"   → GitHub label "state:in-progress"
ADO State "Closed"        → GitHub label "state:closed" + issue closed
```

✅ **Works:** State labels visible and searchable  
✅ **Works:** Filter by `label:state:active` to find "Active" items

### 3. Board Column (Project Status)
When migrating boards, we also set the project Status field based on board column:
```
Board Column "In Progress" → Project field Status = "In Progress"
```

---

## Why GitHub Issues Don't Have "Active" State

GitHub chose to keep issues simple with open/closed. The reasoning:
- **Open** = needs work (could be New, Active, In Progress, Waiting for Review, etc.)
- **Closed** = done (could be Resolved, Won't Fix, Duplicate, etc.)

Detailed states are captured via:
- ✅ Labels (state:active, state:in-progress)
- ✅ Project custom fields (Status, State)
- ✅ Issue timeline (created, moved to project column, commented, closed)

---

## How to Find "Active" Items in GitHub

### Option 1: Use Label Filters
```
label:state:active          # All Active items
label:state:active -label:state:closed  # Only open Active items
```

### Option 2: Search in GitHub UI
1. Go to Issues
2. Filter: `label:state:active`
3. Results show all items that were "Active" in ADO

### Option 3: Use Project View
1. Go to Projects → Your Project
2. Group by Status column
3. See "Active" group

---

## Recommended Workflow

### For Developers
Use GitHub label filters to replicate your ADO searches:

**Instead of ADO query:**
```sql
SELECT * WHERE State = 'Active' AND WorkItemType = 'Task'
```

**Use GitHub search:**
```
label:state:active label:type:task
```

### For Project Managers
Use the GitHub Projects view with Status field:
1. Create a project
2. Add Status field (matches ADO board columns)
3. Filter view to show Status = "In Progress"
4. This shows your "active work"

---

## What's Preserved in Migration

✅ **Issue State (open/closed)** - Based on ADO closed states  
✅ **State Label** - state:active, state:in-progress, etc.  
✅ **Board Column** - Mapped to project Status field  
✅ **Created Date** - In issue metadata  
✅ **History** - In issue comments and timeline  

---

## Example: Finding "Active" Work in GitHub

### Scenario: Find all Active Tasks

**In ADO:**
```sql
SELECT [System.Id], [System.Title]
FROM WorkItems
WHERE [System.State] = 'Active'
  AND [System.WorkItemType] = 'Task'
ORDER BY [System.CreatedDate]
```

**In GitHub:**
```
Search: label:state:active label:type:task is:open
```

**Or use GitHub UI:**
1. Issues tab
2. Filter: Label = "state:active"
3. Filter: Label = "type:task"  
4. Filter: Status = "Open"

---

## Known Limitations & Workarounds

### Limitation: Can't set issue state to "Active"
**Reason:** GitHub only supports open/closed for issues

**Workaround:**
- Use labels: `state:active` indicates this is an "Active" item
- Use project Status field to show detailed state
- Filter issues by labels to find "Active" work

### Limitation: "Active" is a label, not a status
**Reason:** GitHub architecture

**Workaround:**
- Teams learn to search by labels: `label:state:active`
- Or use Projects view with Status field
- Either approach gives you the same items as ADO "Active" state

---

## Project Field Workaround (Advanced)

If you want "State" as a project field rather than just a label:

1. **Option A:** Use GitHub Projects Status field
   - Already done during board migration
   - Shows: Backlog, In Progress, Done, etc.
   - Not the same as ADO states, but similar concept

2. **Option B:** Add custom "ADO State" field
   - Would require manual project setup
   - Could map: state:active → State field = "Active"
   - More work but gives exact ADO state representation

---

## Questions & Answers

**Q: Why is my "Active" task showing as "Open" in GitHub?**  
A: GitHub has only open/closed states. "Active" is captured in the `state:active` label instead. Search by `label:state:active` to find it.

**Q: Can I make GitHub show "Active" instead of "Open"?**  
A: Not natively. But you can:
- Use the `state:active` label
- Filter issues by this label
- Or use a project board with Status field

**Q: How do I find all the "In Progress" items?**  
A: Use search: `label:state:in-progress` or filter by project Status column.

**Q: Will my team understand this change?**  
A: Yes, if you share:
- This guide
- The GITHUB_FILTERS.md (generated during migration)
- Training on using labels and projects

---

## Migration Checklist

✅ States converted correctly:
- Closed/Resolved/Done → GitHub Closed
- New/Active/In Progress → GitHub Open
- All states preserved as labels (state:*)

✅ Filters available:
- `label:state:active` - Find Active items
- `label:state:in-progress` - Find In Progress items
- Etc. for all ADO states

✅ Team trained on:
- Label-based filtering
- Project Status field
- GITHUB_FILTERS.md guide

---

## See Also

- `GITHUB_FILTERS.md` - Your saved query conversions
- Project Status fields - For detailed state in projects
- GitHub Labels - For detailed work item categorization

---

**Summary:**
ADO states are preserved in GitHub via:
1. **Issue open/closed state** (for closed items)
2. **State labels** (state:active, state:in-progress, etc.)
3. **Project Status field** (for detailed state views)

Your workflow remains the same - just use labels or project fields instead of issue state.
