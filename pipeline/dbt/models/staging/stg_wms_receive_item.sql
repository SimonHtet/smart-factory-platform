select
    ReceivedNo                                                  as received_no,
    ProductId                                                   as product_id,
    ProductionDate                                              as production_date,
    PlanProductionDate                                          as plan_production_date,
    MachineCode                                                 as machine_code,
    GroupCode                                                   as group_code,
    filler_code,
    CONVERT(varchar, CAST(PlanProductionDate as date), 112)
        + filler_code                                           as run_key
from {{ source('analytics', 'raw_wms_receive_item') }}
where filler_code != 'Z2'
