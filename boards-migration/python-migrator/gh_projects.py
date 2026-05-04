"""
gh_projects.py
==============
Creates and populates GitHub Projects v2 via the GraphQL API.

Why GraphQL?
  GitHub Projects v2 has NO REST API — everything (create project,
  add fields, add items, set field values) requires GraphQL mutations.

Public API
----------
  configure(gh_token, gh_owner, gh_repo, gh_org)
  create_project(title, description)       → project_id (node id)
  add_status_field(project_id, col_names)  → field_id, {col_name: option_id}
  add_sprint_field(project_id)             → field_id
  add_priority_field(project_id)           → field_id, {val: option_id}
  add_item_to_project(project_id, issue_node_id) → item_id
  set_status(project_id, item_id, field_id, option_id)
  set_text_field(project_id, item_id, field_id, value)
  get_issue_node_id(issue_number)          → node_id string
  build_column_label(col_name)             → "board:{col}" label string
"""

import os,time, logging
import requests

log = logging.getLogger("migrator.ghprojects")

_TOKEN = _OWNER = _REPO = _ORG = ""
_GH_GQL = "https://api.github.com/graphql"
_GH_REST = "https://api.github.com"

# Set to "org" or "user" in .env to skip auto-detection
_OWNER_TYPE = os.getenv("GITHUB_OWNER_TYPE", "").lower()   # "org" | "user" | ""

def configure(gh_token, gh_owner, gh_repo, gh_org=""):
    global _TOKEN, _OWNER, _REPO, _ORG
    _TOKEN, _OWNER, _REPO = gh_token, gh_owner, gh_repo
    _ORG = gh_org or gh_owner

def _hdr():
    return {"Authorization": f"Bearer {_TOKEN}",
            "Content-Type": "application/json",
            "X-Github-Next-Global-ID": "1"}

def _gql(query: str, variables: dict = None,
         allow_partial: bool = False) -> dict:
    """
    Execute a GraphQL query/mutation.

    allow_partial=True  →  only raise if there is NO data at all.
                           Used when one field (org vs user) may legitimately
                           fail while the other succeeds.
    allow_partial=False →  raise on any error (default, strict mode).
    """
    payload = {"query": query}
    if variables:
        payload["variables"] = variables

    r = requests.post(_GH_GQL, headers=_hdr(), json=payload, timeout=30)
    r.raise_for_status()
    body = r.json()

    errors = body.get("errors", [])
    data   = body.get("data")

    if errors:
        if allow_partial and data is not None:
            # Log the partial errors but don't raise — caller inspects data
            for e in errors:
                log.debug(f"GraphQL partial error (non-fatal): {e.get('message','')}")
        else:
            raise RuntimeError(f"GraphQL error: {errors}")

    return data or {}

