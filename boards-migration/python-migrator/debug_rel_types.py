#!/usr/bin/env python3
"""
Debug Relation Types - Show EXACT relation type names from ADO API
Compares what ADO returns vs what relations.py is checking for
"""

import os, sys, json, base64
from dotenv import load_dotenv
import requests

load_dotenv()

ADO_ORG = os.getenv("ADO_ORG", "")
ADO_PROJECT = os.getenv("ADO_PROJECT", "")
ADO_PAT = os.getenv("ADO_PAT", "")

if not all([ADO_ORG, ADO_PROJECT, ADO_PAT]):
    print("❌ Missing ADO credentials")
    sys.exit(1)

def _ado_h():
    tok = base64.b64encode(f":{ADO_PAT}".encode()).decode()
    return {"Authorization": f"Basic {tok}", "Content-Type": "application/json"}

def _get(url):
    r = requests.get(url, headers=_ado_h(), timeout=30)
    r.raise_for_status()
    return r.json()

print("=" * 70)
print("  RELATION TYPE NAMES - EXACT MATCH")
print("=" * 70)

# First, get all work item IDs
wiql_url = f"https://dev.azure.com/{ADO_ORG}/{ADO_PROJECT}/_apis/wit/wiql?api-version=7.1"
wiql_query = {
    "query": f"SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '{ADO_PROJECT}' ORDER BY [System.Id]"
}

try:
    r = requests.post(wiql_url, headers=_ado_h(), json=wiql_query, timeout=30)
    r.raise_for_status()
    resp = r.json()
    work_items = resp.get("workItems", [])
    print(f"\n✅ Found {len(work_items)} work items\n")
except Exception as e:
    print(f"❌ Failed to fetch work items: {e}")
    sys.exit(1)

# Test each item
print("Fetching relations for first 5 items:\n")

expected_types = {
    "System.LinkTypes.Hierarchy-Forward": False,
    "System.LinkTypes.Hierarchy-Reverse": False,
    "Parent": False,
    "Child": False,
    "System.LinkTypes.Related": False,
    "System.LinkTypes.Dependency": False,
    "System.LinkTypes.Dependency-Reverse": False,
}

found_types = {}

for item in work_items[:5]:
    wi_id = item["id"]
    url = f"https://dev.azure.com/{ADO_ORG}/{ADO_PROJECT}/_apis/wit/workitems/{wi_id}?$expand=relations&api-version=7.1"

    try:
        data = _get(url)
        relations = data.get("relations", [])

        if not relations:
            print(f"ADO#{wi_id}: 0 relations")
            continue

        print(f"ADO#{wi_id}: {len(relations)} relation(s)")

        for rel in relations:
            rel_type = rel.get("rel", "")
            if not rel_type:
                continue

            print(f"  - Type: '{rel_type}'")

            # Track found types
            if rel_type not in found_types:
                found_types[rel_type] = 0
            found_types[rel_type] += 1

            # Check if it matches any expected type
            if rel_type in expected_types:
                expected_types[rel_type] = True
                print(f"    ✅ MATCHES expected type")
            else:
                print(f"    ❌ DOES NOT MATCH any expected type")

    except Exception as e:
        print(f"ADO#{wi_id}: ERROR - {e}")

print("\n" + "=" * 70)
print("  ANALYSIS")
print("=" * 70)

print("\n📊 Relation types found in ADO:")
for rel_type, count in sorted(found_types.items()):
    print(f"  - '{rel_type}' ({count} occurrence(s))")

print("\n🔍 Expected types in relations.py:")
for expected_type, found in sorted(expected_types.items()):
    status = "✅ FOUND" if found else "❌ NOT FOUND"
    print(f"  - '{expected_type}': {status}")

print("\n" + "=" * 70)
print("  RECOMMENDATION")
print("=" * 70)

if not found_types:
    print("\n❌ NO RELATIONS FOUND AT ALL")
    print("   - Either work items have no relations")
    print("   - Or API authentication failed")
else:
    unmatched = [t for t in found_types.keys() if t not in expected_types]
    if unmatched:
        print("\n⚠️  UNMATCHED TYPES FOUND:")
        for rel_type in unmatched:
            print(f"\n   Add to relations.py (around line 144):")
            print(f"\n   elif rel_type == \"{rel_type}\":")
            # Try to guess the category
            if "child" in rel_type.lower():
                print(f"       hierarchy[wi_id]['children'].append(target_id)")
            elif "parent" in rel_type.lower():
                print(f"       hierarchy[wi_id]['parents'].append(target_id)")
            elif "depend" in rel_type.lower():
                print(f"       hierarchy[wi_id]['blocks'].append(target_id)")
            else:
                print(f"       hierarchy[wi_id]['related'].append(target_id)")
    else:
        print("\n✅ All found types are already in relations.py")
        print("   Problem may be elsewhere (e.g., URL parsing)")

print()
