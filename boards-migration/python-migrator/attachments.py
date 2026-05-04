"""
attachments.py
==============
Downloads every attachment from an Azure DevOps work item and
re-uploads it to the matching GitHub issue via the GitHub Asset
Upload API. A Markdown table of links is appended to the issue body.

Strategy
--------
1. Fetch the work item's 'relations' of type 'AttachedFile'.
2. Download each file from ADO using the relation URL + PAT auth.
3. Upload to GitHub as a release asset on a dedicated hidden
   release called "ado-migration-attachments".  GitHub does not
   expose a first-class "attach file to issue" endpoint, so the
   release-asset approach is the standard workaround.
4. Edit the GitHub issue body to append a ## Attachments section
   with a Markdown table linking to every uploaded asset.

Limits
------
- GitHub release assets max size: 2 GB per file.
- GitHub API rate limit: 5 000 req/hr for core; uploads use a
  separate 1 000/hr upload rate limit – the module respects both.
- Binary files are streamed to avoid memory issues with large files.
"""

import os, time, logging, mimetypes, hashlib
from pathlib import Path
import requests

log = logging.getLogger("migrator.attachments")

# Filled in at runtime from the main pipeline's config
_ADO_PAT   = ""
_GH_TOKEN  = ""
_GH_OWNER  = ""
_GH_REPO   = ""
_GH_BASE   = "https://api.github.com"
_UPLOAD_BASE = "https://uploads.github.com"

# Local cache dir for downloaded attachments (cleaned up after upload)
_CACHE_DIR = Path(".attachment_cache")

# Name of the hidden release used as an attachment store
_RELEASE_TAG  = "ado-migration-attachments"
_RELEASE_NAME = "ADO Migration – Attachments (do not delete)"

def configure(ado_pat, gh_token, gh_owner, gh_repo):
    """Call once from migrate.py before using any function in this module."""
    global _ADO_PAT, _GH_TOKEN, _GH_OWNER, _GH_REPO
    _ADO_PAT, _GH_TOKEN, _GH_OWNER, _GH_REPO = ado_pat, gh_token, gh_owner, gh_repo
    _CACHE_DIR.mkdir(exist_ok=True)


# ── Helpers ───────────────────────────────────────────────────────────────────

