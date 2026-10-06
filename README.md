# Smart Factory Platform

![Python](https://img.shields.io/badge/Python-3.12-3776AB?logo=python&logoColor=white)
![SQL Server](https://img.shields.io/badge/SQL%20Server-triggers%20%2B%20analytics-CC2927)
![dbt](https://img.shields.io/badge/dbt-sqlserver-FF694B?logo=dbt&logoColor=white)
![Power BI](https://img.shields.io/badge/Power%20BI-DirectQuery-F2C811)
![scikit-learn](https://img.shields.io/badge/scikit--learn-predictive%20maintenance-F7931E?logo=scikitlearn&logoColor=white)
![Status](https://img.shields.io/badge/status-live%20in%20production-brightgreen)
![CI](https://github.com/SimonHtet/smart-factory-platform/actions/workflows/ci.yml/badge.svg)
![Plants](https://img.shields.io/badge/plants-3-blue)
![Machines](https://img.shields.io/badge/filler%20machines-23-blue)

End-to-end manufacturing data platform built for DairyPlus Co., Ltd. (Bangkok) — covering 23 Tetra Pak filler machines across 3 dairy production plants.

Built in-house after a vendor MES was quoted at ฿3M+ — the purchase was never needed. The production-operations core went live across all 3 plants within 6 months of an 18-month internal plan and runs daily in production; SAP raw-material integration is in progress (~50% of full scope delivered).

---

## 🏆 Achievements

- **฿3M+ vendor purchase averted** — the quoted MES was never bought; this platform replaced it
- **6 months to live** across all 3 plants, against an 18-month internal plan
- **23 machines, 1-second polling** — sub-second SQL trigger event capture alongside a Python pipeline, running daily in production
- **16+ Budibase low-code apps, 100+ daily active users** on the production floor, fed by this platform
- **Director-level KPIs** — Power BI efficiency/waste/yield dashboard reviewed weekly by management
- **Recall-grade traceability** — reel → pallet genealogy that reverse-maps any finished pallet to its supplier reels
- **Root-caused a silent data-corruption incident** — a write-audit trap caught a second writer overwriting PLC counters; hardened with a guard trigger (`TRI_CPB_FEED_GUARD`) that makes the regression impossible
- **Formalized into company SOP** — the platform's change management and architecture are codified in the official Digital Transformation SOP (DTO-SOP-001, ISO/IEC 27001 aligned), approved at management level

**The KPI dashboard, reviewed weekly at director level:**

![KPI Scorecard](dashboard/screenshots/kpi-scorecard.png)

More pages (hourly trends, per-product breakdown) and the DAX behind them → [`dashboard/`](dashboard/).

---

## What's in Here

| Folder | Description |
|--------|-------------|
| [`pipeline/`](pipeline/) | Python event pipeline — polls PLC data at 1-second intervals, processes machine step transitions |
| [`pipeline/dbt/`](pipeline/dbt/) | dbt-sqlserver transformation layer — staging + marts, tested (`_models.yml`), plus the WMS ingest scripts |
| [`pipeline/sql/`](pipeline/sql/) | SQL triggers and utility scripts — full version history in [`docs/trigger-engineering-log.md`](docs/trigger-engineering-log.md) |
| [`dashboard/`](dashboard/) | Power BI KPI dashboard — machine efficiency, yield, waste, reviewed at director level |
| [`notebooks/`](notebooks/) | Predictive maintenance prototype — scikit-learn on OPMS sensor data |

---

## Current State

**Deployed to production:** `TRI_UPDATE_FILLER_V6.4` — fixes the root cause behind V6.2's feed-attribution bug: batch selection for the feed paths now requires an actually **running** batch (`[Splicing time 1] IS NOT NULL AND [end time] IS NULL`), not just "no CIP yet."

The short version: V6.1 added power-cut downtime capture and went live cleanly. The very next fix on top of it (V6.2, a feed-counter stash) shipped with its own bug, found a day later. Chasing that bug down (V6.3) surfaced a *deeper*, pre-existing bug one layer down — a batch-selection query that looked like a "current batch" filter but wasn't, fixed in V6.4. Full trail, with the actual `t_log` evidence that cracked it, is in [`docs/trigger-engineering-log.md`](docs/trigger-engineering-log.md).

**WMS ingest is also paused** pending an internal IT security review and Change Request (`ingest_wms.py`, under `pipeline/dbt/ingestion/`). Power BI is temporarily pointed at `analytics.temp_production_run` (a WMS-free fallback table) instead of the dbt `mart_production_runs_view`, and reverts once ingest is reinstated.

---

## Architecture

```
PLC Hardware (23 Tetra Pak fillers)
    │
    ▼
OPMS Server (172.22.x.x) — Tetra Pak proprietary system
  Collects PLC machine state in real time.
  Read-only access — OPMS writes directly into DB_BUDIBASE.dbo.T_M_Filler_Process.
    │
    ▼
WMS Server (172.22.x.x) — WMSDairyPlus2015
  Finished goods tracking — carton scanning, product resends.
  Read-only access.  [INGEST PAUSED — IT security review]
    │
    │  SQL Trigger V6.4                Python ingest_wms.py
    │  fires on T_M_Filler_Process    every 5 min via Task Scheduler
    │  (event-driven, sub-second)     [PAUSED]
    ▼                                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                 DB_BUDIBASE  172.22.x.x  (db_owner)             │
│                                                                 │
│  dbo.*                         analytics.*                      │
│  ──────────────────            ─────────────────────────────    │
│  T_M_Filler_Process            temp_production_run  ◄── live    │
│  [Change paper brik]           v_group_production_run           │
│  [Change strip]                raw_wms_*  (ingest landing)      │
│  Down_log          (mini)      stg_*  (dbt views)               │
│  Big_Downtime_log  (big)       mart_production_runs  (paused)   │
│  DE_Downtime_log   (DE)                                         │
│  Feed_Segment_log  (resets)                                     │
│  Reel_Splice_log   (recall)                                     │
│  t_log                                                          │
└──────────────────────┬──────────────────────────────────────────┘
                       │
            ┌──────────┴──────────┐
            ▼                     ▼
      Power BI               Budibase Apps
      temp_production_run    16+ apps, 100+ DAU
      (temporary source)
```

**Normal data flow (WMS active):** `PLC → T_M_Filler_Process → [Change paper brik] + WMS raw_wms_* → mart_production_runs (dbt, every 10 min) → Power BI`
**Current data flow (WMS paused):** `PLC → T_M_Filler_Process → temp_production_run (event-driven trigger) → Power BI`

Trigger-side downtime/counter capture (four independent episode logs, how they fold back into the batch row) is diagrammed in [`docs/trigger-engineering-log.md`](docs/trigger-engineering-log.md#downtime--counter-capture-trigger-side).

---

## Reel → Pallet Traceability & DE-Line Downtime Isolation

Two of the platform's more involved pieces of domain logic — reverse-traceability for product recall (reel → pallet genealogy) and isolating upstream DE-line stalls from the filler's own downtime — are documented in full in [`docs/trigger-engineering-log.md`](docs/trigger-engineering-log.md).

---

## 🤖 Machine Learning

### Predictive Maintenance — Breakdown Risk Scoring

[`notebooks/predictive_maintenance_prototype.ipynb`](notebooks/predictive_maintenance_prototype.ipynb)

Random Forest classifier (scikit-learn) that scores each filler machine's **breakdown risk as a continuous 0–100% probability** — shifting maintenance from reactive to proactive. Features are the same signals the live pipeline already collects:

| Feature | Source | Why it matters |
|---|---|---|
| `Running_Hour` | PLC odometer counter | Wear accumulates with runtime |
| `Heat_C` | Temperature sensor | Abnormal heat = friction or lubrication failure |
| `Vibration` | Vibration sensor | Imbalance or bearing wear shows up here first |

`predict_proba` risk scores feed a threshold-based maintenance alert (≥70% ⇒ flag for inspection), and `feature_importances_` shows which sensor signals matter most — useful for prioritising sensor calibration. Currently a prototype on simulated data; the production path (live `pyodbc` telemetry → retrain on historical breakdown labels → SQL Server Agent inference per shift → risk scores back to Power BI alert tiles) rides entirely on infrastructure that already exists in `pipeline/`.

### Jarvis for the Factory Floor — GenAI over Production Data

Databricks hackathon project: a GenAI assistant that answers natural-language questions over this platform's production data — "which machine had the most downtime last week?", "show me waste% by product" — without the asker needing SQL. Built on the same layered data model (raw signals → event processing → marts) that powers the Power BI reporting.

### Next: MLOps

Airflow and MLflow are approved under the company Digital Transformation SOP (DTO-SOP-001) — the orchestration and experiment-tracking layer for moving the predictive maintenance model from notebook prototype to scheduled, versioned production inference.

---

## mart_production_runs — Column Reference

*(Full mart available when WMS ingest is active)*

| Column | Source | Formula |
|---|---|---|
| run_key | [Change paper brik] | YYYYMMDD + machine |
| product_date | [Change paper brik] | Production date |
| plan_production_date | stg_wms_transactions | Via ReceivedNo → receive_item |
| start_time / end_time | [Change paper brik] | Splice time / end time |
| run_duration_minutes | derived | DATEDIFF(minute, start, end) |
| in_feed_mc / out_feed_mc | [Change paper brik] | TBA meter counts |
| waste_tba | derived | in_feed_mc − out_feed_mc |
| scanned_briks | [Change paper brik] | Barcode scanner total |
| waste_op | derived | scanned_briks − in_feed_mc |
| transaction_briks | stg_wms_transactions | SUM(in_carton_amount × numbit) |
| resend_briks | stg_wms_receive_item_location | SUM(resend_amount × numbit) |
| fg_briks_amount | derived | transaction_briks − resend_briks |
| waste_de | derived | out_feed_mc − fg_briks_amount |
| efficiency | derived | fg_briks_amount / (run_duration_minutes × 400) |
| downtime_count | [Change paper brik] | V5.3 trigger |
| total_downtime_seconds | [Change paper brik] | V5.3 trigger |

---

## Tech Stack

| Layer | Technology |
|-------|------------|
| Event pipeline | Python 3.12, pyodbc |
| WMS ingest | Python 3.12, pyodbc, watermark-based incremental |
| Transformation | dbt-sqlserver |
| Database | SQL Server (on-premise, 3 servers) |
| BI / Reporting | Power BI — DirectQuery |
| Orchestration | Windows Task Scheduler (Airflow planned) |
| Source data | Tetra Pak PLC → OPMS → SQL Server |

---

## Deep Dives

- [`docs/trigger-engineering-log.md`](docs/trigger-engineering-log.md) — full SQL trigger version history (V3 → V6.4), the power-cut/feed-counter bug chain, reel→pallet traceability, and DE-line downtime isolation
- [`pipeline/README.md`](pipeline/README.md) — why triggers alone don't scale, the Python poll-loop architecture, and the shadow-deployment migration strategy
- [`dashboard/README.md`](dashboard/README.md) — dashboard pages, DAX measures, and data sources
