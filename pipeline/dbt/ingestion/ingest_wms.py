import os
import pyodbc
from datetime import datetime
from dotenv import load_dotenv

load_dotenv(dotenv_path=os.path.join(os.path.dirname(__file__), ".env"))

# ---------------------------------------------------------------------------
# Add a new dict to JOBS to pull additional WMS tables.
# Each job needs: name, source_db, initial_query (first run), incremental_query
# (subsequent runs — must accept a {watermark} placeholder), watermark_col,
# and target_table.
# ---------------------------------------------------------------------------

WMS_INITIAL_CUTOFF = "2026-03-30"
BATCH_SIZE = 5000

JOBS = [
    {
        "name": "wms_transactions",
        "source_db": "WMSDairyPlus2015",
        "initial_query": f"""
            SELECT ReceivedNo, ProductId, ProductionDate, InCartonAmount, CreateDate,
                   MachineCode, GroupCode, GroupCode + MachineCode AS filler_code
            FROM dbo.tbl_Transaction
            WHERE TransactionTypeId = '1'
              AND ProductionDate > '{WMS_INITIAL_CUTOFF}'
        """,
        "incremental_query": """
            SELECT ReceivedNo, ProductId, ProductionDate, InCartonAmount, CreateDate,
                   MachineCode, GroupCode, GroupCode + MachineCode AS filler_code
            FROM dbo.tbl_Transaction
            WHERE TransactionTypeId = '1'
              AND CreateDate > ?
        """,
        "watermark_col": "CreateDate",
        "target_table": "analytics.raw_wms_transactions",
    },
    {
        "name": "wms_receive_item_location",
        "source_db": "WMSDairyPlus2015",
        "initial_query": """
            SELECT ProductionDate, ProductId, FirstAmountCarton AS recall_amount,
                   MachineCode, GroupCode, GroupCode + MachineCode AS filler_code,
                   CreateDate
            FROM dbo.tbl_ReceiveItemLocation
            WHERE TagType = 1
              AND ProductionDate >= '2026-01-01'
        """,
        "incremental_query": """
            SELECT ProductionDate, ProductId, FirstAmountCarton AS recall_amount,
                   MachineCode, GroupCode, GroupCode + MachineCode AS filler_code,
                   CreateDate
            FROM dbo.tbl_ReceiveItemLocation
            WHERE TagType = 1
              AND ProductionDate >= '2026-01-01'
              AND CreateDate > ?
        """,
        "watermark_col": "CreateDate",
        "target_table": "analytics.raw_wms_receive_item_location",
    },
    {
        "name": "wms_mst_product",
        "source_db": "WMSDairyPlus2015",
        "initial_query": """
            SELECT ProductId, numbit
            FROM dbo.mst_Product
        """,
        "incremental_query": None,
        "watermark_col": None,
        "target_table": "analytics.raw_wms_mst_product",
    },
    {
        "name": "wms_receive_item",
        "source_db": "WMSDairyPlus2015",
        "initial_query": """
            SELECT ReceivedNo, ProductId, ProductionDate,
                   MachineCode, GroupCode, GroupCode + MachineCode AS filler_code,
                   PlanProductionDate
            FROM dbo.tbl_ReceiveItem
            WHERE PlanProductionDate IS NOT NULL
        """,
        "incremental_query": None,
        "watermark_col": None,
        "target_table": "analytics.raw_wms_receive_item",
    },
]

WATERMARK_TABLE = "analytics.ingestion_watermarks"


def _wms_conn(db_name):
    return pyodbc.connect(
        f"DRIVER={{ODBC Driver 18 for SQL Server}};"
        f"SERVER=<internal-server>,1433;"
        f"DATABASE={db_name};"
        f"UID={os.environ['WMS_USER']};PWD={os.environ['WMS_PASSWORD']};"
        f"Encrypt=yes;TrustServerCertificate=yes;"
    )


def _dw_conn():
    return pyodbc.connect(
        f"DRIVER={{ODBC Driver 18 for SQL Server}};"
        f"SERVER=<internal-server>,1433;"
        f"DATABASE=DB_BUDIBASE;"
        f"UID={os.environ['DW_USER']};PWD={os.environ['DW_PASSWORD']};"
        f"Encrypt=yes;TrustServerCertificate=yes;"
    )


