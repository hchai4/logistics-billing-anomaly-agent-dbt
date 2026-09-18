-- The reason code string and the anomaly counter are derived from the same gate
-- flags, so they must always agree. They are built by two separate expressions,
-- which means adding a sixth gate to one and forgetting the other is an easy
-- mistake -- and it would silently corrupt every downstream count of how many
-- violations a shipment carries.

with counted as (

    select
        tracking_id,
        anomaly_codes,
        anomaly_count,
        case
            when anomaly_codes is null or anomaly_codes = '' then 0
            else array_length(string_to_array(anomaly_codes, ' | '), 1)
        end as codes_in_string

    from {{ ref('fct_reconciliation_marts') }}

)

select *
from counted
where anomaly_count <> codes_in_string