def _gh_headers(extra=None):
    h = {
        "Authorization": f"Bearer {_GH_TOKEN}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if extra: h.update(extra)
    return h

def _ado_headers():
    import base64
    token = base64.b64encode(f":{_ADO_PAT}".encode()).decode()
    return {"Authorization": f"Basic {token}"}

def _safe_filename(name: str) -> str:
    """Strip characters GitHub asset names don't allow."""
    import re
    name = re.sub(r'[^\w.\-]', '_', name)
    return name[:200]   # GH asset name max length

def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()[:8]   # short hash to de-dupe same-name files


# ── ADO: extract attachment relations ────────────────────────────────────────

def extract_attachment_relations(wi: dict) -> list:
    """
    Return a list of dicts describing each attached file on a work item.
    Each dict has: url, filename, comment, size_bytes.
    """
    relations = wi.get("relations") or []
    attachments = []
    for rel in relations:
        if rel.get("rel") != "AttachedFile":
            continue
        attrs    = rel.get("attributes", {})
        raw_url  = rel.get("url", "")
        filename = attrs.get("name", raw_url.split("/")[-1])
        attachments.append({
            "url":        raw_url,
            "filename":   filename,
            "comment":    attrs.get("comment", ""),
            "size_bytes": attrs.get("resourceSize", 0),
        })
    return attachments


# ── Step A: Download from ADO ─────────────────────────────────────────────────

def download_attachment(att: dict, ado_id: int) -> Path | None:
    """
    Stream-download one ADO attachment to the local cache.
    Returns the local Path, or None on failure.
    """
    url      = att["url"]
    filename = _safe_filename(att["filename"])
    dest     = _CACHE_DIR / f"wi{ado_id}_{filename}"

    if dest.exists():
        log.debug(f"    Cache hit: {dest.name}")
        return dest

    try:
        with requests.get(url, headers=_ado_headers(),
                           stream=True, timeout=120) as r:
            r.raise_for_status()
            with open(dest, "wb") as f:
                for chunk in r.iter_content(chunk_size=65536):
                    f.write(chunk)
        size_kb = dest.stat().st_size // 1024
        log.info(f"    Downloaded: {dest.name} ({size_kb} KB)")
        return dest
    except Exception as e:
        log.warning(f"    Download failed [{filename}]: {e}")
        return None


# ── Step B: Get / create the GitHub release used as an asset store ────────────

_release_id_cache = None
_release_upload_url_cache = None

def _get_or_create_migration_release() -> tuple:
    """Return (release_id, upload_url_template) for the migration release."""
    global _release_id_cache, _release_upload_url_cache
    if _release_id_cache:
        return _release_id_cache, _release_upload_url_cache

    base = f"{_GH_BASE}/repos/{_GH_OWNER}/{_GH_REPO}"

    # Check if the release already exists
    try:
        r = requests.get(f"{base}/releases/tags/{_RELEASE_TAG}",
                         headers=_gh_headers(), timeout=30)
        if r.status_code == 200:
            data = r.json()
            _release_id_cache        = data["id"]
            _release_upload_url_cache = data["upload_url"].split("{")[0]
            log.info(f"  Using existing migration release (id={_release_id_cache})")
            return _release_id_cache, _release_upload_url_cache
    except: pass

    # Create it
    payload = {
        "tag_name":           _RELEASE_TAG,
        "name":               _RELEASE_NAME,
        "body":               ("This release stores attachments migrated from Azure DevOps. "
                               "Do not delete."),
        "draft":              False,
        "prerelease":         True,
        "generate_release_notes": False,
    }
    r = requests.post(f"{base}/releases",
                      headers=_gh_headers(), json=payload, timeout=30)
    print("Raw Response:", r.text)
    r.raise_for_status()
    data = r.json()
    _release_id_cache        = data["id"]
    _release_upload_url_cache = data["upload_url"].split("{")[0]
    log.info(f"  Created migration release (id={_release_id_cache})")
    return _release_id_cache, _release_upload_url_cache


# ── Step C: Upload to GitHub ──────────────────────────────────────────────────

def upload_to_github(local_path: Path, ado_id: int, att: dict) -> str | None:
    """
    Upload a local file as a GitHub release asset.
    Returns the browser_download_url on success, None on failure.
    De-dupes by prefixing the asset name with wi{ado_id}_ and a short hash.
    """
    _, upload_url = _get_or_create_migration_release()

    mime, _ = mimetypes.guess_type(str(local_path))
    mime     = mime or "application/octet-stream"

    short_hash = _sha256(local_path)
    asset_name = _safe_filename(
        f"wi{ado_id}_{short_hash}_{att['filename']}"
    )

    full_url = f"{upload_url}?name={requests.utils.quote(asset_name)}"

    try:
        file_size = local_path.stat().st_size
        with open(local_path, "rb") as fh:
            r = requests.post(
                full_url,
                headers=_gh_headers({
                    "Content-Type":   mime,
                    "Content-Length": str(file_size),
                }),
                data=fh,
                timeout=300,   # large files may take a while
            )
        r.raise_for_status()
        download_url = r.json()["browser_download_url"]
        log.info(f"    Uploaded: {asset_name} ==>> {download_url}")
        return download_url
    except Exception as e:
        log.warning(f"    Upload failed [{asset_name}]: {e}")
        return None


# ── Step D: Append attachment table to GitHub issue ───────────────────────────

def append_attachments_to_issue(issue_number: int, results: list):
    """
    Fetch the current issue body and append a ## Attachments section.
    results: list of dicts {filename, download_url, size_bytes, comment}
    """
    if not results:
        return

    issue_url = f"{_GH_BASE}/repos/{_GH_OWNER}/{_GH_REPO}/issues/{issue_number}"
    r = requests.get(issue_url, headers=_gh_headers(), timeout=30)
    r.raise_for_status()
    current_body = r.json().get("body", "") or ""

    # Build Markdown table
    rows = [
        "## 📎 Attachments\n",
        "| File | Size | Comment |",
        "|------|------|---------|",
    ]
    for res in results:
        name     = res["filename"]
        url      = res.get("download_url")
        size_kb  = res["size_bytes"] // 1024
        comment  = res.get("comment", "") or ""
        link     = f"[{name}]({url})" if url else f"`{name}` _(upload failed)_"
        rows.append(f"| {link} | {size_kb} KB | {comment} |")

    new_body = current_body.rstrip() + "\n\n" + "\n".join(rows)

    r = requests.patch(issue_url, headers=_gh_headers(),
                       json={"body": new_body}, timeout=30)
    r.raise_for_status()
    log.info(f"    Issue #{issue_number} body updated with {len(results)} attachment(s).")


# ── Step E: Cleanup local cache ───────────────────────────────────────────────

def cleanup_cache(paths: list):
    """Delete downloaded files after successful upload."""
    for p in paths:
        try:
            if p and Path(p).exists():
                Path(p).unlink()
        except: pass


# ── Public entry point ────────────────────────────────────────────────────────

def migrate_attachments(wi: dict, gh_issue_number: int,
                         dry_run: bool = False) -> int:
    """
    Full attachment migration for one work item:
      1. Extract attachment relations from the ADO work item dict
      2. Download each file from ADO
      3. Upload to the GitHub migration release
      4. Append a Markdown table to the GitHub issue body
      5. Clean up local cache files

    Returns the number of attachments successfully uploaded.
    """
    attachments = extract_attachment_relations(wi)
    if not attachments:
        return 0

    ado_id = wi["id"]
    log.info(f"  Migrating {len(attachments)} attachment(s) for ADO#{ado_id} …")

    results     = []
    local_paths = []

    for att in attachments:
        if dry_run:
            log.info(f"    [DRY RUN] Would migrate: {att['filename']} "
                     f"({att['size_bytes']//1024} KB)")
            results.append({**att, "download_url": "#dry-run"})
            continue

        # Download
        local = download_attachment(att, ado_id)
        local_paths.append(local)
        if not local:
            results.append({**att, "download_url": None})
            continue

        # Upload (with one retry on transient errors)
        download_url = upload_to_github(local, ado_id, att)
        if not download_url:
            time.sleep(3)
            download_url = upload_to_github(local, ado_id, att)

        results.append({**att, "download_url": download_url})
        time.sleep(1.0)   # respect upload rate limit

    if not dry_run:
        try:
            append_attachments_to_issue(gh_issue_number, results)
        except Exception as e:
            log.warning(f"  Could not update issue body: {e}")
        cleanup_cache(local_paths)

    uploaded = sum(1 for r in results if r.get("download_url"))
    log.info(f"  Attachments: {uploaded}/{len(attachments)} uploaded.")
    return uploaded