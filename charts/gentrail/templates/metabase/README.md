# Metabase (internal analytics portal)

Our-cloud-only sub-component (like the wiki / docs-server). It renders only when
`metabase.enabled` is true, which `infra/k3s-apps` flips when `metabase_domain`
is set. A BYOC install never ships it.

- Deployment + Service: `metabase` on container/Service port **3000**.
- Image: `metabase/metabase:v0.50.x` (open-source edition), pinned in
  `values.yaml` (`metabase.image.tag`).
- Tunnel: `infra/k3s-apps` routes `metabase.gentrail.ai` → `http://metabase:3000`
  and gates it with **Cloudflare Access** (SSO + email allowlist). Internal only.

## Two databases — keep them straight

Metabase touches two **separate** Postgres databases on the existing dashboard
RDS instance. They are configured in two different places:

| | What | How it's configured | Access |
|---|---|---|---|
| **App DB** | Metabase's own state: saved questions, dashboards, users, settings | **Helm/TF config.** `MB_DB_TYPE=postgres` + `MB_DB_CONNECTION_URI` from the `gentrail-metabase-appdb` secret, pointing at a dedicated **`metabase`** database. | Read/write (Metabase owns it) |
| **Metrics datasource** | The analytics data Metabase *reads*: the **`metrics`** db populated by the events-gateway Lambda | **Operator-driven, in the Metabase UI** (Admin → Databases → Add). NOT app config — it never appears in this chart. | **SELECT only**, on the `v_events` view |

Do **not** use the default embedded **H2** file DB for the app DB. H2 lives on
the pod filesystem, is lost on every reschedule, and cannot back more than one
replica. We always point the app DB at the `metabase` Postgres database.

### Provisioning the app DB (out of band, once)

On the RDS instance:

```sql
CREATE DATABASE metabase;
CREATE ROLE metabase LOGIN PASSWORD '<app-db-password>';
GRANT ALL ON DATABASE metabase TO metabase;
```

Then set `metabase_app_db_uri` (a sensitive TF var) to:

```
postgres://metabase:<app-db-password>@<rds_address>:5432/metabase?sslmode=require
```

`<rds_address>` is the `infra/rds` output `rds_address`. TF seeds it into the
`gentrail-metabase-appdb` secret; the password only ever lives in TF state, never
in chart values.

### Adding the metrics datasource (read-only, PII-free)

The `metrics` db (the events-gateway schema) isolates the only PII
(`work_email`) in a `persons` table. Analytics consumers must read the **PII-free
`v_events` view only**, never `persons`. Create a dedicated read role and grant
it SELECT on the view only:

```sql
-- in the `metrics` database
CREATE ROLE metabase_ro LOGIN PASSWORD '<read-only-password>';
GRANT CONNECT ON DATABASE metrics TO metabase_ro;
GRANT USAGE ON SCHEMA public TO metabase_ro;
GRANT SELECT ON v_events TO metabase_ro;        -- the view only
-- deliberately NO grant on persons / events; no table-level grants.
```

Then, in the Metabase UI (Admin → Databases → Add database → PostgreSQL), point
it at the `metrics` db with the `metabase_ro` credentials. This is the only place
that datasource is defined — keep it out of Helm/TF so the read-only boundary is
explicit and auditable.

## Boot / health expectations

- Health endpoint: `GET /api/health` (used by both probes). It returns 200 only
  after the JVM is up, the app-DB migrations have run, and the web server is
  serving.
- Cold start is slow (JVM + first-run migrations). The liveness probe waits
  ~120s with a high `failureThreshold` so a slow first boot does not CrashLoop;
  readiness waits ~30s before sending traffic.
- Resources: ~512Mi requested / 2Gi limit (JVM app). Bump the limit before the
  replica count.
- Single replica: Metabase serializes app-DB migrations at boot, so it runs at
  `replicaCount: 1`.
- Durable state is entirely in the `metabase` Postgres DB; the pod's `/plugins`
  and `/tmp` are ephemeral emptyDirs, safe to lose on reschedule.
