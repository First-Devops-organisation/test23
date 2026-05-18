# Enterprise Variable & Secrets Migration

This folder contains the enterprise-grade architecture for migrating Azure DevOps (ADO) Variable Groups to GitHub Secrets and Variables. 

Unlike a simple "lift-and-shift" script, this approach maps ADO's flat Variable Groups into GitHub's highly scoped architecture (Organizations, Repositories, and Environments).

## Architecture & Workflow

The migration is split into three distinct phases to ensure security, accuracy, and proper permissions mapping:

### 📁 `01-discover`
**Goal:** Map out current usage.
- Run `discover-variable-usage.ps1` locally.
- This queries the ADO REST API to find all Variable Groups, checks their Pipeline Permissions, and identifies exactly which Repository uses which Variable Group.
- Outputs a CSV report.

### 📁 `config`
**Goal:** Define the destination.
- You take the CSV from `01-discover` and use it to fill out `variable-mappings.json`.
- This JSON file acts as the **Single Source of Truth** for the migration. It defines whether an ADO group becomes a GitHub Organization variable, a Repository variable, or an Environment variable.

### 📁 `03-migrate`
**Goal:** Execute the migration.
- `pipeline-migrate-variables.yml`: An ADO Pipeline that reads `variable-mappings.json`.
- It dynamically loops through the mapping and uses the GitHub CLI to push variables to their exact, correct scope in GitHub.
- **Note on Secrets:** Due to ADO REST API limitations, secrets cannot be extracted via API. The pipeline handles non-secret variables automatically. Secrets require special handling (either manual rotation or dynamic pipeline generation).

## Getting Started

1. Go to the `01-discover` folder and run the discovery script to generate your CSV mapping report.
2. Open the `config` folder and edit the JSON template based on your report.
3. Run the pipeline in `03-migrate`!
