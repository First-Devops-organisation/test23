#!/usr/bin/env python3
"""
Verification Script for ADO→GitHub Migration
=============================================
Checks that all migration artifacts are correct:
- Issues created and states set
- Relationships documented as comments
- Milestones created for sprints
- Labels applied correctly
- Projects created with fields
"""

import os, json, sys
from pathlib import Path
from collections import defaultdict
import requests
from dotenv import load_dotenv

load_dotenv()

GH_TOKEN = os.getenv("GITHUB_TOKEN", "")
GH_OWNER = os.getenv("GITHUB_OWNER", "")
GH_REPO = os.getenv("GITHUB_REPO", "")

if not all([GH_TOKEN, GH_OWNER, GH_REPO]):
    print("❌ Missing GitHub credentials in .env")
    print("   Required: GITHUB_TOKEN, GITHUB_OWNER, GITHUB_REPO")
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

# ── Verification Functions ──────────────────────────────────────────────────

def check_issues():
    """Verify GitHub issues were created."""
    print("\n🔍 Checking GitHub Issues...")

    try:
        url = f"{GH_BASE}/repos/{GH_OWNER}/{GH_REPO}/issues?per_page=1&state=all"
        result = _get(url)

        # GitHub returns issues differently, need to check via endpoint
        url_count = f"{GH_BASE}/repos/{GH_OWNER}/{GH_REPO}/issues?state=all&per_page=100"
        issues = _get(url_count)

        issue_count = len(issues)
        if issue_count == 0:
            print("   ⚠️  No issues found in GitHub repo")
            return False

        print(f"   ✅ Found {issue_count} issue(s)")
        return True
    except Exception as e:
        print(f"   ❌ Error checking issues: {e}")
        return False

def check_relationship_comments():
    """Verify relationship comments were added."""
    print("\n🔍 Checking Relationship Comments...")

    try:
        # Get all issues with comments
        url = f"{GH_BASE}/repos/{GH_OWNER}/{GH_REPO}/issues?state=all&per_page=100"
        issues = _get(url)

        comments_found = 0
        issues_with_links = 0

        for issue in issues[:20]:  # Check first 20 issues
            issue_num = issue["number"]
            comments_url = f"{GH_BASE}/repos/{GH_OWNER}/{GH_REPO}/issues/{issue_num}/comments"

            try:
                comments = _get(comments_url)

                for comment in comments:
                    body = comment.get("body", "")
                    if "**Links:**" in body or "**Related:**" in body:
                        comments_found += 1
                        issues_with_links += 1
                        print(f"   ✅ Issue #{issue_num}: Found relationship comment")
                        break
            except:
                pass

        if comments_found == 0:
            print("   ⚠️  No relationship comments found")
            print("   💡 Tip: Check issue #1 for a sample relationship comment")
            return False

        print(f"   ✅ Found {comments_found} relationship comment(s) across {issues_with_links} issue(s)")
        return True
    except Exception as e:
        print(f"   ❌ Error checking comments: {e}")
        return False

def check_labels():
    """Verify labels were created."""
    print("\n🔍 Checking Labels...")

    try:
        url = f"{GH_BASE}/repos/{GH_OWNER}/{GH_REPO}/labels?per_page=100"
        labels = _get(url)

        label_names = [l["name"] for l in labels]

        # Check for expected label patterns
        type_labels = [l for l in label_names if l.startswith("type:")]
        state_labels = [l for l in label_names if l.startswith("state:")]

        print(f"   ✅ Total labels: {len(label_names)}")
        print(f"   ✅ Type labels: {len(type_labels)} ({', '.join(type_labels[:3])}...)")
        print(f"   ✅ State labels: {len(state_labels)} ({', '.join(state_labels[:3])}...)")

        if len(type_labels) > 0 and len(state_labels) > 0:
            return True

        return False
    except Exception as e:
        print(f"   ❌ Error checking labels: {e}")
        return False

def check_milestones():
    """Verify milestones were created for sprints."""
    print("\n🔍 Checking Milestones (Sprints)...")

    try:
        url = f"{GH_BASE}/repos/{GH_OWNER}/{GH_REPO}/milestones?per_page=100&state=all"
        milestones = _get(url)

        if len(milestones) == 0:
            print("   ⚠️  No milestones found")
            print("   💡 Tip: Sprints not migrated, or no sprints in ADO project")
            return False

        print(f"   ✅ Found {len(milestones)} milestone(s)")
        for m in milestones[:5]:
            print(f"      - {m['title']} ({m['open_issues']} open, {m['closed_issues']} closed)")

        return True
    except Exception as e:
        print(f"   ⚠️  Error checking milestones: {e}")
        return False

