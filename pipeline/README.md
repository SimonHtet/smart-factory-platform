# Pipeline

Python event pipeline that replaces SQL Server triggers for processing machine step events across 23 Tetra Pak filler machines at 1-second polling intervals. Built to eliminate trigger-induced race conditions that caused dropped events and blocked PLC writes under concurrent load.

---

## The Problem with SQL Triggers at Scale

The original system used SQL Server triggers on `T_M_Filler_Process` to react to machine step changes — writing timestamps, infeed/outfeed counters, and CIP state to downstream tables the moment a row was updated by the PLC.

At low machine counts this worked. Across 23 machines writing simultaneously every second, it broke down:

- **Triggers run inside the originating transaction.** A slow trigger holds the row lock and blocks the next PLC write. When multiple machines fire near-simultaneously, trigger chains queue up behind each other.
- **No cooldown control.** A signal bouncing between 0 and 1 multiple times in a second fires the trigger multiple times, creating duplicate records. SQL has no built-in mechanism for "ignore repeats within N milliseconds."
- **Race conditions on step transitions.** Two machines transitioning to Step 13 within the same second could interleave trigger executions and write each other's counters to the wrong rows.
- **No visibility.** Trigger logic is opaque — no logs, no traceability, no way to replay a failed event without re-updating the source row.

The Python pipeline takes the trigger logic entirely out of SQL Server and runs it as an application-layer process that owns the state machine explicitly.

---

## Architecture

```
PLC Hardware (23 Tetra Pak fillers)
    │
    ▼
OPMS Server (172.22.x.x) — Tetra Pak proprietary system
  Collects all PLC machine state in real time.
  Writes machine state rows into DB_BUDIBASE on every state change.
    │
    ▼
T_M_Filler_Process          ← Written by OPMS (one row per machine, updated in place)
    │
    │  SELECT * every 1s
    ▼
Python Poller (main.py)
    │
    ├── previous_state dict  ← In-memory snapshot — equivalent of trigger's
    │                           deleted pseudo-table
    │
    ├── Diff current vs prev per machine
    │
    ├── Route by machine group + step transition
    │       │
    │       ├── Step 10 → handle_step10()   → write Splicing time 1
    │       ├── Step 13 → handle_step13()   → write end time + feed counters
    │       ├── Step 14 + CIP=1 → handle_step14_cip()  → write End_time_CIP
    │       └── End roll / strip signal 0→1 → handle_end_roll()
    │
    ▼
Processed Tables
    ├── [Change paper brik]    ← Paper roll change events with splice times + downtime columns
    ├── [Change strip]         ← Strip change events
    ├── [Down_log]             ← Structured downtime event log (START / END / ABORT per stop)
    ├── endtime_log_test       ← Audit log for Step 14 CIP events
    └── t_log                  ← General event log with machine/step/signal detail
```

Each poll cycle fetches all machine rows in a single query. The diff against `previous_state` detects exactly which machines changed and which signal or step transition fired. No row-level triggers. No transaction contention.

---

## Machine Groups

Machines are grouped by how they signal end-of-batch. This is encoded in `config.py` and drives which event handler fires for each machine:

| Group | Machines | End Signal |
|-------|----------|------------|
| `step14_cip` | A1, A4, A5, B1, B2, D1, D2, D3, M1, M2, M3 | Step 14 + `Signal_Final_CIP = 1` |
| `step13` | F1, F2, F3, F4, G1, G2, G3, H1, H2, H3, K1, K2 | Step 13 transition |
| `tbd` | E1, J1 | Under investigation |

Adding a new machine is a config change, not a code change.

---

## Event Handlers

### `handle_step10` — Batch Start
Fires on `Machine_Step_no` transitioning to 10. Writes `Splicing time 1` to the open record in `[Change paper brik]` and `[Change strip]` only if the column is currently NULL — idempotent against retries.

### `handle_step13` — Batch End (Step 13 group)
Fires on transition to Step 13. Writes `end time`, `In_Feed_MC`, and `Out_Feed_MC` to the open record. For A/D machines the handler also backfills `End_time_CIP` in the same write. Only acts on records where `Splicing time 1 IS NOT NULL` — guards against closing a record that was never opened.

### `handle_step14_cip` — CIP End (Step 14 group)
Fires when `Machine_Step_no = 14` AND `Signal_Final_CIP = 1`. Includes a **1-hour in-memory cooldown per machine** — the CIP signal can stay high for extended periods and this prevents repeated writes to the same record. Logs to both `endtime_log_test` and `t_log` for audit traceability.