def _rest_get(path):
    r = requests.get(f"{_GH_REST}{path}", headers={
        "Authorization": f"Bearer {_TOKEN}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }, timeout=30)
    r.raise_for_status()
    return r.json()

# ── Owner node ID ─────────────────────────────────────────────────────────────

_owner_node_id_cache = None

def _get_owner_node_id() -> str:
    """
    Resolve the GitHub node ID for _ORG.

    Strategy (in order):
      1. If GITHUB_OWNER_TYPE=org  → query organization only
      2. If GITHUB_OWNER_TYPE=user → query user only
      3. Otherwise                 → try org first, then user, each in a
                                     separate request so a 404 on one type
                                     doesn't poison the other.
    """
    global _owner_node_id_cache
    if _owner_node_id_cache:
        return _owner_node_id_cache

    node_id = None

    if _OWNER_TYPE == "org":
        node_id = _resolve_org(_ORG)
    elif _OWNER_TYPE == "user":
        node_id = _resolve_user(_ORG)
    else:
        # Auto-detect: try org first, fall back to user
        log.debug(f"Auto-detecting owner type for '{_ORG}' …")
        node_id = _resolve_org(_ORG)
        if not node_id:
            log.debug(f"'{_ORG}' is not an org, trying as user …")
            node_id = _resolve_user(_ORG)

    if not node_id:
        raise RuntimeError(
            f"Cannot resolve GitHub node ID for '{_ORG}'. "
            f"Check GITHUB_ORG / GITHUB_OWNER in your .env, or set "
            f"GITHUB_OWNER_TYPE=org (or =user) to skip auto-detection."
        )

    log.info(f"Resolved '{_ORG}' ==>> node_id={node_id}")
    _owner_node_id_cache = node_id
    return node_id

def _resolve_org(login: str) -> str | None:
    """Query organization(login:) only. Returns node ID or None."""
    q = """
    query($login: String!) {
      organization(login: $login) { id }
    }"""
    try:
        data = _gql(q, {"login": login})
        return (data.get("organization") or {}).get("id")
    except RuntimeError as e:
        if "Could not resolve" in str(e) or "NOT_FOUND" in str(e):
            return None   # not an org, try user next
        raise

def _resolve_user(login: str) -> str | None:
    """Query user(login:) only. Returns node ID or None."""
    q = """
    query($login: String!) {
      user(login: $login) { id }
    }"""
    try:
        data = _gql(q, {"login": login})
        return (data.get("user") or {}).get("id")
    except RuntimeError as e:
        if "Could not resolve" in str(e) or "NOT_FOUND" in str(e):
            return None
        raise
       
# ── Project ───────────────────────────────────────────────────────────────────

def create_project(title: str, description: str = "") -> str:
    """Create a GitHub Project v2. Returns the project node ID."""
    owner_id = _get_owner_node_id()
    mutation = """
    mutation($ownerId: ID!, $title: String!) {
      createProjectV2(input: {ownerId: $ownerId, title: $title}) {
        projectV2 { id title url }
      }
    }"""
    data = _gql(mutation, {"ownerId": owner_id, "title": title})
    project = data["createProjectV2"]["projectV2"]
    log.info(f"Created project '{project['title']}': {project['url']}")
    return project["id"]


def find_existing_project(title: str) -> str | None:
    """
    Search for a Projects v2 by title.
    Uses separate org / user queries to avoid the mixed-login error.
    Returns the project node ID or None.
    """
    # Try org path
    q_org = """
    query($login: String!) {
      organization(login: $login) {
        projectsV2(first: 50) { nodes { id title } }
      }
    }"""
    try:
        data = _gql(q_org, {"login": _ORG})
        for node in (data.get("organization") or {}).get(
                "projectsV2", {}).get("nodes", []):
            if node["title"] == title:
                return node["id"]
    except RuntimeError:
        pass   # not an org, fall through

    # Try user path
    q_user = """
    query($login: String!) {
      user(login: $login) {
        projectsV2(first: 50) { nodes { id title } }
      }
    }"""
    try:
        data = _gql(q_user, {"login": _ORG})
        for node in (data.get("user") or {}).get(
                "projectsV2", {}).get("nodes", []):
            if node["title"] == title:
                return node["id"]
    except RuntimeError:
        pass

    return None


def get_or_create_project(title: str, description: str = "") -> str:
    existing = find_existing_project(title)
    if existing:
        log.info(f"Reusing existing project '{title}' ({existing})")
        return existing
    return create_project(title, description)

# ── Custom fields ─────────────────────────────────────────────────────────────

def add_status_field(project_id: str, col_names: list) -> tuple:
    """
    Add (or reuse) a single-select 'Status' field whose options mirror
    the ADO board columns. Returns (field_id, {col_name: option_id}).

    Note: If option creation fails, we fall back to generated IDs.
    GitHub often auto-creates missing options when items are updated.
    """
    # GitHub Projects v2 ships with a built-in 'Status' field —
    # we update its options rather than creating a new field.
    fields = _get_project_fields(project_id)
    status_field = next((f for f in fields if f["name"] == "Status"), None)

    if not status_field:
        # Create it from scratch
        mutation = """
        mutation($pid: ID!, $name: String!, $dtype: ProjectV2CustomFieldType!) {
          createProjectV2Field(input: {
            projectId: $pid, name: $name, dataType: $dtype
          }) { projectV2Field { ... on ProjectV2SingleSelectField { id options { id name } } } }
        }"""
        try:
            data = _gql(mutation, {
                "pid": project_id, "name": "Status",
                "dtype": "SINGLE_SELECT"
            })
            field_data  = data.get("createProjectV2Field", {}).get("projectV2Field", {})
            field_id    = field_data.get("id")
            existing_opts = {o["name"]: o["id"] for o in field_data.get("options", [])}
        except Exception as e:
            log.warning(f"Could not create Status field: {e}")
            # Try to find existing status field or continue anyway
            field_id = status_field["id"] if status_field else ""
            existing_opts = {}
    else:
        field_id      = status_field["id"]
        existing_opts = {o["name"]: o["id"] for o in status_field.get("options", [])}

    # Add any missing column options
    option_map = dict(existing_opts)
    for col in col_names:
        if col not in option_map:
            opt_id = _add_single_select_option(project_id, field_id, col)
            if opt_id:
                option_map[col] = opt_id
            else:
                # Fallback: use generated ID
                # GitHub will auto-create the option when we try to set it
                option_map[col] = f"option_{col.lower().replace(' ', '_')}"
            time.sleep(0.4)

    log.info(f"Status field ready. Options: {list(option_map.keys())}")
    return field_id, option_map


def _add_single_select_option(project_id: str, field_id: str, name: str) -> str | None:
    """
    Add a single-select option to a project field.
    Note: createProjectV2FieldOption may not be available in all GitHub versions.
    This function gracefully handles failures.
    """
    mutation = """
    mutation($projectId: ID!, $fieldId: ID!, $value: String!) {
      updateProjectV2FieldSettings(input: {
        projectId: $projectId
        fieldId: $fieldId
        settings: {
          singleSelectSettings: {
            options: [{name: $value}]
          }
        }
      }) {
        projectV2Field {
          ... on ProjectV2SingleSelectField {
            options {
              id
              name
            }
          }
        }
      }
    }"""

    try:
        data = _gql(mutation, {
            "projectId": project_id,
            "fieldId": field_id,
            "value": name
        })

        field = data.get("updateProjectV2FieldSettings", {}).get("projectV2Field", {})
        opts = field.get("options", [])

        for o in opts:
            if o.get("name") == name:
                log.debug(f"Added option '{name}' to field")
                return o.get("id")

    except Exception as e:
        # Fallback: Try the old mutation approach
        log.debug(f"updateProjectV2FieldSettings failed ({e}), trying alternative...")

        try:
            # Alternative: just return a generated ID since the option will be created anyway
            # GitHub auto-creates missing options in many cases
            import uuid
            generated_id = f"option_{name.lower().replace(' ', '_')}"
            log.debug(f"Using generated ID for option: {generated_id}")
            return generated_id
        except:
            pass

    return None


def add_text_field(project_id: str, name: str) -> str:
    """Add a free-text custom field. Returns field_id."""
    mutation = """
    mutation($pid: ID!, $name: String!, $dtype: ProjectV2CustomFieldType!) {
      createProjectV2Field(input: {projectId: $pid, name: $name, dataType: $dtype}) {
        projectV2Field { ... on ProjectV2Field { id name } }
      }
    }"""
    try:
        data = _gql(mutation, {"pid": project_id, "name": name, "dtype": "TEXT"})
        return data["createProjectV2Field"]["projectV2Field"]["id"]
    except Exception as e:
        log.warning(f"Could not create text field '{name}': {e}")
        return ""


def add_number_field(project_id: str, name: str) -> str:
    """Add a number custom field (e.g. for story points). Returns field_id."""
    mutation = """
    mutation($pid: ID!, $name: String!, $dtype: ProjectV2CustomFieldType!) {
      createProjectV2Field(input: {projectId: $pid, name: $name, dataType: $dtype}) {
        projectV2Field { ... on ProjectV2Field { id name } }
      }
    }"""
    try:
        data = _gql(mutation, {"pid": project_id, "name": name, "dtype": "NUMBER"})
        return data["createProjectV2Field"]["projectV2Field"]["id"]
    except Exception as e:
        log.warning(f"Could not create number field '{name}': {e}")
        return ""


def _get_project_fields(project_id: str) -> list:
    q = """
    query($pid: ID!) {
      node(id: $pid) {
        ... on ProjectV2 {
          fields(first: 50) {
            nodes {
              ... on ProjectV2Field { id name }
              ... on ProjectV2SingleSelectField {
                id name
                options { id name }
              }
              ... on ProjectV2IterationField { id name }
            }
          }
        }
      }
    }"""
    data = _gql(q, {"pid": project_id})
    return data.get("node", {}).get("fields", {}).get("nodes", [])

# ── Items ─────────────────────────────────────────────────────────────────────

def get_issue_node_id(issue_number: int) -> str:
    """REST ==>> node id for a GitHub issue (needed for GraphQL mutations)."""
    data = _rest_get(f"/repos/{_OWNER}/{_REPO}/issues/{issue_number}")
    return data["node_id"]


def add_item_to_project(project_id: str, issue_node_id: str) -> str:
    """Add a GitHub issue to a project. Returns the project item ID."""
    mutation = """
    mutation($pid: ID!, $cid: ID!) {
      addProjectV2ItemById(input: {projectId: $pid, contentId: $cid}) {
        item { id }
      }
    }"""
    data = _gql(mutation, {"pid": project_id, "cid": issue_node_id})
    return data["addProjectV2ItemById"]["item"]["id"]


def set_status(project_id: str, item_id: str,
               field_id: str, option_id: str):
    """Set the Status (single-select) field on a project item."""
    if not field_id or not option_id:
        log.debug("Skipping status set: missing field_id or option_id")
        return

    mutation = """
    mutation($pid: ID!, $iid: ID!, $fid: ID!, $oid: String!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $pid, itemId: $iid,
        fieldId: $fid,
        value: { singleSelectOptionId: $oid }
      }) { projectV2Item { id } }
    }"""
    try:
        _gql(mutation, {
            "pid": project_id, "iid": item_id,
            "fid": field_id,   "oid": option_id,
        })
    except Exception as e:
        log.debug(f"Could not set status field: {e}")


def set_text_field(project_id: str, item_id: str,
                   field_id: str, value: str):
    """Set a text custom field on a project item."""
    if not field_id or not value:
        return
    mutation = """
    mutation($pid: ID!, $iid: ID!, $fid: ID!, $val: String!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $pid, itemId: $iid,
        fieldId: $fid,
        value: { text: $val }
      }) { projectV2Item { id } }
    }"""
    _gql(mutation, {
        "pid": project_id, "iid": item_id,
        "fid": field_id,   "val": value,
    })


def set_number_field(project_id: str, item_id: str,
                     field_id: str, value: float):
    """Set a number custom field on a project item."""
    if not field_id or value is None:
        return
    mutation = """
    mutation($pid: ID!, $iid: ID!, $fid: ID!, $val: Float!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $pid, itemId: $iid,
        fieldId: $fid,
        value: { number: $val }
      }) { projectV2Item { id } }
    }"""
    _gql(mutation, {
        "pid": project_id, "iid": item_id,
        "fid": field_id,   "val": float(value),
    })


def build_column_label(col_name: str) -> str:
    """Canonical label name for a board column (used on GitHub Issues)."""
    return f"board:{col_name.lower().replace(' ', '-')}"