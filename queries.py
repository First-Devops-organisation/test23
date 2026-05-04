"""
queries.py
==========
Converts Azure DevOps saved queries to GitHub search filters and label systems.

Strategy
--------
1. Fetch all saved queries from ADO
2. Parse WIQL (Work Item Query Language) to extract filter criteria
3. Convert WIQL predicates to GitHub label combinations
4. Create named filter sets as lists of labels users should search for
5. Export as:
   - JSON mapping (query_name → [labels, ...])
   - GitHub saved filter snippets (for docs/wiki)
   - Markdown guide with filter examples

Key Conversions
  WIQL: [System.State] = 'Active'    → GitHub label: state:active
  WIQL: [System.WorkItemType] = 'Bug' → GitHub label: type:bug
  WIQL: [System.Tags] CONTAINS 'urgent' → GitHub label: tag:urgent
  WIQL: [Microsoft.VSTS.Common.Priority] = '1' → GitHub label: priority:1

Public API
----------
  configure(ado_org, ado_project, ado_pat)
  get_all_queries()                      → list of query dicts
  parse_wiql_to_labels(wiql_query)       → [label, ...]
  export_query_map(filename)             → JSON file with all mappings
  generate_filter_guide(filename)        → Markdown guide for GitHub searches
"""

import base64, logging, json, re
from pathlib import Path
import requests

log = logging.getLogger("migrator.queries")

_ORG = _PROJECT = _PAT = ""

def configure(ado_org, ado_project, ado_pat):
    """Configure ADO credentials."""
    global _ORG, _PROJECT, _PAT
    _ORG, _PROJECT, _PAT = ado_org, ado_project, ado_pat

def _ado_hdr():
    """Azure DevOps Basic Auth header."""
    tok = base64.b64encode(f":{_PAT}".encode()).decode()
    return {"Authorization": f"Basic {tok}", "Content-Type": "application/json"}

def _get(url, params=None):
    """GET request."""
    r = requests.get(url, headers=_ado_hdr(), params=params, timeout=30)
    r.raise_for_status()
    return r.json()

def _post(url, data):
    """POST request."""
    r = requests.post(url, headers=_ado_hdr(), json=data, timeout=30)
    r.raise_for_status()
    return r.json()

# ── Query Repository ──────────────────────────────────────────────────────────

def get_all_queries() -> list:
    """
    Fetch all saved queries (Shared Queries) from ADO.

    Returns list of query dicts:
    {
        'id': query_id,
        'name': query_name,
        'path': query_path,
        'wiql': wiql_string,
        'url': query_url
    }
    """
    url = f"https://dev.azure.com/{_ORG}/{_PROJECT}/_apis/wit/queries?$depth=1&api-version=7.1"

    try:
        data = _get(url)
        queries = _flatten_queries(data.get('value', []))
        log.info(f"Fetched {len(queries)} saved query(ies)")
        return queries

    except Exception as e:
        log.error(f"Failed to fetch queries: {e}")
        return []

def _flatten_queries(items: list, parent_path: str = "Shared Queries") -> list:
    """
    Recursively flatten nested query folders.
    """
    flat = []

    for item in items:
        if item.get('isFolder'):
            # Recurse into folder
            child_path = f"{parent_path}/{item['name']}"
            flat.extend(_flatten_queries(item.get('children', []), child_path))
        else:
            # It's a query
            flat.append({
                'id': item.get('id'),
                'name': item.get('name'),
                'path': f"{parent_path}/{item['name']}",
                'wiql': item.get('wiql', ''),
                'url': item.get('url', ''),
            })

    return flat

# ── WIQL Parser ───────────────────────────────────────────────────────────────

# Mapping of ADO fields/values to GitHub labels
FIELD_MAPPING = {
    'System.State': {
        'Active': 'state:active',
        'Closed': 'state:closed',
        'Resolved': 'state:resolved',
        'Done': 'state:done',
        'In Progress': 'state:in-progress',
        'New': 'state:new',
        'Removed': 'state:removed',
    },
    'System.WorkItemType': {
        'Bug': 'type:bug',
        'Task': 'type:task',
        'User Story': 'type:story',
        'Feature': 'type:feature',
        'Epic': 'type:epic',
        'Issue': 'type:issue',
        'Test Case': 'type:test-case',
    },
    'Microsoft.VSTS.Common.Priority': {
        '1': 'priority:1',
        '2': 'priority:2',
        '3': 'priority:3',
        '4': 'priority:4',
    },
    'System.AssignedTo': {
        # Username → assignee:username (will need post-processing)
    },
}

