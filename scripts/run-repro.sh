#!/usr/bin/env bash
# Seed → CREATE SINK INTO → wait for backfill catalogs to clear →
# snapshot counts → stream-key move (#26713) → compare counts.
#
# EXPECT=report (default): exit 1 if the bug is visible, 0 if not.
# EXPECT=bug:             exit 0 if the bug is visible, 1 if not.
# EXPECT=fix:             exit 0 if the check passes, 1 if the bug is still there.
set -euo pipefail

export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-4566}"
export PGDATABASE="${PGDATABASE:-dev}"
export PGUSER="${PGUSER:-root}"
export PGPASSWORD="${PGPASSWORD:-}"

N_USERS="${N_USERS:-500}"
EXPECT="${EXPECT:-report}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PSQL=(psql -X -v ON_ERROR_STOP=1)

echo "=== RisingWave version ==="
"${PSQL[@]}" -c "SELECT version();"

echo "=== Seed schema (N_USERS=${N_USERS} EXPECT=${EXPECT}) ==="
"${PSQL[@]}" -f "${ROOT}/sql/seed.sql"

echo "=== Insert ${N_USERS} users ==="
# RisingWave does not accept PostgreSQL typed literals (`timestamptz '…'`).
"${PSQL[@]}" <<SQL
INSERT INTO users (user_id, created_at)
SELECT
  'aaaaaaaa-bbbb-4ccc-8ddd-' || lpad(g::text, 12, '0'),
  '2024-01-01 00:00:00+00'::timestamptz + (g * interval '1 minute')
FROM generate_series(1, ${N_USERS}) AS g;
SQL

echo "=== Insert join_side (active + spare per user) ==="
"${PSQL[@]}" <<SQL
INSERT INTO join_side (join_id, user_id, owner_user_id, slot)
SELECT
  'a-' || user_id,
  user_id,
  user_id,
  'active'
FROM users
UNION ALL
SELECT
  's-' || user_id,
  'zzzzzzzz-ffff-4ccc-8ddd-000000000000',
  user_id,
  'spare'
FROM users;
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

read_counts() {
  # users_n|family_src|join_n|wide_rows|wide_spine_nz|wide_metric_nz|wide_ao_nz
  "${PSQL[@]}" -Atc "
    SELECT
      (SELECT COUNT(*) FROM users),
      (SELECT COUNT(*) FROM family_metrics),
      (SELECT COUNT(*) FROM join_side),
      (SELECT COUNT(*) FROM wide_user),
      (SELECT COUNT(*) FILTER (WHERE account_created_at IS NOT NULL) FROM wide_user),
      (SELECT COUNT(*) FILTER (WHERE metric_lt <> 0) FROM wide_user),
      (SELECT COUNT(*) FILTER (WHERE metric_ao <> 0) FROM wide_user);
  " | tr '|' ' '
}

wait_idle "after CREATE SINK" 240

echo "=== Phase 1: snapshot backfill counts (catalogs idle) ==="
"${PSQL[@]}" -f "${ROOT}/sql/check.sql"
"${PSQL[@]}" -c "SELECT * FROM rw_catalog.rw_ddl_progress;"
"${PSQL[@]}" -c "SELECT job_name, upstream_table_name, progress FROM rw_catalog.rw_fragment_backfill_progress;" 2>/dev/null || true

read -r users_n family_src join_n wide_rows snap_spine snap_metric snap_ao < <(read_counts)
echo "snapshot: users_n=${users_n} family_src=${family_src} join_n=${join_n} wide_rows=${wide_rows} wide_spine_nz=${snap_spine} wide_metric_nz=${snap_metric} wide_ao_nz=${snap_ao}"

echo "=== Phase 2: stream-key move (join row hops to spare join_id, one barrier) ==="
"${PSQL[@]}" -f "${ROOT}/sql/swap_join_keys.sql"

# Give the upsert sink a moment to apply the barrier, then require idle catalogs.
sleep 3
wait_idle "after stream-key move" 60

echo "=== Phase 2 counts ==="
"${PSQL[@]}" -f "${ROOT}/sql/check.sql"

read -r users_n family_src join_n wide_rows wide_spine_nz wide_metric_nz wide_ao_nz < <(read_counts)
echo "after_swap: users_n=${users_n} family_src=${family_src} join_n=${join_n} wide_rows=${wide_rows} wide_spine_nz=${wide_spine_nz} wide_metric_nz=${wide_metric_nz} wide_ao_nz=${wide_ao_nz}"

threshold_num=$(( family_src * 95 / 100 ))

snap_underfill=0
if [[ "${snap_metric}" -lt "${threshold_num}" || "${snap_ao}" -lt "${threshold_num}" || "${snap_spine}" -lt "${threshold_num}" ]]; then
  snap_underfill=1
fi

# #26713 signature: Delete+Insert for the same PK wipes columns other sinks wrote.
# metric_lt is rewritten by the join Insert; spine / force_append_only are not.
keymove_wipe=0
if [[ "${wide_spine_nz}" -lt "${threshold_num}" || "${wide_ao_nz}" -lt "${threshold_num}" ]]; then
  keymove_wipe=1
fi

bug=0
if [[ "${snap_underfill}" -eq 1 || "${keymove_wipe}" -eq 1 ]]; then
  bug=1
fi

echo ""
echo "=== Verdict ==="
echo "snapshot underfill=${snap_underfill} (spine=${snap_spine} metric_lt=${snap_metric} metric_ao=${snap_ao} / ${family_src})"
echo "key-move wipe=${keymove_wipe} (spine=${wide_spine_nz} metric_lt=${wide_metric_nz} metric_ao=${wide_ao_nz} / ${family_src})"

if [[ "${bug}" -eq 1 ]]; then
  echo "BUG REPRODUCED: SINK INTO + DO UPDATE IF NOT NULL lost columns (RisingWave #26713 class)."
  if [[ "${EXPECT}" == "bug" ]]; then
    echo "EXPECT=bug: this is the intended result on the broken baseline image."
    exit 0
  fi
  if [[ "${EXPECT}" == "fix" ]]; then
    echo "EXPECT=fix: this image still shows the bug."
    exit 1
  fi
  exit 1
fi

echo "NOT REPRODUCED on this build: spine/metric/ao remain filled after snapshot and stream-key move."
if [[ "${EXPECT}" == "bug" ]]; then
  echo "EXPECT=bug: harness did not observe underfill/wipe on this image."
  exit 1
fi
exit 0
