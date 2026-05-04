#!/usr/bin/env python3
"""
Azure DevOps → GitHub Issues + Projects Migration Pipeline (ENHANCED)
======================================================================

NEW FEATURES:
  ✓ Parent-child work item relationships (via GitHub issue links)
  ✓ Sprints & iterations migration (to milestones + custom fields)
  ✓ Saved queries conversion (to GitHub labels & search filters)
  ✓ Delivery plans export (CSV, Mermaid, Markdown)
  ✓ Full hierarchy support (Epic → Feature → Task)
  ✓ Backlog tracking & sprint assignment

Flags:
  --skip-attachments      Skip file uploads
  --skip-boards           Skip board/project migration
  --skip-sprints          Skip sprint/iteration migration
  --skip-relations        Skip work item relationship links
  --skip-queries          Skip query conversion
  --skip-delivery-plans   Skip delivery plan export
  --board-only            Only migrate boards (issues already done)
  --dry-run              Test without writing to GitHub
  --limit N              Migrate max N work items
  --resume-from N        Resume from work item ID N
"""

import os, sys, json, time, logging, argparse, base64
from pathlib import Path
import requests
from dotenv import load_dotenv

# Import all migration modules
import attachments as att_module
import boards as board_module
import gh_projects as proj_module
import relations as rel_module
import sprints as sprint_module
import queries as query_module
import delivery_plans as dp_module

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    handlers=[logging.StreamHandler(sys.stdout),
              logging.FileHandler("migration.log")],
)
log = logging.getLogger("migrator")

# ── Configuration ─────────────────────────────────────────────────────────────

ADO_ORG     = os.getenv("ADO_ORG", "")
ADO_PROJECT = os.getenv("ADO_PROJECT", "")
ADO_PAT     = os.getenv("ADO_PAT", "")
GH_TOKEN    = os.getenv("GITHUB_TOKEN", "")
GH_OWNER    = os.getenv("GITHUB_OWNER", "")
GH_REPO     = os.getenv("GITHUB_REPO", "")
GH_ORG      = os.getenv("GITHUB_ORG", "")

ADO_BASE       = f"https://dev.azure.com/{ADO_ORG}/{ADO_PROJECT}/_apis"
GH_BASE        = "https://api.github.com"
GH_WRITE_DELAY = 0.8
ADO_PAGE_SIZE  = 200

TYPE_LABEL_MAP = {
    "Bug":"type:bug", "Task":"type:task", "User Story":"type:story",
    "Feature":"type:feature", "Epic":"type:epic",
    "Issue":"type:issue", "Test Case":"type:test-case",
}
CLOSED_STATES = {"Closed","Resolved","Done","Removed","Completed"}

# ── Helpers ───────────────────────────────────────────────────────────────────

def _ado_h():
    tok = base64.b64encode(f":{ADO_PAT}".encode()).decode()
    return {"Authorization": f"Basic {tok}", "Content-Type": "application/json"}

def _gh_h():
    return {"Authorization": f"Bearer {GH_TOKEN}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"}

def _get(u,h,p=None):
    r=requests.get(u,headers=h,params=p,timeout=30); r.raise_for_status(); return r.json()
def _post(u,h,d):
    r=requests.post(u,headers=h,json=d,timeout=30); r.raise_for_status(); return r.json()
def _patch(u,h,d):
    r=requests.patch(u,headers=h,json=d,timeout=30); r.raise_for_status(); return r.json()

PROGRESS_FILE = Path("migration_progress.json")

def load_progress():
    if PROGRESS_FILE.exists():
        return json.loads(PROGRESS_FILE.read_text())
    return {
        "migrated": {},
        "attachments": {},
        "projects": {},
        "relations": {},
        "sprints": {},
        "queries": {},
        "delivery_plans": {}
    }

def save_progress(p):
    PROGRESS_FILE.write_text(json.dumps(p, indent=2))

# ── ADO Helpers ───────────────────────────────────────────────────────────────

