#!/usr/bin/env python3
"""
Test ado_fetch_work_item_relations directly
Shows if the function is working and what it returns
"""

import os, sys
from dotenv import load_dotenv
import relations as rel_module

load_dotenv()

ADO_ORG = os.getenv("ADO_ORG", "")
ADO_PROJECT = os.getenv("ADO_PROJECT", "")
ADO_PAT = os.getenv("ADO_PAT", "")

if not all([ADO_ORG, ADO_PROJECT, ADO_PAT]):
    print("❌ Missing ADO credentials")
    sys.exit(1)

# Configure
rel_module.configure(ADO_ORG, ADO_PROJECT, ADO_PAT)

print("=" * 70)
print("  TEST ado_fetch_work_item_relations()")
print("=" * 70)

# Test fetching relations for specific items
test_ids = [204, 207]

for wi_id in test_ids:
    print(f"\nFetching relations for ADO#{wi_id}:")

    relations = rel_module.ado_fetch_work_item_relations(wi_id)

    if not relations:
        print(f"  ⚠️  No relations returned")
        continue

    print(f"  ✅ {len(relations)} relation(s) returned:")

    for i, rel in enumerate(relations):
        rel_type = rel.get("rel", "")
        url = rel.get("url", "")

        # Try to extract target ID
        try:
            target_id = url.split("/workitems/")[-1] if "/workitems/" in url else url.split("/attachments/")[-1] if "/attachments/" in url else "unknown"
        except:
            target_id = "unknown"

        print(f"\n     [{i+1}] Type: '{rel_type}'")
        print(f"         URL: {url[:80]}...")
        print(f"         Target: {target_id}")

print("\n" + "=" * 70)
print("  SUMMARY")
print("=" * 70)

relations_204 = rel_module.ado_fetch_work_item_relations(204)
relations_207 = rel_module.ado_fetch_work_item_relations(207)

print(f"\nADO#204: {len(relations_204)} relations")
print(f"ADO#207: {len(relations_207)} relations")

if len(relations_204) > 0 or len(relations_207) > 0:
    print("\n✅ Relations ARE being fetched by API")
    print("   Problem is in relation type matching in get_all_relations()")
else:
    print("\n❌ Relations are NOT being fetched")
    print("   Problem is with ado_fetch_work_item_relations() or API call")
