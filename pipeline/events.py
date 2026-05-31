import logging
from datetime import datetime, timezone

log = logging.getLogger(__name__)


def utcnow():
    return datetime.now(timezone.utc).replace(tzinfo=None)


def handle_step10(machine, conn):
    cursor = conn.cursor()

    cursor.execute("""
        UPDATE [Change paper brik]
        SET [Splicing time 1] = ?
        WHERE Machine = ?
        AND [Splicing time 1] IS NULL
    """, utcnow(), machine)

    cursor.execute("""
        UPDATE [Change strip]
        SET [Splicing time 1] = ?
        WHERE Machine = ?
        AND ID = (SELECT MAX(ID) FROM [Change strip] WHERE Machine = ?)
        AND [Splicing time 1] IS NULL
    """, utcnow(), machine, machine)

    conn.commit()
    log.info("[%s] Step 10 — Splicing time 1 written", machine)


def handle_step13(machine, infeed, outfeed, conn):
    cursor = conn.cursor()
    now = utcnow()
    is_ad_machine = machine.startswith("A") or machine.startswith("D")

    cursor.execute("""
        UPDATE [Change paper brik]
        SET [end time] = ?,
            [In_Feed_MC] = ?,
            [Out_Feed_MC] = ?,
            End_time_CIP = CASE WHEN ? = 1 THEN ? ELSE End_time_CIP END
        WHERE Machine = ?
        AND [end time] IS NULL
        AND [Splicing time 1] IS NOT NULL
    """, now, infeed, outfeed, 1 if is_ad_machine else 0, now, machine)

    cursor.execute("""
        UPDATE [Change strip]
        SET [end time] = ?
        WHERE Machine = ?
        AND ID = (SELECT MAX(ID) FROM [Change strip] WHERE Machine = ?)
        AND [end time] IS NULL
        AND [Splicing time 1] IS NOT NULL
    """, now, machine, machine)

    conn.commit()
    log.info("[%s] Step 13 — end time written", machine)


def handle_step14_cip(machine, cooldown_log, conn):
    now = utcnow()
    last_time = cooldown_log.get(machine)

    if last_time:
        diff = (now - last_time).total_seconds()
        if 0 <= diff < 3600:
            log.info("[%s] Step 14 CIP — cooldown (%ds remaining)", machine, int(3600 - diff))
            return

    cursor = conn.cursor()
    cursor.execute("""
        SELECT TOP 1 ID, [end time], [Out_Feed_MC]
        FROM [Change paper brik]
        WHERE Machine = ?
        AND [end time] IS NOT NULL
        ORDER BY ID DESC
    """, machine)

    row = cursor.fetchone()
    if not row:
        return

    gid, end_time, outfeed = row

    cursor.execute("""
        UPDATE [Change paper brik]
        SET End_time_CIP = ?
        WHERE ID = ?
    """, now, gid)

    cursor.execute("""
        INSERT INTO [endtime_log_test] (Machine, Step, Signal_CIP, Outfeed, End_Time, Log_Time)
        VALUES (?, 14, 1, ?, ?, ?)
    """, machine, str(outfeed), end_time, now)

    cursor.execute("""
        INSERT INTO t_log (txt) VALUES (?)
    """, f"{machine}_S14:CIP=1:ID={gid}:Outfeed={outfeed}:BatchEndTime={end_time}:CIPTime={now}-PYTHON")

    conn.commit()
    cooldown_log[machine] = now
    log.info("[%s] Step 14 CIP — End_time_CIP written (ID=%s)", machine, gid)


def handle_end_roll(machine, gid, splicing_count, last_splice_time, conn, table="Change paper brik", splice_cooldown=None):
    if splice_cooldown is None:
        splice_cooldown = {}

    splicing_count = int(splicing_count)
    now = utcnow()
    cursor = conn.cursor()

    last_entry = splice_cooldown.get(f"{machine}_{table}")
    if last_entry:
        last_time, last_count = last_entry
        diff_ms = (now - last_time).total_seconds() * 1000
        if 0 <= diff_ms < 30000:
            col = f"Splicing time {last_count + 1}"
            cursor.execute(f"""
                UPDATE [{table}]
                SET [{col}] = ?
                WHERE ID = ?
            """, now, gid)
            conn.commit()
            log.info("[%s] %s — cooldown rewrite %s", machine, table, col)
            return

    new_count = splicing_count + 1
    col = f"Splicing time {new_count + 1}"
    splice_cooldown[f"{machine}_{table}"] = (now, new_count)

    cursor.execute(f"""
        UPDATE [{table}]
        SET [{col}] = ?,
            Splicing_Count = ?,
            Last_Splice_Time = ?
        WHERE ID = ?
    """, now, new_count, now, gid)

    conn.commit()
    log.info("[%s] End roll — %s written | Splicing_Count=%d | ID=%s", machine, col, new_count, gid)