def _normalize(v):
    return str(v) if v is not None else None


def _ensure_watermark_table(cur):
    cur.execute(f"""
        IF OBJECT_ID('{WATERMARK_TABLE}', 'U') IS NULL
        CREATE TABLE {WATERMARK_TABLE} (
            job_name    NVARCHAR(100) PRIMARY KEY,
            last_run    DATETIME2
        )
    """)


def _get_watermark(cur, job_name):
    cur.execute(
        f"SELECT last_run FROM {WATERMARK_TABLE} WHERE job_name = ?", job_name
    )
    row = cur.fetchone()
    return row[0] if row else None


def _set_watermark(cur, job_name, value):
    cur.execute(f"""
        MERGE {WATERMARK_TABLE} AS t
        USING (SELECT ? AS job_name, ? AS last_run) AS s
        ON t.job_name = s.job_name
        WHEN MATCHED THEN UPDATE SET last_run = s.last_run
        WHEN NOT MATCHED THEN INSERT (job_name, last_run) VALUES (s.job_name, s.last_run);
    """, job_name, value)


def run_job(job, dw):
    name = job["name"]
    target = job["target_table"]

    dw_cur = dw.cursor()
    full_reload = job["watermark_col"] is None

    if full_reload:
        query = job["initial_query"]
        params = []
        print(f"[{name}] full reload", flush=True)
    else:
        _ensure_watermark_table(dw_cur)
        watermark = _get_watermark(dw_cur, name)
        if watermark is None:
            query = job["initial_query"]
            params = []
            print(f"[{name}] first run — full load", flush=True)
        else:
            query = job["incremental_query"]
            params = [watermark]
            print(f"[{name}] incremental — rows after {watermark}", flush=True)

    new_watermark = None
    total_rows = 0

    with _wms_conn(job["source_db"]) as src:
        src_cur = src.cursor()
        src_cur.execute(query, *params)
        columns = [col[0] for col in src_cur.description]
        watermark_idx = columns.index(job["watermark_col"]) if not full_reload else None

        col_defs = ", ".join(f"[{c}] NVARCHAR(MAX)" for c in columns)
        if full_reload or watermark is None:
            dw_cur.execute(f"IF OBJECT_ID('{target}', 'U') IS NOT NULL DROP TABLE {target}")
            dw_cur.execute(f"CREATE TABLE {target} ({col_defs})")
        else:
            dw_cur.execute(f"""
                IF OBJECT_ID('{target}', 'U') IS NULL
                CREATE TABLE {target} ({col_defs})
            """)

        dw_cur.fast_executemany = True
        placeholders = ", ".join("?" * len(columns))
        insert_sql = f"INSERT INTO {target} VALUES ({placeholders})"

        while True:
            batch = src_cur.fetchmany(BATCH_SIZE)
            if not batch:
                break

            normalized = [tuple(_normalize(v) for v in row) for row in batch]
            dw_cur.executemany(insert_sql, normalized)
            total_rows += len(batch)

            if watermark_idx is not None:
                batch_max = max(row[watermark_idx] for row in batch if row[watermark_idx] is not None)
                if new_watermark is None or batch_max > new_watermark:
                    new_watermark = batch_max

            print(f"[{name}] {total_rows} rows written...", flush=True)

    if not full_reload and new_watermark:
        _set_watermark(dw_cur, name, new_watermark)

    dw.commit()
    print(f"[{name}] done — {total_rows} rows total, watermark set to {new_watermark}", flush=True)


POLL_INTERVAL_SECONDS = 300  # run every 5 minutes


def main():
    import time
    print("=== WMS ingestion service started ===", flush=True)
    while True:
        print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] running jobs...", flush=True)
        with _dw_conn() as dw:
            for job in JOBS:
                try:
                    run_job(job, dw)
                except Exception as e:
                    print(f"[{job['name']}] ERROR: {e}", flush=True)
        print(f"sleeping {POLL_INTERVAL_SECONDS}s...", flush=True)
        time.sleep(POLL_INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
