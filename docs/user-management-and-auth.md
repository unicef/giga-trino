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

## Transport: HTTP vs HTTPS

Trino's PASSWORD authenticator normally refuses to run over HTTP — it requires
HTTPS unless `http-server.authentication.allow-insecure-over-http=true` is set.
This chart sets that flag (`coordinatorExtraConfig` in `values.yaml`) because
Trino's own `https.enabled` stays `false`: Trino never terminates TLS itself.

TLS is terminated upstream instead, at the Azure Application Gateway ingress
(`infra/helm/trino/templates/ingress.yaml`, enabled per-env via
`--set ingress.enabled=true` in `azure/templates/helm-deploy.yaml`, with
`ssl-redirect: "true"` and a cert from Key Vault). Client↔gateway is HTTPS;
gateway↔coordinator pod (inside the cluster network) is plain HTTP —
`http-server.process-forwarded=true` makes the coordinator trust the gateway's
forwarded headers. So client passwords are always TLS-protected in transit;
`allow-insecure-over-http` only concerns the internal gateway→pod hop.

docker-compose sets no `authenticationType` at all, so none of this applies
locally.

**Could Trino terminate TLS itself?** The chart has unused scaffolding for it —
`server.config.https.enabled`/`.port`/`.keystore.path` in `values.yaml`, wired
into `http-server.https.*` in `configmap-coordinator.yaml` — but nothing mounts
a keystore into the pod and there's no keystore-password field modeled. Doing
this for real means provisioning a keystore secret/volume, and would duplicate
what the Application Gateway already handles — a known option, not something
to build unless there's a specific need for TLS all the way to the pod.

## Roles

Groups are defined in `conf/group.txt` (local dev) and the `group.db` block in
`azure/templates/create-config.yaml` (deployed). Privileges per group live in
`conf/rules.json` (local) / `accessControl.rules` in
`infra/helm/trino/values.yaml` (deployed) — read those files for the current
set of groups and what each can do; don't rely on this doc for that, it drifts.

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
**read-only (`SELECT`) across all catalogs** role, add these four entries:

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
  scoped to specific catalogs/schemas — see `conf/rules.json` for existing
  examples of catalog/schema-scoped write rules rather than granting them
  across `.*`.
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
```

## Removing a user

Reverse the steps: delete the password line and group mapping from
`create-config.yaml`, remove the entry from `conf/group.txt`, drop the group's
rules from `values.yaml`, delete the `ADMIN_AUTH_*` secret variable, and redeploy.
