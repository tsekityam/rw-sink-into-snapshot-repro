#!/usr/bin/env bash
# Seed → create SINK INTO sinks → wait for backfill catalogs to clear → compare counts.
set -euo pipefail

export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-4566}"
export PGDATABASE="${PGDATABASE:-dev}"
export PGUSER="${PGUSER:-root}"
export PGPASSWORD="${PGPASSWORD:-}"

N_USERS="${N_USERS:-3000}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PSQL=(psql -X -v ON_ERROR_STOP=1)

echo "=== RisingWave version ==="
"${PSQL[@]}" -c "SELECT version();"

echo "=== Seed schema (N_USERS=${N_USERS}) ==="
"${PSQL[@]}" -f "${ROOT}/sql/seed.sql"

echo "=== Insert ${N_USERS} users ==="
"${PSQL[@]}" <<SQL
INSERT INTO users (user_id, created_at)
SELECT
  format(
    'aaaaaaaa-bbbb-4ccc-8ddd-%012s',
    to_hex(g)
  ),
  timestamptz '2024-01-01 00:00:00+00' + (g || ' minutes')::interval
FROM generate_series(1, ${N_USERS}) AS g;
SQL

echo "=== Wait for family_metrics MV to catch up ==="
for i in $(seq 1 60); do
  n="$("${PSQL[@]}" -Atc "SELECT COUNT(*) FROM family_metrics;")"
  if [[ "${n}" -eq "${N_USERS}" ]]; then
    echo "family_metrics has ${n} rows."
    break
  fi
  if [[ "${i}" -eq 60 ]]; then
    echo "ERROR: family_metrics stuck at ${n}/${N_USERS}" >&2
    exit 2
  fi
  sleep 1
done

echo "=== CREATE SINK INTO (BACKGROUND_DDL=true) ==="
"${PSQL[@]}" -f "${ROOT}/sql/create_sinks.sql"

wait_idle() {
  local label="$1"
  local max="${2:-180}"
  echo "=== Waiting for DDL / fragment backfill to go idle (${label}, max ${max}s) ==="
  for i in $(seq 1 "${max}"); do
    ddl="$("${PSQL[@]}" -Atc "SELECT COUNT(*) FROM rw_catalog.rw_ddl_progress;")"
    frag="$("${PSQL[@]}" -Atc "SELECT COUNT(*) FROM rw_catalog.rw_fragment_backfill_progress;" 2>/dev/null || echo 0)"
    echo "t=${i}s ddl_progress=${ddl} fragment_backfill=${frag}"
    if [[ "${ddl}" == "0" && "${frag}" == "0" ]]; then
      # Require two consecutive idle polls (BACKGROUND_DDL can briefly clear)
      sleep 2
      ddl2="$("${PSQL[@]}" -Atc "SELECT COUNT(*) FROM rw_catalog.rw_ddl_progress;")"
      frag2="$("${PSQL[@]}" -Atc "SELECT COUNT(*) FROM rw_catalog.rw_fragment_backfill_progress;" 2>/dev/null || echo 0)"
      if [[ "${ddl2}" == "0" && "${frag2}" == "0" ]]; then
        echo "Idle confirmed."
        return 0
      fi
    fi
    sleep 1
  done
  echo "WARN: still not idle after ${max}s; continuing with counts anyway." >&2
}

wait_idle "after CREATE SINK" 240

echo "=== Counts ==="
"${PSQL[@]}" -f "${ROOT}/sql/check.sql"
"${PSQL[@]}" -c "SELECT * FROM rw_catalog.rw_ddl_progress;"
"${PSQL[@]}" -c "SELECT job_name, upstream_table_name, progress FROM rw_catalog.rw_fragment_backfill_progress;" 2>/dev/null || true

read -r users_n family_src wide_rows wide_spine_nz wide_metric_nz < <(
  "${PSQL[@]}" -Atc "
    SELECT
      (SELECT COUNT(*) FROM users),
      (SELECT COUNT(*) FROM family_metrics),
      (SELECT COUNT(*) FROM wide_user),
      (SELECT COUNT(*) FILTER (WHERE account_created_at IS NOT NULL) FROM wide_user),
      (SELECT COUNT(*) FILTER (WHERE metric_lt <> 0) FROM wide_user);
  " | tr '|' ' '
)

echo "users_n=${users_n} family_src=${family_src} wide_rows=${wide_rows} wide_spine_nz=${wide_spine_nz} wide_metric_nz=${wide_metric_nz}"

# Expectation: after snapshot backfill, every family key lands in wide.
# Prod observation: family_src≈6677, wide_metric_nz≈145 after CREATE (+ recreate).
threshold_num=$(( family_src * 95 / 100 ))
if [[ "${wide_metric_nz}" -lt "${threshold_num}" ]]; then
  echo ""
  echo "BUG REPRODUCED: wide metric fill ${wide_metric_nz}/${family_src} (< 95%)."
  echo "SINK INTO snapshot appears incomplete while ddl/fragment progress is idle."
  exit 1
fi

echo ""
echo "NOT REPRODUCED on this build: wide_metric_nz=${wide_metric_nz} family_src=${family_src}."
echo "Prod still saw ~145/6677 after full_refresh; try larger N_USERS or RisingWave Cloud."
exit 0
