# Artifact Migration Guide

This guide explains how to migrate build binaries and package feeds from Azure DevOps to GitHub.

## 1. Build Artifacts Migration
**Script**: `migrate-artifacts.ps1`  
**Goal**: Move files produced by pipeline builds into **GitHub Releases**.

*   **Process**: Downloads artifacts from ADO Build IDs $\rightarrow$ Uploads them as assets to a GitHub Release tag.
*   **Tag Format**: `{PipelineName}-build-{BuildID}-{Status}`
*   **Status Label**: You can use the `Version` parameter to label builds as `stable`, `working`, or `backup`.

## 2. NuGet Feed Migration
**Script**: `migrate-nuget-feed.ps1`  
**Goal**: Move NuGet packages from Azure Artifacts to **GitHub Packages**.

*   **Process**: Scans your ADO Feed $\rightarrow$ Downloads all versions of all packages (`.nupkg`) $\rightarrow$ Pushes them to the GitHub NuGet registry.
*   **Registry URL**: `https://nuget.pkg.github.com/{OrgName}/index.json`

## 3. Configuration (Variable Group)
Ensure your Azure DevOps Variable Group (`artifact-migration`) has these keys:
*   **ADO_ORG / ADO_PROJECT**: Source location.
*   **ADO_PAT**: Access to ADO builds/packaging.
*   **GH_ORG / GH_PAT**: Target GitHub location and permission to create Releases/Packages.
*   **ADO_FEED**: (For NuGet) The name of the source feed.
