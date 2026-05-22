# Documentation & Git Repository Strategy

## Objective
Establish a two-repo Git strategy — code and documentation separated — to ensure version-controlled, searchable, and governed project knowledge.

---

## Why Separate Repos
- Fabric Git Integration only syncs workspace items — docs would appear as noise  
- Code PRs stay clean — no documentation commits mixed in  
- Wider contributor group for docs (PBI dev, admin, manager, client)  
- Docs repo publishes as ADO Wiki — works best with .md-only repos  

---

## Documentation Repository
- **Repo:** Byline-Data-Docs  
- **Published as:** Azure DevOps Wiki (auto-rendered)  
- **Contains:** `.md` files only — no code, no PBIX, no data  
- **Rule:** Every project decision, runbook, and guide lives here  

---

## Docs Repository Structure

### architecture/
- system-overview.md  
- workspace-structure.md  

### governance/
- access-control.md  
- naming-conventions.md  
- rls-rbac-guide.md  

### migration/
- migration-log.md  
- validation-checklist.md  

### runbooks/
- git-integration-setup.md  
- gateway-setup.md  

### decisions/
- ADR-001-two-repo-strategy.md  
- ADR-002-dev-git-sync-only.md  

### handover/
- onboarding.md  
- client-handover-checklist.md  

---

## Contribution Workflow

**Developer**
- Edit in Fabric workspace  
- Commit changes  
- Create PR: `dev → main`

**Documenter**
- Create branch: `docs/<topic>`  
- Update `.md` file  
- Raise PR  
- Merge → Wiki auto-updates  

**Reviewer**
- Minimum 1 approver required before merge  

---

## Notes
- Keep documentation **simple, readable, and structured**
- Avoid adding code artifacts in docs repo
- Use Markdown only for consistency
``