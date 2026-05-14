select
    txt,
    st_time as logged_at
from {{ source('dbo', 't_log') }}
where st_time is not null