def ado_get_all_ids(extra=""):
    url  = f"{ADO_BASE}/wit/wiql?api-version=7.1"
    wiql = {"query": (
        f"SELECT [System.Id] FROM WorkItems "
        f"WHERE [System.TeamProject] = '{ADO_PROJECT}' {extra} "
        f"ORDER BY [System.Id] ASC"
    )}
    return [i["id"] for i in _post(url,_ado_h(),wiql).get("workItems",[])]

def ado_fetch_wis(ids):
    if not ids: return []
    url = (f"{ADO_BASE}/wit/workitems?ids={','.join(str(i) for i in ids)}"
           f"&$expand=all&api-version=7.1")
    return _get(url,_ado_h()).get("value",[])

def ado_fetch_comments(wi_id):
    #url = f"{ADO_BASE}/wit/workitems/{wi_id}/comments?api-version=7.1-preview.3"
    url = f"{ADO_BASE}/wit/workitems/{wi_id}/comments?api-version=7.1"
    try: return _get(url,_ado_h()).get("comments",[])
    except: return []

# ── GitHub Helpers ────────────────────────────────────────────────────────────

def gh_get_labels():
    url,ls = f"{GH_BASE}/repos/{GH_OWNER}/{GH_REPO}/labels?per_page=100",set()
    while url:
        r=requests.get(url,headers=_gh_h(),timeout=30); r.raise_for_status()
        for l in r.json(): ls.add(l["name"])
        url=r.links.get("next",{}).get("url")
    return ls

def gh_ensure_label(name,color="ededed"):
    try:
        _post(f"{GH_BASE}/repos/{GH_OWNER}/{GH_REPO}/labels",_gh_h(),
              {"name":name,"color":color})
    except requests.HTTPError as e:
        if e.response.status_code!=422: raise

def gh_ensure_labels(wis, existing):
    needed,colors = set(),{
        "type:bug":"d73a4a","type:task":"0075ca","type:story":"e4e669",
        "type:feature":"a2eeef","type:epic":"7057ff",
        "type:issue":"d876e3","type:test-case":"fbca04",
    }
    for wi in wis:
        f=wi["fields"]
        t=f.get("System.WorkItemType","")
        if t in TYPE_LABEL_MAP: needed.add(TYPE_LABEL_MAP[t])
        s=f.get("System.State","")
        if s: needed.add(f"state:{s.lower().replace(' ','-')}")
        bc=f.get("System.BoardColumn","")
        if bc: needed.add(proj_module.build_column_label(bc))
        for tg in (f.get("System.Tags","") or "").split(";"):
            tg=tg.strip()
            if tg: needed.add(f"tag:{tg.lower()}")
    for lbl in sorted(needed-existing):
        gh_ensure_label(lbl,colors.get(lbl,"c2e0c6" if lbl.startswith("board:") else "bfd4f2"))
        existing.add(lbl); time.sleep(0.3)

def gh_ms(title,cache):
    if title in cache: return cache[title]
    try:
        d=_post(f"{GH_BASE}/repos/{GH_OWNER}/{GH_REPO}/milestones",_gh_h(),{"title":title})
        cache[title]=d["number"]
    except requests.HTTPError as e:
        if e.response.status_code==422:
            for m in requests.get(
                f"{GH_BASE}/repos/{GH_OWNER}/{GH_REPO}/milestones?per_page=100",
                headers=_gh_h(),timeout=30).json():
                if m["title"]==title: cache[title]=m["number"]; break
        else: raise
    return cache.get(title)

def _html_md(html):
    try:
        from markdownify import markdownify; return markdownify(html,heading_style="ATX")
    except:
        import re
        return re.sub(r"<[^>]+>","",re.sub(r"<br\s*/?>","\n",html,flags=re.I)).strip()

def _rate():
    try:
        d=_get(f"{GH_BASE}/rate_limit",_gh_h())
        rem=d["resources"]["core"]["remaining"]
        rst=d["resources"]["core"]["reset"]
        if rem<50:
            wait=max(0,rst-int(time.time()))+5
            log.warning(f"Rate limit low. Sleeping {wait}s"); time.sleep(wait)
    except: pass

# ── Board Migration ───────────────────────────────────────────────────────────

