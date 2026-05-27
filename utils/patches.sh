#!/usr/bin/env bash
# Patch PostHog source for Zerops's runtime model. All in-place sed edits to
# /opt/posthog/code/... after the image filesystem has been extracted by init.sh.
#
# Usage: bash utils/patches.sh <role>
#   role = web | worker | pluginserver
#
# Pluginserver doesn't need source patches — its quirks are handled entirely via env vars
# in zerops.yml. The patches below all apply to PostHog's Python codebase.
set -euo pipefail

ROLE="${1:?usage: patches.sh <web|worker|pluginserver>}"

[ "$ROLE" = "pluginserver" ] && { echo "no source patches needed for pluginserver"; exit 0; }

CLUSTER_PY=/opt/posthog/code/posthog/clickhouse/cluster.py
VIEWS_PY=/opt/posthog/code/posthog/views.py
WORKER_SCRIPT=/opt/posthog/code/bin/docker-worker-celery

# Patch 1 — Zerops ClickHouse doesn't define the PostHog-Cloud-only `hostClusterType` /
# `hostClusterRole` macros. Replace the lookups with empty string literals so SQL parses.
sudo sed -i "s/getMacro('hostClusterType')/''/g; s/getMacro('hostClusterRole')/''/g" "$CLUSTER_PY"

# Patch 2 — PostHog's `__hosts_by_roles` only matches hosts whose host_cluster_role is in a
# known set. Zerops's CH hosts have an empty role; treat empty as "match-any" so single-cluster
# fan-out works.
sudo sed -i "s/host.host_cluster_role in node_roles or NodeRole.ALL in node_roles/host.host_cluster_role in node_roles or NodeRole.ALL in node_roles or not host.host_cluster_role/g" "$CLUSTER_PY"

if [ "$ROLE" = "web" ]; then
  # Patch 3 — PostHog's /_preflight/ hard-codes `"kafka": in_cloud or settings.TEST` (views.py).
  # On self-hosted both are False, so the field is always False even though Kafka is healthy,
  # and the setup wizard renders that as an Error. Force True since we run native Kafka.
  sudo sed -i 's|"kafka": in_cloud or settings.TEST,|"kafka": True,  # patched: native Kafka via SASL_PLAINTEXT|' "$VIEWS_PY"
fi

if [ "$ROLE" = "worker" ]; then
  # Patch 4 — bin/docker-worker-celery hard-codes SKIP_ASYNC_MIGRATIONS_SETUP=0 in front of the
  # celery worker command. That forces posthog.apps.ready() to call setup_async_migrations(),
  # which raises ImproperlyConfigured for the Cloud-only async migrations and the worker dies
  # before forking. Drop the override so the worker honors the SKIP=1 default web already uses.
  sudo sed -i "s/SKIP_ASYNC_MIGRATIONS_SETUP=0 //g" "$WORKER_SCRIPT"
fi
