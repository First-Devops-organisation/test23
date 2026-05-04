#!/usr/bin/env python3
"""
Debug Relations Script
======================
Diagnoses why relationship comments may not be appearing.
Checks:
1. ADO relations data availability
2. GitHub issue comments
3. Relationship data in migration_progress.json
"""

import os, json, sys
from pathlib import Path
import requests
from dotenv import load_dotenv

# Import ADO relation functions
import relations as rel_module

load_dotenv()

ADO_ORG = os.getenv("ADO_ORG", "")
ADO_PROJECT = os.getenv("ADO_PROJECT", "")
ADO_PAT = os.getenv("ADO_PAT", "")
GH_TOKEN = os.getenv("GITHUB_TOKEN", "")
GH_OWNER = os.getenv("GITHUB_OWNER", "")
GH_REPO = os.getenv("GITHUB_REPO", "")

if not all([ADO_ORG, ADO_PROJECT, ADO_PAT, GH_TOKEN, GH_OWNER, GH_REPO]):
    print("❌ Missing credentials in .env")
    sys.exit(1)

GH_BASE = "https://api.github.com"

def _gh_h():
    return {
        "Authorization": f"Bearer {GH_TOKEN}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28"
    }

def _get(url, params=None):
    r = requests.get(url, headers=_gh_h(), params=params, timeout=30)
    r.raise_for_status()
    return r.json()

# ──────────────────────────────────────────────────────────────────────────

print("=" * 70)
print("  RELATION DEBUG SCRIPT")
print("=" * 70)

# 1. Check migration_progress.json
print("\n1️⃣  Checking migration_progress.json…")
progress_file = Path("migration_progress.json")

if not progress_file.exists():
    print("   ❌ migration_progress.json not found")
    sys.exit(1)

progress = json.loads(progress_file.read_text())
migrated_count = len(progress.get("migrated", {}))

print(f"   ✅ Found {migrated_count} migrated items")

if migrated_count == 0:
    print("   ⚠️  No migrated items - nothing to create relations for")
    sys.exit(0)

# 2. Check ADO relations
print("\n2️⃣  Checking ADO relations…")

rel_module.configure(ADO_ORG, ADO_PROJECT, ADO_PAT)

print("   Fetching relations from ADO (this may take a moment)…")
hierarchy = rel_module.get_all_relations()

if not hierarchy:
    print("   ❌ No relations found in ADO")
    print("   💡 Tip: Check ADO project for parent-child links, dependencies, etc.")
else:
    print(f"   ✅ Found {len(hierarchy)} items in hierarchy")

    # Count relations
    total_children = sum(len(item.get('children', [])) for item in hierarchy.values())
    total_blocked = sum(len(item.get('blockedBy', [])) for item in hierarchy.values())
    total_related = sum(len(item.get('related', [])) for item in hierarchy.values())

    print(f"      - Parent/child relations: {total_children}")
    print(f"      - Blocked-by relations: {total_blocked}")
    print(f"      - Related relations: {total_related}")

    # Check if any relations match migrated items
    matched = 0
    for ado_id in hierarchy.keys():
        if str(ado_id) in progress["migrated"] or ado_id in progress["migrated"]:
            matched += 1

    print(f"      - Items with relations AND migrated: {matched}")

    if matched == 0:
        print("   ❌ No relations on migrated items!")
        print("   💡 Relations may exist only on non-migrated items")

# 3. Check GitHub issue comments
print("\n3️⃣  Checking GitHub issue comments…")

try:
    migrated_map = progress["migrated"]

    # Check first 5 migrated issues
    check_count = min(5, len(migrated_map))
    print(f"   Checking comments on first {check_count} migrated issues…")

    issues_with_links = 0
    issues_checked = 0

    for ado_id_str, gh_num in list(migrated_map.items())[:check_count]:
        issues_checked += 1

        try:
            url = f"{GH_BASE}/repos/{GH_OWNER}/{GH_REPO}/issues/{gh_num}/comments"
            comments = _get(url)

            has_link_comment = False
            for comment in comments:
                body = comment.get("body", "")
                if "**Links:**" in body or "**Related:**" in body:
                    has_link_comment = True
                    print(f"   ✅ GH#{gh_num}: Found link comment")
                    issues_with_links += 1
                    break

            if not has_link_comment and len(comments) == 0:
                print(f"   ⚠️  GH#{gh_num}: No comments at all")
            elif not has_link_comment:
                print(f"   ℹ️  GH#{gh_num}: {len(comments)} comment(s) but no links")

        except Exception as e:
            print(f"   ❌ GH#{gh_num}: Error checking comments: {e}")

    print(f"\n   Summary: {issues_with_links}/{issues_checked} issues have link comments")

except Exception as e:
    print(f"   ❌ Error checking GitHub: {e}")

# 4. Check migration log
print("\n4️⃣  Checking migration.log…")

log_file = Path("migration.log")

if not log_file.exists():
    print("   ⚠️  migration.log not found")
else:
    log_content = log_file.read_text()

    # Check for Step 7
    if "Step 7/9" in log_content:
        print("   ✅ Step 7/9 (Relations) was executed")

        # Extract relations section
        lines = log_content.split('\n')
        in_relations = False
        relations_lines = []

        for line in lines:
            if "Step 7/9" in line:
                in_relations = True
            elif "Step 8/9" in line or "Step 6/9" in line:
                in_relations = False
            elif in_relations:
                relations_lines.append(line)

        if relations_lines:
            print("   Relations log:")
            for line in relations_lines[:20]:  # Show first 20 lines
                if line.strip():
                    print(f"      {line}")

        # Check for errors
        error_count = log_content.count("❌") + log_content.count("Failed")
        if error_count > 0:
            print(f"\n   ⚠️  Found {error_count} error/failure indicators in log")
    else:
        print("   ⚠️  Step 7/9 not found in log - relations may not have run")

# 5. Summary & Recommendations
print("\n" + "=" * 70)
print("  DIAGNOSIS")
print("=" * 70)

if not hierarchy:
    print("\n❌ ISSUE: No relations found in ADO")
    print("   ACTION: Check if ADO project has parent-child relationships defined")
elif matched == 0:
    print("\n⚠️  ISSUE: Relations exist but on non-migrated items")
    print("   ACTION: Migration may not have included all items with relations")
elif issues_with_links == 0:
    print("\n❌ ISSUE: Relations not appearing as comments on GitHub issues")
    print("   POSSIBLE CAUSES:")
    print("      1. REST API call failed silently")
    print("      2. Comments were posted to wrong issue numbers")
    print("      3. API authentication issue")
    print("   ACTION:")
    print("      - Re-run migration.py with full logging")
    print("      - Check GitHub tokens/permissions")
    print("      - Review migration.log for API errors")
elif issues_with_links > 0:
    print(f"\n✅ SUCCESS: {issues_with_links} issue(s) have relationship comments")
    print("   Relationship linking is working!")

print("\n" + "=" * 70)
print("  NEXT STEPS")
print("=" * 70)
print("""
1. If no relations in ADO:
   - Add parent-child links in Azure DevOps
   - Re-run migration

2. If relations exist but comments not appearing:
   - Check GitHub API permissions
   - Verify GITHUB_TOKEN has 'repo' scope
   - Re-run: python migrate.py --skip-boards --skip-sprints

3. To see detailed logging:
   - Check migration.log for "Step 7/9" section
   - Look for POST requests and HTTP status codes
   - Review any "ERROR" or "FAILED" messages

4. Manual verification:
   - Go to GitHub issue that should have relation
   - Check Comments section for "**Links:**" text
""")