def migrate_boards(progress: dict, dry_run: bool):
    """
    For every ADO board:
      1. Create a matching GitHub Project v2
      2. Add Status field with columns from the ADO board
      3. Add ADO ID, Story Points, Sprint text fields
      4. For each issue already migrated, add it to the project
         and set its Status to the ADO board column it was in
    """
    log.info("Board migration: fetching ADO boards …")
    all_boards = board_module.get_all_boards()
    log.info(f"Found {len(all_boards)} board(s).")

    migrated = progress["migrated"]    # {str(ado_id): gh_issue_number}
    proj_map = progress.setdefault("projects", {})

    for board in all_boards:
        b_id   = board["id"]
        b_name = board["name"]
        team   = board["team_name"]
        proj_title = f"{ADO_PROJECT} – {b_name}"

        log.info(f"\n== Board: '{b_name}' (team: {team}) ==")

        # ── 1. Fetch board structure ──────────────────────────────────────
        detail    = board_module.get_board_detail(b_id, team)
        col_names = [c["name"] for c in detail["columns"]]
        log.info(f"  Columns: {col_names}")

        # ── 2. Get card placement (col → [ado_ids]) ───────────────────────
        col_items = board_module.get_board_work_items(b_id, team)
        # Build reverse: ado_id → col_name (keyed by column id OR name)
        detail_col_by_id = {c["id"]:c["name"] for c in detail["columns"]}
        wi_to_col = {}
        for col_key, wi_ids in col_items.items():
            col_label = detail_col_by_id.get(col_key, col_key)
            for wid in wi_ids:
                wi_to_col[str(wid)] = col_label

        if dry_run:
            log.info(f"  [DRY RUN] Would create project '{proj_title}' with {len(col_names)} columns.")
            continue

        # ── 3. Create / reuse GitHub Project v2 ──────────────────────────
        if b_id in proj_map:
            project_id = proj_map[b_id]["project_id"]
            log.info(f"  Reusing project {project_id}")
        else:
            project_id = proj_module.get_or_create_project(proj_title)
            proj_map[b_id] = {"project_id": project_id, "title": proj_title}
            save_progress(progress)

        # ── 4. Ensure custom fields exist ────────────────────────────────
        status_fid, option_map = proj_module.add_status_field(project_id, col_names)
        ado_id_fid  = proj_module.add_text_field(project_id,   "ADO ID")
        sprint_fid  = proj_module.add_text_field(project_id,   "Sprint")
        points_fid  = proj_module.add_number_field(project_id, "Story Points")
        time.sleep(0.5)

        # ── 5. Add each migrated issue to the project ────────────────────
        relevant_ids = [
            ado_id for ado_id in migrated
            if ado_id in wi_to_col or  # on this board
               str(ado_id) in wi_to_col
        ]
        # If col_items is empty, add ALL migrated items to the project
        if not wi_to_col:
            relevant_ids = list(migrated.keys())

        log.info(f"  Adding {len(relevant_ids)} issue(s) to project …")

        for ado_id_str in relevant_ids:
            gh_num = migrated.get(str(ado_id_str)) or migrated.get(ado_id_str)
            if not gh_num:
                continue
            try:
                _rate()
                node_id = proj_module.get_issue_node_id(gh_num)
                item_id = proj_module.add_item_to_project(project_id, node_id)
                time.sleep(0.5)

                # Set Status column
                col_name = wi_to_col.get(str(ado_id_str)) or wi_to_col.get(ado_id_str)
                if col_name and col_name in option_map:
                    proj_module.set_status(project_id, item_id,
                                           status_fid, option_map[col_name])
                    time.sleep(0.4)

                # Set ADO ID field
                proj_module.set_text_field(project_id, item_id,
                                            ado_id_fid, str(ado_id_str))
                time.sleep(0.3)

                log.info(f"    ADO#{ado_id_str} ==>> GH#{gh_num} ==>> col='{col_name}'")

            except Exception as e:
                log.warning(f"    Failed to add GH#{gh_num} to project: {e}")

        save_progress(progress)
        log.info(f"  Board '{b_name}' ==>> project '{proj_title}' done.")

# ── Work Item Transform ───────────────────────────────────────────────────────

