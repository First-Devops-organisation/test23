# Rollback Plan

## Overview
This document describes how to roll back a migration batch if critical issues are discovered after cutover to GitHub.

**Key principle**: Azure DevOps repos are kept **read-only** (not deleted) for the duration of the retention period, enabling rollback at any time.

---

## Decision Criteria for Rollback

Rollback should be considered if:
- [ ] Critical repos are missing or corrupted after GEI migration
- [ ] Git history is incomplete (commit count mismatch > 1%)
- [ ] Branch protection cannot be applied (blocking development)
- [ ] GitHub Actions workflows fail to trigger on critical pipelines
- [ ] SAML SSO integration prevents team access for >4 hours
- [ ] Regulatory/compliance blocker identified post-migration

Rollback should **NOT** be done for:
- Mannequin reclaim delays (cosmetic; does not block development)
- Individual pipeline conversion failures (fix forward)
- Label/milestone/project configuration issues (fix in place)

---

## Rollback Procedure by Component

### 1. Repository Rollback (Partial or Full)

**Scenario**: Migrated repo in GitHub is missing content or corrupted.

```powershell
# Step 1: Remove the GitHub repo
# WARNING: This is destructive on the GitHub side
gh repo delete ORG/REPO --yes

# Step 2: Re-enable write access on ADO repo
# Via ADO UI: Project Settings → Repositories → Select repo → Security
# Or via API:

# Step 3: Notify team to resume work in ADO
# Step 4: Investigate root cause before re-attempting migration
```

### 2. Pipeline Rollback

**Scenario**: GitHub Actions workflows are non-functional for a team.

```powershell
# Step 1: Re-enable ADO pipelines (they are not deleted)
# ADO pipelines remain functional after repos are migrated (they point to the ADO repo copy)

# Step 2: Delete the GitHub Actions workflow files from the repo
# This stops GitHub Actions from running

# Step 3: Team continues using ADO pipelines pointing to the ADO repo
```

### 3. Boards/Work Items Rollback

**Scenario**: GitHub Issues are incomplete or incorrectly mapped.

```powershell
# Step 1: ADO work items are NOT modified during migration — they are still in ADO
# Simply direct teams back to ADO Boards

# Step 2: Close/delete the GitHub issues if desired
# Or add "rollback" label and archive

# Step 3: Re-attempt boards migration after fixing the mappings
```

### 4. Full Batch Rollback

**Scenario**: Entire batch needs to revert.

```
1. Communicate to all teams in the batch
2. Re-enable write access on all ADO repos in the batch
3. Teams resume ADO development workflow
4. Keep GitHub repos for investigation (do not delete immediately)
5. Document root cause
6. Plan re-migration with fixes
```

---

## Rollback Timeline

| Phase | Action | Duration |
|-------|--------|----------|
| T+0 | Issue detected | — |
| T+15min | Assess severity against rollback criteria | 15 min |
| T+30min | Decision: rollback or fix-forward | 15 min |
| T+1hr | If rollback: re-enable ADO write access | 30 min |
| T+1.5hr | Notify affected teams | 30 min |
| T+2hr | Teams resume ADO workflow | — |
| T+1 week | Root cause analysis complete | — |
| T+2 weeks | Re-attempt migration with fix | — |

---

## Data Retention

| System | Retention After Migration |
|--------|--------------------------|
| ADO Repos | Read-only for 90 days minimum |
| ADO Pipelines | Remain accessible (no changes) |
| ADO Boards | Remain accessible (no changes) |
| ADO Audit Logs | Per org retention policy |
| ADO Pipeline Logs | Remain accessible indefinitely |

---

## Prevention

To minimize rollback risk:
1. **Always run pilot batch first** with non-critical repos
2. **Run validation script** after every batch: `validate-migration.ps1`
3. **Get team sign-off** before proceeding to next batch
4. **Do not delete ADO repos** during the migration project
5. **Maintain dual access** until final decommission sign-off
