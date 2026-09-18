-- Recovery must be conserved between the two marts.
--
-- fct_reconciliation_marts totals recovery per shipment; fct_billing_anomalies
-- attributes it per violation. If the two disagree, either a recoverable dollar
-- is counted at the shipment level but never claimed against a specific gate
-- (money we would never actually file for), or a gate claims dollars the
-- shipment-level attribution never granted (double recovery, which discredits
-- an entire claim file when a carrier audits it back).

with shipment_level as (

    select coalesce(sum(total_recoverable_usd), 0) as recoverable_usd
    from {{ ref('fct_reconciliation_marts') }}

),

anomaly_level as (

    select coalesce(sum(recoverable_usd), 0) as recoverable_usd
    from {{ ref('fct_billing_anomalies') }}

)

select
    shipment_level.recoverable_usd as shipment_level_recoverable_usd,
    anomaly_level.recoverable_usd  as anomaly_level_recoverable_usd,
    round(
        shipment_level.recoverable_usd - anomaly_level.recoverable_usd, 2
    ) as unattributed_usd

from shipment_level
cross join anomaly_level

where abs(shipment_level.recoverable_usd - anomaly_level.recoverable_usd) > 0.01
