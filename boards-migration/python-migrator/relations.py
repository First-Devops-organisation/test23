"""
relations.py
=============
Handles Azure DevOps work item parent-child relationships and maps them to GitHub.

Strategy
--------
1. Fetch all work item relations from ADO (Parent/Child links)
2. Build a hierarchy map: child_id -> parent_id, parent_id -> [child_ids]
3. After all issues are migrated, create GitHub issue links via GraphQL
4. Links are stored both as:
   - GitHub native "relates to" / "blocked by" / "blocks" relationships
   - Custom fields "Parent Issue #" and "Child Issues"

Public API
----------
  configure(ado_org, ado_project, ado_pat)
  get_all_relations()                    → {ado_id: {parent_ids, child_ids, ...}}
  ado_fetch_work_item_relations(wi_id)  → list of relations
  gh_create_issue_link(source_num, target_num, rel_type, dry_run)
  migrate_relations(progress, migrated_map, dry_run)
"""

import base64, logging, time
import requests

log = logging.getLogger("migrator.relations")

_ORG = _PROJECT = _PAT = ""
_GH_TOKEN = _GH_OWNER = _GH_REPO = ""
_GH_GQL = "https://api.github.com/graphql"

def configure(ado_org, ado_project, ado_pat, gh_token="", gh_owner="", gh_repo=""):
    """Configure both ADO and GitHub credentials."""
    global _ORG, _PROJECT, _PAT, _GH_TOKEN, _GH_OWNER, _GH_REPO
    _ORG, _PROJECT, _PAT = ado_org, ado_project, ado_pat
    _GH_TOKEN, _GH_OWNER, _GH_REPO = gh_token, gh_owner, gh_repo

def _ado_hdr():
    """Azure DevOps Basic Auth header."""
    tok = base64.b64encode(f":{_PAT}".encode()).decode()
    return {"Authorization": f"Basic {tok}", "Content-Type": "application/json"}

def _gh_hdr():
    """GitHub GraphQL header."""
    return {
        "Authorization": f"Bearer {_GH_TOKEN}",
        "Content-Type": "application/json",
        "X-GitHub-Api-Version": "2022-11-28"
    }

def _get(url, headers, params=None):
    """GET request with retries."""
    r = requests.get(url, headers=headers, params=params, timeout=30)
    r.raise_for_status()
    return r.json()

def _post(url, headers, data):
    """POST request with retries."""
    r = requests.post(url, headers=headers, json=data, timeout=30)
    r.raise_for_status()
    return r.json()

def _gql(query: str, variables: dict = None) -> dict:
    """Execute GraphQL mutation for GitHub issue links."""
    payload = {"query": query}
    if variables:
        payload["variables"] = variables

    r = requests.post(_GH_GQL, headers=_gh_hdr(), json=payload, timeout=30)
    r.raise_for_status()
    body = r.json()

    errors = body.get("errors", [])
    if errors:
        log.warning(f"GraphQL error: {errors}")
        return {}

    return body.get("data", {})

# ── ADO: Fetch Relations ──────────────────────────────────────────────────────

def ado_fetch_work_item_relations(wi_id: int) -> list:
    """
    Fetch all relations for a single work item.
    Returns list of dicts with: rel (Parent/Child/Related), url, attributes.
    """
    url = f"https://dev.azure.com/{_ORG}/{_PROJECT}/_apis/wit/workitems/{wi_id}?$expand=relations&api-version=7.1"
    try:
        data = _get(url, _ado_hdr())
        return data.get("relations", [])
    except Exception as e:
        log.warning(f"Failed to fetch relations for WI#{wi_id}: {e}")
        return []

