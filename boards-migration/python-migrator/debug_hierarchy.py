#!/usr/bin/env python3
"""
Debug Hierarchy - See what's actually in the relations hierarchy
Shows exactly what get_all_relations() returns for each work item
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

# Configure and fetch
rel_module.configure(ADO_ORG, ADO_PROJECT, ADO_PAT)

print("=" * 70)
print("  HIERARCHY DEBUG")
print("=" * 70)

print("\n🔍 Fetching hierarchy from get_all_relations()...")
hierarchy = rel_module.get_all_relations()

if not hierarchy:
    print("❌ No hierarchy returned!")
    sys.exit(1)

print(f"\n✅ Got hierarchy for {len(hierarchy)} items\n")

# Show each item
for wi_id, rels in sorted(hierarchy.items()):
    print(f"ADO#{wi_id}:")

    parents = rels.get('parents', [])
    children = rels.get('children', [])
    related = rels.get('related', [])
    blockedBy = rels.get('blockedBy', [])
    blocks = rels.get('blocks', [])

    total = len(parents) + len(children) + len(related) + len(blockedBy) + len(blocks)

    if total == 0:
        print(f"  ⚠️  NO RELATIONS")
    else:
        if parents:
            print(f"  Parents: {parents}")
        if children:
            print(f"  Children: {children}")
        if related:
            print(f"  Related: {related}")
        if blockedBy:
            print(f"  Blocked By: {blockedBy}")
        if blocks:
            print(f"  Blocks: {blocks}")
    print()

print("=" * 70)
print("  SUMMARY")
print("=" * 70)

# Count total relations
total_parents = sum(len(r.get('parents', [])) for r in hierarchy.values())
total_children = sum(len(r.get('children', [])) for r in hierarchy.values())
total_related = sum(len(r.get('related', [])) for r in hierarchy.values())
total_blockedBy = sum(len(r.get('blockedBy', [])) for r in hierarchy.values())
total_blocks = sum(len(r.get('blocks', [])) for r in hierarchy.values())

print(f"\nTotal relations found:")
print(f"  Parents: {total_parents}")
print(f"  Children: {total_children}")
print(f"  Related: {total_related}")
print(f"  Blocked By: {total_blockedBy}")
print(f"  Blocks: {total_blocks}")
print(f"  TOTAL: {total_parents + total_children + total_related + total_blockedBy + total_blocks}")

if total_parents + total_children + total_related + total_blockedBy + total_blocks == 0:
    print("\n❌ NO RELATIONS FOUND - Something is wrong with the relation type matching")
    print("\nDebugging steps:")
    print("1. Check that relation type names in relations.py match ADO output")
    print("2. Run: python debug_ado_relations.py")
    print("3. Compare type names with what's in relations.py (lines 144-160)")
else:
    print("\n✅ Relations found - they should be migrated on next run")
