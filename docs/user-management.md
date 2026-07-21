# User Management

Trino access is controlled by three things working together: **authentication**
(who you are — a password), **group membership** (which role you belong to), and
**authorization rules** (what your group is allowed to do). Adding a user means
touching each of these.

## How it fits together

The deployed clusters (dev/stg/prd) run with `authenticationType: PASSWORD`
(`infra/helm/trino/values.yaml`). At runtime the coordinator loads:

| Concern | File (runtime) | Source of truth (repo) |
| --- | --- | --- |
| Passwords | `password.db` | `password.db` block in `azure/templates/create-config.yaml`, values from Azure DevOps secret variables |
| Group membership | `group.db` | `group.db` block in `azure/templates/create-config.yaml` (kept in sync with `conf/group.txt`) |
| Authorization rules | `rules.json` (ConfigMap) | `accessControl.rules` in `infra/helm/trino/values.yaml` |

`password.db` and `group.db` are mounted from the K8s secret
`giga-trino-secrets-<env>`, which the `create-config` pipeline stage builds inline.
Password values themselves are **secret pipeline variables** (declared in
`azure/templates/variables.yaml`), never committed to the repo.

> Local `docker-compose` has **no** authentication — you connect with just
> `--user <name>` and only `conf/group.txt` + `conf/rules.json` apply. The steps
> below are for the deployed clusters.

## Roles today

Groups are defined in `conf/group.txt` / the `group.db` block. Current roles:

- `admin` — full access to every catalog (`giga-admin`, `tmadmin`, `admin`).
- `giga-trino`, `giga-superset`, `giga-ingestion-portal` — read access
  (`SELECT` + `GRANT_SELECT`) across catalogs, plus write access to specific
  `delta_lake` schemas for `giga-superset`.
- `giga-data-user` — strictly read-only (`SELECT` only) across all catalogs.

A "user" here is really a **username mapped to a group**; privileges are attached
to the group, not the individual username.

## Adding a new user

Steps 1–4 are code changes in this repo; step 5 is a manual secret setup in Azure
DevOps. Use a name like `<name>` for the username and pick (or reuse) a group.

### 1. Declare the password pipeline variable — `azure/templates/variables.yaml`

Add a variable that references an Azure DevOps secret:

```yaml
  adminAuthMyUser: $(ADMIN_AUTH_MY_USER)
```

### 2. Wire it into the secret — `azure/templates/create-config.yaml`

Add the password line to the `password.db` block and the group mapping to the
`group.db` block:

```yaml
                    password.db: |-
                      ...
                      $(adminAuthMyUser)
                    group.db: |-
                      ...
                      my-user:my-group
```

### 3. Keep `conf/group.txt` in sync

Append the same mapping so the repo's source-of-truth matches:

```
my-user:my-group
```

### 4. Grant authorization — `infra/helm/trino/values.yaml`

Add the group to the relevant sections of `accessControl.rules.rules.json`. For a
**read-only (`SELECT`) across all catalogs** role, add these four entries (this is
exactly how `giga-data-user` is configured):

```json
// catalogs
{ "group": "my-group", "catalog": ".*", "allow": "read-only" }

// tables
{ "group": "my-group", "catalog": ".*", "schema": ".*", "table": ".*", "privileges": ["SELECT"] }

// functions  (EXECUTE lets SELECT queries call built-in/SQL functions)
{ "group": "my-group", "catalog": ".*", "schema": ".*", "function": ".*", "privileges": ["EXECUTE"] }

// queries
{ "group": "my-group", "allow": ["execute", "view"] }
```

Privilege notes:
- `SELECT` = read the table. `GRANT_SELECT` (not included above) = the extra right
  to grant read access to *other* users. Omit it for a pure read-only role.
- For write access, add privileges like `INSERT`, `UPDATE`, `DELETE`, `OWNERSHIP`
  scoped to specific catalogs/schemas — mirror the `giga-superset` `delta_lake`
  rules rather than granting them across `.*`.
- If no rule matches a group, access is **denied** by default.

### 5. Create the password secret (manual, in Azure DevOps)

Generate a bcrypt htpasswd line (Trino's file authenticator requires bcrypt or
PBKDF2):

```bash
htpasswd -nbBC 10 my-user '<password>'
# -> my-user:$2y$10$....
```

Add the **full line** as a **secret** variable named `ADMIN_AUTH_MY_USER` in the
Trino variable group / pipeline for each environment. Never commit the hash.

### 6. Deploy

Merge to the branch for the target environment (`main`→DEV, `staging`→STG,
`production`→PRD) or trigger the pipeline manually — see [Deployment](deployment.md).
The `create-config` stage rebuilds the secret and the deploy restarts the
coordinator so the new user is picked up.

## Verifying

```bash
# 1. Rules still render and JSON is valid
helm template infra/helm/trino | grep my-group

# 2. Secret contains the user (after the create-config stage)
kubectl -n <ns> get secret giga-trino-secrets-<env> -o jsonpath='{.data.group\.db}'    | base64 -d
kubectl -n <ns> get secret giga-trino-secrets-<env> -o jsonpath='{.data.password\.db}' | base64 -d

# 3. End-to-end: read works, write is denied (for a read-only role)
trino --server <host> --user my-user --password
> SHOW CATALOGS;                                      -- lists catalogs
> SELECT * FROM <catalog>.<schema>.<table> LIMIT 5;   -- succeeds
> CREATE SCHEMA delta_lake.tmp_x;                     -- Access Denied
```

## Removing a user

Reverse the steps: delete the password line and group mapping from
`create-config.yaml`, remove the entry from `conf/group.txt`, drop the group's
rules from `values.yaml`, delete the `ADMIN_AUTH_*` secret variable, and redeploy.
