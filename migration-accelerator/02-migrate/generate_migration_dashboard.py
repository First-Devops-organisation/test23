#!/usr/bin/env python3
import os
import sys
import re
import json
from datetime import datetime

def main():
    if len(sys.argv) < 3:
        print("Usage:")
        print("  generate_migration_dashboard.py rewrite-config <config_yml_path> <central_repo> <reusables_ref>")
        print("  generate_migration_dashboard.py generate-dashboard <output_dir> <ado_org> <ado_project> <gh_org> <results_json_path>")
        sys.exit(1)

    action = sys.argv[1]

    if action == "rewrite-config":
        config_yml_path = sys.argv[2]
        central_repo = sys.argv[3]
        reusables_ref = sys.argv[4]
        rewrite_config(config_yml_path, central_repo, reusables_ref)
    elif action == "generate-dashboard":
        output_dir = sys.argv[2]
        ado_org = sys.argv[3]
        ado_project = sys.argv[4]
        gh_org = sys.argv[5]
        results_json_path = sys.argv[6]
        generate_dashboard(output_dir, ado_org, ado_project, gh_org, results_json_path)
    else:
        print(f"Unknown action: {action}")
        sys.exit(1)

def rewrite_config(config_yml_path, central_repo, reusables_ref):
    if not os.path.exists(config_yml_path):
        print(f"Error: Config file not found at {config_yml_path}")
        sys.exit(1)

    central_url = central_repo
    if not central_url.startswith("http://") and not central_url.startswith("https://"):
        if "/" in central_url:
            central_url = f"https://github.com/{central_url}"
        else:
            print(f"Error: Invalid central repo format: {central_repo}")
            sys.exit(1)

    print(f"Rewriting {config_yml_path} to centralize reusables at {central_url} (ref: {reusables_ref})")

    # Read config.yml
    try:
        with open(config_yml_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
    except Exception as e:
        print(f"Error reading config: {e}")
        sys.exit(1)

    # Backup original
    backup_path = f"{config_yml_path}.bak"
    try:
        with open(backup_path, 'w', encoding='utf-8') as f:
            f.writelines(lines)
        print(f"Backup saved to: {backup_path}")
    except Exception as e:
        print(f"Warning: Could not create backup: {e}")

    rewritten = []
    i = 0
    is_entry_prop = lambda l: (
        l.strip().startswith("target_url:") or
        l.strip().startswith("ref:") or
        l.strip().startswith("path:")
    )

    while i < len(lines):
        line = lines[i]
        match = re.match(r'^(\s*)-\s*name:\s*(\S+)', line)
        if match:
            indent = match.group(1)
            raw_name = match.group(2)
            prop_indent = f"{indent}  "

            # Sanitize name
            folder_name = raw_name.lower()
            if folder_name.endswith('.yml'): folder_name = folder_name[:-4]
            if folder_name.endswith('.yaml'): folder_name = folder_name[:-5]
            folder_name = re.sub(r'[^a-z0-9_\-]', '_', folder_name)

            rewritten.append(line)
            rewritten.append(f"{prop_indent}target_url: {central_url}\n")
            rewritten.append(f"{prop_indent}ref: {reusables_ref}\n")
            rewritten.append(f"{prop_indent}path: .github/actions/{folder_name}\n")

            # Skip existing target_url, ref, path
            j = i + 1
            while j < len(lines) and is_entry_prop(lines[j]):
                j += 1
            i = j
            continue
        else:
            rewritten.append(line)
            i += 1

    try:
        with open(config_yml_path, 'w', encoding='utf-8') as f:
            f.writelines(rewritten)
        print(f"Successfully normalized configuration file.")
    except Exception as e:
        print(f"Error writing rewritten config: {e}")
        sys.exit(1)

def generate_dashboard(output_dir, ado_org, ado_project, gh_org, results_json_path):
    if not os.path.exists(results_json_path):
        print(f"Error: Results JSON file not found at {results_json_path}")
        sys.exit(1)

    try:
        with open(results_json_path, 'r', encoding='utf-8') as f:
            results = json.load(f)
    except Exception as e:
        print(f"Error reading results JSON: {e}")
        sys.exit(1)

    dashboard_dir = os.path.join(output_dir, "dashboard")
    os.makedirs(dashboard_dir, exist_ok=True)

    scan_date = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")
    enc_org = html_escape(ado_org)
    enc_proj = html_escape(ado_project)
    enc_gh_org = html_escape(gh_org)

    total_count = len(results)
    success_count = sum(1 for r in results if r.get("Status") == "SUCCESS")
    partial_count = sum(1 for r in results if r.get("Status") == "PARTIAL")
    no_output_count = sum(1 for r in results if r.get("Status") == "NO_OUTPUT")
    failed_count = sum(1 for r in results if r.get("Status") in ["FAILED", "ERROR"])

    safe_divisor = max(total_count, 1)
    pct_success = round((success_count / safe_divisor) * 100)
    pct_partial = round((partial_count / safe_divisor) * 100)
    pct_failed = round((failed_count / safe_divisor) * 100)
    pct_no_output = round((no_output_count / safe_divisor) * 100)
    pct_migrated = pct_success + pct_partial

    seg1 = pct_success
    seg2 = seg1 + pct_partial
    seg3 = seg2 + pct_failed

    pipeline_table_rows = ""
    # Sort results by status and then pipeline name
    results_sorted = sorted(results, key=lambda x: (x.get("Status", ""), x.get("Pipeline", "")))
    for r in results_sorted:
        p_name = html_escape(r.get("Pipeline", ""))
        p_id = r.get("Id", "")
        p_repo = html_escape(r.get("TargetRepo", ""))
        p_mode = html_escape(r.get("Mode", ""))
        p_status = r.get("Status", "")

        status_badge = ""
        if p_status == "SUCCESS":
            status_badge = "<span class='badge-ok'>&#9989; Success</span>"
        elif p_status == "PARTIAL":
            status_badge = "<span class='badge-warn'>&#9888;&#65039; Partial</span>"
        elif p_status == "NO_OUTPUT":
            status_badge = "<span class='badge-warn'>&#128196; No Output</span>"
        elif p_status in ["FAILED", "ERROR"]:
            status_badge = "<span class='badge-fail'>&#10060; Failed</span>"
        else:
            status_badge = f"<span class='badge-fail'>{p_status}</span>"

        gh_repo_url = f"https://github.com/{gh_org}/{r.get('TargetRepo', '')}"
        pipeline_table_rows += f"    <tr><td>{p_id}</td><td>{p_name}</td><td><a href='{gh_repo_url}' target='_blank'>{p_repo}</a></td><td class='center'>{p_mode}</td><td class='center'>{status_badge}</td></tr>\n"

    # Find generated workflow files
    workflow_rows = ""
    for root, dirs, files in os.walk(output_dir):
        for file in files:
            if file.endswith(('.yml', '.yaml')):
                full_path = os.path.join(root, file)
                rel_path = os.path.relpath(full_path, output_dir)
                if "dashboard" in rel_path:
                    continue
                name = html_escape(os.path.splitext(file)[0])
                directory = html_escape(os.path.dirname(rel_path))
                size_kb = os.path.getsize(full_path) / 1024
                size_str = f"{size_kb:.1f} KB"
                workflow_rows += f"    <tr><td>{directory}</td><td>{name}</td><td class='num'>{size_str}</td></tr>\n"

    workflow_section = ""
    if workflow_rows:
        workflow_section = f"""
      <table>
        <thead><tr><th>Directory</th><th>Workflow</th><th>Size</th></tr></thead>
        <tbody>
{workflow_rows}
        </tbody>
      </table>
"""
    else:
        workflow_section = "      <p class='empty-state'><span class='empty-icon'>&#128194;</span>No workflow YAML files generated.</p>"

    breakdown_rows = f"""
        <tr><td><span class='dot' style='background:#10b981'></span> Successful</td>
            <td class='num'>{success_count}</td>
            <td><div class='mini-bar'><div class='mini-fill' style='width:{pct_success}%;background:#10b981'></div></div></td>
            <td class='num'>{pct_success}%</td></tr>
        <tr><td><span class='dot' style='background:#f59e0b'></span> Partial</td>
            <td class='num'>{partial_count}</td>
            <td><div class='mini-bar'><div class='mini-fill' style='width:{pct_partial}%;background:#f59e0b'></div></div></td>
            <td class='num'>{pct_partial}%</td></tr>
        <tr><td><span class='dot' style='background:#ef4444'></span> Failed / Error</td>
            <td class='num'>{failed_count}</td>
            <td><div class='mini-bar'><div class='mini-fill' style='width:{pct_failed}%;background:#ef4444'></div></div></td>
            <td class='num'>{pct_failed}%</td></tr>
        <tr><td><span class='dot' style='background:#6b7280'></span> No Output</td>
            <td class='num'>{no_output_count}</td>
            <td><div class='mini-bar'><div class='mini-fill' style='width:{pct_no_output}%;background:#6b7280'></div></div></td>
            <td class='num'>{pct_no_output}%</td></tr>
"""

    html_content = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Pipeline Migration Report &mdash; {enc_org}</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap');
  :root {{
    --green: #10b981; --yellow: #f59e0b; --red: #ef4444; --gray: #6b7280;
    --bg: #0f172a; --surface: #1e293b; --surface2: #334155;
    --text: #f1f5f9; --text2: #94a3b8; --accent: #38bdf8; --accent2: #818cf8;
    --border: rgba(148,163,184,.15); --radius: 16px;
  }}
  * {{ margin:0; padding:0; box-sizing:border-box; }}
  body {{ font-family:'Inter',system-ui,sans-serif; background:var(--bg); color:var(--text); min-height:100vh; }}

  .header {{ background: linear-gradient(135deg, #10b981 0%, #0ea5e9 50%, #8b5cf6 100%);
    padding: 40px 48px 32px; position: relative; overflow: hidden; }}
  .header::before {{ content:''; position:absolute; top:-50%; right:-20%; width:600px; height:600px;
    background: radial-gradient(circle, rgba(255,255,255,.08) 0%, transparent 70%); }}
  .header h1 {{ font-size:2.2rem; font-weight:800; letter-spacing:-.02em; position:relative; z-index:1; }}
  .header h1 .icon {{ font-size:1.6rem; margin-right:10px; }}
  .header .meta {{ margin-top:8px; font-size:.9rem; opacity:.85; position:relative; z-index:1; }}
  .header .meta span {{ margin-right:24px; }}
  .header .badge {{ display:inline-block; background:rgba(255,255,255,.2); backdrop-filter:blur(8px);
    padding:4px 14px; border-radius:20px; font-size:.8rem; font-weight:600; margin-top:12px; position:relative; z-index:1; }}

  .container {{ max-width:1440px; margin:0 auto; padding: 0 32px 40px; }}

  .kpi-row {{ display:grid; grid-template-columns:repeat(5,1fr); gap:16px; margin: -40px 0 32px; position:relative; z-index:2; }}
  .kpi {{ background:var(--surface); border:1px solid var(--border); border-radius:var(--radius); padding:24px 20px;
    text-align:center; transition: transform .2s, box-shadow .2s; }}
  .kpi:hover {{ transform:translateY(-4px); box-shadow: 0 12px 40px rgba(0,0,0,.3); }}
  .kpi .kpi-icon {{ font-size:1.6rem; margin-bottom:8px; }}
  .kpi .kpi-val {{ font-size:2.4rem; font-weight:800; font-variant-numeric:tabular-nums; }}
  .kpi .kpi-label {{ font-size:.78rem; color:var(--text2); margin-top:4px; text-transform:uppercase; letter-spacing:.06em; }}
  .kpi.total .kpi-val {{ color:var(--accent); }}
  .kpi.success .kpi-val {{ color:var(--green); }}
  .kpi.partial .kpi-val {{ color:var(--yellow); }}
  .kpi.failed .kpi-val {{ color:var(--red); }}
  .kpi.nooutput .kpi-val {{ color:var(--gray); }}

  .panel {{ background:var(--surface); border:1px solid var(--border); border-radius:var(--radius);
    padding:28px; margin-bottom:20px; }}
  .panel h2 {{ font-size:1.15rem; font-weight:700; margin-bottom:20px; display:flex; align-items:center; gap:10px; }}
  .panel h2 .sec-icon {{ font-size:1.2rem; }}

  .chart-grid {{ display:grid; grid-template-columns: 280px 1fr; gap:32px; align-items:center; }}
  @media (max-width:768px) {{ .chart-grid {{ grid-template-columns:1fr; }} }}
  .donut-wrap {{ position:relative; width:220px; height:220px; margin:0 auto; }}
  .donut {{ width:220px; height:220px; border-radius:50%;
    background: conic-gradient(
      var(--green) 0% {seg1}%,
      var(--yellow) {seg1}% {seg2}%,
      var(--red) {seg2}% {seg3}%,
      var(--gray) {seg3}% 100%
    );
    -webkit-mask: radial-gradient(circle, transparent 60%, black 61%);
            mask: radial-gradient(circle, transparent 60%, black 61%);
  }}
  .donut-center {{ position:absolute; top:50%; left:50%; transform:translate(-50%,-50%); text-align:center; }}
  .donut-center .big {{ font-size:2.6rem; font-weight:800; color:var(--accent); }}
  .donut-center .sub {{ font-size:.8rem; color:var(--text2); }}

  .breakdown {{ width:100%; border-collapse:collapse; }}
  .breakdown td {{ padding:12px 10px; border-bottom:1px solid var(--border); font-size:.9rem; }}
  .breakdown tr:last-child td {{ border-bottom:none; }}
  .dot {{ display:inline-block; width:10px; height:10px; border-radius:50%; margin-right:8px; vertical-align:middle; }}
  .num {{ text-align:right; font-variant-numeric:tabular-nums; font-weight:600; }}
  .mini-bar {{ width:100%; height:8px; background:var(--surface2); border-radius:4px; overflow:hidden; }}
  .mini-fill {{ height:100%; border-radius:4px; transition: width .8s ease; }}

  .stacked-bar {{ display:flex; height:14px; border-radius:7px; overflow:hidden; margin-top:16px; }}
  .stacked-bar .seg {{ transition: width .8s ease; }}

  table:not(.breakdown) {{ width:100%; border-collapse:collapse; }}
  table:not(.breakdown) th {{ background: linear-gradient(135deg,#10b981,#0ea5e9); color:#fff;
    padding:14px 12px; text-align:left; font-size:.8rem; text-transform:uppercase; letter-spacing:.06em; font-weight:600; }}
  table:not(.breakdown) td {{ padding:12px; border-bottom:1px solid var(--border); font-size:.85rem; }}
  table:not(.breakdown) tr:hover {{ background:rgba(56,189,248,.06); }}
  .center {{ text-align:center; }}
  a {{ color:var(--accent); text-decoration:none; }}
  a:hover {{ text-decoration:underline; }}

  .badge-ok {{ background:rgba(16,185,129,.15); color:var(--green); padding:3px 12px; border-radius:12px; font-size:.78rem; font-weight:600; }}
  .badge-warn {{ background:rgba(245,158,11,.15); color:var(--yellow); padding:3px 12px; border-radius:12px; font-size:.78rem; font-weight:600; }}
  .badge-fail {{ background:rgba(239,68,68,.15); color:var(--red); padding:3px 12px; border-radius:12px; font-size:.78rem; font-weight:600; }}

  .checklist-item {{ display:flex; align-items:flex-start; gap:10px; padding:8px 0; font-size:.88rem; cursor:pointer; }}
  .checklist-item input[type=checkbox] {{ accent-color:var(--accent); margin-top:3px; width:16px; height:16px; }}
  .checklist-item span {{ flex:1; }}

  .empty-state {{ text-align:center; padding:32px; color:var(--text2); }}
  .empty-icon {{ font-size:2rem; display:block; margin-bottom:8px; }}

  .footer {{ text-align:center; color:var(--text2); font-size:.78rem; margin-top:32px; padding:20px;
    border-top:1px solid var(--border); }}

  @keyframes fadeUp {{ from {{ opacity:0; transform:translateY(20px); }} to {{ opacity:1; transform:translateY(0); }} }}
  .kpi, .panel {{ animation: fadeUp .5s ease both; }}
  .kpi:nth-child(2) {{ animation-delay:.05s; }}
  .kpi:nth-child(3) {{ animation-delay:.1s; }}
  .kpi:nth-child(4) {{ animation-delay:.15s; }}
  .kpi:nth-child(5) {{ animation-delay:.2s; }}
  .panel:nth-of-type(1) {{ animation-delay:.25s; }}
  .panel:nth-of-type(2) {{ animation-delay:.3s; }}
  .panel:nth-of-type(3) {{ animation-delay:.35s; }}
</style>
</head>
<body>

<div class="header">
  <h1><span class="icon">🚀</span>Pipeline Migration Report</h1>
  <div class="meta">
    <span>🏢 ADO: <strong>{enc_org} / {enc_proj}</strong></span>
    <span>🐱 GitHub: <strong>{enc_gh_org}</strong></span>
    <span>📅 {scan_date}</span>
  </div>
  <div class="badge">✅ Migration Rate: {pct_migrated}% ({success_count + partial_count} of {total_count} pipelines)</div>
</div>

<div class="container">

  <div class="kpi-row">
    <div class="kpi total">
      <div class="kpi-icon">📊</div>
      <div class="kpi-val">{total_count}</div>
      <div class="kpi-label">Total Pipelines</div>
    </div>
    <div class="kpi success">
      <div class="kpi-icon">✅</div>
      <div class="kpi-val">{success_count}</div>
      <div class="kpi-label">Successful</div>
    </div>
    <div class="kpi partial">
      <div class="kpi-icon">⚠️</div>
      <div class="kpi-val">{partial_count}</div>
      <div class="kpi-label">Partial</div>
    </div>
    <div class="kpi failed">
      <div class="kpi-icon">❌</div>
      <div class="kpi-val">{failed_count}</div>
      <div class="kpi-label">Failed / Error</div>
    </div>
    <div class="kpi nooutput">
      <div class="kpi-icon">📄</div>
      <div class="kpi-val">{no_output_count}</div>
      <div class="kpi-label">No Output</div>
    </div>
  </div>

  <div class="panel">
    <h2><span class="sec-icon">🌐</span>Migration Breakdown</h2>
    <div class="chart-grid">
      <div class="donut-wrap">
        <div class="donut"></div>
        <div class="donut-center">
          <div class="big">{pct_migrated}%</div>
          <div class="sub">Migrated</div>
        </div>
      </div>
      <div>
        <table class="breakdown">
{breakdown_rows}
        </table>
        <div class="stacked-bar">
          <div class="seg" style="width:{pct_success}%;background:var(--green)"></div>
          <div class="seg" style="width:{pct_partial}%;background:var(--yellow)"></div>
          <div class="seg" style="width:{pct_failed}%;background:var(--red)"></div>
          <div class="seg" style="width:{pct_no_output}%;background:var(--gray)"></div>
        </div>
      </div>
    </div>
  </div>

  <div class="panel">
    <h2><span class="sec-icon">🛠️</span>Pipeline Details</h2>
    <table>
      <thead><tr><th>ID</th><th>Pipeline</th><th>Target Repo</th><th>Mode</th><th>Status</th></tr></thead>
      <tbody>
{pipeline_table_rows}
      </tbody>
    </table>
  </div>

  <div class="panel">
    <h2><span class="sec-icon">📄</span>Generated Workflow Files</h2>
{workflow_section}
  </div>

  <div class="panel">
    <h2><span class="sec-icon">✍️</span>Post-Migration Checklist</h2>
    <label class="checklist-item"><input type="checkbox"/><span>Review generated GitHub Actions YAML for correctness</span></label>
    <label class="checklist-item"><input type="checkbox"/><span>Create GitHub Actions secrets: Settings &gt; Secrets &gt; Actions</span></label>
    <label class="checklist-item"><input type="checkbox"/><span>Configure environments with protection rules (replaces ADO gates)</span></label>
    <label class="checklist-item"><input type="checkbox"/><span>Set up self-hosted runners if needed</span></label>
    <label class="checklist-item"><input type="checkbox"/><span>Configure OIDC for Azure deployments (replaces service connections)</span></label>
    <label class="checklist-item"><input type="checkbox"/><span>Test trigger each workflow in GitHub Actions</span></label>
    <label class="checklist-item"><input type="checkbox"/><span>Disable original ADO pipelines after verification</span></label>
    <label class="checklist-item"><input type="checkbox"/><span>Update branch policies and PR triggers</span></label>
  </div>

  <div class="footer">
    Generated by <strong>ADO-to-GitHub Migration Accelerator</strong> &mdash; Pipeline Migration Module &bull; {scan_date}
  </div>
</div>

</body>
</html>
"""

    html_out = os.path.join(dashboard_dir, "index.html")
    try:
        with open(html_out, 'w', encoding='utf-8') as f:
            f.write(html_content)
        print(f"Generated HTML migration dashboard report at: {html_out}")
    except Exception as e:
        print(f"Error generating HTML report: {e}")

def html_escape(text):
    return text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;').replace("'", '&#x27;')

if __name__ == "__main__":
    main()
