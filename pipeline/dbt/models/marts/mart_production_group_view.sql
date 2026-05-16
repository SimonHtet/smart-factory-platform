{{ config(materialized='view') }}

select
    LEFT(machine, 1)                                            as machine_group,
    product_date,

    -- date labels
    CASE
        WHEN DATEPART(week, product_date) = DATEPART(week, GETUTCDATE())
             AND YEAR(product_date) = YEAR(GETUTCDATE())
        THEN 'Current Week'
        ELSE 'Week ' + CAST(DATEPART(week, product_date) AS varchar)
    END                                                         as week_label,

    CASE
        WHEN CAST(product_date AS DATE) = CAST(GETUTCDATE() AS DATE)
        THEN 'Today'
        ELSE CONVERT(varchar, CAST(product_date AS DATE), 111)
    END                                                         as date_status,

    -- run counts
    COUNT(*)                                                    as run_count,
    SUM(downtime_count)                                         as downtime_count,

    -- volume
    SUM(in_feed_mc)                                             as in_feed_mc,
    SUM(out_feed_mc)                                            as out_feed_mc,
    SUM(scanned_briks)                                          as scanned_briks,
    SUM(CASE WHEN product_id NOT LIKE '%[0-9].[0-9]%' THEN fg_briks_amount ELSE 0 END)
                                                                as fg_briks_amount,

    -- waste (fg-dependent columns exclude loop runs to avoid WMS double-count)
    SUM(waste_tba)                                              as waste_tba,
    SUM(waste_op)                                               as waste_op,
    SUM(CASE WHEN product_id NOT LIKE '%[0-9].[0-9]%' THEN waste_de ELSE 0 END)
                                                                as waste_de,

    -- time
    SUM(run_duration_minutes)                                   as total_run_minutes,
    SUM(total_downtime_seconds) / 60.0                          as total_downtime_minutes,

    -- derived KPIs
    CAST(SUM(fg_briks_amount) AS float)
        / NULLIF(SUM(run_duration_minutes) * 400.0, 0)          as efficiency,

    CAST(SUM(waste_tba) + SUM(waste_op) + SUM(waste_de) AS float)
        / NULLIF(CAST(SUM(fg_briks_amount) AS float), 0)        as waste_pct,

    CAST(SUM(waste_tba) AS float)
        / NULLIF(CAST(SUM(out_feed_mc) AS float), 0)            as waste_tba_pct,

    CAST(SUM(waste_op) AS float)
        / NULLIF(CAST(SUM(out_feed_mc) AS float), 0)            as waste_op_pct,

    -- OEE loss components
    SUM(total_downtime_seconds) / 60.0
        / NULLIF(CAST(SUM(run_duration_minutes) AS float), 0)   as availability_loss,

    1.0 - CAST(SUM(out_feed_mc) AS float)
        / NULLIF(
            (SUM(run_duration_minutes) - SUM(total_downtime_seconds) / 60.0) * 400.0
          , 0)                                                   as performance_loss

from {{ ref('mart_production_runs') }}
where end_time is not null
group by
    LEFT(machine, 1),
    product_date