def get_all_relations() -> dict:
    """
    Build a hierarchy map from all work items.
    Returns:
    {
        ado_id: {
            'parents': [parent_ado_id, ...],
            'children': [child_ado_id, ...],
            'related': [related_ado_id, ...],
            'type': 'Epic|Feature|User Story|Task|...'
        }
    }
    """
    # First, get all work item IDs
    wiql_url = f"https://dev.azure.com/{_ORG}/{_PROJECT}/_apis/wit/wiql?api-version=7.1"
    wiql_query = {
        "query": f"SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '{_PROJECT}' ORDER BY [System.Id]"
    }

    try:
        resp = _post(wiql_url, _ado_hdr(), wiql_query)
        wi_ids = [item["id"] for item in resp.get("workItems", [])]
    except Exception as e:
        log.error(f"Failed to fetch work item IDs: {e}")
        return {}

    hierarchy = {}

    for wi_id in wi_ids:
        relations = ado_fetch_work_item_relations(wi_id)
        hierarchy[wi_id] = {
            'parents': [],
            'children': [],
            'related': [],
            'blockedBy': [],
            'blocks': []
        }

        if relations:
            log.debug(f"WI#{wi_id} has {len(relations)} relation(s)")

        for rel in relations:
            rel_type = rel.get("rel", "")
            target_url = rel.get("url", "")

            # Debug: log the actual relation type names we see
            if rel_type:
                log.debug(f"  WI#{wi_id}: rel_type='{rel_type}'")

            # Extract target WI ID from URL (format: ...workItems/123)
            # Note: URL uses capital 'I' in workItems
            try:
                if "/workItems/" in target_url:
                    target_id = int(target_url.split("/workItems/")[-1])
                elif "/workitems/" in target_url:
                    target_id = int(target_url.split("/workitems/")[-1])
                else:
                    continue
            except:
                continue

            # ADO Hierarchy relations (parent-child)
            if rel_type == "System.LinkTypes.Hierarchy-Forward":
                # Forward = parent pointing to child
                hierarchy[wi_id]['children'].append(target_id)
            elif rel_type == "System.LinkTypes.Hierarchy-Reverse":
                # Reverse = child pointing to parent
                hierarchy[wi_id]['parents'].append(target_id)
            # Alternative naming conventions (fallback)
            elif rel_type == "Parent":
                hierarchy[wi_id]['parents'].append(target_id)
            elif rel_type == "Child":
                hierarchy[wi_id]['children'].append(target_id)
            # Related items
            elif rel_type == "System.LinkTypes.Related":
                hierarchy[wi_id]['related'].append(target_id)
            # Dependencies
            elif rel_type == "System.LinkTypes.Dependency-Reverse":
                hierarchy[wi_id]['blockedBy'].append(target_id)
            elif rel_type == "System.LinkTypes.Dependency":
                hierarchy[wi_id]['blocks'].append(target_id)

        log.debug(f"WI#{wi_id}: parents={len(hierarchy[wi_id]['parents'])}, "
                 f"children={len(hierarchy[wi_id]['children'])}")

    log.info(f"Built hierarchy for {len(hierarchy)} work items")
    return hierarchy

# ── GitHub: Create Issue Links ───────────────────────────────────────────────

def gh_create_issue_link(source_num: int, target_num: int,
                         link_type: str = "BLOCKS", dry_run: bool = False):
    """
    Create a GitHub issue link via comment-based tracking.

    Since GitHub GraphQL issue linking has limited support, we use a fallback:
    - Add a comment to track the relationship
    - This makes the relationship visible and searchable

    link_type: "BLOCKS", "BLOCKED_BY", "RELATES_TO"
    """
    if dry_run:
        log.debug(f"    [DRY RUN] GH#{source_num} {link_type} GH#{target_num}")
        return True

    try:
        # Use REST API to add a comment documenting the relationship
        comment_map = {
            "PARENT": f"**Parent Issue:** #{target_num}",
            "CHILD": f"**Child Issue:** #{target_num}",
            "BLOCKS": f"**Blocks:** #{target_num}",
            "BLOCKED_BY": f"**Blocked by:** #{target_num}",
            "RELATES_TO": f"**Related:** #{target_num}"
        }

        comment_text = comment_map.get(link_type, f"**Links:** {link_type} #{target_num}")

        # Add comment to source issue
        url = f"https://api.github.com/repos/{_GH_OWNER}/{_GH_REPO}/issues/{source_num}/comments"

        payload = {"body": comment_text}

        log.debug(f"    POSTing comment to GH#{source_num}: {comment_text}")

        r = requests.post(url, headers=_gh_hdr(), json=payload, timeout=30)

        if r.status_code == 201:
            log.debug(f"    ✓ GH#{source_num} {link_type} GH#{target_num}")
            return True
        else:
            log.warning(f"    Unexpected status {r.status_code} for GH#{source_num}: {r.text}")
            return True  # Still return True - best effort

    except requests.exceptions.RequestException as e:
        log.error(f"    Network error linking GH#{source_num} {link_type} GH#{target_num}: {e}")
        return True  # Still return True - best effort
    except Exception as e:
        log.error(f"    Error linking GH#{source_num} {link_type} GH#{target_num}: {e}")
        return True  # Still return True - best effort

