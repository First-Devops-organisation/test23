"""
delivery_plans.py
=================
Handles Azure DevOps Delivery Plans (timeline views) and dependency tracking.

Strategy
--------
1. Fetch all delivery plans from ADO
2. Extract work items and their timeline info (planned dates, dependencies)
3. Export as:
   - CSV timeline (ado_id, gh_issue_num, title, start_date, end_date, status)
   - Mermaid timeline diagram
   - Markdown roadmap view
4. Create GitHub Project views/filters that simulate timeline behavior

Note: GitHub doesn't have native "Delivery Plans" like ADO, so we:
  - Use GitHub Projects v2 (with custom date fields when available)
  - Export timeline as CSV/Markdown
  - Create Mermaid diagrams for visual timelines
  - Use issue linking for dependencies

Public API
----------
  configure(ado_org, ado_project, ado_pat)
  get_all_delivery_plans()               → list of plan dicts
  get_plan_work_items(plan_id)           → [wi_dict, ...]
  export_timeline_csv(migrated_map, output_file)
  export_timeline_mermaid(migrated_map, output_file)
  generate_roadmap_markdown(migrated_map, output_file)
"""

import base64, logging, csv, json
from datetime import datetime
from pathlib import Path
import requests

log = logging.getLogger("migrator.delivery_plans")

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

# ── Delivery Plans ────────────────────────────────────────────────────────────

def get_all_delivery_plans() -> list:
    """
    Fetch all delivery plans from ADO.

    Returns list of plan dicts:
    {
        'id': plan_id,
        'name': plan_name,
        'description': description,
        'teams': [team_ids],
        'criteria': filter_criteria,
        'url': plan_url
    }
    """
    # Delivery Plans are typically fetched via DeliveryPlans API
    #url = f"https://dev.azure.com/{_ORG}/{_PROJECT}/_apis/work/plans?api-version=7.1-preview.3"
    url = f"https://dev.azure.com/{_ORG}/{_PROJECT}/_apis/work/plans?api-version=7.1"

    try:
        data = _get(url)
        plans = []

        for plan in data.get('value', []):
            plans.append({
                'id': plan.get('id'),
                'name': plan.get('name'),
                'description': plan.get('description', ''),
                'teams': plan.get('teams', []),
                'url': plan.get('url', ''),
            })

        log.info(f"Fetched {len(plans)} delivery plan(s)")
        return plans

    except Exception as e:
        log.warning(f"Failed to fetch delivery plans: {e}")
        return []

def get_plan_work_items(plan_id: str) -> list:
    """
    Fetch all work items in a delivery plan with timeline metadata.

    Returns list of wi_dicts with timeline info.
    """
    #url = f"https://dev.azure.com/{_ORG}/{_PROJECT}/_apis/work/plans/{plan_id}?api-version=7.1-preview.3"
    url = f"https://dev.azure.com/{_ORG}/{_PROJECT}/_apis/work/plans/{plan_id}?api-version=7.1"

    try:
        data = _get(url)
        items = []

        for card_row_data in data.get('cardRowsPagedList', []):
            for card in card_row_data.get('cards', []):
                wi = card.get('workItem', {})
                items.append({
                    'id': wi.get('id'),
                    'title': wi.get('title', ''),
                    'type': wi.get('type', ''),
                    'start_date': card.get('startDate'),
                    'end_date': card.get('endDate'),
                    'state': card.get('status'),
                })

        return items

    except Exception as e:
        log.warning(f"Failed to fetch plan items for {plan_id}: {e}")
        return []

# ── Export Functions ──────────────────────────────────────────────────────────

def export_timeline_csv(migrated_map: dict, plans: list = None,
                        output_file: str = "timeline.csv"):
    """
    Export work items from all delivery plans to CSV with timeline info.

    CSV columns:
      ADO_ID, GitHub_Issue, Title, Type, Start_Date, End_Date, Status, Plan_Name
    """
    if plans is None:
        plans = get_all_delivery_plans()

    rows = []

    for plan in plans:
        plan_items = get_plan_work_items(plan['id'])

        for item in plan_items:
            ado_id = item['id']
            gh_num = migrated_map.get(str(ado_id)) or migrated_map.get(ado_id)

            rows.append({
                'ADO_ID': ado_id,
                'GitHub_Issue': f"#{gh_num}" if gh_num else "N/A",
                'Title': item['title'],
                'Type': item['type'],
                'Start_Date': item['start_date'] or '',
                'End_Date': item['end_date'] or '',
                'Status': item['state'] or '',
                'Plan': plan['name'],
            })

    # Write CSV
    output_path = Path(output_file)
    if rows:
        with open(output_path, 'w', newline='', encoding='utf-8') as f:
            writer = csv.DictWriter(f, fieldnames=rows[0].keys())
            writer.writeheader()
            writer.writerows(rows)
        log.info(f"Exported {len(rows)} timeline items to {output_file}")
    else:
        log.info("No timeline items to export")

