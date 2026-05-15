{{ config(materialized='view') }}

select
    m.id,
    m.run_key,
    m.product_date,
    m.plan_production_date,
    m.product_id,
    m.machine,

    -- timing
    m.start_time,
    m.end_time,
    m.end_time_cip,
    m.run_duration_minutes,

    -- live counters: use T_M_Filler_Process for in-progress runs, mart values for completed
    CASE WHEN m.end_time IS NULL THEN p.Counter_infeed  ELSE m.in_feed_mc  END as in_feed_mc,
    CASE WHEN m.end_time IS NULL THEN p.Counter_Outfeed ELSE m.out_feed_mc END as out_feed_mc,

    -- waste (recalculated from live counters for in-progress runs)
    CASE
        WHEN m.end_time IS NULL
        THEN p.Counter_infeed + 150 - p.Counter_Outfeed
        ELSE m.waste_tba
    END                                                             as waste_tba,

    m.scanned_briks,
    CASE
        WHEN m.end_time IS NULL
        THEN m.scanned_briks - p.Counter_infeed
        ELSE m.waste_op
    END                                                             as waste_op,

    m.transaction_briks,
    m.resend_briks,
    m.fg_briks_amount,

    CASE
        WHEN m.end_time IS NULL
        THEN p.Counter_Outfeed - m.fg_briks_amount
        ELSE m.waste_de
    END                                                             as waste_de,

    m.efficiency,
    m.tba_target,
    m.downtime_count,
    m.total_downtime_seconds,

    -- dynamic date labels
    CASE
        WHEN DATEPART(week, m.product_date) = DATEPART(week, GETUTCDATE())
             AND YEAR(m.product_date) = YEAR(GETUTCDATE())
        THEN 'Current Week'
        ELSE 'Week ' + CAST(DATEPART(week, m.product_date) AS varchar)
    END                                                             as week_label,

    CASE
        WHEN CAST(m.product_date AS DATE) = CAST(GETUTCDATE() AS DATE)
        THEN 'Today'
        ELSE CONVERT(varchar, CAST(m.product_date AS DATE), 106)
    END                                                             as date_status,

    -- derived KPIs
    (CASE WHEN m.end_time IS NULL THEN p.Counter_infeed + 150 - p.Counter_Outfeed ELSE m.waste_tba END
     + CASE WHEN m.end_time IS NULL THEN m.scanned_briks - p.Counter_infeed ELSE m.waste_op END
     + CASE WHEN m.end_time IS NULL THEN p.Counter_Outfeed - m.fg_briks_amount ELSE m.waste_de END)
        / NULLIF(CAST(m.fg_briks_amount AS float), 0)              as waste_pct,

    m.total_downtime_seconds / 60.0                                as downtime_minutes,

    CAST(CASE WHEN m.end_time IS NULL THEN p.Counter_infeed + 150 - p.Counter_Outfeed ELSE m.waste_tba END AS float)
        / NULLIF(CAST(CASE WHEN m.end_time IS NULL THEN p.Counter_Outfeed ELSE m.out_feed_mc END AS float), 0)
                                                                    as waste_tba_pct,

    CASE
        WHEN m.end_time IS NOT NULL THEN m.run_duration_minutes
        ELSE DATEDIFF(minute, m.start_time, GETUTCDATE())
    END                                                             as live_duration_minutes,

    CASE
        WHEN m.end_time IS NOT NULL THEN m.efficiency
        ELSE CAST(p.Counter_Outfeed AS float)
             / NULLIF(DATEDIFF(minute, m.start_time, GETUTCDATE()) * 400.0, 0)
    END                                                             as efficiency_live

from {{ ref('mart_production_runs') }} m
left join {{ source('dbo', 'T_M_Filler_Process') }} p
    on m.machine = p.Machine
    and m.end_time is null