### `handle_end_roll` — Splice Signal
Fires on the rising edge (0→1) of `Paper_Splicing_End_roll_Signal_Brik` or `Strip_Splicing_Signal_Strip`. Increments `Splicing_Count` and writes the next `Splicing time N` column. A **30-second in-memory cooldown** absorbs signal bounce — if the same machine fires again within the window, the cooldown rewrites the same timestamp column instead of creating a duplicate splice entry.

---

## SQL Trigger — TRI_UPDATE_FILLER_V4

Some events cannot be captured by a 1-second Python poll. Splice signals pulse 0→1 in ~10ms — the Python poller misses most of them. For these, a SQL trigger (`TRI_UPDATE_FILLER_V4`) runs on `T_M_Filler_Process` and captures transitions synchronously at write time.

V4 extends the splice/CIP logic from V3 with **downtime (minor stoppage) tracking**.

### Downtime Columns on `[Change paper brik]`

| Column | Type | Description |
|---|---|---|
| `Downtime_Count` | INT | Number of times machine hit step 8 this batch |
| `Total_Downtime_Seconds` | INT | Cumulative downtime in seconds across all stops |
| `Current_Downtime_Start` | DATETIME | Start of current stop (cleared on recovery) |

### Downtime Event Logic

| Step Transition | Action |
|---|---|
| 11 → 8 | Increment `Downtime_Count`, stamp `Current_Downtime_Start` |
| 8 → anything except 7 | Calculate duration, add to `Total_Downtime_Seconds`, clear start |
| 8 → 7 | Batch aborted — nullify all 3 downtime columns |

> Company definition: **breakdown = >30 min**. The trigger logs raw seconds. The reporting layer (Power BI / Budibase) applies the threshold to classify minor stoppage vs. breakdown.

### Down_log Table

Every downtime event also writes a row to `[Down_log]` — a structured audit table for verifying trigger behaviour and building downtime reports without parsing `t_log` text.

```sql
SELECT * FROM Down_log ORDER BY Log_Time DESC
-- Event: START, END, or ABORT
-- Columns: Machine, Batch_ID, Downtime_Count, Duration_Seconds, Total_Downtime_Seconds, Log_Time
```

→ Full trigger source: [`sql/TRI_UPDATE_FILLER_V4.sql`](sql/TRI_UPDATE_FILLER_V4.sql)

---

## Cooldown System

Both cooldowns are held in process memory as dicts — no additional DB table required:

```python
step14_cooldown  = {}  # { machine: last_fired_datetime }
splice_cooldown  = {}  # { "machine_table": (last_fired_datetime, splice_count) }
```

`COOLDOWN_STEP14_SECONDS = 3600`
`COOLDOWN_SPLICE_MS = 30000`

On restart the cooldowns reset. This is acceptable — a restart takes under 5 seconds and the CIP cooldown exists to suppress redundant writes during continuous operation, not across restarts.

---

## Tech Stack

| Component | Choice |
|-----------|--------|
| Runtime | Python 3.12 |
| DB driver | `pyodbc` + ODBC Driver 18 for SQL Server |
| Config | `python-dotenv` / `.env` file |
| Deployment | Windows Task Scheduler |
| Source data | Tetra Pak PLC → `T_M_Filler_Process` |

No ORM, no async framework, no message queue. The poll loop is synchronous and single-threaded — each cycle completes before the next begins. At 23 machines with ~5 possible transitions each, a full cycle processes in well under the 1-second poll budget.

---

## Running Locally

**Prerequisites:** Python 3.10+, ODBC Driver 18 for SQL Server, network access to the factory DB server.

```bash
pip install pyodbc python-dotenv

cp .env.example .env
# Edit .env with DB_SERVER, DB_NAME, DB_USER, DB_PASSWORD

python test.py    # verify connectivity
python main.py    # start the pipeline
```

---

## Migration Strategy (Shadow Deployment)

The pipeline was deployed alongside the existing triggers, not as a replacement. During the shadow phase:

1. Python runs in **read + log mode** — detects all transitions and prints what it *would* write but does not commit.
2. Output is compared against what the triggers actually wrote to verify identical behavior.
3. Machine groups are onboarded one at a time — `config.py` groups represent both the final grouping and the incremental rollout order.
4. Once a group's output matches triggers across a 48-hour window, triggers for those machines are disabled.
5. `t_log` entries tagged with `-PYTHON` allow distinguishing pipeline writes from trigger writes during overlap.

---

## Connection Resilience

The main loop wraps every cycle in a try/except. On any unhandled exception — including SQL Server connection drops — the loop attempts to reconnect and resumes from the last known `previous_state`.

---

## Security Note

`.env` is excluded from version control via `.gitignore`. Never commit DB credentials.
