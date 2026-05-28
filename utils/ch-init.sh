#!/usr/bin/env bash
# One-time ClickHouse bootstrap — runs from web's initCommands.
#
# PostHog assumes (from Cloud) that:
#   1. The target database uses the Atomic engine.
#   2. A `default` user exists on every CH node so ON CLUSTER DDL has someone to authenticate
#      as during cross-shard fan-out.
#   3. A named collection `msk_cluster` holds Kafka SASL credentials for the CH-side Kafka
#      engine tables.
#
# Zerops's fresh ClickHouse provides none of those. This script creates all three.
#
# Reads the same UPPERCASE envs web already exports (CLICKHOUSE_HTTP_URL / CLICKHOUSE_USER /
# CLICKHOUSE_PASSWORD / KAFKA_HOSTS / KAFKA_SASL_USER / KAFKA_SASL_PASSWORD). The lowercase
# ${clickhouse_*} / ${kafka_*} forms are Zerops template refs resolved into other values at
# deploy time — they aren't standalone container envs.
set -euo pipefail

: "${CLICKHOUSE_HTTP_URL:?}"
: "${CLICKHOUSE_USER:?}"
: "${CLICKHOUSE_PASSWORD:?}"
: "${KAFKA_HOSTS:?}"
: "${KAFKA_SASL_USER:?}"
: "${KAFKA_SASL_PASSWORD:?}"

CH="${CLICKHOUSE_HTTP_URL}/"
AUTH="-u ${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}"

curl -sf $AUTH --data "CREATE DATABASE IF NOT EXISTS posthog ON CLUSTER zerops ENGINE = Atomic" "$CH"

curl -sf $AUTH --data "CREATE USER IF NOT EXISTS default IDENTIFIED WITH no_password ON CLUSTER zerops" "$CH"

# Force every ALTER from `default` to wait until all replicas have applied the change before
# returning (alter_sync=2; default is 1 — wait for self only). PostHog's migrate_clickhouse
# fans ALTERs across replicas in parallel via map_hosts_by_roles; with default sync=1, the second
# replica's ALTER races against ZK replication of the first one and fails with code 517
# ("Metadata on replica is not up to date with common metadata in Zookeeper"). sync=2 serializes.
curl -sf $AUTH --data "ALTER USER default SETTINGS alter_sync = 2 ON CLUSTER zerops" "$CH"

curl -sf $AUTH --data "GRANT SELECT, INSERT, ALTER, CREATE, DROP, TRUNCATE, OPTIMIZE, SHOW, dictGet ON posthog.* TO default ON CLUSTER zerops" "$CH"

# PostHog's migrate_clickhouse queries system.clusters to discover the cluster topology
# (hostname + port + shard + replica per node). Without SELECT on system.*, that query fails with
# "Not enough privileges. To execute this query, it's necessary to have the grant SELECT ON system.clusters."
# Granting SELECT on system.* broadly because PostHog also reads system.zookeeper, system.replicas,
# system.parts, etc. during migration and as part of various ops queries.
curl -sf $AUTH --data "GRANT SELECT ON system.* TO default ON CLUSTER zerops" "$CH"

curl -sf $AUTH --data "CREATE NAMED COLLECTION IF NOT EXISTS msk_cluster ON CLUSTER zerops AS kafka_broker_list = '${KAFKA_HOSTS}', kafka_security_protocol = 'SASL_PLAINTEXT', kafka_sasl_mechanism = 'PLAIN', kafka_sasl_username = '${KAFKA_SASL_USER}', kafka_sasl_password = '${KAFKA_SASL_PASSWORD}'" "$CH"
