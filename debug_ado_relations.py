#!/usr/bin/env python3
"""
Debug ADO Relations
===================
Deep dive into ADO relations data to see what's available.
Tests with specific work item IDs.
"""

import os, sys, json, base64
import requests
from dotenv import load_dotenv

load_dotenv()

ADO_ORG = os.getenv("ADO_ORG", "")
ADO_PROJECT = os.getenv("ADO_PROJECT", "")
ADO_PAT = os.getenv("ADO_PAT", "")

if not all([ADO_ORG, ADO_PROJECT, ADO_PAT]):
    print("❌ Missing ADO credentials in .env")
    sys.exit(1)

def _ado_h():
    tok = base64.b64encode(f":{ADO_PAT}".encode()).decode()
    return {"Authorization": f"Basic {tok}", "Content-Type": "application/json"}

def _get(url, params=None):
    r = requests.get(url, headers=_ado_h(), params=params, timeout=30)
    r.raise_for_status()
    return r.json()

def _post(url, data):
    r = requests.post(url, headers=_ado_h(), json=data, timeout=30)
    r.raise_for_status()
    return r.json()

print("=" * 70)
print("  ADO RELATIONS DEBUG")
print("=" * 70)

# 1. Get all work item IDs
print("\n1️⃣  Fetching all work item IDs from ADO…")

wiql_url = f"https://dev.azure.com/{ADO_ORG}/{ADO_PROJECT}/_apis/wit/wiql?api-version=7.1"
wiql_query = {
    "query": f"SELECT [System.Id], [System.Title], [System.WorkItemType] FROM WorkItems WHERE [System.TeamProject] = '{ADO_PROJECT}' ORDER BY [System.Id]"
}

try:
    resp = _post(wiql_url, wiql_query)
    work_items = resp.get("workItems", [])
    print(f"   ✅ Found {len(work_items)} work items")

    # Show first 10
    print(f"\n   First 10 items:")
    for item in work_items[:10]:
        print(f"      ID: {item['id']}")
except Exception as e:
    print(f"   ❌ Error: {e}")
    sys.exit(1)

# 2. Test fetching relations for a specific item
print(f"\n2️⃣  Testing relation fetch for specific items…")

# Try to find items and check their relations
test_ids = []

# Get first 5 IDs to test
for item in work_items[:5]:
    test_ids.append(item["id"])

print(f"   Testing IDs: {test_ids}")

for wi_id in test_ids:
    print(f"\n   ADO#{wi_id}:")

    # Fetch with $expand=relations
    url = f"https://dev.azure.com/{ADO_ORG}/{ADO_PROJECT}/_apis/wit/workitems/{wi_id}?$expand=relations&api-version=7.1"

    try:
        data = _get(url)

        relations = data.get("relations", [])
        print(f"      Relations count: {len(relations)}")

        if relations:
            for rel in relations:
                rel_type = rel.get("rel", "")
                target_url = rel.get("url", "")

                # Try to extract target ID
                try:
                    target_id = target_url.split("/workitems/")[-1]
                except:
                    target_id = "unknown"

                print(f"      - Type: {rel_type}")
                print(f"        Target: WI#{target_id}")
                print(f"        URL: {target_url[:80]}...")

    except Exception as e:
        print(f"      ❌ Error: {e}")

# 3. Check relation type names
print(f"\n3️⃣  Checking relation type names used in ADO…")

relation_types_found = set()

for wi_id in work_items[:20]:  # Check first 20 items
    url = f"https://dev.azure.com/{ADO_ORG}/{ADO_PROJECT}/_apis/wit/workitems/{wi_id}?$expand=relations&api-version=7.1"

    try:
        data = _get(url)
        relations = data.get("relations", [])

        for rel in relations:
            rel_type = rel.get("rel", "")
            if rel_type:
                relation_types_found.add(rel_type)

    except:
        pass

if relation_types_found:
    print(f"   ✅ Found {len(relation_types_found)} unique relation types:")
    for rt in sorted(relation_types_found):
        print(f"      - {rt}")
else:
    print(f"   ⚠️  No relations found in first 20 items")

# 4. Check a specific pair if user story 204 exists
print(f"\n4️⃣  Checking for specific parent-child pair (204→207 if exists)…")

for test_id in [204, 207]:
    url = f"https://dev.azure.com/{ADO_ORG}/{ADO_PROJECT}/_apis/wit/workitems/{test_id}?$expand=relations&api-version=7.1"

    try:
        data = _get(url)
        title = data.get("fields", {}).get("System.Title", "Unknown")
        relations = data.get("relations", [])

        print(f"   ADO#{test_id} ({title}):")
        print(f"      Relations: {len(relations)}")

        for rel in relations:
            rel_type = rel.get("rel", "")
            target_url = rel.get("url", "")

            try:
                target_id = target_url.split("/workitems/")[-1]
            except:
                target_id = "unknown"

            print(f"      - {rel_type} → #{target_id}")

    except Exception as e:
        print(f"   ⚠️  ADO#{test_id}: {e}")

# 5. Raw JSON output
print(f"\n5️⃣  Raw JSON for detailed inspection…")
print("\n   Getting raw relations for first item with relations:")

for wi_id in work_items[:10]:
    url = f"https://dev.azure.com/{ADO_ORG}/{ADO_PROJECT}/_apis/wit/workitems/{wi_id}?$expand=relations&api-version=7.1"

    try:
        data = _get(url)
        relations = data.get("relations", [])

        if relations:
            print(f"\n   ADO#{wi_id} relations (raw JSON):")
            print(json.dumps(relations, indent=2)[:500])  # First 500 chars
            break

    except:
        pass

print("\n" + "=" * 70)
print("  SUMMARY")
print("=" * 70)
print("""
Check the output above for:
1. Are relations being returned? (count > 0)
2. What are the actual relation type names?
3. Can we find 204→207 relationship?
4. What's the raw JSON structure?

If relations are found, update relations.py with correct type names.
If no relations found, ADO project may not have any configured.
""")
