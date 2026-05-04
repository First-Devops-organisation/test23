#!/usr/bin/env python3
"""
Relations Type Fixer
====================
Automatically detects actual ADO relation type names and updates relations.py

Usage:
  1. Run: python fix_relations.py --diagnose
     This will run debug_ado_relations.py and extract the type names used by ADO

  2. Review the output showing:
     - Current type names in relations.py
     - Actual type names found in ADO
     - Proposed mappings

  3. Run: python fix_relations.py --apply
     This will update relations.py with the correct type names
"""

import os, sys, json, re, subprocess
from pathlib import Path

def run_diagnostic():
    """Execute debug_ado_relations.py and capture output."""
    print("🔍 Running diagnostic scan of ADO relations...")
    print("=" * 70)

    try:
        result = subprocess.run(
            ["python", "debug_ado_relations.py"],
            capture_output=True,
            text=True,
            timeout=120
        )

        output = result.stdout + result.stderr
        return output

    except subprocess.TimeoutExpired:
        print("❌ Diagnostic timed out (120 seconds). ADO API may be slow.")
        return ""
    except Exception as e:
        print(f"❌ Failed to run diagnostic: {e}")
        return ""

def extract_relation_types(diagnostic_output):
    """Parse diagnostic output to extract actual relation type names."""

    # Look for the "unique relation types" section
    pattern = r"3️⃣.*?Checking relation type names.*?\n(.*?)(?:4️⃣|$)"
    match = re.search(pattern, diagnostic_output, re.DOTALL)

    if not match:
        print("❌ Could not find relation types in diagnostic output")
        return []

    section = match.group(1)

    # Extract type names (lines starting with "- ")
    type_names = []
    for line in section.split('\n'):
        if line.strip().startswith('- '):
            type_name = line.strip()[2:].strip()
            if type_name:
                type_names.append(type_name)

    return sorted(set(type_names))

def check_204_207_relationship(diagnostic_output):
    """Check if 204→207 relationship was found."""

    pattern = r"4️⃣.*?Checking for specific parent-child pair.*?\n(.*?)(?:5️⃣|$)"
    match = re.search(pattern, diagnostic_output, re.DOTALL)

    if not match:
        return None, None

    section = match.group(1)

    # Extract info about items 204 and 207
    found_204 = False
    found_207 = False
    relation_type = None

    for line in section.split('\n'):
        if 'ADO#204' in line:
            found_204 = True
        elif 'ADO#207' in line:
            found_207 = True
        elif found_204 and '#207' in line:
            # Extract the relation type
            match_rel = re.search(r'- (.*?) →', line)
            if match_rel:
                relation_type = match_rel.group(1).strip()
                break

    return found_204, relation_type

def get_current_type_mappings():
    """Get current type name mappings from relations.py."""

    rel_file = Path("relations.py")
    if not rel_file.exists():
        return {}

    content = rel_file.read_text()

    mappings = {}

    # Extract the type name checks
    patterns = {
        'parents': r'if rel_type == "([^"]+)":\s*hierarchy\[wi_id\]\[\'parents\'\]',
        'children': r'elif rel_type == "([^"]+)":\s*hierarchy\[wi_id\]\[\'children\'\]',
        'related': r'elif rel_type == "([^"]+)":\s*hierarchy\[wi_id\]\[\'related\'\]',
        'blockedBy': r'elif rel_type == "([^"]+)":\s*hierarchy\[wi_id\]\[\'blockedBy\'\]',
        'blocks': r'elif rel_type == "([^"]+)":\s*hierarchy\[wi_id\]\[\'blocks\'\]',
    }

    for key, pattern in patterns.items():
        match = re.search(pattern, content)
        if match:
            mappings[key] = match.group(1)

    return mappings

def suggest_new_mappings(found_types):
    """Suggest new type name mappings based on found types."""

    suggestions = {
        'parents': None,
        'children': None,
        'related': None,
        'blockedBy': None,
        'blocks': None,
    }

    # Common patterns
    for type_name in found_types:
        t = type_name.lower()

        if 'parent' in t and suggestions['parents'] is None:
            suggestions['parents'] = type_name
        elif 'child' in t and suggestions['children'] is None:
            suggestions['children'] = type_name
        elif 'related' in t and suggestions['related'] is None:
            suggestions['related'] = type_name
        elif 'block' in t and 'reverse' in t and suggestions['blockedBy'] is None:
            suggestions['blockedBy'] = type_name
        elif 'block' in t and suggestions['blocks'] is None:
            suggestions['blocks'] = type_name
        elif 'depend' in t and 'reverse' in t and suggestions['blockedBy'] is None:
            suggestions['blockedBy'] = type_name
        elif 'depend' in t and suggestions['blocks'] is None:
            suggestions['blocks'] = type_name

    return suggestions

