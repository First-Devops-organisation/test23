# GitHub Permissions & JSON Mapping Guide

This guide explains the different levels of permissions in GitHub and how you can automatically assign them using your `team-mappings.json` file during the migration pipeline.

There are two distinct levels of permissions you need to manage: **Team Roles** (who manages the team itself) and **Repository Permissions** (what the team can do to the code).

---

## 1. Team Roles (Organization Level)
Team roles dictate what a user can do *within the team itself*.

| Role | What they can do | How to assign it in JSON |
| :--- | :--- | :--- |
| **Member** | Standard user. Can see the team and its repositories. | *Default.* Everyone discovered in ADO becomes a Member automatically. |
| **Maintainer** | Team Admin. Can add/remove users from the team and change the team's description. | Add their exact **GitHub Username** to the `"maintainers"` array. |

### JSON Example: Team Roles
```json
{
  "githubTeam": "serverless-core-team",
  "maintainers": [
    "Urvashi773",       // Urvashi is a Maintainer (Team Admin)
    "varsha-patilyash"  // Varsha is a Maintainer
  ],
  "members": []         // Everyone else from ADO defaults to Member
}
```

---

## 2. Repository Permissions (Repo Level)
Repository permissions dictate what the entire team is allowed to do with a specific codebase.

| Permission | What they can do | Who it is best for |
| :--- | :--- | :--- |
| `pull` | **(Read)** Can clone the code and open Pull Requests. Cannot push directly. | QA, Auditors, Cross-functional teams |
| `triage` | Can manage issues, labels, and PRs, but cannot push code. | Project Managers, Scrum Masters |
| `push` | **(Write)** Can push code directly to the repository. | Standard Developers |
| `maintain` | Can manage repo settings, branch protections, and merge PRs. Cannot delete repo. | Tech Leads, DevOps, SRE |
| `admin` | Full control. Can delete the repository and manage team access directly. | Global Organization Admins |

### JSON Example: Repository Access
You map these permissions by adding the repository name and the desired permission level to the `"repositories"` array.

```json
{
  "githubTeam": "serverless-core-team",
  "repositories": [
    {
      "name": "Serverless-Frontend",
      "permission": "push"         // The team can write code to the Frontend
    },
    {
      "name": "Serverless-Backend",
      "permission": "maintain"     // The team manages settings for the Backend
    },
    {
      "name": "Global-Platform-Docs",
      "permission": "pull"         // The team can only read the global docs
    }
  ]
}
```

---

## Quick Decision Matrix
Not sure what to give? Use this standard enterprise matrix:

1. **Tech Lead / DevOps Engineer?** 
   * Put their username in `"maintainers"`. 
   * Give the team `"maintain"` access to the repos.
2. **Core Developer?** 
   * Leave them as standard members. 
   * Give the team `"push"` access to the repos.
3. **QA / Tester?** 
   * Leave them as standard members. 
   * Give the team `"pull"` access to the repos.
