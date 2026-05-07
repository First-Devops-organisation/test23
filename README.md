# API Reference — `migrate-artifacts.ps1`

---

## Azure DevOps REST APIs

All ADO APIs use **`api-version=7.1`** and authenticate via **HTTP Basic Auth** (Base64-encoded PAT).

| # | API | Method | Endpoint | Purpose | Docs |
|---|-----|--------|----------|---------|------|
| 1 | **Build Definitions** | `GET` | `https://dev.azure.com/{org}/{project}/_apis/build/definitions?api-version=7.1` | Lists all pipeline definitions to find the target pipeline by name | [📄 Definitions - List](https://learn.microsoft.com/en-us/rest/api/azure/devops/build/definitions/list?view=azure-devops-rest-7.1) |
| 2 | **Builds - List** | `GET` | `https://dev.azure.com/{org}/{project}/_apis/build/builds?definitions={id}&$top={n}&api-version=7.1` | Fetches the N most recent builds for the pipeline | [📄 Builds - List](https://learn.microsoft.com/en-us/rest/api/azure/devops/build/builds/list?view=azure-devops-rest-7.1) |
| 3 | **Build Artifacts** | `GET` | `https://dev.azure.com/{org}/{project}/_apis/build/builds/{buildId}/artifacts?api-version=7.1` | Returns all artifact metadata (name + download URL) for a specific build | [📄 Artifacts - List](https://learn.microsoft.com/en-us/rest/api/azure/devops/build/artifacts/list?view=azure-devops-rest-7.1) |

> [!NOTE]
> The artifact ZIP files are downloaded directly using the `downloadUrl` returned by API #3 via `Invoke-WebRequest`, still authenticated with the same PAT header.

---

## GitHub CLI (`gh`) Commands

All GitHub operations use the **[GitHub CLI](https://cli.github.com/)** (`gh`), authenticated via `GH_TOKEN` / `GH_PAT` environment variables.

| # | Command | Purpose | Docs |
|---|---------|---------|------|
| 1 | `gh release view <tag> --repo <org/repo>` | Checks if a GitHub Release with the given tag already exists | [📄 gh release view](https://cli.github.com/manual/gh_release_view) |
| 2 | `gh release upload <tag> --repo <org/repo> --clobber <files>` | Uploads / overwrites artifact ZIPs into an **existing** release | [📄 gh release upload](https://cli.github.com/manual/gh_release_upload) |
| 3 | `gh release create <tag> --repo <org/repo> --title ... --notes ... -- <files>` | Creates a **new** GitHub Release and attaches artifact ZIPs | [📄 gh release create](https://cli.github.com/manual/gh_release_create) |

---

## Authentication Summary

| Platform | Method | Header / Env Var |
|----------|--------|-----------------|
| Azure DevOps | HTTP Basic Auth (PAT) | `Authorization: Basic <base64(:PAT)>` |
| GitHub CLI | Environment variable | `GH_TOKEN` (falls back from `GH_PAT`) |

