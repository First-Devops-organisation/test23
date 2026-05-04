"""
boards.py
=========
Fetches every Azure DevOps board in the project:
  - Board metadata (name, columns, swimlanes)
  - Which work items sit in which column / swimlane
  - Column WIP limits and column type (incoming / in-progress / outgoing)

Public API
----------
  configure(ado_org, ado_project, ado_pat)
  get_all_boards()           → list of board summary dicts
  get_board_detail(board_id) → full board with columns + swimlanes
  get_board_work_items(board_id, team_name) → {col_name: [wi_id, …]}
"""

import base64, logging
import requests

log = logging.getLogger("migrator.boards")

_ORG = _PROJECT = _PAT = ""

def configure(org, project, pat):
    global _ORG, _PROJECT, _PAT
    _ORG, _PROJECT, _PAT = org, project, pat

def _hdr():
    tok = base64.b64encode(f":{_PAT}".encode()).decode()
    return {"Authorization": f"Basic {tok}",
            "Content-Type": "application/json"}

def _get(url, params=None):
    r = requests.get(url, headers=_hdr(), params=params, timeout=30)
    r.raise_for_status()
    return r.json()

def _base(team=""):
    seg = f"/{team}" if team else ""
    return f"https://dev.azure.com/{_ORG}/{_PROJECT}{seg}/_apis"

# ── Teams ────────────────────────────────────────────────────────────────────

def get_all_teams() -> list:
    """Return all teams in the project."""
    url  = f"https://dev.azure.com/{_ORG}/_apis/projects/{_PROJECT}/teams?api-version=7.1"
    data = _get(url)
    return data.get("value", [])

# ── Boards ───────────────────────────────────────────────────────────────────

def get_all_boards() -> list:
    """
    Return a flat list of board summary dicts across all teams.
    Each dict: {id, name, team_name, team_id, url}
    """
    teams  = get_all_teams()
    boards = []
    for team in teams:
        tname = team["name"]
        url   = f"{_base(tname)}/work/boards?api-version=7.1"
        try:
            data = _get(url)
            for b in data.get("value", []):
                boards.append({
                    "id":        b["id"],
                    "name":      b["name"],
                    "team_name": tname,
                    "team_id":   team["id"],
                    "url":       b.get("url", ""),
                })
        except Exception as e:
            log.warning(f"Could not fetch boards for team '{tname}': {e}")
    log.info(f"Found {len(boards)} board(s) across {len(teams)} team(s).")
    return boards


def get_board_detail(board_id: str, team_name: str) -> dict:
    """
    Fetch full board detail: columns (with WIP limits + type) and swimlanes.
    Returns a dict:
      {id, name, columns: [{id, name, column_type, item_limit,
                             stateMappings: {wi_type: state}}],
       swimlanes: [{id, name}]}
    """
    url  = f"{_base(team_name)}/work/boards/{board_id}?api-version=7.1"
    data = _get(url)

    columns = []
    for col in data.get("columns", []):
        columns.append({
            "id":            col["id"],
            "name":          col["name"],
            "column_type":   col.get("columnType", "inProgress"),
            "item_limit":    col.get("itemLimit", 0),
            "stateMappings": col.get("stateMappings", {}),
            "is_split":      col.get("isSplit", False),
        })

    swimlanes = [
        {"id": s["id"], "name": s.get("name", "Default Lane")}
        for s in data.get("rows", [])
    ]

    return {
        "id":         board_id,
        "name":       data.get("name", board_id),
        "team_name":  team_name,
        "columns":    columns,
        "swimlanes":  swimlanes,
    }


def get_board_work_items(board_id: str, team_name: str) -> dict:
    """
    Return a mapping of {column_name: [work_item_id, …]} for a board.
    Uses the board's work item API to get cards in each column.
    Falls back to WIQL column queries if the board items endpoint 404s.
    """
    url = (
        f"{_base(team_name)}/work/boards/{board_id}"
        f"/workitems?api-version=7.1-preview.1"
    )
    try:
        data     = _get(url)
        col_map  = {}
        for item in data.get("workItemsPagedResponse", {}).get("workItems", []):
            col  = item.get("columnId", "Unknown")
            wi_id = item.get("workItemId")
            col_map.setdefault(col, []).append(wi_id)
        return col_map
    except Exception as e:
        log.warning(f"Board items endpoint failed, using WIQL fallback: {e}")
        return _get_board_items_via_wiql(board_id, team_name)


def _get_board_items_via_wiql(board_id: str, team_name: str) -> dict:
    """
    WIQL fallback: query work items grouped by board column state.
    Returns {column_name: [work_item_id, …]}.
    """
    wiql_url = f"{_base(team_name)}/wit/wiql?api-version=7.1"
    wiql = {
        "query": (
            f"SELECT [System.Id], [System.BoardColumn] FROM WorkItems "
            f"WHERE [System.TeamProject] = '{_PROJECT}' "
            f"AND [System.BoardColumn] <> '' "
            f"ORDER BY [System.BoardColumn]"
        )
    }
    r = requests.post(wiql_url, headers=_hdr(), json=wiql, timeout=30)
    r.raise_for_status()
    items = r.json().get("workItems", [])

    if not items:
        return {}

    # Batch-fetch the BoardColumn field
    ids    = [str(i["id"]) for i in items[:200]]
    fields_url = (
        f"https://dev.azure.com/{_ORG}/{_PROJECT}/_apis/wit/workitems"
        f"?ids={','.join(ids)}"
        f"&fields=System.Id,System.BoardColumn&api-version=7.1"
    )
    details = _get(fields_url).get("value", [])
    col_map = {}
    for d in details:
        col   = d["fields"].get("System.BoardColumn", "Backlog")
        wi_id = d["id"]
        col_map.setdefault(col, []).append(wi_id)
    return col_map