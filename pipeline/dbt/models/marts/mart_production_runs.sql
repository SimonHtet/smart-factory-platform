with production as (
    select
        id,
        run_key,
        product_date,
        product_id,
        machine,
        start_time,
        end_time,
        end_time_cip,
        CASE WHEN end_time IS NOT NULL
             THEN DATEDIFF(minute, start_time, end_time)
        END                                                     as run_duration_minutes,
        in_feed_mc,
        out_feed_mc,
        waste_tba,
        scanned_briks,
        downtime_count,
        total_downtime_seconds,
        de_downtime_count,
        total_de_downtime_seconds
    from {{ ref('stg_change_paper_brik') }}
),

wms as (
    select
        run_key,
        CAST(SUM(total_briks_amount) as int)                    as transaction_briks
    from {{ ref('stg_wms_transactions') }}
    where run_key is not null
    group by run_key
),

-- plan date looked up at group level (date + group letter) so M1/M2/M3 share
-- the same plan date even if only one machine has a WMS receive record
plan_dates as (
    select
        LEFT(run_key, 9)                                        as group_key,
        MIN(plan_production_date)                               as plan_production_date
    from {{ ref('stg_wms_transactions') }}
    where run_key is not null
      and plan_production_date is not null
    group by LEFT(run_key, 9)
),

recalls as (
    select
        resend_run_key,
        CAST(SUM(resend_briks_amount) as int)                   as resend_briks
    from {{ ref('stg_wms_receive_item_location') }}
    where resend_run_key is not null
    group by resend_run_key
)

select
    p.id,
    p.run_key,
    p.product_date,
    d.plan_production_date,
    p.product_id,
    p.machine,

    -- timing
    p.start_time,
    p.end_time,
    p.end_time_cip,
    p.run_duration_minutes,

    -- output & waste
    p.in_feed_mc,
    p.out_feed_mc,
    p.waste_tba,
    p.scanned_briks,
    p.scanned_briks - p.in_feed_mc                             as waste_op,
    w.transaction_briks,
    r.resend_briks,
    w.transaction_briks - ISNULL(r.resend_briks, 0)            as fg_briks_amount,
    p.out_feed_mc - (w.transaction_briks - ISNULL(r.resend_briks, 0))
                                                                as waste_de,

    -- efficiency
    (w.transaction_briks - ISNULL(r.resend_briks, 0))
        / NULLIF(p.run_duration_minutes * 400.0, 0)            as efficiency,
    (p.total_downtime_seconds / 60.0 * 400)
        / NULLIF(p.out_feed_mc, 0)                             as loss_efficiency,

    -- targets
    CASE WHEN p.machine LIKE 'M%'
         THEN p.out_feed_mc * 0.0044
    END                                                             as tba_target,

    -- downtime
    p.downtime_count,
    p.total_downtime_seconds,

    -- V5.8 DE-line downtime + isolated TBA-actual downtime (floored at 0)
    p.de_downtime_count,
    p.total_de_downtime_seconds,
    CASE WHEN p.total_downtime_seconds - p.total_de_downtime_seconds > 0
         THEN p.total_downtime_seconds - p.total_de_downtime_seconds
         ELSE 0 END                                             as tba_actual_downtime_seconds

from production p
left join wms w        on p.run_key          = w.run_key
left join plan_dates d on LEFT(p.run_key, 9) = d.group_key
left join recalls r    on p.run_key          = r.resend_run_key