def diagnose():
    """Run diagnostic and show findings."""

    print("\nStarting diagnostic...")
    diagnostic_output = run_diagnostic()

    if not diagnostic_output:
        print("❌ Diagnostic failed - no output captured")
        return False

    print("\n" + "=" * 70)
    print("  DIAGNOSTIC RESULTS")
    print("=" * 70)

    # Extract relation types
    found_types = extract_relation_types(diagnostic_output)

    if found_types:
        print(f"\n✅ Found {len(found_types)} relation type(s) in ADO:")
        for t in found_types:
            print(f"   - {t}")
    else:
        print("\n⚠️  No relation types found in ADO")
        return False

    # Check 204→207
    print("\n🔍 Checking for 204→207 relationship:")
    found_204, rel_type = check_204_207_relationship(diagnostic_output)

    if found_204 and rel_type:
        print(f"   ✅ Found! Type: {rel_type}")
    else:
        print(f"   ⚠️  Not found (either doesn't exist or uses different type name)")

    # Show current mappings
    print("\n📋 Current mappings in relations.py:")
    current = get_current_type_mappings()

    if current:
        for key, val in current.items():
            print(f"   {key:12} = \"{val}\"")
    else:
        print("   (Could not parse - may be using different structure)")

    # Suggest new mappings
    print("\n💡 Suggested new mappings:")
    suggestions = suggest_new_mappings(found_types)

    has_suggestions = False
    for key, val in suggestions.items():
        if val:
            print(f"   {key:12} = \"{val}\"")
            has_suggestions = True

    if not has_suggestions:
        print("   (Could not auto-detect - review type names above manually)")

    print("\n" + "=" * 70)
    print("  NEXT STEP")
    print("=" * 70)
    print("\nRun: python fix_relations.py --apply")
    print("This will update relations.py with the correct type names.")

    return True

def apply_fix():
    """Apply the suggested type name mappings to relations.py."""

    print("🔧 Applying relations type mappings...")

    # First, run diagnostic to get type names
    diagnostic_output = run_diagnostic()

    if not diagnostic_output:
        print("❌ Could not run diagnostic")
        return False

    found_types = extract_relation_types(diagnostic_output)

    if not found_types:
        print("❌ No relation types found - cannot apply fix")
        return False

    # Get suggestions
    suggestions = suggest_new_mappings(found_types)

    rel_file = Path("relations.py")
    if not rel_file.exists():
        print("❌ relations.py not found")
        return False

    content = rel_file.read_text()

    # Apply replacements
    replacements = [
        ('if rel_type == "Parent":', f'if rel_type == "{suggestions["parents"]}":' if suggestions['parents'] else None),
        ('elif rel_type == "Child":', f'elif rel_type == "{suggestions["children"]}":' if suggestions['children'] else None),
        ('elif rel_type == "System.LinkTypes.Related":', f'elif rel_type == "{suggestions["related"]}":' if suggestions['related'] else None),
        ('elif rel_type == "System.LinkTypes.Dependency-Reverse":', f'elif rel_type == "{suggestions["blockedBy"]}":' if suggestions['blockedBy'] else None),
        ('elif rel_type == "System.LinkTypes.Dependency":', f'elif rel_type == "{suggestions["blocks"]}":' if suggestions['blocks'] else None),
    ]

    changes_made = 0
    for old, new in replacements:
        if new and old in content:
            content = content.replace(old, new)
            changes_made += 1
            print(f"   ✅ Updated: {old[:40]}...")

    if changes_made == 0:
        print("   ⚠️  No changes made - type names may already be correct or structure differs")
        return False

    # Backup original
    backup = Path("relations.py.backup")
    backup.write_text(rel_file.read_text())
    print(f"\n   💾 Backup saved to: relations.py.backup")

    # Write updated file
    rel_file.write_text(content)
    print(f"   ✅ Updated relations.py with {changes_made} change(s)")

    print("\n" + "=" * 70)
    print("  FIX APPLIED")
    print("=" * 70)
    print("\nNext: Re-run migration with: python migrate.py --skip-boards --skip-sprints --skip-queries --skip-plans")

    return True

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--apply":
        success = apply_fix()
        sys.exit(0 if success else 1)
    else:
        success = diagnose()
        sys.exit(0 if success else 1)