def export_timeline_mermaid(migrated_map: dict, plans: list = None,
                            output_file: str = "timeline.mmd"):
    """
    Export timeline as Mermaid gantt diagram.

    Useful for visualizing dependencies and schedules.
    """
    if plans is None:
        plans = get_all_delivery_plans()

    lines = [
        "gantt",
        "    title Delivery Plan Timeline",
        "    dateFormat YYYY-MM-DD",
        "    axisFormat %Y-%m",
        "",
    ]

    for plan in plans:
        plan_items = get_plan_work_items(plan['id'])

        if not plan_items:
            continue

        lines.append(f"    section {plan['name']}")

        for item in plan_items:
            ado_id = item['id']
            title = item['title'][:60]  # Truncate
            start = item['start_date'] or '2024-01-01'
            end = item['end_date'] or '2024-12-31'
            status = item['state'] or 'planned'

            # Mermaid task: milestone, crit (critical), done, active
            task_type = 'done' if status == 'Completed' else 'active' if status == 'In Progress' else ''
            task_str = f"{task_type}, " if task_type else ""

            lines.append(f"    GH#{migrated_map.get(str(ado_id), ado_id)} : {task_str}{start}, {end}")

        lines.append("")

    output_path = Path(output_file)
    output_path.write_text("\n".join(lines))
    log.info(f"Generated Mermaid timeline: {output_file}")

def generate_roadmap_markdown(migrated_map: dict, plans: list = None,
                              output_file: str = "ROADMAP.md"):
    """
    Generate a human-readable roadmap/timeline document in Markdown.

    Shows delivery plans, key milestones, and work item schedule.
    """
    if plans is None:
        plans = get_all_delivery_plans()

    lines = [
        "# Delivery Roadmap",
        "",
        "This roadmap shows the planned timeline for features and work items.",
        "See the corresponding GitHub issues for detailed discussions.",
        "",
    ]

    if not plans:
        lines.append("(No delivery plans found)")
    else:
        for plan in plans:
            lines.append(f"## {plan['name']}")

            if plan.get('description'):
                lines.append(f"\n{plan['description']}\n")

            plan_items = get_plan_work_items(plan['id'])

            if not plan_items:
                lines.append("*(No items in this plan)*\n")
                continue

            # Group by quarter/time
            lines.append("| Item | GitHub | Type | Timeline | Status |")
            lines.append("|------|--------|------|----------|--------|")

            for item in plan_items:
                ado_id = item['id']
                gh_num = migrated_map.get(str(ado_id)) or migrated_map.get(ado_id)
                gh_link = f"[#{gh_num}](https://github.com/{_ORG}/{_PROJECT}/issues/{gh_num})" if gh_num else "N/A"

                start = item['start_date'] or "TBD"
                end = item['end_date'] or "TBD"
                timeline = f"{start} → {end}"

                lines.append(
                    f"| {item['title'][:50]} | {gh_link} | {item['type']} | {timeline} | {item['state']} |"
                )

            lines.append("")

    output_path = Path(output_file)
    output_path.write_text("\n".join(lines))
    log.info(f"Generated roadmap: {output_file}")

# ── Dependencies & Linking ────────────────────────────────────────────────────

def extract_critical_path(plans: list = None) -> list:
    """
    Analyze delivery plans to find the critical path
    (longest sequence of dependent items).

    Returns list of item sequences.
    """
    if plans is None:
        plans = get_all_delivery_plans()

    critical_items = []

    for plan in plans:
        items = get_plan_work_items(plan['id'])

        # Simple heuristic: items with dependencies on critical items
        # Proper implementation would build a DAG and compute critical path

        for item in items:
            if item['state'] in ['In Progress', 'Active']:
                critical_items.append({
                    'id': item['id'],
                    'title': item['title'],
                    'plan': plan['name'],
                    'urgency': 'high' if item['state'] == 'In Progress' else 'medium'
                })

    return sorted(critical_items, key=lambda x: x['urgency'])

# ── Summary Export ────────────────────────────────────────────────────────────

def export_delivery_plan_summary(migrated_map: dict,
                                  output_dir: str = "."):
    """
    Export all delivery plan artifacts:
    - timeline.csv
    - timeline.mmd (Mermaid diagram)
    - ROADMAP.md (Markdown)
    - critical_path.json (JSON)
    """
    output_path = Path(output_dir)
    output_path.mkdir(exist_ok=True)

    plans = get_all_delivery_plans()

    log.info(f"Exporting delivery plans ({len(plans)} found) …")

    # CSV
    export_timeline_csv(migrated_map, plans,
                       str(output_path / "timeline.csv"))

    # Mermaid
    export_timeline_mermaid(migrated_map, plans,
                            str(output_path / "timeline.mmd"))

    # Markdown
    generate_roadmap_markdown(migrated_map, plans,
                              str(output_path / "ROADMAP.md"))

    # Critical path
    critical = extract_critical_path(plans)
    if critical:
        cp_file = output_path / "critical_path.json"
        cp_file.write_text(json.dumps(critical, indent=2))
        log.info(f"  Critical path: {len(critical)} item(s)")

    log.info(f"Exported delivery plan summary to {output_dir}")
