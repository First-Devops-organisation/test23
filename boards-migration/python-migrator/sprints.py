"""
sprints.py
==========
Handles Azure DevOps sprints/iterations and backlogs.

Strategy
--------
1. Fetch all sprints/iterations from ADO for each team
2. Create GitHub milestones for each sprint
3. Add an 'Iteration' field to GitHub Projects v2 (if using projects)
4. Map work items to sprints via:
   - Milestone assignment (simple view)
   - Custom 'Sprint' text field (for more detail)
   - Iteration field in Projects v2 (if available)
5. Track backlog items (not in any sprint)

Public API
----------
  configure(ado_org, ado_project, ado_pat, gh_token, gh_owner, gh_repo)
  get_all_sprints()                      → {team_id: [sprint_info, ...]}
  ado_get_wi_sprint(wi_id)              → sprint_name or None
  gh_create_milestone(title, description, dry_run)  → milestone_number
  migrate_sprints(progress, migrated_map, dry_run)
"""

import base64, logging, time
import requests

log = logging.getLogger("migrator.sprints")

_ORG = _PROJECT = _PAT = ""
_GH_TOKEN = _GH_OWNER = _GH_REPO = _GH_ORG = ""
_GH_BASE = "https://api.github.com"
_GH_GQL = "https://api.github.com/graphql"

def configure(ado_org, ado_project, ado_pat, gh_token="", gh_owner="",
              gh_repo="", gh_org=""):
    """Configure ADO and GitHub credentials."""
    global _ORG, _PROJECT, _PAT, _GH_TOKEN, _GH_OWNER, _GH_REPO, _GH_ORG
    _ORG, _PROJECT, _PAT = ado_org, ado_project, ado_pat
    _GH_TOKEN, _GH_OWNER, _GH_REPO = gh_token, gh_owner, gh_repo
    _GH_ORG = gh_org or gh_owner

def _ado_hdr():
    """Azure DevOps Basic Auth header."""
    tok = base64.b64encode(f":{_PAT}".encode()).decode()
    return {"Authorization": f"Basic {tok}", "Content-Type": "application/json"}

def _gh_hdr():
    """GitHub REST header."""
    return {
        "Authorization": f"Bearer {_GH_TOKEN}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28"
    }

def _gh_gql_hdr():
    """GitHub GraphQL header."""
    return {
        "Authorization": f"Bearer {_GH_TOKEN}",
        "Content-Type": "application/json",
        "X-GitHub-Api-Version": "2022-11-28"
    }

def _get(url, headers, params=None):
    """GET request."""
    r = requests.get(url, headers=headers, params=params, timeout=30)
    r.raise_for_status()
    return r.json()

def _post(url, headers, data):
    """POST request."""
    r = requests.post(url, headers=headers, json=data, timeout=30)
    r.raise_for_status()
    return r.json()

def _gql(query: str, variables: dict = None) -> dict:
    """Execute GraphQL query/mutation."""
    payload = {"query": query}
    if variables:
        payload["variables"] = variables

    r = requests.post(_GH_GQL, headers=_gh_gql_hdr(), json=payload, timeout=30)
    r.raise_for_status()
    body = r.json()

    errors = body.get("errors", [])
    if errors:
        log.warning(f"GraphQL error: {errors}")
        return {}

    return body.get("data", {})

# ── ADO: Fetch Sprints ────────────────────────────────────────────────────────

def get_all_teams() -> list:
    """Get all teams in the ADO project."""
    url = f"https://dev.azure.com/{_ORG}/_apis/projects/{_PROJECT}/teams?api-version=7.1"
    try:
        data = _get(url, _ado_hdr())
        return data.get("value", [])
    except Exception as e:
        log.warning(f"Failed to fetch teams: {e}")
        return []

def get_team_sprints(team_id: str) -> list:
    """
    Fetch all iterations/sprints for a team.
    Returns list of sprint dicts: {id, name, start_date, end_date, status, path}
    """
    url = f"https://dev.azure.com/{_ORG}/{_PROJECT}/{team_id}/_apis/work/teamsettings/iterations?api-version=7.1"

    try:
        data = _get(url, _ado_hdr())
        sprints = []

        for item in data.get("value", []):
            sprints.append({
                'id': item.get('id', ''),
                'name': item.get('name', ''),
                'path': item.get('path', ''),
                'start_date': item.get('attributes', {}).get('startDate', ''),
                'end_date': item.get('attributes', {}).get('finishDate', ''),
                'status': item.get('attributes', {}).get('timeFrame', 'future'),  # past/current/future
            })

        return sprints

    except Exception as e:
        log.warning(f"Failed to fetch sprints for team {team_id}: {e}")
        return []

def get_all_sprints() -> dict:
    """
    Build a map of all sprints across all teams.
    Returns: {team_id: [sprint_dict, ...]}
    """
    teams = get_all_teams()
    all_sprints = {}

    for team in teams:
        team_id = team['id']
        sprints = get_team_sprints(team_id)
        if sprints:
            all_sprints[team_id] = sprints
            log.info(f"Team '{team['name']}': {len(sprints)} sprint(s)")

    return all_sprints

