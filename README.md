# recipe-posthog

Self-hosted [PostHog](https://posthog.com) on Zerops — Django web, Celery worker, Node CDP/plugin-server, fed by Kafka and backed by Postgres, ClickHouse, Valkey, and S3-compatible storage. **No Docker.** The recipe lifts the official PostHog images via `crane` and runs them directly on Zerops runtime containers.

## What you get

| Service | Type | Role |
|---|---|---|
| `db` | postgresql@18 | application database |
| `clickhouse` | clickhouse@25.3 (**HA required**) | analytics database |
| `kafka` | kafka@3.9 | event queue |
| `valkey` | valkey@7.2 | cache + plugin-server pub/sub + celery broker/backend |
| `storage` | object-storage | session replays, exports |
| `mailpit` | alpine@3.20 ([recipe-mailpit](https://github.com/zeropsio/recipe-mailpit)) | SMTP sink + web inbox on `:8025` |
| `cyclotrondb` | postgresql@18 | dedicated job-queue database for Cyclotron |
| `web` | ubuntu/python@3.12 | Django + gunicorn on `:8000` |
| `worker` | ubuntu/python@3.12 | Celery worker + RedBeat scheduler |
| `pluginserver` | ubuntu/nodejs@24 | default Node capability merge — CDP API on `:6738`, feature flag evaluation, logs, error tracking |
| `ingestion` | ubuntu/nodejs@24 | `PLUGIN_SERVER_MODE=ingestion-v2` — hot path Kafka → ClickHouse |
| `recordings` | ubuntu/nodejs@24 | `PLUGIN_SERVER_MODE=recordings-blob-ingestion-v2` — session replay blobs |
| `cyclotron` | ubuntu/nodejs@24 | `PLUGIN_SERVER_MODE=cdp-cyclotron-worker` — hog-function destination retries |

All three runtimes pull their code from the prebuilt PostHog Docker images (`posthog/posthog:latest` for web/worker, `posthog/posthog-node:latest` for pluginserver) at deploy time, via `crane export` — no `docker build`, no `docker run`, no privileged container needed.

## Deploy

Import this project topology from the Zerops dashboard (Settings → Import project) using [`zerops-import.yaml`](./zerops-import.yaml). Zerops provisions the five managed services and clones this repo into each runtime via `buildFromGit`, then `zerops.yml`'s `run.prepareCommands` runs [`utils/init.sh`](./utils/init.sh) + [`utils/patches.sh`](./utils/patches.sh) to materialize PostHog under `/opt/posthog/`.

First boot takes ~10 minutes (image pull + extraction + ~272 ClickHouse migrations). When `web`'s health check goes green, browse to the assigned subdomain — PostHog's "Validate implementation" wizard should show all checks green.

## ClickHouse must be HA

PostHog issues `ON CLUSTER zerops` DDL throughout its migrations. The `zerops` cluster, the Keeper coordination layer, and the macros PostHog reads (`{cluster}`, `{shard}`, `{replica}`) only exist when ClickHouse runs in HA mode. NON_HA provisioning will fail mid-migration with cryptic "cluster not found" errors.

## What's in the patches

PostHog assumes a PostHog-Cloud Kubernetes environment. The recipe bridges that to Zerops's runtime model. See [`utils/patches.sh`](./utils/patches.sh) for the in-place sed edits and [`zerops.yml`](./zerops.yml) for the env overrides.

**Web ([`patches.sh web`](./utils/patches.sh))**
- `posthog/clickhouse/cluster.py` — `getMacro('hostClusterType')` / `getMacro('hostClusterRole')` → `''` (Cloud-only macros don't exist on Zerops's CH).
- Same file — `__hosts_by_roles` accepts empty `host.host_cluster_role` as match-any (single-cluster fan-out).
- `posthog/views.py` — `/_preflight/` `"kafka": in_cloud or settings.TEST` → `"kafka": True` (hard-coded `False` outside Cloud, wizard renders it as Error even though Kafka works).

**Worker ([`patches.sh worker`](./utils/patches.sh))**
- Same `cluster.py` patches as web.
- `bin/docker-worker-celery` — drop the `SKIP_ASYNC_MIGRATIONS_SETUP=0` override that prevents the worker from booting (it forces `posthog.apps.ready()` into `setup_async_migrations()` which throws on the Cloud-only async migration set).

**Pluginserver (env only — see [`zerops.yml`](./zerops.yml))**
- `CDP_REDIS_HOST` / `LOGS_REDIS_HOST` / `TRACES_REDIS_HOST` / `SESSION_RECORDING_API_REDIS_HOST` default to `127.0.0.1`. Must be the full `redis://valkey:6379` URL — ioredis treats a bare hostname as an unparseable URL and silently falls back to localhost.
- Every Kafka producer mode the plugin-server creates reads its own env prefix (`KAFKA_PRODUCER_*`, `KAFKA_METRICS_PRODUCER_*`, `KAFKA_WARPSTREAM_PRODUCER_*`, `KAFKA_WAREHOUSE_PRODUCER_*`, `KAFKA_CDP_PRODUCER_*`). Modes without SASL keys configured yield a plaintext producer that hangs forever retrying idempotence PID acquisition — that blocks `startServices()`'s `Promise.all` and the HTTP server never opens.
- `KAFKA_CONSUMER_sasl_mechanisms` (plural alias) is required alongside the singular form — `dist/kafka/admin.js` reads the plural key by name when building the AdminClient.

**Web ([`zerops.yml`](./zerops.yml) env)**
- `CDP_API_URL=http://pluginserver:6738` — PostHog's default is a k8s service DNS name (`ingestion-cdp-api.posthog.svc.cluster.local`) that doesn't resolve outside Kubernetes. The `plugins` preflight probe hits this URL.

## One-time ClickHouse bootstrap

[`utils/ch-init.sh`](./utils/ch-init.sh) runs once on first deploy (via `zsc execOnce` in [`zerops.yml`](./zerops.yml#L57)):

1. Create the `posthog` database with the Atomic engine on the `zerops` cluster.
2. Create the `default` user on every CH node so `ON CLUSTER` DDL has someone to authenticate as during cross-shard fan-out.
3. Grant `default` the permissions PostHog's migrations need.
4. Create the `msk_cluster` named collection carrying Kafka SASL credentials for the CH-side Kafka engine tables.

The Django and ClickHouse migrations follow, both also guarded by `execOnce` so re-deploys are idempotent.

## File layout

```
.
├── README.md
├── zerops-import.yaml      # project topology (services + types + buildFromGit refs)
├── zerops.yml              # 3 setups: web, worker, pluginserver
└── utils/
    ├── init.sh             # crane export + venv repoint + system libs (parameterized by role)
    ├── patches.sh          # PostHog source patches (Python services only)
    └── ch-init.sh          # ClickHouse one-time bootstrap (called from web's initCommands)
```

## Secrets

Four project-level secrets are auto-generated once at import (see [`zerops-import.yaml`](./zerops-import.yaml#L13)) and shared across all three runtimes:

| Env | Purpose | PostHog default (insecure) |
|---|---|---|
| `SECRET_KEY` | Django session / CSRF crypto | Django refuses to boot in production |
| `ENCRYPTION_SALT_KEYS` | Fernet field encryption (integrations, hog functions) | `00beef0000beef0000beef0000beef00` |
| `SALT_KEY` | Older symmetric salt for `encrypted_fields` helper | `0123456789abcdefghijklmnopqrstuvwxyz` |
| `INTERNAL_API_SECRET` | Django ↔ plugin-server internal-API auth | `posthog123` (LOCAL_DEV literal) |

`INTERNAL_API_SECRET` in particular must match across `web` and `pluginserver`. Defining it at the project level guarantees both runtimes see the same value.

## What about a dedicated capture service?

PostHog Cloud uses a Rust binary (`rust/capture/`) to serve the high-throughput capture endpoints (`/e/`, `/i/`, `/decide/`, `/flags/`) instead of Django. This recipe doesn't include it because **upstream capture-rs has no SASL Kafka support** — its `rust/common/kafka/src/kafka_producer.rs` builds the rdkafka client config from a fixed struct that exposes only TLS, not SASL. Zerops's managed Kafka requires SASL_PLAINTEXT, so capture-rs can't authenticate.

To use it we'd need to fork capture-rs and patch the Kafka client init, then maintain that fork against PostHog upstream. That's out of scope for a deploy recipe. Capture endpoints stay on Django; throughput ceiling is whatever your `web` gunicorn workers can handle (currently `--workers 2`, increase via overriding the start command if you need more).

## SMTP / Mailpit

`web` and `worker` are wired to send through the bundled Mailpit (plain SMTP on `mailpit:1025`, no auth, no TLS). Open Mailpit's subdomain to see every email PostHog sends — alerts, weekly digests, password resets, invites. To use a real provider instead, override `EMAIL_HOST` + `EMAIL_PORT` + `EMAIL_HOST_USER` + `EMAIL_HOST_PASSWORD` + `EMAIL_USE_TLS` as service-level envs on `web` and `worker` from the Zerops dashboard.

## Caveats

- **Pinned to image `:latest`.** First deploy locks in whatever `posthog/posthog:latest` and `posthog/posthog-node:latest` resolved to at build time. Switching versions = redeploy. The patches in `patches.sh` were verified against PostHog ~late 2025; newer versions may move code around and require re-targeting.
- **Cyclotron migrations pinned to `master`.** [`utils/cyclotron-migrations.sh`](./utils/cyclotron-migrations.sh) fetches SQL from PostHog's `master` branch. Schema changes upstream require either updating the migration list in the script or accepting drift.
- **Third-party integrations not wired up.** Slack, Google/GitHub/GitLab OAuth, Hubspot, Salesforce, OpenAI, etc. need their respective `SLACK_*` / `GOOGLE_*` / etc. credentials set as service-level env vars in the Zerops dashboard if you want them.
- **Async migrations are skipped** (`POSTHOG_SKIP_MIGRATION_CHECKS=1` + the docker-worker-celery patch). PostHog's 10 async migrations target old-version schema reshapes; on a fresh install they're unnecessary, but if you later upgrade PostHog versions and a new required async migration ships, you'll need to run `manage.py run_async_migrations` by hand or temporarily flip the flag.
- **Persistent data lives in the managed services**, not in the runtime containers. Scaling/restarting the runtimes is safe.

## License

MIT — same as the underlying recipe scaffolding. PostHog itself is dual-licensed (MIT / PostHog Cloud terms); consult upstream before commercial use.
