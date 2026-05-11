# API Reference - Migration Accelerator

This document provides a comprehensive list of all external APIs consumed by the Migration Accelerator toolset for Azure DevOps to GitHub migrations.

## Azure DevOps APIs (Version 7.1)
Azure DevOps calls are made to the REST API endpoints using Personal Access Tokens (PAT).

| Category | Endpoint Path | Method | Purpose |
| :--- | :--- | :--- | :--- |
| **Projects** | `_apis/projects` | GET | Lists all projects in the organization. |
| **Git** | `_apis/git/repositories` | GET | Enumerates repositories within a project. |
| **Git** | `_apis/git/repositories/{id}/refs` | GET | Fetches branch and tag references. |
| **Git** | `_apis/git/repositories/{id}/pullrequests` | GET | Retrieves PR status and counts for validation. |
| **Build** | `_apis/build/definitions` | GET | Retrieves CI build definitions (YAML & Classic). |
| **Release** | `_apis/release/definitions` | GET | Retrieves CD release definitions (Host: `vsrm.dev.azure.com`). |
| **Task Groups**| `_apis/distributedtask/taskgroups` | GET | Discovers reusable task blocks in classic pipelines. |
| **Variables** | `_apis/distributedtask/variablegroups`| GET | Inventories variable groups for mapping. |
| **Environments**| `_apis/distributedtask/environments` | GET | Lists YAML-based deployment environments. |
| **Endpoints** | `_apis/serviceendpoint/endpoints` | GET | Discovers service connections for audit. |
| **Work Items** | `_apis/wit/wiql` | POST | Executes WIQL queries for work item discovery. |

---

## GitHub APIs (REST v3)
GitHub calls are made via the `gh` CLI or directly through the REST API.

| Category | Endpoint Path | Method | Purpose |
| :--- | :--- | :--- | :--- |
| **Org** | `/orgs/{org}` | GET | Validates organization availability. |
| **Repos** | `/orgs/{org}/repos` | GET | Lists repositories in the target organization. |
| **Repos** | `/repos/{owner}/{repo}` | PATCH | Updates repository settings and visibility. |
| **Security** | `.../vulnerability-alerts` | PUT | Enables Dependabot vulnerability alerts. |
| **Security** | `.../code-scanning/default-setup` | PATCH | Configures CodeQL default scanning setup. |
| **Teams** | `/orgs/{org}/teams/{team_slug}` | GET | Validates team mappings. |
| **Protection** | `.../branches/{branch}/protection` | PUT | Configures branch protection rules. |
| **Languages** | `.../languages` | GET | Analyzes repo languages for security setup. |
| **Search** | `/search/issues` | GET | Verifies Pull Request migration status. |
| **User** | `/user` | GET | Checks PAT token scopes and validity. |

---

## Authentication & Scopes

### Azure DevOps (PAT)
*   `Code (Read)`
*   `Build (Read)`
*   `Release (Read)`
*   `Project and Team (Read)`
*   `Work Items (Read)`

### GitHub (PAT)
*   `repo` (full control)
*   `admin:org` (read/write)
*   `workflow`