def parse_wiql_to_labels(wiql_query: str) -> list:
    """
    Parse a WIQL query and extract GitHub label equivalents.

    Simple parser handles common patterns:
      [Field] = 'value'
      [Field] <> 'value'
      [Field] CONTAINS 'value'
      AND/OR combinations

    Returns list of labels to search for.
    """
    labels = set()

    # Remove comments and normalize
    wiql = re.sub(r'--.*?$', '', wiql_query, flags=re.MULTILINE)
    wiql = re.sub(r'/\*.*?\*/', '', wiql, flags=re.DOTALL)
    wiql = wiql.strip()

    # Pattern: [Field] OP 'value'
    # Captures: field_name, operator, value
    pattern = r'\[([^\]]+)\]\s*(=|<>|CONTAINS)\s+[''\"]([^''\"]+)[''\"]'

    for match in re.finditer(pattern, wiql, re.IGNORECASE):
        field, operator, value = match.groups()

        # Handle = (equals) and <> (not equals)
        negate = (operator == '<>')

        # Look up field mapping
        if field in FIELD_MAPPING:
            mapped = FIELD_MAPPING[field].get(value)
            if mapped:
                if not negate:
                    labels.add(mapped)
                # For now, skip negations (can't easily express "NOT state:closed")
                continue

        # For tags/free text, create tag: labels
        if field == 'System.Tags':
            tag_label = f"tag:{value.lower()}"
            if not negate:
                labels.add(tag_label)

        # For area path
        if field == 'System.AreaPath':
            area_label = f"area:{value.lower().replace(' ', '-')}"
            if not negate:
                labels.add(area_label)

    return sorted(list(labels))

# ── Export Functions ──────────────────────────────────────────────────────────

def export_query_map(output_file: str = "query_map.json"):
    """
    Export all ADO queries and their GitHub label equivalents to JSON.

    File format:
    {
        "queries": [
            {
                "name": "Active Bugs",
                "path": "Shared Queries/Bugs",
                "wiql": "SELECT...",
                "github_labels": ["type:bug", "state:active"],
                "github_search": "label:\"type:bug\" label:\"state:active\""
            }
        ]
    }
    """
    queries = get_all_queries()
    output = {"queries": []}

    for q in queries:
        labels = parse_wiql_to_labels(q['wiql'])
        search_expr = " ".join(f'label:"{l}"' for l in labels) if labels else "(no labels)"

        output["queries"].append({
            'name': q['name'],
            'path': q['path'],
            'wiql': q['wiql'],
            'github_labels': labels,
            'github_search': search_expr,
        })

    output_path = Path(output_file)
    output_path.write_text(json.dumps(output, indent=2))
    log.info(f"Exported {len(queries)} queries to {output_file}")

    return output

def generate_filter_guide(output_file: str = "GITHUB_FILTERS.md"):
    """
    Generate a Markdown guide showing how to search for items
    that were previously found using ADO queries.

    Output file includes:
    - Each ADO query name and description
    - Original WIQL
    - Equivalent GitHub label search
    - Example URL
    """
    queries = get_all_queries()

    lines = [
        "# GitHub Issue Search Guide",
        "",
        "This guide maps Azure DevOps saved queries to GitHub issue searches.",
        "Use the label filters below to find issues equivalent to your old ADO queries.",
        "",
    ]

    if not queries:
        lines.append("(No saved queries found)")
    else:
        for q in queries:
            labels = parse_wiql_to_labels(q['wiql'])

            lines.append(f"## {q['name']}")
            lines.append(f"**Path:** `{q['path']}`")
            lines.append("")

            if q['wiql']:
                lines.append("**Original WIQL:**")
                lines.append(f"```sql")
                lines.append(q['wiql'])
                lines.append("```")
                lines.append("")

            if labels:
                lines.append("**Search on GitHub:**")
                search_expr = " ".join(f'label:"{l}"' for l in labels)
                lines.append(f"`{search_expr}`")
                lines.append("")
                lines.append("**Labels:**")
                for lbl in labels:
                    lines.append(f"  - `{lbl}`")
            else:
                lines.append("*No label equivalents found for this query.*")

            lines.append("")
            lines.append("---")
            lines.append("")

    output_path = Path(output_file)
    output_path.write_text("\n".join(lines))
    log.info(f"Generated filter guide: {output_file}")

# ── Quick Helpers ─────────────────────────────────────────────────────────────

def suggest_labels_for_search(search_term: str) -> list:
    """
    Quick helper: suggest GitHub labels for a search term.
    Useful for helping users migrate manual searches.
    """
    term_lower = search_term.lower()
    suggestions = []

    # Simple heuristics
    if any(x in term_lower for x in ['bug', 'broken', 'issue', 'error']):
        suggestions.append('type:bug')
    if any(x in term_lower for x in ['task', 'do', 'implement']):
        suggestions.append('type:task')
    if any(x in term_lower for x in ['feature', 'request', 'enhancement']):
        suggestions.append('type:feature')
    if any(x in term_lower for x in ['epic', 'initiative', 'program']):
        suggestions.append('type:epic')
    if any(x in term_lower for x in ['active', 'open', 'new']):
        suggestions.append('state:active')
    if any(x in term_lower for x in ['done', 'closed', 'resolved']):
        suggestions.append('state:closed')
    if any(x in term_lower for x in ['urgent', 'critical', 'priority:1']):
        suggestions.append('priority:1')

    return list(set(suggestions))
