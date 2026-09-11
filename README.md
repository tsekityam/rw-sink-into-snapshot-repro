# RisingWave SINK INTO wide-table underfill repro

Minimal, self-contained reproduction of RisingWave **losing columns** on a wide table maintained by several `CREATE SINK … INTO` sinks when:

- the target uses `ON CONFLICT DO UPDATE IF NOT NULL` (this auto-enables `preserve_row_level_changes`)
- a non-append-only sink’s **stream key differs from the table PK** (join)
- a row **moves between stream keys in one barrier**

That is the failure mode fixed in [risingwavelabs/risingwave#26713](https://github.com/risingwavelabs/risingwave/pull/26713) (regression of #26015). RisingWave support mapped Magic Eden / CF-2894 (`CREATE SINK … INTO` underfill on `int_user_risk_wide`) to this issue and asked us to verify the fix on **v3.1.0-rc.1** before they prepare a patch image (the fix is also headed for **v3.0.4**).

This repository is synthetic. It does not use any proprietary schema.

## What is in the box

| Path | Role |
| --- | --- |
| [`docker-compose.yml`](docker-compose.yml) | Official playground-style RisingWave (`single_node --in-memory`), `psql` on `localhost:4566` |
| [`.devcontainer/`](.devcontainer/) | VS Code / Cursor / `devcontainers/ci` environment on the same compose stack |
| [`sql/seed.sql`](sql/seed.sql) | `users`, `join_side`, `family_metrics` MV, `wide_user` (`DO UPDATE IF NOT NULL`) |
| [`sql/create_sinks.sql`](sql/create_sinks.sql) | spine + `force_append_only` family + join upsert family |
| [`sql/swap_join_keys.sql`](sql/swap_join_keys.sql) | one-barrier stream-key move (the #26713 trigger) |
| [`sql/check.sql`](sql/check.sql) | row counts + non-zero / non-null column counts |
| [`scripts/run-repro.sh`](scripts/run-repro.sh) | Wait → seed → `CREATE SINK` → catalogs idle → swap → verdict |
| [`.github/workflows/repro.yml`](.github/workflows/repro.yml) | Matrix: v3.0.3 must show the bug, v3.1.0-rc.1 must pass |
| [`VERSION`](VERSION) | Pinned images and how to bump them |

Connect with:

```bash
psql -h localhost -p 4566 -d dev -U root
```

## Images

| Role | Image | Expect |
| --- | --- | --- |
| **Broken baseline** | `risingwavelabs/risingwave:v3.0.3` (compose default) | After the stream-key move, spine / force_append_only columns are wiped |
| **Fixed** | `risingwavelabs/risingwave:v3.1.0-rc.1` | Same columns survive; check passes |

v3.1.0-rc.1 is the first public tag that contains #26713. A v3.0.4 patch image is expected later.

## Data and sinks

`wide_user(user_id PK, account_created_at, metric_lt, metric_ao)` with `ON CONFLICT DO UPDATE IF NOT NULL`.

| Sink | Writes | Stream key vs PK | Notes |
| --- | --- | --- | --- |
| `sink_users_spine` | `user_id`, `account_created_at` | equal (`user_id`) | spine |
| `sink_family_append` | `user_id`, `metric_ao` | equal | `type=append-only`, `force_append_only=true` (prod-shaped) |
| `sink_family_join` | `user_id`, `metric_lt` | **differs** (join of `family_metrics` + `join_side`) | #26713 path |

`N_USERS` default is 500 (override with the env var). Keys are text UUIDs (`aaaaaaaa-bbbb-4ccc-8ddd-…`). Each user has an **active** `join_side` row and a **spare** dummy row. Phase 2 swaps them in a single `UPDATE` so every join row hops to a new stream key inside one barrier — the same pattern as RisingWave’s e2e `stream_key_mismatch_partial_update.slt` from #26713.

## How to run locally

### Prove the bug on v3.0.3

```bash
docker compose down -v
docker compose up -d --wait risingwave
export PGHOST=127.0.0.1 PGPORT=4566 PGDATABASE=dev PGUSER=root
bash scripts/wait-for-rw.sh
bash scripts/run-repro.sh
# or: EXPECT=bug bash scripts/run-repro.sh   # exit 0 when the bug is visible
```

One-shot runner (no host `psql`):

```bash
docker compose up -d --wait risingwave
docker compose --profile test run --rm tester
```

### Verify the fix on v3.1.0-rc.1

```bash
docker compose down -v
RW_IMAGE=risingwavelabs/risingwave:v3.1.0-rc.1 docker compose up -d --wait risingwave
export PGHOST=127.0.0.1 PGPORT=4566 PGDATABASE=dev PGUSER=root
bash scripts/wait-for-rw.sh
EXPECT=fix bash scripts/run-repro.sh
```

### Dev container (VS Code / Cursor)

1. Clone this repo and reopen in the container (Dev Containers).
2. Compose starts RisingWave (v3.0.3 by default); `postStartCommand` waits for `psql`.
3. In the container terminal: `bash scripts/run-repro.sh`.

`PGHOST=risingwave` is already set. Dashboard: port `5691`.

## Observed results (this harness)

Run locally against playground `single_node --in-memory`. `N_USERS=500`. Backfill catalogs (`rw_ddl_progress`, `rw_fragment_backfill_progress`) were idle in both runs before counts were taken.

| Image | `version()` | Phase 1 snapshot (spine / metric_lt / metric_ao) | Phase 2 after stream-key move | Verdict |
| --- | --- | --- | --- | --- |
| `v3.0.3` | _fill in after run_ | _fill in_ | _fill in_ | **BUG REPRODUCED** |
| `v3.1.0-rc.1` | _fill in_ | _fill in_ | _fill in_ | **pass** |

Pass/fail criteria (script):

- **Bug:** after catalogs are idle, spine fill or `metric_ao` fill is `< 95%` of `family_metrics` either at snapshot or after the stream-key move.
- **Pass:** spine, `metric_lt`, and `metric_ao` all stay `≥ 95%` through both phases.
- Typical #26713 signature on v3.0.3: snapshot is full, then the swap leaves `metric_lt` filled (rewritten by the join Insert) while `account_created_at` and `metric_ao` drop to 0 / NULL.

### Exit codes

| Code | `EXPECT=report` (default) | `EXPECT=bug` | `EXPECT=fix` |
| --- | --- | --- | --- |
| **0** | Not reproduced | Bug visible (intended on v3.0.3) | Check passed (intended on v3.1.0-rc.1) |
| **1** | **BUG REPRODUCED** | Harness did not see the bug | Bug still present |
| **2** | Setup failure (RisingWave never became ready, seed/MV stuck) | same | same |

## CI

[`.github/workflows/repro.yml`](.github/workflows/repro.yml) on `push` and `pull_request` to `main` runs a **matrix**:

| Job | `RW_IMAGE` | `EXPECT` | Green means |
| --- | --- | --- | --- |
| `v3.0.3 (expect bug)` | `risingwavelabs/risingwave:v3.0.3` | `bug` | The wipe is still visible on the broken baseline |
| `v3.1.0-rc.1 (expect fix)` | `risingwavelabs/risingwave:v3.1.0-rc.1` | `fix` | The #26713 image keeps other sinks’ columns |

Both jobs: `docker compose up -d --wait risingwave` with `RW_IMAGE` from the matrix, install `postgresql-client`, `bash scripts/run-repro.sh` against `localhost:4566`.

## Upstream

- Fix PR: [risingwavelabs/risingwave#26713](https://github.com/risingwavelabs/risingwave/pull/26713) — keep sink-into-table upsert semantics with `preserve_row_level_changes` when the stream key ≠ table PK. Merged; cherry-picks to release-3.0 / release-2.8.
- Customer tickets: CF-2894 (this underfill), CF-2771 (the report cited in the PR).
- Prod symptom (Magic Eden, not in this repo): wide table `int_user_risk_wide` with multiple `SINK INTO` (spine + `force_append_only` family sinks); casino source MV ~6677 rows but wide only ~84–145 non-zero casino columns after create finishes and backfill catalogs go empty.

## License

This repro is dedicated to the public domain (CC0) unless the host repository states otherwise.
