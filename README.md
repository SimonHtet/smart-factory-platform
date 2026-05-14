# Smart Factory Platform

End-to-end manufacturing data platform built for DairyPlus Co., Ltd. (Bangkok) — covering 23 Tetra Pak filler machines across 3 dairy production plants.

Built in-house to replace a ฿3M+ vendor quote for custom MES trigger logic and reporting. Delivered in 6 months against an 18-month vendor timeline.

---

## What's in Here

| Folder | Description |
|--------|-------------|
| [`pipeline/`](pipeline/) | Python event pipeline — polls PLC data at 1-second intervals, processes machine step transitions |
| [`pipeline/dbt/`](pipeline/dbt/) | dbt transformation layer — staging models, mart, and WMS ingest scripts |
| [`dashboard/`](dashboard/) | Power BI KPI dashboard — machine efficiency, yield, waste analysis, reviewed at director level |
| [`notebooks/`](notebooks/) | Predictive maintenance prototype — scikit-learn on OPMS sensor data |

---

## Architecture

```
PLC Hardware (23 Tetra Pak fillers)
    │
    ▼
OPMS Server (172.22.x.x) — Tetra Pak proprietary system
  Collects PLC machine state in real time.
  Read-only access — vendor-owned, cannot create tables here.
  OPMS writes machine state directly into DB_BUDIBASE.dbo.T_M_Filler_Process.
    │
    ▼
WMS Server (172.22.x.x) — WMSDairyPlus2015
  Finished goods tracking — carton scanning, product resends.
  Read-only access — must pull data into DB_BUDIBASE to transform.
    │
    │  Python ingest_wms.py          SQL Trigger V4
    │  every 5 min                   fires on every write to
    │  (Task Scheduler)              T_M_Filler_Process
    ▼                                (event-driven, sub-second)
┌──────────────────────────────────────────────────────────────────┐
│                  DB_BUDIBASE  172.22.x.x  (db_owner)            │
│  Only server where Simon can create tables and run dbt.          │
│  All cross-system joins happen here after data lands.            │
│                                                                  │
│  dbo.*                          analytics.*                      │
│  ──────────────────             ────────────────────────────     │
│  T_M_Filler_Process             raw_wms_*  (ingest landing)      │
│  [Change paper brik]            stg_*      (dbt views)           │
│  Down_log                       mart_production_runs  (table)    │
│  t_log                          mart_production_runs_view        │
└──────────────────────┬───────────────────────────────────────────┘
                       │  dbt run every 10 min (Task Scheduler)
            ┌──────────┴──────────┐
            ▼                     ▼
      Power BI               Budibase Apps
      DirectQuery            16+ apps, 100+ DAU
      mart_production
      _runs_view
```

---

## Data Flow (5 layers)

```
Layer 1 — Sources
  PLC → OPMS app → DB_BUDIBASE.dbo (via SQL Trigger V4)
  WMS Server → Python ingest → DB_BUDIBASE.analytics.raw_wms_*

Layer 2 — Ingestion  (ingest_wms.py, every 5 min)
  tbl_Transaction          ──incremental──► raw_wms_transactions
  tbl_ReceiveItem          ──full reload──► raw_wms_receive_item
  tbl_ReceiveItemLocation  ──incremental──► raw_wms_receive_item_location
  mst_Product              ──full reload──► raw_wms_mst_product

Layer 3 — dbt Staging  (views)
  [Change paper brik] ──► stg_change_paper_brik
  raw_wms_receive_item ──► stg_wms_receive_item
  raw_wms_transactions + stg_wms_receive_item + raw_wms_mst_product ──► stg_wms_transactions
  raw_wms_receive_item_location ──► stg_wms_receive_item_location

Layer 4 — dbt Mart  (physical table, rebuilt every 10 min)
  stg_change_paper_brik + stg_wms_transactions + stg_wms_receive_item_location
      ──► mart_production_runs

Layer 5 — Consumption  (view, always live)
  mart_production_runs ──► mart_production_runs_view
      Adds: week_label, date_status, waste_pct, waste_tba_pct, downtime_minutes
      ──► Power BI DirectQuery (KPI dashboard, director level)
```

---

## SQL Trigger — TRI_UPDATE_FILLER_V4

For events that require sub-second capture (splice signals pulse in ~10ms — too fast for a 1-second Python poll), a SQL trigger runs alongside the Python pipeline. V4 adds downtime tracking on top of the splice/CIP logic from V3.

**Downtime events logged to `[Down_log]`:**

| Transition | Event | What's recorded |
|---|---|---|
| Step 11 → 8 | `START` | Machine, Batch_ID, stop count |
| Step 8 → 9 | `END` | Duration in seconds, cumulative total |
| Step 8 → 7 | `ABORT` | In-progress stop undone — previous valid stops preserved |

> `[Down_log]` is a structured audit table — queryable per machine/batch unlike the raw text in `t_log`. "Breakdown" in company terms means >30 min; that classification is applied at the reporting layer from `Total_Downtime_Seconds`.

→ See [`pipeline/sql/TRI_UPDATE_FILLER_V4.sql`](pipeline/sql/TRI_UPDATE_FILLER_V4.sql)

---

## mart_production_runs — Column Reference

| Column | Source | Formula |
|---|---|---|
| run_key | stg_change_paper_brik | YYYYMMDD + machine |
| product_date | stg_change_paper_brik | Production date |
| plan_production_date | stg_wms_transactions | Via ReceivedNo → receive_item |
| start_time / end_time | stg_change_paper_brik | Splice time / end time |
| run_duration_minutes | derived | DATEDIFF(minute, start, end) |
| in_feed_mc / out_feed_mc | stg_change_paper_brik | TBA meter counts |
| waste_tba | derived | in_feed_mc + 150 - out_feed_mc (live) / in_feed_mc - out_feed_mc (complete) |
| scanned_briks | stg_change_paper_brik | Barcode scanner total |
| waste_op | derived | scanned_briks - in_feed_mc |
| transaction_briks | stg_wms_transactions | SUM(in_carton_amount × numbit) |
| resend_briks | stg_wms_receive_item_location | SUM(resend_amount × numbit) |
| fg_briks_amount | derived | transaction_briks - resend_briks |
| waste_de | derived | out_feed_mc - fg_briks_amount |
| efficiency | derived | fg_briks_amount / (run_duration_minutes × 400) |
| downtime_count | stg_change_paper_brik | V4 trigger (0 if no stoppages) |
| total_downtime_seconds | stg_change_paper_brik | V4 trigger (0 if no stoppages) |

---

## Tech Stack

| Layer | Technology |
|-------|------------|
| Event pipeline | Python 3.12, pyodbc |
| WMS ingest | Python 3.12, pyodbc, watermark-based incremental |
| Transformation | dbt-sqlserver |
| Database | SQL Server (on-premise, 3 servers) |
| BI / Reporting | Power BI — DirectQuery on mart view |
| Orchestration | Windows Task Scheduler (Airflow planned) |
| Source data | Tetra Pak PLC → OPMS → SQL Server |
