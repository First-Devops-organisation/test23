# Fix Relations - Action Plan

## The Problem
Work item 204 (User Story) has a child task 207, but the parent-child relationship is not being captured during migration to GitHub.

**Root Cause:** The `relations.py` module is checking for hardcoded relation type names that don't match what your ADO instance is returning.

---

## The Solution (3 Simple Steps)

### Step 1: Diagnose (5 minutes)

Run the automated diagnostic:

```bash
python fix_relations.py --diagnose
```

This will:
- Fetch all work items from ADO ✓
- Extract actual relation type names your ADO is using ✓
- Check if the 204→207 relationship exists ✓
- Suggest the correct mappings to use ✓

**Output you'll see:**
```
✅ Found 3 relation type(s) in ADO:
   - Type1
   - Type2
   - Type3

✅ Found! Type: TheActualTypeName

💡 Suggested new mappings:
   parents = "ActualParentTypeName"
   children = "ActualChildTypeName"
   ...
```

### Step 2: Apply Fix (1 minute)

Once diagnostic shows the correct type names, apply them:

```bash
python fix_relations.py --apply
```

This will:
- Auto-detect the correct type names ✓
- Update `relations.py` automatically ✓
- Create a backup (relations.py.backup) ✓

**Output you'll see:**
```
✅ Updated: if rel_type == ...
✅ Updated: elif rel_type == ...
...
✅ Updated relations.py with X change(s)
```

### Step 3: Re-Run Migration (varies by data size)

Re-run the migration with the corrected type names:

```bash
python migrate.py --skip-boards --skip-sprints --skip-queries --skip-plans
```

This will:
- Skip all the steps that already completed ✓
- Re-run Step 7/9 (Relations) with correct type names ✓
- Post relationship comments to GitHub issues ✓

**Verify with:**
```bash
python verify_migration.py
```

Look for:
```
✅ Found relationship comment(s) across N issue(s)
✅ Relationships: PASS
```

---

## What's Happening Behind the Scenes

### How Relations Currently Works

1. `relations.py` fetches all work items from ADO
2. For each work item, it gets relations using `$expand=relations`
3. It looks for specific type names:
   ```python
   if rel_type == "Parent":       # Check for this name
       hierarchy[wi_id]['parents'].append(target_id)
   elif rel_type == "Child":      # Or this name
       hierarchy[wi_id]['children'].append(target_id)
   # etc.
   ```

### Why It Fails

Your ADO might return:
- `"Microsoft.VSTS.Common.Parent"` instead of `"Parent"`
- `"System.LinkTypes.Child"` instead of `"Child"`
- Something completely different

If the type name doesn't match, the relation is ignored.

### How The Fix Works

1. **Diagnostic script** runs debug_ado_relations.py in the background
2. **Parses output** to extract actual type names (e.g., "Microsoft.VSTS.Common.Parent")
3. **Suggests mappings** (parents → "Microsoft.VSTS.Common.Parent", etc.)
4. **Applies updates** to relations.py, replacing the hardcoded names

---

## Manual Alternative (If Automated Fix Doesn't Work)

If `fix_relations.py` has issues, you can manually do it:

### 1. Get the Type Names

Run:
```bash
python debug_ado_relations.py
```

Look for section:
```
3️⃣  Checking relation type names used in ADO…
   ✅ Found X unique relation types:
```

Write down those type names.

### 2. Update relations.py

Open `relations.py` line 144-153 and find:
```python
if rel_type == "Parent":
    hierarchy[wi_id]['parents'].append(target_id)
elif rel_type == "Child":
    hierarchy[wi_id]['children'].append(target_id)
elif rel_type == "System.LinkTypes.Related":
    hierarchy[wi_id]['related'].append(target_id)
elif rel_type == "System.LinkTypes.Dependency-Reverse":
    hierarchy[wi_id]['blockedBy'].append(target_id)
elif rel_type == "System.LinkTypes.Dependency":
    hierarchy[wi_id]['blocks'].append(target_id)
```

Replace with the type names from step 1. Example:

If you found: `Microsoft.VSTS.Common.Parent`, replace `"Parent"` with `"Microsoft.VSTS.Common.Parent"`.

### 3. Save and Re-run

Save relations.py, then run Step 3 (Re-Run Migration) above.

---

## Troubleshooting

### "Failed to run diagnostic"
**Check:**
- Is your `.env` file set up correctly? (`ADO_ORG`, `ADO_PROJECT`, `ADO_PAT`)
- Can you run other scripts? (`python debug_relations.py`)
- Is your ADO PAT token still valid?

**Fix:**
- Verify credentials with: `python debug_relations.py`
- Regenerate PAT token if needed

### "No relation types found"
**This means:**
- ADO project has no parent-child relationships configured
- OR the API call isn't working

**Check:**
- Go to Azure DevOps UI
- Pick a work item
- Click "Links" tab
- Do you see any parent/child relationships?
- If no, you need to add them in ADO first

### "Found type names but 204→207 not found"
**This means:**
- Relations exist in ADO but 204→207 specifically doesn't
- OR it uses a different type name than others
- OR items 204/207 don't exist in your project

**Check:**
- Go to Azure DevOps UI
- Find work item 204
- Click "Links" tab
- Is item 207 listed? If not, add it there first

---

## Expected Results After Fix

### Before (Current State)
```
2️⃣  Checking ADO relations…
   ❌ No relations found in ADO
   (Actually they exist but type names don't match)

7️⃣  Relations complete:
   - Links created: 0
   (No links because no relations were detected)
```

### After (After Fix)
```
2️⃣  Checking ADO relations…
   ✅ Found 25 items in hierarchy
   - Parent/child relations: 12
   - Blocked-by relations: 8
   - Related relations: 5

7️⃣  Relations complete:
   - Links created: 25
   (Relationship comments posted to GitHub issues)
```

---

## Quick Reference

| Command | Purpose | Time |
|---------|---------|------|
| `python fix_relations.py --diagnose` | Find correct type names | ~30-60 sec |
| `python fix_relations.py --apply` | Update relations.py | ~2 sec |
| `python migrate.py --skip-boards --skip-sprints --skip-queries --skip-plans` | Re-run Step 7/9 | ~1-5 min |
| `python verify_migration.py` | Verify comments posted | ~10 sec |

---

## What Gets Fixed

✅ **relations.py**: Type names updated to match your ADO instance  
✅ **migration_progress.json**: Relations count corrected  
✅ **GitHub issues**: Relationship comments added (e.g., "**Links:** Blocks #123")  
✅ **204→207 relationship**: Now visible in GitHub as a comment on issue 204  

---

## Next Steps

1. **Run diagnostic**: `python fix_relations.py --diagnose`
2. **Review output** to confirm type names were found
3. **Apply fix**: `python fix_relations.py --apply`
4. **Re-run migration**: `python migrate.py --skip-boards --skip-sprints --skip-queries --skip-plans`
5. **Verify**: `python verify_migration.py` (look for Relationships: ✅ PASS)
6. **Check GitHub**: Open an issue that should have links and verify comment is there

---

**Questions?** Check the detailed guide: `RELATIONS_DIAGNOSTIC_GUIDE.md`