def transform(wi,ms_cache):
    f=wi["fields"]; aid=wi["id"]
    wt=f.get("System.WorkItemType",""); st=f.get("System.State","")
    ti=f.get("System.Title",f"Work Item {aid}")
    desc=f.get("System.Description","") or ""
    tags=f.get("System.Tags","") or ""
    prio=f.get("Microsoft.VSTS.Common.Priority","")
    area=f.get("System.AreaPath","")
    itr=f.get("System.IterationPath","")
    crd=f.get("System.CreatedDate","")
    crb=f.get("System.CreatedBy",{})
    if isinstance(crb,dict): crb=crb.get("displayName","")
    bc=f.get("System.BoardColumn","")
    sp=f.get("Microsoft.VSTS.Scheduling.StoryPoints","") or \
       f.get("Microsoft.VSTS.Scheduling.Effort","")

    lines=["<!-- migrated-from-azure-devops -->",
           f"> **ADO:** [{wt} #{aid}]({wi.get('url','')})"]
    if crd: lines.append(f"> **Created:** {crd[:10]} by {crb}")
    if area: lines.append(f"> **Area:** `{area}`")
    if itr: lines.append(f"> **Iteration:** `{itr}`")
    if prio: lines.append(f"> **Priority:** {prio}")
    if bc: lines.append(f"> **Board Column:** {bc}")
    if sp: lines.append(f"> **Story Points:** {sp}")
    lines+=["","---","",_html_md(desc) if desc else "_No description._"]

    labels=[]
    if wt in TYPE_LABEL_MAP: labels.append(TYPE_LABEL_MAP[wt])
    if st: labels.append(f"state:{st.lower().replace(' ','-')}")
    if bc: labels.append(proj_module.build_column_label(bc))
    for t in tags.split(";"):
        t=t.strip()
        if t: labels.append(f"tag:{t.lower()}")

    ms=None
    if itr: ms=gh_ms(itr.split("\\")[-1],ms_cache)

    return {"title":ti,"body":"\n".join(lines),"labels":labels,
            "milestone":ms,"board_column":bc,"story_points":sp,
            "state":"closed" if st in CLOSED_STATES else "open"}

def gh_create_issue(payload,dry_run):
    if dry_run: log.info(f"  [DRY RUN] {payload['title'][:80]}"); return None
    cp={"title":payload["title"],"body":payload["body"],"labels":payload["labels"]}
    if payload.get("milestone"): cp["milestone"]=payload["milestone"]
    data=_post(f"{GH_BASE}/repos/{GH_OWNER}/{GH_REPO}/issues",_gh_h(),cp)
    num=data["number"]
    if payload["state"]=="closed":
        _patch(f"{GH_BASE}/repos/{GH_OWNER}/{GH_REPO}/issues/{num}",_gh_h(),{"state":"closed"})
    return num

def gh_add_comments(num,comments,dry_run):
    for c in comments:
        author=c.get("createdBy",{})
        if isinstance(author,dict): author=author.get("displayName","Unknown")
        body=f"> **{author}** · {c.get('createdDate','')[:10]}\n\n{_html_md(c.get('text','') or '')}"
        if dry_run: continue
        try:
            _post(f"{GH_BASE}/repos/{GH_OWNER}/{GH_REPO}/issues/{num}/comments",
                  _gh_h(),{"body":body})
            time.sleep(GH_WRITE_DELAY)
        except Exception as e: log.warning(f"Comment fail: {e}")

def validate_config():
    miss=[k for k,v in {
        "ADO_ORG":ADO_ORG,"ADO_PROJECT":ADO_PROJECT,"ADO_PAT":ADO_PAT,
        "GITHUB_TOKEN":GH_TOKEN,"GITHUB_OWNER":GH_OWNER,"GITHUB_REPO":GH_REPO,
    }.items() if not v]
    if miss: log.error(f"Missing: {', '.join(miss)}"); sys.exit(1)

# ── Main Pipeline ─────────────────────────────────────────────────────────────

