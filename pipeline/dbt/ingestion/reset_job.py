import os
import pyodbc
from dotenv import load_dotenv

load_dotenv(dotenv_path=os.path.join(os.path.dirname(__file__), ".env"))

conn = pyodbc.connect(
    f"DRIVER={{ODBC Driver 18 for SQL Server}};"
    f"SERVER={os.environ['DW_SERVER']},1433;DATABASE=DB_BUDIBASE;"
    f"UID={os.environ['DW_USER']};PWD={os.environ['DW_PASSWORD']};"
    f"Encrypt=yes;TrustServerCertificate=yes;"
)
cur = conn.cursor()
cur.execute("IF OBJECT_ID('analytics.raw_wms_transactions', 'U') IS NOT NULL DROP TABLE analytics.raw_wms_transactions")
cur.execute("DELETE FROM analytics.ingestion_watermarks WHERE job_name = 'wms_transactions'")
conn.commit()
conn.close()
print("Reset done")
