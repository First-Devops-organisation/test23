| API Category                    | HTTP Method | Endpoint                                                                                                             | API Version |
| ------------------------------- | ----------- | -------------------------------------------------------------------------------------------------------------------- | ----------- |
| Get User Information            | GET         | `https://api.github.com/users/{username}`                                                                            | 2022-11-28  |
| Create or Update Environment    | PUT         | `https://api.github.com/repos/{owner}/{repo}/environments/{environment_name}`                                        | 2022-11-28  |
| List Deployment Branch Policies | GET         | `https://api.github.com/repos/{owner}/{repo}/environments/{environment_name}/deployment-branch-policies`             | 2022-11-28  |
| Delete Deployment Branch Policy | DELETE      | `https://api.github.com/repos/{owner}/{repo}/environments/{environment_name}/deployment-branch-policies/{policy_id}` | 2022-11-28  |
| Create Deployment Branch Policy | POST        | `https://api.github.com/repos/{owner}/{repo}/environments/{environment_name}/deployment-branch-policies`             | 2022-11-28  |
