#!/usr/bin/env python3
"""
Debug URL Format - Show the complete URL structure for relations
"""

import os, sys, json
from dotenv import load_dotenv
import relations as rel_module

load_dotenv()

ADO_ORG = os.getenv("ADO_ORG", "")
ADO_PROJECT = os.getenv("ADO_PROJECT", "")
ADO_PAT = os.getenv("ADO_PAT", "")

if not all([ADO_ORG, ADO_PROJECT, ADO_PAT]):
    print("❌ Missing ADO credentials")
    sys.exit(1)

rel_module.configure(ADO_ORG, ADO_PROJECT, ADO_PAT)

print("=" * 70)
print("  URL FORMAT DEBUG")
print("=" * 70)

# Test item 204 which has Hierarchy-Forward relation
relations = rel_module.ado_fetch_work_item_relations(204)

print(f"\nADO#204 relations (raw data):\n")

for i, rel in enumerate(relations):
    print(f"Relation {i+1}:")
    print(f"  'rel': {rel.get('rel')}")
    print(f"  'url': {rel.get('url')}")

    url = rel.get('url', '')

    # Show different parsing attempts
    print(f"\n  Parsing attempts:")

    # Current logic from relations.py
    try:
        target_id = int(url.split("/workitems/")[-1])
        print(f"    ✓ /workitems/ split: {target_id}")
    except Exception as e:
        print(f"    ✗ /workitems/ split failed: {e}")

    # Alternative: check if URL contains workitems
    if "/workitems/" in url:
        parts = url.split("/workitems/")
        print(f"      URL parts: {parts}")
        print(f"      Last part: '{parts[-1]}'")
    else:
        print(f"    'workitems' not in URL")

        # Try to find any number in URL
        import re
        numbers = re.findall(r'\d+', url)
        if numbers:
            print(f"      Numbers found in URL: {numbers}")

    print()

print("=" * 70)
print("  FULL JSON")
print("=" * 70)
print(json.dumps(relations, indent=2))
