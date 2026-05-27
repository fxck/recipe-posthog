# recipe-posthog

Self-hosted [PostHog](https://posthog.com) on Zerops — Django web, Celery worker, four Node plugin-server modes (default CDP, ingestion-v2, recordings-blob, cyclotron-worker), a Rust capture binary, plus Postgres, ClickHouse, Kafka, Valkey, S3 storage, and Mailpit SMTP. **No Docker.** The recipe lifts the official PostHog images via `crane` and runs them directly on Zerops runtime containers.

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
| `capture` | ubuntu/rust@stable | high-throughput Rust capture binary (`/e/`, `/i/`, etc.), built from [fxck/posthog-capture](https://github.com/fxck/posthog-capture) |

The Python and Node runtimes pull their code from the prebuilt PostHog Docker images (`posthog/posthog:latest` for web/worker, `posthog/posthog-node:latest` for the four plugin-server-mode services) at deploy time, via `crane export` — no `docker build`, no `docker run`, no privileged container needed. The capture binary is built from source via [fxck/posthog-capture](https://github.com/fxck/posthog-capture) (a SASL-patched fork of PostHog's `rust/` tree).

## Deploy

Import this project topology from the Zerops dashboard (Settings → Import project) using [`zerops-import.yaml`](./zerops-import.yaml). Zerops provisions the six managed/utility services and clones this repo into each Node/Python runtime via `buildFromGit`. The recipe's [`utils/init.sh`](./utils/init.sh) + [`utils/patches.sh`](./utils/patches.sh) (shipped via `build.addToRunPrepare`) materialize PostHog under `/opt/posthog/` during `run.prepareCommands`.

First boot takes ~10 minutes for the Python/Node services (image pull + extraction + ~272 ClickHouse migrations) and ~19 minutes for the capture service (cold cargo build). When `web`'s health check goes green, browse to the assigned subdomain — PostHog's "Validate implementation" wizard should show all checks green.

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

**Pluginserver / ingestion / recordings / cyclotron (env only — see [`zerops.yml`](./zerops.yml))**
- `CDP_REDIS_HOST` / `LOGS_REDIS_HOST` / `TRACES_REDIS_HOST` / `SESSION_RECORDING_API_REDIS_HOST` default to `127.0.0.1`. Must be the full `redis://valkey:6379` URL — ioredis treats a bare hostname as an unparseable URL and silently falls back to localhost.
- Every Kafka producer mode the plugin-server creates reads its own env prefix (`KAFKA_PRODUCER_*`, `KAFKA_METRICS_PRODUCER_*`, `KAFKA_WARPSTREAM_PRODUCER_*`, `KAFKA_WAREHOUSE_PRODUCER_*`, `KAFKA_CDP_PRODUCER_*`). Modes without SASL keys configured yield a plaintext producer that hangs forever retrying idempotence PID acquisition — that blocks `startServices()`'s `Promise.all` and the HTTP server never opens.
- Env names use **UPPERCASE** (`KAFKA_PRODUCER_SASL_USERNAME`, not `KAFKA_PRODUCER_sasl_username`). Two code paths read the same prefix: the legacy `parseEnvToRdkafkaConfig` lowercases the suffix after stripping the prefix, and the newer `KafkaProducerRegistry` (used by ingestion-v2 / recordings / error-tracking) reads explicit UPPERCASE names by name. The Zerops platform treats env var keys as case-insensitive for uniqueness within one service, so only one variant can ship — UPPERCASE works for both.
- `KAFKA_CONSUMER_SASL_MECHANISMS` (plural) is set alongside `KAFKA_CONSUMER_SASL_MECHANISM` (singular). librdkafka accepts either, but `dist/kafka/admin.js` reads the plural form by name when building the AdminClient.

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
├── zerops-import.yaml             # project topology (services + types + buildFromGit refs)
├── zerops.yml                     # 6 setups: web, worker, pluginserver, ingestion, recordings, cyclotron
│                                  # (capture's setup lives in fxck/posthog-capture, the fork)
└── utils/
    ├── init.sh                    # crane export + venv repoint + system libs (parameterized by role)
    ├── patches.sh                 # PostHog Python source patches (web + worker)
    ├── ch-init.sh                 # ClickHouse one-time bootstrap (called from web's initCommands)
    └── cyclotron-migrations.sh    # Cyclotron sqlx schema bootstrap (called from cyclotron's initCommands)
```

## Secrets

Four project-level secrets are auto-generated once at import (see [`zerops-import.yaml`](./zerops-import.yaml)) and shared across every runtime:

| Env | Purpose | PostHog default (insecure) |
|---|---|---|
| `SECRET_KEY` | Django session / CSRF crypto | Django refuses to boot in production |
| `ENCRYPTION_SALT_KEYS` | Fernet field encryption (integrations, hog functions) | `00beef0000beef0000beef0000beef00` |
| `SALT_KEY` | Older symmetric salt for `encrypted_fields` helper | `0123456789abcdefghijklmnopqrstuvwxyz` |
| `INTERNAL_API_SECRET` | Django ↔ plugin-server internal-API auth | `posthog123` (LOCAL_DEV literal) |

`INTERNAL_API_SECRET` in particular must match across `web` and all four plugin-server-mode services. Defining it at the project level guarantees every runtime sees the same value.

## Routing capture vs UI

PostHog Cloud serves the high-throughput capture endpoints (`/e/`, `/i/`, `/decide/`, `/flags/`) from a dedicated Rust binary, not Django. Upstream `capture-rs` has no SASL Kafka support — its rdkafka `ClientConfig` is built from a struct exposing only TLS — so to use it against Zerops's SASL-only Kafka listener we run a small fork at [`fxck/posthog-capture`](https://github.com/fxck/posthog-capture) that adds four optional env vars (`KAFKA_SECURITY_PROTOCOL` / `KAFKA_SASL_MECHANISM` / `KAFKA_SASL_USERNAME` / `KAFKA_SASL_PASSWORD`) and propagates them to the rdkafka client. The fork's own `zerops.yml` carries the `capture` setup block.

The `capture` service builds that fork via `cargo build --release -p capture` on first deploy (~19 min first time, cached on subsequent builds via `build.cache` on the cargo target dir + registry) and exposes the binary on its own subdomain.

Point your PostHog JS at both subdomains:

```js
posthog.init('your-api-key', {
  api_host: 'https://capture-<subdomain>.prg1.zerops.app',  // events go here
  ui_host: 'https://web-<subdomain>.prg1.zerops.app',       // app/dashboard
})
```

If you don't need the throughput, you can ignore `capture` entirely and point `api_host` at the `web` subdomain — Django serves the same endpoints, just with whatever ceiling `gunicorn --workers 2` can hold.

## SMTP / Mailpit

`web` and `worker` are wired to send through the bundled Mailpit (plain SMTP on `mailpit:1025`, no auth, no TLS). Open Mailpit's subdomain to see every email PostHog sends — alerts, weekly digests, password resets, invites. To use a real provider instead, override `EMAIL_HOST` + `EMAIL_PORT` + `EMAIL_HOST_USER` + `EMAIL_HOST_PASSWORD` + `EMAIL_USE_TLS` as service-level envs on `web` and `worker` from the Zerops dashboard.

## Honest comparison

### vs the hobby `docker-compose.hobby.yml`

Hobby is a single VM running everything via Docker. Faster to spin up, cheaper at low volume, but a single SPOF across Postgres + ClickHouse + Kafka + the app — and ClickHouse is single-node so you can't even reproduce the `ON CLUSTER` semantics PostHog's migrations assume. Ours splits every dependency into a managed service with backups, runs ClickHouse HA (3-node + Keeper), and autoscales runtime containers horizontally + vertically. **Crossover ≈100k events/month**: below that, hobby is fine and ours is overkill. Above it, hobby starts hitting the single-VM ceiling on disk I/O and partition rebalancing — ours just adds containers.

### vs the official Helm chart ([`PostHog/charts-clickhouse`](https://github.com/PostHog/charts-clickhouse))

The Helm chart is the supported self-host path. Comparing template-by-template against [`charts/posthog/templates/`](https://github.com/PostHog/charts-clickhouse/tree/main/charts/posthog/templates):

**1:1 mappings** — our 7 runtime services cover the chart's main Deployments:

| Helm template | Our service |
|---|---|
| `web-deployment.yaml` | `web` |
| `worker-deployment.yaml` | `worker` |
| `plugins-deployment.yaml` | `pluginserver` |
| `plugins-ingestion-deployment.yaml` + `plugins-analytics-ingestion-deployment.yaml` + `plugins-ingestion-overflow-deployment.yaml` | `ingestion` (chart still splits analytics vs overflow lanes; we collapse) |
| `recordings-blob-ingestion-deployment.yaml` | `recordings` |
| `plugins-async-deployment.yaml` | `cyclotron` (chart name predates the rename) |
| `events-deployment.yaml` + `recordings-deployment.yaml` + `decide-deployment.yaml` | `capture` — the chart still routes these through Django; we leapfrog with capture-rs |

**Missing — functional gaps that disable features**

| Helm template / service | What breaks without it |
|---|---|
| [`temporal-py-worker-deployment.yaml`](https://github.com/PostHog/charts-clickhouse/blob/main/charts/posthog/templates/temporal-py-worker-deployment.yaml) (+ external Temporal cluster) | **Batch exports** to BigQuery / Snowflake / S3 / Redshift / Postgres, and **data-warehouse source syncs**. Hog functions cover most realtime destinations; batch and DWH paths silently never fire. |
| `plugins-exports-deployment.yaml` | **Legacy plugin-based exports** (old destinations using plugin-server `exports` mode). |
| `plugins-jobs-deployment.yaml` | **Plugin job runner** — "Export historical events", retroactive backfills, similar long-running plugin jobs. |
| `plugins-scheduler-deployment.yaml` | **Plugin scheduled tasks** (`runEveryMinute` / `runEveryHour` / `runEveryDay` plugin hooks). |

**Missing — Rust/Go services that aren't in the chart yet either** (PostHog Cloud runs these; the public chart hasn't caught up)

| Service | What breaks without it | Severity |
|---|---|---|
| `property-defs-rs` | Property/event taxonomy still works via the plugin-server fallback, but with higher Postgres write load. | optimization |
| `feature-flags-rs` | `/flags` eval handled by Django / plugin-server (slower, higher PG load). | optimization |
| `log-capture-rs` | **Logs product** (log ingestion endpoint) doesn't work. | functional |
| `livestream` (Go) | **Activity / live events** view shows nothing. Historical event queries are unaffected. | functional |
| Error-tracking symbol-set server | Stack traces in the error-tracking product remain unminified. | functional |

**Operational gear Helm bundles that Zerops absorbs into the platform** — `pgbouncer-deployment.yaml` (connection pooling), `clickhouse-operator/` + `clickhouse-backup-cronjob.yaml` (operator + backups), `grafana-*` + `prometheus*` + statsd subcharts (observability), `cert-issuer.yaml` + `ingress.yaml` + `storage_class.yaml` (k8s plumbing), `toolbox-deployment.yaml` (ops shell). None of these have an analogue in ours because Zerops's managed services + platform logs/metrics + automatic TLS replace them.

**Operational gear Helm gives that we don't** — PgBouncer in front of Postgres at very high scale (>thousands of concurrent connections); first-class PostHog community support (the chart is what every PostHog PR is tested against; our patches are off the supported path and have to be re-targeted when upstream churns).

### vs PostHog Cloud

Cloud terminates SASL inside its own private VPC and runs capture-rs there with plaintext to brokers — that's why upstream `capture-rs` ships no SASL support and why we needed the [fxck/posthog-capture](https://github.com/fxck/posthog-capture) fork. Our private VXLAN has the same property: traffic between web ↔ kafka ↔ clickhouse never leaves the project network. So the privacy posture is comparable; the difference is who runs it and at what price.

**Cost model**

Zerops bills resources, not events. CPU is allocated in whole cores; default `cpuMode: SHARED` overcommits a physical core up to 10× with other tenants at **$0.60/core/month** — bursty performance, ideal for a recipe whose floor sits idle most of the time. Switch any service to `cpuMode: DEDICATED` ($6/core/month, exclusive core) for consistent latency under sustained load. RAM is billed at $3/GB/month, disk at $0.10/GB/month.

Floor sizings (see [`zerops-import.yaml`](./zerops-import.yaml) — vertical autoscaling lifts CPU/RAM up to the listed max under load):

| Line item | Floor → autoscale max | ~Monthly idle |
|---|---|---|
| ClickHouse HA (3 nodes, mandatory) | 3 × (2 core / 4 GB / 50 GB) | ~$55 |
| Postgres `db` | 1 core / 1 GB / 20 GB | ~$6 |
| Postgres `cyclotrondb` | 1 core / 0.5 GB / 10 GB | ~$4 |
| Kafka | 1 core / 2 GB / 20 GB | ~$9 |
| Valkey | 1 core / 1 GB / 5 GB | ~$4 |
| Object storage + Mailpit | nominal | ~$2 |
| `web`, `worker` | 1 core / 0.5 GB each → 2 / 2 | ~$4 |
| `pluginserver` (biggest Node bundle) | 1 core / 0.75 GB → 2 / 2 | ~$3 |
| `ingestion`, `recordings` | 1 core / 0.5 GB each → 2 / 2 | ~$4 |
| `cyclotron` | 1 core / 0.5 GB → 2 / 1 | ~$2 |
| `capture` (Rust, tiny at rest) | 1 core / 0.25 GB → 2 / 1 | ~$1 |
| Project core (Serious plan) | — | $10 |
| **Idle floor** | | **~$100/mo** |

Node services cap `maxCpu: 2` — JavaScript runs on a single event loop, so extra cores only feed the libuv I/O pool, V8 GC threads, and (for ingestion-v2) the Piscina worker pool. Beyond 2 cores per container, horizontal scaling (`maxContainers > 1`) is the right lever, not more vertical CPU. Python services (`web` gunicorn, `worker` Celery) scale linearly with cores up to their worker-count — same cap, same reasoning.

PostHog Cloud at posted list price: $0.00005 per event after 1M free, $0.005 per recording after 5K free. Comparing at four traffic levels (Cloud free tier included):

| Traffic / month | PostHog Cloud | Zerops | Winner |
|---|---|---|---|
| 1M events, 5K recordings | $0 (free tier) | ~$100 | **Cloud** |
| 10M events, 50K recordings | ~$675 | ~$120 | Zerops by ~$555 |
| 100M events, 500K recordings | ~$8,300 | ~$600–700 | Zerops by ~$7,500 |
| 1B events, 5M recordings | ~$60,000+ | ~$2,500–4,000 | Zerops by ~$55,000+ |

**Crossover ≈3–5M events/month** at list prices. Cloud scales linearly per event; Zerops scales sublinearly because most cost is already in the idle floor and the autoscaler only adds capacity for actual load. Above ~10M events/month the gap widens fast — Zerops costs maybe 2–3× idle to handle 100× the throughput.

**Caveats to the math**
- Cloud's enterprise tier discounts cut the list rate (30–50% at >100M events) — still loses to Zerops at that volume, but by less.
- Engineer time to maintain the patches (capture-rs fork + `patches.sh` re-targeting when upstream churns) is real. Budget ~2–4 hrs/month at fully-loaded rate — shifts the crossover from ~3M events to closer to ~10M before total cost favors Zerops.
- Egress: the Serious plan's 3TB covers ~100M events of internal traffic comfortably because most traffic stays inside the private VXLAN. External egress is only dashboard/API traffic.

### Where this recipe actually fits

A narrow but real niche: self-host, own your data, **don't want to run Kubernetes**, accept that you're carrying a Rust fork + ~5 lines of Python sed patches that will need re-targeting on PostHog upstream churn. If you have an existing k8s team and platform, the Helm chart is strictly better for app-level support. If PostHog is the *reason* you'd stand up k8s, this recipe is a faster path with comparable durability.

## Caveats

- **Pinned to image `:latest`.** First deploy locks in whatever `posthog/posthog:latest` and `posthog/posthog-node:latest` resolved to at build time. Switching versions = redeploy. The patches in `patches.sh` were verified against PostHog ~late 2025; newer versions may move code around and require re-targeting.
- **Cyclotron migrations pinned to `master`.** [`utils/cyclotron-migrations.sh`](./utils/cyclotron-migrations.sh) fetches SQL from PostHog's `master` branch. Schema changes upstream require either updating the migration list in the script or accepting drift.
- **Third-party integrations not wired up.** Slack, Google/GitHub/GitLab OAuth, Hubspot, Salesforce, OpenAI, etc. need their respective `SLACK_*` / `GOOGLE_*` / etc. credentials set as service-level env vars in the Zerops dashboard if you want them.
- **Async migrations are skipped** (`POSTHOG_SKIP_MIGRATION_CHECKS=1` + the docker-worker-celery patch). PostHog's 10 async migrations target old-version schema reshapes; on a fresh install they're unnecessary, but if you later upgrade PostHog versions and a new required async migration ships, you'll need to run `manage.py run_async_migrations` by hand or temporarily flip the flag.
- **Persistent data lives in the managed services**, not in the runtime containers. Scaling/restarting the runtimes is safe.

## License

MIT — same as the underlying recipe scaffolding. PostHog itself is dual-licensed (MIT / PostHog Cloud terms); consult upstream before commercial use.
