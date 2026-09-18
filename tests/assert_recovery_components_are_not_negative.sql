-- No recovery component may be negative.
--
-- A negative component would mean an undercharge is quietly cancelling out a
-- proven overcharge elsewhere on the same shipment. Carriers do not honour that
-- netting -- they credit the proven overcharge and keep the undercharge -- so
-- letting it into the model would understate the claim.

select
    tracking_id,
    gsr_refund_usd,
    base_rate_recovery_usd,
    fuel_recovery_usd,
    accessorial_recovery_usd,
    duplicate_recovery_usd,
    total_recoverable_usd

from {{ ref('fct_reconciliation_marts') }}

where gsr_refund_usd < 0
   or base_rate_recovery_usd < 0
   or fuel_recovery_usd < 0
   or accessorial_recovery_usd < 0
   or duplicate_recovery_usd < 0
   or total_recoverable_usd < 0
