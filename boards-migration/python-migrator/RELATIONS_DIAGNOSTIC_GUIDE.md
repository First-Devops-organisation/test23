# Relations Capture Diagnostic Guide

## Problem
Work item 204 (User Story) has a child task 207, but the relationship is not being captured during migration.

## Root Cause Analysis
The `get_all_relations()` function in `relations.py` checks for these hardcoded relation type names:
- `"Parent"`
- `"Child"`  
- `"System.LinkTypes.Related"`
- `"System.LinkTypes.Dependency-Reverse"`
- `"System.LinkTypes.Dependency"`

**If ADO is returning different type names, the relations won't be captured.**

## Step 1: Run the Diagnostic Script

Execute this command in the pythonmigratorv1 folder:

```bash
python debug_ado_relations.py
```

This will:
1. Fetch all work items from ADO
2. Check relations for first 5 items
3. **Show the ACTUAL relation type names ADO is using** ← This is key
4. Test specific items 204 and 207
5. Dump raw JSON for inspection

## Step 2: Analyze the Output

Look for this section:
```
3️⃣  Checking relation type names used in ADO…
   ✅ Found N unique relation types:
      - Type1
      - Type2
      - Type3
```

**Write down ALL the relation type names you see here.**

Also look for:
```
4️⃣  Checking for specific parent-child pair (204→207 if exists)…
   ADO#204 (...):
      Relations: N
      - RelationType → #TargetID
```

If you see `- Type → #207`, that confirms the 204→207 relationship exists but we're checking for the wrong type name.

## Step 3: Update relations.py

Once you have the ACTUAL type names from step 2, they need to be added to `relations.py`.

### Example Scenario

**If debug output shows:**
```
✅ Found 5 unique relation types:
   - Microsoft.VSTS.Common.Child
   - Microsoft.VSTS.Common.Parent
   - Microsoft.VSTS.Common.Related
   - Microsoft.VSTS.Common.Blocks
   - Microsoft.VSTS.Common.BlockedBy
```

**Then relations.py needs to change from:**
```python
if rel_type == "Parent":
    hierarchy[wi_id]['parents'].append(target_id)
elif rel_type == "Child":
    hierarchy[wi_id]['children'].append(target_id)
```

**To:**
```python
if rel_type == "Microsoft.VSTS.Common.Parent":
    hierarchy[wi_id]['parents'].append(target_id)
elif rel_type == "Microsoft.VSTS.Common.Child":
    hierarchy[wi_id]['children'].append(target_id)
```

## Step 4: Verify the Fix

After updating relation type names in relations.py:

```bash
python debug_relations.py
```

This will verify whether:
- Relations are now being found in ADO
- Relations match migrated work items
- Relationship comments are posting to GitHub

## Common ADO Relation Type Names

Different ADO instances use different naming conventions:

### Convention 1 (Some Azure DevOps versions):
- Parent
- Child  
- Related

### Convention 2 (Other Azure DevOps versions):
- System.LinkTypes.Parent
- System.LinkTypes.Child
- System.LinkTypes.Related

### Convention 3 (Enterprise ADO):
- Microsoft.VSTS.Common.Parent
- Microsoft.VSTS.Common.Child
- Microsoft.VSTS.Common.Related

### Convention 4 (With full paths):
- System.LinkTypes.Dependency
- System.LinkTypes.Dependency-Reverse
- System.LinkTypes.Related

**Your ADO instance uses ONE of these. The debug script will tell you which.**

## Expected Output

If running successfully, you should see:

```
1️⃣  Fetching all work item IDs from ADO…
   ✅ Found 250 work items

2️⃣  Testing relation fetch for specific items…
   Testing IDs: [1, 2, 3, 4, 5]
   ADO#1:
      Relations count: 0
   ADO#2:
      Relations count: 2
      - Type: TheActualTypeName
        Target: WI#7

3️⃣  Checking relation type names used in ADO…
   ✅ Found 3 unique relation types:
      - TypeName1
      - TypeName2
      - TypeName3

4️⃣  Checking for specific parent-child pair (204→207 if exists)…
   ADO#204 (Your User Story Title):
      Relations: 1
      - TheTypeNameFor204to207 → #207
   ADO#207 (Your Task Title):
      Relations: 1
      - TheTypeNameFor207to204 → #204
```

## Troubleshooting

### Scenario 1: "No relations found"
**Diagnosis:** Relations don't exist in ADO, or ADO project doesn't have any configured.
**Action:** Check ADO Project Settings → Links → Verify parent-child relationships exist.

### Scenario 2: "Found N unique relation types"
**Diagnosis:** Relations exist, we just need to update the type names.
**Action:** Follow Step 3 above to update relations.py with correct type names.

### Scenario 3: "Found 204→207" in raw JSON but not in relations summary
**Diagnosis:** The type name for that relationship doesn't match our hardcoded list.
**Action:** Look at the raw JSON output, find the `"rel"` field value, and add it to relations.py.

## Files Modified After Diagnostic

1. **relations.py** - Update the `if rel_type ==` checks with actual type names
2. **migrate.py** - Already has migrate_relations() call, no changes needed
3. **migration_progress.json** - Will auto-update with correct relations count after fix

## Next Command After Fix

Once you've updated relations.py with the correct type names:

```bash
python migrate.py --skip-boards --skip-sprints --skip-queries --skip-plans
```

This will re-run just the relations step (Step 7/9) with the corrected type names.

---

**Summary:** The debug script will tell you exactly what relation type names ADO is using. Once you share those names, the fix is a simple find-and-replace in relations.py.
