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
set -euo pipefail

: "${clickhouse_hostname:?}"
: "${clickhouse_portHttp:?}"
: "${clickhouse_superUser:?}"
: "${clickhouse_superUserPassword:?}"
: "${kafka_hostname:?}"
: "${kafka_port:?}"
: "${kafka_user:?}"
: "${kafka_password:?}"

CH="http://${clickhouse_hostname}:${clickhouse_portHttp}/"
AUTH="-u ${clickhouse_superUser}:${clickhouse_superUserPassword}"

curl -sf $AUTH --data "CREATE DATABASE IF NOT EXISTS posthog ON CLUSTER zerops ENGINE = Atomic" "$CH"

curl -sf $AUTH --data "CREATE USER IF NOT EXISTS default IDENTIFIED WITH no_password ON CLUSTER zerops" "$CH"

curl -sf $AUTH --data "GRANT SELECT, INSERT, ALTER, CREATE, DROP, TRUNCATE, OPTIMIZE, SHOW, dictGet ON posthog.* TO default ON CLUSTER zerops" "$CH"

curl -sf $AUTH --data "CREATE NAMED COLLECTION IF NOT EXISTS msk_cluster ON CLUSTER zerops AS kafka_broker_list = '${kafka_hostname}:${kafka_port}', kafka_security_protocol = 'SASL_PLAINTEXT', kafka_sasl_mechanism = 'PLAIN', kafka_sasl_username = '${kafka_user}', kafka_sasl_password = '${kafka_password}'" "$CH"