def run_pipeline(dry_run=False, limit=None, resume_from=None,
                  skip_attachments=False, skip_boards=False,
                  skip_sprints=False, skip_relations=False,
                  skip_queries=False, skip_delivery_plans=False,
                  board_only=False):
    validate_config()

    # Configure all modules
    att_module.configure(ADO_PAT, GH_TOKEN, GH_OWNER, GH_REPO)
    board_module.configure(ADO_ORG, ADO_PROJECT, ADO_PAT)
    proj_module.configure(GH_TOKEN, GH_OWNER, GH_REPO, GH_ORG or GH_OWNER)
    rel_module.configure(ADO_ORG, ADO_PROJECT, ADO_PAT, GH_TOKEN, GH_OWNER, GH_REPO)
    sprint_module.configure(ADO_ORG, ADO_PROJECT, ADO_PAT, GH_TOKEN, GH_OWNER, GH_REPO, GH_ORG or GH_OWNER)
    query_module.configure(ADO_ORG, ADO_PROJECT, ADO_PAT)
    dp_module.configure(ADO_ORG, ADO_PROJECT, ADO_PAT)

    log.info("=" * 70)
    log.info(f"  ADO Migration Pipeline (ENHANCED)")
    log.info(f"  Source      : {ADO_ORG}/{ADO_PROJECT}")
    log.info(f"  Target      : {GH_OWNER}/{GH_REPO}")
    log.info(f"  Mode        : {'DRY RUN' if dry_run else 'LIVE'}")
    log.info(f"  Attachments : {'SKIP' if skip_attachments else 'ON'}")
    log.info(f"  Boards      : {'SKIP' if skip_boards else 'ON'}")
    log.info(f"  Sprints     : {'SKIP' if skip_sprints else 'ON'}")
    log.info(f"  Relations   : {'SKIP' if skip_relations else 'ON'}")
    log.info(f"  Queries     : {'SKIP' if skip_queries else 'ON'}")
    log.info(f"  Delivery Plans : {'SKIP' if skip_delivery_plans else 'ON'}")
    log.info("=" * 70)

    progress = load_progress()
    already  = set(progress["migrated"].keys())
    ms_cache = {}

    if not board_only:
        # ── Step 1: Work item IDs ────────────────────────────────────────
        log.info("Step 1/9  Fetching work item IDs …")
        extra  = f"AND [System.Id] >= {resume_from}" if resume_from else ""
        all_ids = ado_get_all_ids(extra)
        to_do   = [i for i in all_ids if str(i) not in already]
        if limit: to_do=to_do[:limit]
        log.info(f"          {len(to_do)} to migrate ({len(already)} done).")

        if to_do:
            # ── Step 2: Fetch details ────────────────────────────────────
            log.info("Step 2/9  Fetching work item details …")
            all_wis=[]
            for i in range(0,len(to_do),ADO_PAGE_SIZE):
                all_wis.extend(ado_fetch_wis(to_do[i:i+ADO_PAGE_SIZE]))
                log.info(f"          {len(all_wis)}/{len(to_do)} …")

            # ── Step 3: Labels ───────────────────────────────────────────
            log.info("Step 3/9  Syncing labels …")
            if not dry_run: gh_ensure_labels(all_wis, gh_get_labels())

            # ── Step 4: Attachments ──────────────────────────────────────
            if not dry_run and not skip_attachments:
                log.info("Step 4/9  Preparing attachment release …")
                att_module._get_or_create_migration_release()
            else:
                log.info("Step 4/9  Skipped attachment release.")

            # ── Step 5: Create issues ────────────────────────────────────
            log.info("Step 5/9  Migrating work items …")
            ok=fail=0
            for idx,wi in enumerate(all_wis,1):
                aid=wi["id"]
                log.info(f"  [{idx}/{len(all_wis)}] ADO#{aid}  {wi['fields'].get('System.Title','')[:55]}")
                try:
                    payload=transform(wi,ms_cache)
                    _rate()
                    gh_num=gh_create_issue(payload,dry_run)
                    time.sleep(GH_WRITE_DELAY)
                    if not dry_run and gh_num:
                        comments=ado_fetch_comments(aid)
                        if comments: gh_add_comments(gh_num,comments,dry_run)
                        if not skip_attachments:
                            ac=len(att_module.extract_attachment_relations(wi))
                            if ac: att_module.migrate_attachments(wi,gh_num,dry_run)
                        progress["migrated"][str(aid)]=gh_num
                        save_progress(progress)
                        log.info(f"    [OK] GH#{gh_num}")
                    ok+=1
                except Exception as e:
                    log.error(f"    [FAIL] ADO#{aid}: {e}"); fail+=1

            log.info(f"Step 5/9  Work items: {ok} OK / {fail} failed.")
        else:
            log.info("Steps 2-5 skipped (nothing new to migrate).")

    # ── Step 6: Boards ───────────────────────────────────────────────────────
    if not skip_boards:
        log.info("Step 6/9  Migrating boards ==>> GitHub Projects v2 …")
        migrate_boards(progress, dry_run)
    else:
        log.info("Step 6/9  Board migration skipped.")

    # ── Step 7: Relations ────────────────────────────────────────────────────
    if not skip_relations:
        log.info("Step 7/9  Migrating work item relationships …")
        rel_module.migrate_relations(progress, progress["migrated"], dry_run)
    else:
        log.info("Step 7/9  Relationship migration skipped.")

    # ── Step 8: Sprints ──────────────────────────────────────────────────────
    if not skip_sprints:
        log.info("Step 8/9  Migrating sprints & iterations …")
        proj_id = ""
        if progress.get("projects"):
            first_proj = next(iter(progress.get("projects", {}).values()), {})
            proj_id = first_proj.get("project_id", "")
        sprint_module.migrate_sprints(progress, progress["migrated"], proj_id, dry_run)
    else:
        log.info("Step 8/9  Sprint migration skipped.")

    # ── Step 9: Queries, Delivery Plans, Summary ─────────────────────────────
    if not skip_queries:
        log.info("Step 9a/9 Exporting saved queries …")
        query_module.export_query_map("query_map.json")
        query_module.generate_filter_guide("GITHUB_FILTERS.md")
        log.info("          Query exports done (see query_map.json, GITHUB_FILTERS.md)")
    else:
        log.info("Step 9a/9 Query export skipped.")

    if not skip_delivery_plans:
        log.info("Step 9b/9 Exporting delivery plans …")
        dp_module.export_delivery_plan_summary(progress["migrated"], ".")
        log.info("          Delivery plan exports done (see timeline.csv, ROADMAP.md)")
    else:
        log.info("Step 9b/9 Delivery plan export skipped.")

    # ── Summary ──────────────────────────────────────────────────────────────
    total = len(progress["migrated"])
    proj  = len(progress.get("projects",{}))
    sprints = len(progress.get("sprints", {}))
    log.info(f"\nStep 9c/9 Complete.")
    log.info(f"  Issues     : {total}")
    log.info(f"  Projects   : {proj}")
    log.info(f"  Sprints    : {sprints}")
    log.info("")
    log.info("Next steps:")
    log.info("  1. Review GitHub issues and projects")
    log.info("  2. Check GITHUB_FILTERS.md for saved query conversions")
    log.info("  3. Check ROADMAP.md for delivery plan timeline")
    log.info("  4. Check critical_path.json for critical dependencies")


if __name__=="__main__":
    p=argparse.ArgumentParser(description="ADO → GitHub Migration (Enhanced)")
    p.add_argument("--dry-run",               action="store_true")
    p.add_argument("--limit",                 type=int,  default=None)
    p.add_argument("--resume-from",           type=int,  default=None)
    p.add_argument("--skip-attachments",      action="store_true")
    p.add_argument("--skip-boards",           action="store_true")
    p.add_argument("--skip-sprints",          action="store_true")
    p.add_argument("--skip-relations",        action="store_true")
    p.add_argument("--skip-queries",          action="store_true")
    p.add_argument("--skip-delivery-plans",   action="store_true")
    p.add_argument("--board-only",            action="store_true")
    a=p.parse_args()
    run_pipeline(
        dry_run=a.dry_run,
        limit=a.limit,
        resume_from=a.resume_from,
        skip_attachments=a.skip_attachments,
        skip_boards=a.skip_boards,
        skip_sprints=a.skip_sprints,
        skip_relations=a.skip_relations,
        skip_queries=a.skip_queries,
        skip_delivery_plans=a.skip_delivery_plans,
        board_only=a.board_only
    )
