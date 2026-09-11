# Reproduce RisingWave `SINK INTO` wide-table underfill

Minimal public harness for this symptom: after `CREATE SINK … INTO` finishes and backfill catalogs go idle, a **family source MV has many more rows than non-zero family columns on the wide table**, while the spine column looks fine. Recreating the family sinks still underfills.

This repository is synthetic. It does not use any proprietary schema.

## What is in the box

| Path | Role |
| --- | --- |
| [`docker-compose.yml`](docker-compose.yml) | Playground-style RisingWave (`single_node --in-memory`), `psql` on `localhost:4566` |
| [`.devcontainer/`](.devcontainer/) | VS Code / Cursor environment on the same compose stack |
| [`sql/seed.sql`](sql/seed.sql) | `users`, per-family event tables + MVs, `wide_user` (`DO UPDATE IF NOT NULL`) |
| [`sql/create_sinks.sql`](sql/create_sinks.sql) | spine `SINK INTO` + two `force_append_only` family sinks |
| [`sql/recreate_family_sinks.sql`](sql/recreate_family_sinks.sql) | drop + create family sinks again (second pass) |
| [`sql/check.sql`](sql/check.sql) | source counts vs wide non-zero column counts |
| [`scripts/run-repro.sh`](scripts/run-repro.sh) | seed → create → wait idle → count → recreate → count |
| [`.github/workflows/repro.yml`](.github/workflows/repro.yml) | CI matrix of the two images below |
| [`VERSION`](VERSION) | Pinned image and how to bump it |

Connect with:

```bash
psql -h localhost -p 4566 -d dev -U root
```

## Step 1 — reproduce on the current prod-class image

Pin: **`risingwavelabs/risingwave:v3.0.2`** (Docker Hub tag exists; RW support said the cluster is ~3.0.2 / ticket “3.0”).

```bash
docker compose down -v
docker compose up -d --wait risingwave
export PGHOST=127.0.0.1 PGPORT=4566 PGDATABASE=dev PGUSER=root
bash scripts/wait-for-rw.sh
N_USERS=3000 bash scripts/run-repro.sh
```

One-shot (no host `psql`):

```bash
docker compose up -d --wait risingwave
docker compose --profile test run --rm tester
```

**Pass/fail:** after `rw_ddl_progress` and `rw_fragment_backfill_progress` are idle, `family_a` / `family_b` `COUNT(*)` is ground truth. The wide table **underfills** when `COUNT(*) FILTER (WHERE metric_a <> 0)` (or `metric_b`) is **well below** that source count (script: &lt; 95%), while `account_created_at` (spine) stays populated. Pass 2 drops and recreates the family sinks so a one-off race is not enough.

## Step 2 — same SQL on a candidate build

Only after Step 1 underfills. `v3.0.4` is not released; do not invent that tag.

```bash
docker compose down -v
RW_IMAGE=risingwavelabs/risingwave:v3.1.0-rc.1 docker compose up -d --wait risingwave
export PGHOST=127.0.0.1 PGPORT=4566 PGDATABASE=dev PGUSER=root
bash scripts/wait-for-rw.sh
N_USERS=3000 bash scripts/run-repro.sh
```

This answers “does *this harness* still underfill on that image?”, not “this is production’s root cause.”

## Schema

`wide_user(user_id PK, account_created_at, metric_a, metric_b) ON CONFLICT DO UPDATE IF NOT NULL`

| Sink | Writes | Options |
| --- | --- | --- |
| `sink_users_spine` | `user_id`, `account_created_at` | default (upsert) |
| `sink_family_a` | `user_id`, `metric_a` | `type=append-only`, `force_append_only=true` |
| `sink_family_b` | `user_id`, `metric_b` | `type=append-only`, `force_append_only=true` |

`family_a` / `family_b` are `GROUP BY user_id` MVs over per-user events (every user has a non-zero sum). Default `N_USERS=3000`. `metric_*` columns use `DEFAULT 0` (load-bearing; see below).

## Observed results

Playground `single_node --in-memory`, `N_USERS=3000`. Catalogs were idle (`rw_ddl_progress` = 0, `rw_fragment_backfill_progress` = 0) before each count.

| Image | `version()` | Pass | spine_nz / users | metric_a_nz / family_a | metric_b_nz / family_b | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| `v3.0.2` | `PostgreSQL 13.14.0-RisingWave-3.0.2 (391c3a16ef26d0cd86d1236c9b7c122a9a27fb1e)` | 1 | **3000 / 3000** | **0 / 3000** | 3000 / 3000 | underfill |
| `v3.0.2` | same | 2 (recreate family sinks) | **3000 / 3000** | **0 / 3000** | 3000 / 3000 | underfill again |
| `v3.1.0-rc.1` | `PostgreSQL 13.14.0-RisingWave-3.1.0-rc.1 (e4644f6ff28b405aeb4a5937386b45f6112c2c11)` | 1 | **3000 / 3000** | **0 / 3000** | 3000 / 3000 | still underfills |
| `v3.1.0-rc.1` | same | 2 | **3000 / 3000** | **0 / 3000** | 3000 / 3000 | still underfills |

Spine is full. `family_a` source is 3000 rows with `metric_a = 3006`, but the wide column stays `0` (the table default) after both creates. `family_b` is full in these runs (last family sink).

**Step 2:** identical SQL on `v3.1.0-rc.1` did **not** clear the underfill.

A one-off probe on v3.0.2 **without** `DEFAULT 0` on `metric_a` / `metric_b` filled both families (500/500). `DEFAULT 0` is therefore load-bearing for *this* harness: RisingWave fills omitted `SINK INTO` columns with the table default, and `0` is not NULL, so `DO UPDATE IF NOT NULL` can overwrite the other family’s column.

### Exit codes

| Code | Meaning |
| --- | --- |
| **1** | **BUG REPRODUCED** (default `EXPECT=report`): both passes underfill. |
| **0** | Not reproduced: family columns ≥ 95% on both passes. |
| **2** | Setup failure (RisingWave never ready, seed/MV stuck). |

`EXPECT=bug` inverts 0/1 so a job can be green when underfill is visible.

## CI

[`.github/workflows/repro.yml`](.github/workflows/repro.yml) runs the **same** script on `v3.0.2` and `v3.1.0-rc.1` (`EXPECT=report`, `fail-fast: false`). A red job with `BUG REPRODUCED` means that image still underfills this harness.

## Context

Production (not in this repo): wide table filled by a spine `SINK INTO` plus several `force_append_only` family sinks; one family source MV had ~6677 rows but the wide table only ~84–145 non-zero columns for that family after create finished and backfill catalogs were empty.

RisingWave support (CF-2894) suggested this *might* relate to [risingwavelabs/risingwave#26713](https://github.com/risingwavelabs/risingwave/pull/26713). That is a footnote, not the goal of this repo. On this harness, **v3.1.0-rc.1 (which contains #26713) still underfills**, so this reproduction is not evidence that #26713 addresses the counts above.

## License

This repro is dedicated to the public domain (CC0) unless the host repository states otherwise.
