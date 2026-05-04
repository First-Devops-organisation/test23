Parameters & Variables
Parameters: Control migration mode (Single/Batch), repo names, batch name, audit/validation toggles, etc.
Variables: Store secrets and org/project/repo info.
Stages
1. Discover
Purpose: Analyze ADO repos, audit sizes, and scan for secrets.
Artifacts: Discovery reports, repo inventory, size audits, and secret scan results.
2. ReviewGate
Purpose: Manual review step. User checks discovery/scanning results and approves or rejects migration.
3A. MigrateSingle (Single Repo Mode)
Install tools: Installs GitHub CLI and ado2gh extension.
Prepare output folders.
Run migration: Executes migrate-single.ps1 for the selected repo.
Publish artifacts: Logs, audit data, dashboard HTML.
Show dashboard: Displays migration dashboard as a pipeline tab.
3B. MigrateBatch (Batch Mode)
Install tools: Installs GitHub CLI and ado2gh extension.
Prepare output folders.
Run migration: Executes migrate-batch.ps1 for all repos in the batch.
Publish artifacts: Batch logs, audit data, dashboards, and summary reports.
4. Validate
Download artifacts: Retrieves audit data, dashboards, and reports from migration stages.
Validate repos: Runs validate-migration.ps1 for single repo or all batch repos.
Publish validation reports: HTML, CSV, JSON, Markdown.
Show validation report: Displays validation HTML as a pipeline tab.
Show migration report: Displays migration dashboard as a pipeline tab.
Publish summary: Publishes a Markdown summary to the pipeline summary tab.
Summary:

The pipeline discovers and audits repos, waits for manual approval, migrates (single or batch), then validates and reports results.
Artifacts are published at each stage for traceability and review.
The process is parameterized for flexibility and can handle both single and batch migrations.

Urvashi
