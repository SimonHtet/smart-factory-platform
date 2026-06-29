import time
import logging
from db import get_connection
from config import MACHINES, POLL_INTERVAL_SECONDS

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)


def get_live_counters(conn):
    cursor = conn.cursor()
    placeholders = ",".join("?" * len(MACHINES))
    cursor.execute(f"""
        SELECT Machine, Counter_infeed, Counter_Outfeed
        FROM T_M_Filler_Process
        WHERE Machine IN ({placeholders})
    """, *MACHINES)
    return {row[0]: (row[1], row[2]) for row in cursor.fetchall()}


def update_counters(conn, live):
    cursor = conn.cursor()
    for machine, (infeed, outfeed) in live.items():
        cursor.execute("""
            UPDATE [Change paper brik]
            SET In_Feed_MC = ?, Out_Feed_MC = ?
            WHERE ID = (
                SELECT MAX(ID)
                FROM [Change paper brik]
                WHERE Machine = ? AND [end time] IS NULL
            )
        """, infeed, outfeed, machine)

        if cursor.rowcount:
            log.debug("[%s] counters updated — infeed=%s outfeed=%s", machine, infeed, outfeed)

    conn.commit()


def main():
    log.info("Plant 3 real-time counter pipeline starting — machines: %s", MACHINES)
    conn = get_connection()

    while True:
        try:
            live = get_live_counters(conn)
            update_counters(conn, live)
            time.sleep(POLL_INTERVAL_SECONDS)

        except Exception as e:
            log.error("Error: %s", e)
            try:
                conn = get_connection()
                log.info("Reconnected")
            except Exception as reconnect_err:
                log.error("Reconnect failed: %s", reconnect_err)
            time.sleep(5)


if __name__ == "__main__":
    main()
