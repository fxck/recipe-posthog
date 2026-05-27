#!/usr/bin/env bash
# Apply Cyclotron's sqlx migrations against the dedicated cyclotrondb Postgres database.
#
# Cyclotron is PostHog's Rust-based job queue. The compiled native node addon ships inside
# posthog/posthog-node, but the schema migration SQL doesn't — it lives only in PostHog's
# Rust source tree at rust/cyclotron-core/migrations/.
#
# We fetch the SQL from raw.githubusercontent.com and apply via psql. Idempotent — sqlx-style
# migrations are run inside a single transaction with `IF NOT EXISTS` guards.
set -euo pipefail

: "${CYCLOTRONDB_USER:?}"
: "${CYCLOTRONDB_PASSWORD:?}"
: "${CYCLOTRONDB_DBNAME:?}"

# Pin to master — PostHog's image is :latest, this keeps the moving parts aligned
BASE="https://raw.githubusercontent.com/PostHog/posthog/master/rust/cyclotron-core/migrations"
MIGRATIONS=(
  20240804122549_initial_job_queue_schema.sql
  20240823191751_bytes_over_text.sql
  20250205162334_fix_dequeue_index.sql
  20260115221204_add_parent_run_id_column.sql
  20260121092625_add_canceled_job_state.sql
)

export PGPASSWORD="$CYCLOTRONDB_PASSWORD"
PSQL="psql -h cyclotrondb -p 5432 -U $CYCLOTRONDB_USER -d $CYCLOTRONDB_DBNAME -v ON_ERROR_STOP=1"

# Track applied migrations in a tiny table so re-runs are idempotent
$PSQL -c "CREATE TABLE IF NOT EXISTS _zerops_recipe_applied (name TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())"

for migration in "${MIGRATIONS[@]}"; do
  already=$($PSQL -tA -c "SELECT 1 FROM _zerops_recipe_applied WHERE name = '$migration'")
  if [ -n "$already" ]; then
    echo "skip $migration (already applied)"
    continue
  fi
  echo "apply $migration"
  curl -fsSL "$BASE/$migration" | $PSQL
  $PSQL -c "INSERT INTO _zerops_recipe_applied (name) VALUES ('$migration')"
done
