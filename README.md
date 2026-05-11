# API Reference - Migration Accelerator

This document lists the external APIs consumed by the Migration Accelerator scripts for Azure DevOps to GitHub transitions.

## Azure DevOps APIs
All Azure DevOps API calls default to version **7.1** unless otherwise specified.

| Category | Endpoint Path | Method | Purpose |
| :--- | :--- | :--- | :--- |
| **Projects** | `_apis/projects` | GET | Lists all projects in the ADO organization. |
| **Git** | `_apis/git/repositories` | GET | Lists repositories within a specific project. |
| **Git** | `_apis/git/repositories/{id}` | GET | Retrieves metadata for a specific repository. |
| **Git** | `_apis/git/repositories/{id}/refs` | GET | Fetches branch and tag references (e.g., filter=heads). |
| **Git** | `_apis/git/repositories/{id}/pullrequests` | GET | Retrieves PR status and counts for migration validation. |
| **Build** | `_apis/build/definitions` | GET | Discovers CI/CD build definitions (YAML and Classic). |
| **Release** | `_apis/release/definitions` | GET | Discovers Classic Release definitions (Note: Uses `vsrm.dev.azure.com`). |
| **Work Items** | `_apis/wit/wiql` | POST | Executes WIQL queries to inventory work items. |
| **Teams** | `_apis/projects/{id}/teams` | GET | Lists teams associated with a project. |
| **Teams** | `_apis/projects/{id}/teams/{id}/members` | GET | Counts members within a specific team. |
| **Task** | `_apis/distributedtask/variablegroups` | GET | Inventories variable groups for migration planning. |
| **Task** | `_apis/distributedtask/environments` | GET | Inventories pipeline environments. |
| **Service Conn** | `_apis/serviceendpoint/endpoints` | GET | Lists service connections/endpoints. |

---

## GitHub APIs
GitHub calls use the standard **REST API v3** (latest).

| Category | Endpoint Path | Method | Purpose |
| :--- | :--- | :--- | :--- |
| **Organization** | `/orgs/{org}` | GET | Validates organization access and metadata. |
| **Repositories** | `/orgs/{org}/repos` | GET | Lists repositories existing in the target organization. |
| **Repositories** | `/repos/{owner}/{repo}` | GET/PATCH | Manages repository settings, visibility, and descriptions. |
| **Branches** | `/repos/{owner}/{repo}/branches` | GET | Lists branches in the target repository. |
| **Protection** | `/repos/{owner}/{repo}/branches/{branch}/protection` | GET/PUT | Gets or sets branch protection rules (e.g., required reviewers). |
| **Security** | `/repos/{owner}/{repo}/vulnerability-alerts` | GET/PUT | Enables Dependabot vulnerability alerts. |
| **Security** | `/repos/{owner}/{repo}/code-scanning/default-setup` | PATCH | Configures default setup for GitHub Code Scanning. |
| **Teams** | `/orgs/{org}/teams/{team_slug}` | GET | Validates team existence for mapping. |
| **Languages** | `/repos/{owner}/{repo}/languages` | GET | Detects repository languages for security setup optimization. |
| **User** | `/user` | GET | Used for initial token validation and scope checking. |
| **Search** | `/search/issues` | GET | Searches for migrated pull requests to verify integrity. |
| **Enterprise** | `/enterprises/{enterprise}` | GET | Validates enterprise-level settings if applicable. |

---

## Authentication Requirements

### Azure DevOps
- **Mechanism**: Basic Authentication (using Personal Access Token).
- **Required Scopes**: 
  - `Code (Read & Status)`
  - `Build (Read)`
  - `Release (Read)`
  - `Work Items (Read)`
  - `Project and Team (Read)`

### GitHub
- **Mechanism**: Bearer Token (using Personal Access Token).
- **Required Scopes**: 
  - `repo` (Full control for migration)
  - `admin:org` (Read for team/org validation)
  - `workflow` (For pipeline migration)
