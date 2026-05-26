#!/usr/bin/env python3
import os
import sys
import re
import json
import urllib.parse
from datetime import datetime

def main():
    if len(sys.argv) < 5:
        print("Usage: generate_audit_dashboard.py <output_dir> <ado_org> <ado_project> <name_to_id_json_path>")
        sys.exit(1)

    output_dir = sys.argv[1]
    ado_org = sys.argv[2]
    ado_project = sys.argv[3]
    name_to_id_json_path = sys.argv[4]

    # Load name to id mapping
    name_to_id = {}
    if os.path.exists(name_to_id_json_path):
        try:
            with open(name_to_id_json_path, 'r', encoding='utf-8') as f:
                name_to_id = json.load(f)
        except Exception as e:
            print(f"Warning: Could not load name-to-id mapping: {e}")

    audit_summary_file = os.path.join(output_dir, "audit_summary.md")
    manual_tasks_file = os.path.join(output_dir, "manual-tasks-summary.md")
    dashboard_dir = os.path.join(output_dir, "dashboard")
    os.makedirs(dashboard_dir, exist_ok=True)

    metrics = {"Successful": 0, "Partial": 0, "Unsupported": 0, "Failed": 0, "Total": 0}

    audit_content = ""
    if os.path.exists(audit_summary_file):
        try:
            with open(audit_summary_file, 'r', encoding='utf-8') as f:
                audit_content = f.read()
            
            s = re.search(r"Successful:\s*\*{0,2}(\d+)\*{0,2}", audit_content, re.IGNORECASE)
            p = re.search(r"Partially successful:\s*\*{0,2}(\d+)\*{0,2}", audit_content, re.IGNORECASE)
            u = re.search(r"Unsupported:\s*\*{0,2}(\d+)\*{0,2}", audit_content, re.IGNORECASE)
            f_match = re.search(r"Failed:\s*\*{0,2}(\d+)\*{0,2}", audit_content, re.IGNORECASE)

            if s: metrics["Successful"] = int(s.group(1))
            if p: metrics["Partial"] = int(p.group(1))
            if u: metrics["Unsupported"] = int(u.group(1))
            if f_match: metrics["Failed"] = int(f_match.group(1))

            metrics["Total"] = metrics["Successful"] + metrics["Partial"] + metrics["Unsupported"] + metrics["Failed"]
        except Exception as e:
            print(f"Error parsing audit_summary.md: {e}")
    else:
        print(f"Warning: audit_summary.md not found at {audit_summary_file}")

    # Build manual tasks HTML
    manual_section = ""
    if os.path.exists(manual_tasks_file):
        try:
            with open(manual_tasks_file, 'r', encoding='utf-8') as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    if line.startswith("#"):
                        header_text = line.lstrip("#").strip()
                        manual_section += f"<h4>{header_text}</h4>\n"
                    elif line.startswith("- [ ]"):
                        task_text = line[5:].strip()
                        escaped = html_escape(task_text)
                        manual_section += f"<label class='checklist-item'><input type='checkbox'/><span>{escaped}</span></label>\n"
                    elif line.startswith("-"):
                        note_text = line[1:].strip()
                        escaped = html_escape(note_text)
                        manual_section += f"<div class='task-note'>&#8226; {escaped}</div>\n"
        except Exception as e:
            print(f"Error parsing manual tasks: {e}")
    
    if not manual_section:
        manual_section = "<p class='empty-state'><span class='empty-icon'>&#9989;</span>No manual tasks file found.</p>"

    # Find converted YAML files
    pipeline_rows = ""
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
                pipeline_rows += f"    <tr><td>{directory}</td><td>{name}</td><td class='num'>{size_str}</td><td class='center'>&#9989; Converted</td></tr>\n"

    converted_section = ""
    if pipeline_rows:
        converted_section = f"""
      <table>
        <thead><tr><th>Directory</th><th>Pipeline</th><th>Size</th><th>Status</th></tr></thead>
        <tbody>
{pipeline_rows}
        </tbody>
      </table>
"""
    else:
        converted_section = "      <p class='empty-state'><span class='empty-icon'>&#128194;</span>No converted YAML files found in audit output.</p>"

    # Math
    total = max(metrics["Total"], 1)
    pct_success = round((metrics["Successful"] / total) * 100)
    pct_partial = round((metrics["Partial"] / total) * 100)
    pct_unsupported = round((metrics["Unsupported"] / total) * 100)
    pct_failed = round((metrics["Failed"] / total) * 100)
    pct_ready = pct_success + pct_partial

    scan_date = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")
    proj_label = ado_project if ado_project else "All Projects"

    enc_org = html_escape(ado_org)
    enc_proj = html_escape(proj_label)

    # Donut Segments
    donut_seg1 = pct_success
    donut_seg2 = donut_seg1 + pct_partial
    donut_seg3 = donut_seg2 + pct_unsupported

    breakdown_rows = f"""
        <tr><td><span class='dot' style='background:#10b981'></span> Fully Convertible</td>
            <td class='num'>{metrics["Successful"]}</td>
            <td><div class='mini-bar'><div class='mini-fill' style='width:{pct_success}%;background:#10b981'></div></div></td>
            <td class='num'>{pct_success}%</td></tr>
        <tr><td><span class='dot' style='background:#f59e0b'></span> Partially Convertible</td>
            <td class='num'>{metrics["Partial"]}</td>
            <td><div class='mini-bar'><div class='mini-fill' style='width:{pct_partial}%;background:#f59e0b'></div></div></td>
            <td class='num'>{pct_partial}%</td></tr>
        <tr><td><span class='dot' style='background:#ef4444'></span> Unsupported</td>
            <td class='num'>{metrics["Unsupported"]}</td>
            <td><div class='mini-bar'><div class='mini-fill' style='width:{pct_unsupported}%;background:#ef4444'></div></div></td>
            <td class='num'>{pct_unsupported}%</td></tr>
        <tr><td><span class='dot' style='background:#6b7280'></span> Failed</td>
            <td class='num'>{metrics["Failed"]}</td>
            <td><div class='mini-bar'><div class='mini-fill' style='width:{pct_failed}%;background:#6b7280'></div></div></td>
            <td class='num'>{pct_failed}%</td></tr>
"""

    raw_section = ""
    if audit_content:
        escaped_raw = html_escape(audit_content)
        raw_section = f"<pre class='raw-block'>{escaped_raw}</pre>"
    else:
        raw_section = "<p class='empty-state'>audit_summary.md not available.</p>"

    html_content = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Pipeline Audit Report &mdash; {enc_org}</title>
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

  /* --- Header banner --- */
  .header {{ background: linear-gradient(135deg, #0ea5e9 0%, #8b5cf6 50%, #ec4899 100%);
    padding: 40px 48px 32px; position: relative; overflow: hidden; }}
  .header::before {{ content:''; position:absolute; top:-50%; right:-20%; width:600px; height:600px;
    background: radial-gradient(circle, rgba(255,255,255,.08) 0%, transparent 70%); }}
  .header::after {{ content:''; position:absolute; bottom:-40%; left:-10%; width:500px; height:500px;
    background: radial-gradient(circle, rgba(255,255,255,.05) 0%, transparent 70%); }}
  .header h1 {{ font-size:2.2rem; font-weight:800; letter-spacing:-.02em; position:relative; z-index:1; }}
  .header h1 .icon {{ font-size:1.6rem; margin-right:10px; }}
  .header .meta {{ margin-top:8px; font-size:.9rem; opacity:.85; position:relative; z-index:1; }}
  .header .meta span {{ margin-right:24px; }}
  .header .badge {{ display:inline-block; background:rgba(255,255,255,.2); backdrop-filter:blur(8px);
    padding:4px 14px; border-radius:20px; font-size:.8rem; font-weight:600; margin-top:12px; position:relative; z-index:1; }}

  .container {{ max-width:1440px; margin:0 auto; padding: 0 32px 40px; }}

  /* --- KPI Cards --- */
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
  .kpi.unsupported .kpi-val {{ color:var(--red); }}
  .kpi.failed .kpi-val {{ color:var(--gray); }}

  /* --- Sections --- */
  .panel {{ background:var(--surface); border:1px solid var(--border); border-radius:var(--radius);
    padding:28px; margin-bottom:20px; }}
  .panel h2 {{ font-size:1.15rem; font-weight:700; margin-bottom:20px; display:flex; align-items:center; gap:10px; }}
  .panel h2 .sec-icon {{ font-size:1.2rem; }}

  /* --- Donut + Breakdown side-by-side --- */
  .chart-grid {{ display:grid; grid-template-columns: 280px 1fr; gap:32px; align-items:center; }}
  @media (max-width:768px) {{ .chart-grid {{ grid-template-columns:1fr; }} }}
  .donut-wrap {{ position:relative; width:220px; height:220px; margin:0 auto; }}
  .donut {{ width:220px; height:220px; border-radius:50%;
    background: conic-gradient(
      var(--green) 0% {donut_seg1}%,
      var(--yellow) {donut_seg1}% {donut_seg2}%,
      var(--red) {donut_seg2}% {donut_seg3}%,
      var(--gray) {donut_seg3}% 100%
    );
    -webkit-mask: radial-gradient(circle, transparent 60%, black 61%);
            mask: radial-gradient(circle, transparent 60%, black 61%);
  }}
  .donut-center {{ position:absolute; top:50%; left:50%; transform:translate(-50%,-50%); text-align:center; }}
  .donut-center .big {{ font-size:2.6rem; font-weight:800; color:var(--accent); }}
  .donut-center .sub {{ font-size:.8rem; color:var(--text2); }}

  /* Breakdown table */
  .breakdown {{ width:100%; border-collapse:collapse; }}
  .breakdown td {{ padding:12px 10px; border-bottom:1px solid var(--border); font-size:.9rem; }}
  .breakdown tr:last-child td {{ border-bottom:none; }}
  .dot {{ display:inline-block; width:10px; height:10px; border-radius:50%; margin-right:8px; vertical-align:middle; }}
  .num {{ text-align:right; font-variant-numeric:tabular-nums; font-weight:600; }}
  .mini-bar {{ width:100%; height:8px; background:var(--surface2); border-radius:4px; overflow:hidden; }}
  .mini-fill {{ height:100%; border-radius:4px; transition: width .8s ease; }}

  /* --- Stacked bar --- */
  .stacked-bar {{ display:flex; height:14px; border-radius:7px; overflow:hidden; margin-top:16px; }}
  .stacked-bar .seg {{ transition: width .8s ease; }}

  /* --- Table --- */
  table:not(.breakdown) {{ width:100%; border-collapse:collapse; }}
  table:not(.breakdown) th {{ background: linear-gradient(135deg,#0ea5e9,#8b5cf6); color:#fff;
    padding:14px 12px; text-align:left; font-size:.8rem; text-transform:uppercase; letter-spacing:.06em; font-weight:600; }}
  table:not(.breakdown) td {{ padding:12px; border-bottom:1px solid var(--border); font-size:.85rem; }}
  table:not(.breakdown) tr:hover {{ background:rgba(56,189,248,.06); }}
  .center {{ text-align:center; }}
  .badge-ok {{ background:rgba(16,185,129,.15); color:var(--green); padding:3px 12px; border-radius:12px; font-size:.78rem; font-weight:600; }}

  /* --- Checklist --- */
  .checklist-item {{ display:flex; align-items:flex-start; gap:10px; padding:8px 0; font-size:.88rem; cursor:pointer; }}
  .checklist-item input[type=checkbox] {{ accent-color:var(--accent); margin-top:3px; width:16px; height:16px; }}
  .checklist-item span {{ flex:1; }}
  h4 {{ color:var(--accent); font-size:.95rem; margin:18px 0 6px; font-weight:600; }}
  h4:first-child {{ margin-top:0; }}
  .task-note {{ padding:4px 0 4px 26px; font-size:.85rem; color:var(--text2); }}

  /* --- Raw block --- */
  .raw-block {{ background:var(--bg); border:1px solid var(--border); border-radius:12px; padding:20px;
    font-family:'Cascadia Code','Fira Code',Consolas,monospace; font-size:.82rem; color:var(--text2);
    white-space:pre-wrap; max-height:400px; overflow-y:auto; line-height:1.6; }}

  /* Collapsible */
  details {{ margin-bottom:4px; }}
  details summary {{ cursor:pointer; font-weight:600; font-size:.95rem; padding:8px 0; color:var(--text);
    list-style:none; display:flex; align-items:center; gap:8px; }}
  details summary::before {{ content:'▶'; font-size:.7rem; transition:transform .2s; display:inline-block; }}
  details[open] summary::before {{ transform:rotate(90deg); }}
  details > div {{ padding: 8px 0 0 20px; }}

  .empty-state {{ text-align:center; padding:32px; color:var(--text2); }}
  .empty-icon {{ font-size:2rem; display:block; margin-bottom:8px; }}

  .footer {{ text-align:center; color:var(--text2); font-size:.78rem; margin-top:32px; padding:20px;
    border-top:1px solid var(--border); }}
  .footer a {{ color:var(--accent); text-decoration:none; }}

  /* Animate on load */
  @keyframes fadeUp {{ from {{ opacity:0; transform:translateY(20px); }} to {{ opacity:1; transform:translateY(0); }} }}
  .kpi, .panel {{ animation: fadeUp .5s ease both; }}
  .kpi:nth-child(2) {{ animation-delay:.05s; }}
  .kpi:nth-child(3) {{ animation-delay:.1s; }}
  .kpi:nth-child(4) {{ animation-delay:.15s; }}
  .kpi:nth-child(5) {{ animation-delay:.2s; }}
  .panel:nth-of-type(1) {{ animation-delay:.25s; }}
  .panel:nth-of-type(2) {{ animation-delay:.3s; }}
  .panel:nth-of-type(3) {{ animation-delay:.35s; }}
  .panel:nth-of-type(4) {{ animation-delay:.4s; }}
</style>
</head>
<body>

<!-- ===== HEADER ===== -->
<div class="header">
  <h1><span class="icon">⚡</span>ADO Pipeline Audit Report</h1>
  <div class="meta">
    <span>🏢 <strong>{enc_org}</strong></span>
    <span>📁 <strong>{enc_proj}</strong></span>
    <span>📅 {scan_date}</span>
  </div>
  <div class="badge">🚀 Migration Readiness: {pct_ready}% Convertible</div>
</div>

<div class="container">

  <!-- ===== KPI CARDS ===== -->
  <div class="kpi-row">
    <div class="kpi total">
      <div class="kpi-icon">📊</div>
      <div class="kpi-val">{metrics["Total"]}</div>
      <div class="kpi-label">Total Pipelines</div>
    </div>
    <div class="kpi success">
      <div class="kpi-icon">✅</div>
      <div class="kpi-val">{metrics["Successful"]}</div>
      <div class="kpi-label">Fully Convertible</div>
    </div>
    <div class="kpi partial">
      <div class="kpi-icon">⚠️</div>
      <div class="kpi-val">{metrics["Partial"]}</div>
      <div class="kpi-label">Partially Convertible</div>
    </div>
    <div class="kpi unsupported">
      <div class="kpi-icon">❌</div>
      <div class="kpi-val">{metrics["Unsupported"]}</div>
      <div class="kpi-label">Unsupported</div>
    </div>
    <div class="kpi failed">
      <div class="kpi-icon">🚫</div>
      <div class="kpi-val">{metrics["Failed"]}</div>
      <div class="kpi-label">Failed</div>
    </div>
  </div>

  <!-- ===== READINESS CHART ===== -->
  <div class="panel">
    <h2><span class="sec-icon">🌐</span>Readiness Breakdown</h2>
    <div class="chart-grid">
      <div class="donut-wrap">
        <div class="donut"></div>
        <div class="donut-center">
          <div class="big">{pct_ready}%</div>
          <div class="sub">Ready</div>
        </div>
      </div>
      <div>
        <table class="breakdown">
{breakdown_rows}
        </table>
        <div class="stacked-bar">
          <div class="seg" style="width:{pct_success}%;background:var(--green)"></div>
          <div class="seg" style="width:{pct_partial}%;background:var(--yellow)"></div>
          <div class="seg" style="width:{pct_unsupported}%;background:var(--red)"></div>
          <div class="seg" style="width:{pct_failed}%;background:var(--gray)"></div>
        </div>
      </div>
    </div>
  </div>

  <!-- ===== CONVERTED PIPELINES ===== -->
  <div class="panel">
    <h2><span class="sec-icon">📄</span>Converted Pipeline Files</h2>
{converted_section}
  </div>

  <!-- ===== MANUAL TASKS ===== -->
  <div class="panel">
    <h2><span class="sec-icon">✍️</span>Manual Tasks Required Post-Migration</h2>
{manual_section}
  </div>

  <!-- ===== RAW AUDIT ===== -->
  <div class="panel">
    <h2><span class="sec-icon">📜</span>Raw Audit Summary</h2>
    <details>
      <summary>View full audit_summary.md output</summary>
      <div>{raw_section}</div>
    </details>
  </div>

  <div class="footer">
    Generated by <strong>ADO-to-GitHub Migration Accelerator</strong> &mdash; Pipeline Audit Module &bull; {scan_date}
  </div>
</div>

</body>
</html>
"""

    html_out = os.path.join(dashboard_dir, "index.html")
    try:
        with open(html_out, 'w', encoding='utf-8') as f:
            f.write(html_content)
        print(f"Generated HTML report at: {html_out}")
    except Exception as e:
        print(f"Error generating HTML report: {e}")

    # Generate pipeline-audit-summary.md
    summary_md = f"""## Pipeline Audit Results

| Metric | Count | % |
|---|---:|---:|
| **Total Pipelines** | **{metrics["Total"]}** | 100% |
| Fully Convertible | {metrics["Successful"]} | {pct_success}% |
| Partially Convertible | {metrics["Partial"]} | {pct_partial}% |
| Unsupported | {metrics["Unsupported"]} | {pct_unsupported}% |
| Failed | {metrics["Failed"]} | {pct_failed}% |

**Migration Readiness: {pct_ready}% convertible**

---
*Organization:* `{ado_org}` | *Project:* `{proj_label}` | *Scanned:* {scan_date}
"""
    summary_md_path = os.path.join(output_dir, "pipeline-audit-summary.md")
    try:
        with open(summary_md_path, 'w', encoding='utf-8') as f:
            f.write(summary_md)
        print(f"Generated summary MD at: {summary_md_path}")
    except Exception as e:
        print(f"Error generating summary MD: {e}")

def html_escape(text):
    return text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;').replace("'", '&#x27;')

if __name__ == "__main__":
    main()
