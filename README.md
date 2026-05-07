📡 Migration API Reference
This document provides a concise list of all API endpoints and orchestrated tools used in the ADO-to-GitHub migration framework.

1. Azure DevOps REST APIs (v7.1)
Category	Endpoint	Purpose
Pipeline	_apis/build/definitions	Extracting build logic and YAML structures.
Release	_apis/release/definitions	Extracting Classic Release (VSRM) logic.
Inventory	_apis/git/repositories	Analyzing repository scale and inventory.
Validation	_apis/git/repositories/{id}/refs	Branch and Tag parity verification.
History	_apis/git/repositories/{id}/pullrequests	Verifying migrated PR counts.
2. GitHub REST APIs (v2022-11-28 / v3)
Category	Endpoint	Version	Purpose
Repo	/repos/{org}/{repo}	2022-11-28	Verifying target settings.
Security	/repos/{org}/{repo}/protection	2022-11-28	Enabling branch governance.
Identity	/orgs/{org}/mannequins	v3	Reclaiming user identities.
Advanced	/repos/{org}/{repo}/code-scanning	2022-11-28	Enabling GHAS security features.
Search	/search/issues	2022-11-28	Validating PR/Issue migration status.
3. Orchestrated Tools
Tool	Provider	Primary Function
Actions Importer	GitHub	Core pipeline-to-workflow conversion.
Git-Sizer	GitHub OSS	Feasibility and scale analysis.
gh ado2gh	GitHub	Identity and repo migration orchestration.