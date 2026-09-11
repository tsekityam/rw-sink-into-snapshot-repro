#!/usr/bin/env bash
# Seed → CREATE SINK INTO → wait for backfill catalogs to idle → count →
# recreate family sinks → count again. Underfill = family source rows
# far exceed non-zero family columns on the wide table.
#
# EXPECT=report (default): exit 1 if underfill is visible, 0 if not.
# EXPECT=bug:              exit 0 if underfill is visible, 1 if not.
set -euo pipefail

export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-4566}"
export PGDATABASE="${PGDATABASE:-dev}"
export PGUSER="${PGUSER:-root}"
export PGPASSWORD="${PGPASSWORD:-}"

N_USERS="${N_USERS:-3000}"
EXPECT="${EXPECT:-report}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PSQL=(psql -X -v ON_ERROR_STOP=1)

echo "=== RisingWave version ==="
"${PSQL[@]}" -c "SELECT version();"
echo "N_USERS=${N_USERS} EXPECT=${EXPECT} RW_IMAGE=${RW_IMAGE:-<compose default>}"

echo "=== Seed schema ==="
"${PSQL[@]}" -f "${ROOT}/sql/seed.sql"

echo "=== Insert ${N_USERS} users and family events ==="
# RisingWave rejects PostgreSQL typed literals (`timestamptz '…'`).
# DML is not visible across sessions until flush; keep load in one session.
"${PSQL[@]}" <<SQL
SET RW_IMPLICIT_FLUSH TO true;

INSERT INTO users (user_id, created_at)
SELECT
  'aaaaaaaa-bbbb-4ccc-8ddd-' || lpad(g::text, 12, '0'),
  '2024-01-01 00:00:00+00'::timestamptz + (g * interval '1 minute')
FROM generate_series(1, ${N_USERS}) AS g;

-- Three events per user so the family MV is a real GROUP BY, not a 1:1 copy.
INSERT INTO events_a (user_id, evt_id, amount)
SELECT user_id, e, (1000 + e)::numeric
FROM users, generate_series(1, 3) AS e;

INSERT INTO events_b (user_id, evt_id, amount)
SELECT user_id, e, (2000 + e)::numeric
FROM users, generate_series(1, 3) AS e;
SQL

echo "=== Wait for family MVs to catch up ==="
for i in $(seq 1 90); do
  a="$("${PSQL[@]}" -Atc "SELECT COUNT(*) FROM family_a;")"
  b="$("${PSQL[@]}" -Atc "SELECT COUNT(*) FROM family_b;")"
  if [[ "${a}" -eq "${N_USERS}" && "${b}" -eq "${N_USERS}" ]]; then
    echo "family_a=${a} family_b=${b}"
    break
  fi
  if [[ "${i}" -eq 90 ]]; then
    echo "ERROR: family_a=${a} family_b=${b} want ${N_USERS}" >&2
    exit 2
  fi
  sleep 1
done

wait_idle() {
  local label="$1"
  local max="${2:-180}"
  echo "=== Waiting for DDL / fragment backfill to go idle (${label}, max ${max}s) ==="
  for i in $(seq 1 "${max}"); do
    ddl="$("${PSQL[@]}" -Atc "SELECT COUNT(*) FROM rw_catalog.rw_ddl_progress;")"
    frag="$("${PSQL[@]}" -Atc "SELECT COUNT(*) FROM rw_catalog.rw_fragment_backfill_progress;" 2>/dev/null || echo 0)"
    echo "t=${i}s ddl_progress=${ddl} fragment_backfill=${frag}"
    if [[ "${ddl}" == "0" && "${frag}" == "0" ]]; then
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
  "${PSQL[@]}" -Atc "
    SELECT
      (SELECT COUNT(*) FROM users),
      (SELECT COUNT(*) FROM family_a),
      (SELECT COUNT(*) FROM family_b),
      (SELECT COUNT(*) FROM wide_user),
      (SELECT COUNT(*) FILTER (WHERE account_created_at IS NOT NULL) FROM wide_user),
      (SELECT COUNT(*) FILTER (WHERE metric_a <> 0) FROM wide_user),
      (SELECT COUNT(*) FILTER (WHERE metric_b <> 0) FROM wide_user);
  " | tr '|' ' '
}

print_catalogs() {
  "${PSQL[@]}" -c "SELECT * FROM rw_catalog.rw_ddl_progress;"
  "${PSQL[@]}" -c "SELECT job_name, upstream_table_name, progress FROM rw_catalog.rw_fragment_backfill_progress;" 2>/dev/null || true
}

echo "=== CREATE SINK INTO (pass 1) ==="
"${PSQL[@]}" -f "${ROOT}/sql/create_sinks.sql"
wait_idle "after CREATE SINK pass 1" 240

echo "=== Counts pass 1 (catalogs idle) ==="
"${PSQL[@]}" -f "${ROOT}/sql/check.sql"
print_catalogs
read -r users_n src_a src_b wide_rows spine1 a1 b1 < <(read_counts)
echo "pass1: users=${users_n} family_a_src=${src_a} family_b_src=${src_b} wide_rows=${wide_rows} spine_nz=${spine1} metric_a_nz=${a1} metric_b_nz=${b1}"

echo "=== Recreate family sinks (pass 2) ==="
"${PSQL[@]}" -f "${ROOT}/sql/recreate_family_sinks.sql"
wait_idle "after CREATE SINK pass 2" 240

echo "=== Counts pass 2 (catalogs idle) ==="
"${PSQL[@]}" -f "${ROOT}/sql/check.sql"
print_catalogs
read -r users_n src_a src_b wide_rows spine2 a2 b2 < <(read_counts)
echo "pass2: users=${users_n} family_a_src=${src_a} family_b_src=${src_b} wide_rows=${wide_rows} spine_nz=${spine2} metric_a_nz=${a2} metric_b_nz=${b2}"

threshold_num=$(( src_a * 95 / 100 ))

underfill1=0
underfill2=0
if [[ "${a1}" -lt "${threshold_num}" || "${b1}" -lt "${threshold_num}" ]]; then
  underfill1=1
fi
if [[ "${a2}" -lt "${threshold_num}" || "${b2}" -lt "${threshold_num}" ]]; then
  underfill2=1
fi

echo ""
echo "=== Verdict ==="
echo "pass1 underfill=${underfill1}  spine=${spine1}/${users_n}  metric_a=${a1}/${src_a}  metric_b=${b1}/${src_b}"
echo "pass2 underfill=${underfill2}  spine=${spine2}/${users_n}  metric_a=${a2}/${src_a}  metric_b=${b2}/${src_b}"

if [[ "${underfill1}" -eq 1 && "${underfill2}" -eq 1 ]]; then
  echo "BUG REPRODUCED: family source count ≫ wide non-zero family columns after idle backfill, twice."
  if [[ "${EXPECT}" == "bug" ]]; then
    exit 0
  fi
  exit 1
fi

if [[ "${underfill1}" -eq 1 || "${underfill2}" -eq 1 ]]; then
  echo "PARTIAL: underfill on one pass only (pass1=${underfill1} pass2=${underfill2}). Not treating as a stable repro."
  if [[ "${EXPECT}" == "bug" ]]; then
    exit 1
  fi
  exit 1
fi

echo "NOT REPRODUCED on this build: family columns stayed >= 95% filled on both passes."
if [[ "${EXPECT}" == "bug" ]]; then
  exit 1
fi
exit 0