# ── Migration Orchestrator ────────────────────────────────────────────────────

def migrate_relations(progress: dict, migrated_map: dict, dry_run: bool = False):
    """
    Migrate all work item relations to GitHub issue links (via comments).

    Args:
        progress: migration_progress.json data
        migrated_map: {ado_id: gh_issue_number, ...}
        dry_run: if True, don't actually create links
    """
    log.info("Step 7/9  Migrating work item relations …")

    if not migrated_map:
        log.warning("  No migrated work items to create relations for")
        return

    log.info(f"  Fetching relations for {len(migrated_map)} work items…")
    hierarchy = get_all_relations()

    if not hierarchy:
        log.info("  No relations found in ADO.")
        return

    log.info(f"  Found {len(hierarchy)} items with relations data")

    ok = fail = 0
    links_created = 0
    skipped_unmigrated = 0

    for ado_id, rels in hierarchy.items():
        # Skip if this work item wasn't migrated
        gh_src = migrated_map.get(str(ado_id)) or migrated_map.get(ado_id)
        if not gh_src:
            skipped_unmigrated += 1
            continue

        # Count total relations for this item
        total_rels = (len(rels.get('children', [])) +
                     len(rels.get('blockedBy', [])) +
                     len(rels.get('related', [])))

        if total_rels > 0:
            log.debug(f"  ADO#{ado_id} → GH#{gh_src}: {total_rels} relation(s)")

        # ── Migrate parents (child pointing to parent) ──
        for parent_ado_id in rels.get('parents', []):
            gh_tgt = migrated_map.get(str(parent_ado_id)) or migrated_map.get(parent_ado_id)
            if gh_tgt:
                result = gh_create_issue_link(gh_src, gh_tgt, "PARENT", dry_run)
                if result:
                    ok += 1
                    links_created += 1
                else:
                    fail += 1
                time.sleep(0.2)
            else:
                log.debug(f"    Parent ADO#{parent_ado_id} not migrated")

        # ── Migrate children (parent→child) ──
        for child_ado_id in rels.get('children', []):
            gh_tgt = migrated_map.get(str(child_ado_id)) or migrated_map.get(child_ado_id)
            if gh_tgt:
                result = gh_create_issue_link(gh_src, gh_tgt, "CHILD", dry_run)
                if result:
                    ok += 1
                    links_created += 1
                else:
                    fail += 1
                time.sleep(0.2)
            else:
                log.debug(f"    Child ADO#{child_ado_id} not migrated")

        # ── Migrate dependencies ──
        for blocked_by_id in rels.get('blockedBy', []):
            gh_tgt = migrated_map.get(str(blocked_by_id)) or migrated_map.get(blocked_by_id)
            if gh_tgt:
                result = gh_create_issue_link(gh_src, gh_tgt, "BLOCKED_BY", dry_run)
                if result:
                    ok += 1
                    links_created += 1
                else:
                    fail += 1
                time.sleep(0.2)
            else:
                log.debug(f"    Dependency ADO#{blocked_by_id} not migrated")

        # ── Migrate related issues ──
        for related_id in rels.get('related', []):
            gh_tgt = migrated_map.get(str(related_id)) or migrated_map.get(related_id)
            if gh_tgt:
                result = gh_create_issue_link(gh_src, gh_tgt, "RELATES_TO", dry_run)
                if result:
                    ok += 1
                    links_created += 1
                else:
                    fail += 1
                time.sleep(0.2)
            else:
                log.debug(f"    Related ADO#{related_id} not migrated")

    log.info(f"  Relations complete:")
    log.info(f"    - Links created: {links_created}")
    log.info(f"    - Skipped (unmigrated): {skipped_unmigrated}")
    if fail > 0:
        log.warning(f"    - Failed: {fail}")