def ado_get_wi_sprint(wi_id: int) -> str | None:
    """
    Fetch the iteration/sprint for a single work item.
    Returns the sprint name or None.
    """
    url = (f"https://dev.azure.com/{_ORG}/{_PROJECT}/_apis/wit/workitems/{wi_id}"
           f"?fields=System.IterationPath&api-version=7.1")

    try:
        data = _get(url, _ado_hdr())
        itr_path = data.get('fields', {}).get('System.IterationPath', '')

        if itr_path:
            # IterationPath is like "Project\Sprint 1" → extract "Sprint 1"
            return itr_path.split("\\")[-1]

        return None

    except Exception as e:
        log.debug(f"Failed to get sprint for WI#{wi_id}: {e}")
        return None

# ── GitHub: Manage Milestones ─────────────────────────────────────────────────

_milestone_cache = {}

def gh_create_milestone(title: str, description: str = "", dry_run: bool = False) -> int | None:
    """
    Create or reuse a GitHub milestone (used as sprint container).
    Returns milestone number.
    """
    if title in _milestone_cache:
        return _milestone_cache[title]

    if dry_run:
        log.info(f"  [DRY RUN] Milestone: {title}")
        return None

    url = f"{_GH_BASE}/repos/{_GH_OWNER}/{_GH_REPO}/milestones"

    try:
        # Try to create
        payload = {"title": title}
        if description:
            payload["description"] = description

        data = _post(url, _gh_hdr(), payload)
        milestone_num = data.get('number')
        _milestone_cache[title] = milestone_num
        log.info(f" Created milestone #{milestone_num}: {title}")
        return milestone_num

    except requests.HTTPError as e:
        if e.response.status_code == 422:
            # Already exists, fetch it
            try:
                existing = _get(f"{url}?per_page=100", _gh_hdr())
                for m in existing:
                    if m['title'] == title:
                        _milestone_cache[title] = m['number']
                        log.info(f" Reusing milestone #{m['number']}: {title}")
                        return m['number']
            except:
                pass

    return None

# ── GitHub Projects: Iteration Field ──────────────────────────────────────────

def add_iteration_field(project_id: str) -> str | None:
    """
    Add an 'Iteration' field to a GitHub Project v2.
    GitHub Projects v2 has native iteration support.
    Returns field_id.
    """
    mutation = """
    mutation($projectId: ID!, $name: String!) {
      createProjectV2Field(input: {
        projectId: $projectId, name: $name, dataType: "ITERATION"
      }) {
        projectV2Field {
          ... on ProjectV2IterationField {
            id name
          }
        }
      }
    }"""

    try:
        data = _gql(mutation, {"projectId": project_id, "name": "Sprint"})
        field = data.get('createProjectV2Field', {}).get('projectV2Field', {})
        field_id = field.get('id')

        if field_id:
            log.info(f"  Added Iteration field: {field_id}")
            return field_id

    except Exception as e:
        log.debug(f"Could not add iteration field: {e}")

    return None

# ── Migration Orchestrator ────────────────────────────────────────────────────

def migrate_sprints(progress: dict, migrated_map: dict,
                    project_id: str = "", dry_run: bool = False):
    """
    Migrate ADO sprints to GitHub:
    1. Create milestones for each sprint
    2. Assign issues to milestones
    3. Optionally add sprint custom field to project
    4. Track backlog items separately

    Args:
        progress: migration_progress.json data
        migrated_map: {ado_id: gh_issue_number, ...}
        project_id: GitHub Projects v2 ID (optional)
        dry_run: if True, don't create/modify anything
    """
    log.info("Step 6/7  Migrating sprints & iterations …")

    sprints_by_team = get_all_sprints()

    if not sprints_by_team:
        log.info("  No sprints found.")
        return

    all_sprints = []
    for team_id, sprints in sprints_by_team.items():
        all_sprints.extend(sprints)

    # Create milestones
    sprint_to_milestone = {}
    for sprint in all_sprints:
        sprint_name = sprint['name']
        status = sprint['status']
        desc = f"Status: {status}\nStart: {sprint['start_date']}\nEnd: {sprint['end_date']}"

        milestone_num = gh_create_milestone(sprint_name, desc, dry_run)
        if milestone_num:
            sprint_to_milestone[sprint_name] = milestone_num

    log.info(f"  Created {len(sprint_to_milestone)} milestone(s)")

    # Assign issues to milestones
    # For each migrated issue, check if it has a sprint and assign milestone
    assigned = 0
    skipped = 0

    for ado_id, gh_num in migrated_map.items():
        sprint_name = ado_get_wi_sprint(int(ado_id))

        if not sprint_name:
            skipped += 1
            continue

        milestone_num = sprint_to_milestone.get(sprint_name)

        if not milestone_num:
            log.debug(f"  No milestone for sprint '{sprint_name}' on GH#{gh_num}")
            skipped += 1
            continue

        if dry_run:
            log.debug(f"  [DRY RUN] Assign GH#{gh_num} to milestone #{milestone_num}")
            assigned += 1
            continue

        try:
            url = f"{_GH_BASE}/repos/{_GH_OWNER}/{_GH_REPO}/issues/{gh_num}"
            _post(url, _gh_hdr(), {"milestone": milestone_num})
            assigned += 1
            log.debug(f"  GH#{gh_num} → Sprint '{sprint_name}' (milestone #{milestone_num})")
            time.sleep(0.4)

        except Exception as e:
            log.warning(f"  Failed to assign GH#{gh_num} to milestone: {e}")
            skipped += 1

    log.info(f"  Sprint assignment: {assigned} assigned / {skipped} unassigned")

    # Save sprint mapping to progress
    progress.setdefault('sprints', {}).update(sprint_to_milestone)