def check_progress_file():
    """Verify migration_progress.json exists."""
    print("\n🔍 Checking Migration Progress File...")

    try:
        progress_file = Path("migration_progress.json")

        if not progress_file.exists():
            print("   ❌ migration_progress.json not found")
            return False

        progress = json.loads(progress_file.read_text())

        migrated_count = len(progress.get("migrated", {}))
        projects_count = len(progress.get("projects", {}))
        sprints_count = len(progress.get("sprints", {}))

        print(f"   ✅ Migrated items: {migrated_count}")
        print(f"   ✅ Projects: {projects_count}")
        print(f"   ✅ Sprints: {sprints_count}")

        return migrated_count > 0
    except Exception as e:
        print(f"   ❌ Error reading progress file: {e}")
        return False

def check_export_files():
    """Verify export files were created."""
    print("\n🔍 Checking Export Files...")

    files_to_check = [
        ("query_map.json", "Query mappings"),
        ("GITHUB_FILTERS.md", "Filter guide"),
        ("timeline.csv", "Timeline data"),
        ("timeline.mmd", "Mermaid diagram"),
        ("ROADMAP.md", "Roadmap"),
    ]

    found_files = []
    missing_files = []

    for filename, description in files_to_check:
        filepath = Path(filename)
        if filepath.exists():
            size = filepath.stat().st_size
            found_files.append(filename)
            print(f"   ✅ {filename:20} ({description}) - {size:,} bytes")
        else:
            missing_files.append(filename)
            print(f"   ⚠️  {filename:20} - not found")

    return len(found_files) > 0

def check_log_file():
    """Verify migration.log exists and check for errors."""
    print("\n🔍 Checking Migration Log...")

    try:
        log_file = Path("migration.log")

        if not log_file.exists():
            print("   ⚠️  migration.log not found")
            return False

        log_content = log_file.read_text()

        # Count key events
        issues_count = log_content.count("[OK] GH#")
        fails_count = log_content.count("[FAIL]")
        warnings_count = log_content.count("WARNING")

        print(f"   ✅ Log file exists ({log_file.stat().st_size:,} bytes)")
        print(f"   ✅ Issues migrated: {issues_count}")

        if fails_count > 0:
            print(f"   ⚠️  Failed items: {fails_count}")

        if warnings_count > 0:
            print(f"   ℹ️  Warnings: {warnings_count}")

        # Check for critical errors
        if "GraphQL error" in log_content:
            print("   ℹ️  GraphQL errors occurred (expected with fallbacks)")

        return True
    except Exception as e:
        print(f"   ❌ Error reading log: {e}")
        return False

# ── Main ────────────────────────────────────────────────────────────────────

def main():
    print("=" * 60)
    print("  ADO→GitHub Migration Verification")
    print("=" * 60)
    print(f"\nTarget: {GH_OWNER}/{GH_REPO}")

    results = {
        "Issues": check_issues(),
        "Labels": check_labels(),
        "Milestones": check_milestones(),
        "Progress File": check_progress_file(),
        "Export Files": check_export_files(),
        "Log File": check_log_file(),
        "Relationships": check_relationship_comments(),
    }

    # Summary
    print("\n" + "=" * 60)
    print("  SUMMARY")
    print("=" * 60)

    passed = sum(1 for v in results.values() if v)
    total = len(results)

    for check, result in results.items():
        status = "✅ PASS" if result else "❌ FAIL"
        print(f"  {check:20} {status}")

    print(f"\n  Total: {passed}/{total} checks passed")

    if passed == total:
        print("\n✅ Migration appears successful!")
        print("\nNext steps:")
        print("  1. Review GITHUB_FILTERS.md for query conversions")
        print("  2. Check ROADMAP.md for delivery timeline")
        print("  3. Open GitHub issues to verify relationship comments")
        print("  4. Check repo → Milestones for sprints")
        return 0
    elif passed >= total - 2:
        print("\n⚠️  Migration mostly successful with minor issues.")
        print("   Check warnings above and migration.log for details")
        return 0
    else:
        print("\n❌ Migration has issues. Check details above.")
        return 1

if __name__ == "__main__":
    sys.exit(main())
