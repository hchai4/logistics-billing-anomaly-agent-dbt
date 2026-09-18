-- A shipment that cleared all five gates is one we are asserting the carrier
-- billed correctly. If such a shipment still shows a dollar variance between
-- what the contract says we owe and what was billed, then a gate has a blind
-- spot and the audit is understating recovery.
--
-- This is the test that protects against the failure mode that actually matters
-- in freight audit: silent false negatives. A false positive gets rejected by a
-- carrier rep; a false negative is money that is never claimed.

select
    tracking_id,
    audit_status,
    expected_total_cost_usd,
    billed_total_all_lines_usd,
    total_variance_usd

from {{ ref('fct_reconciliation_marts') }}

where audit_status = 'CLEAN'
  and abs(total_variance_usd) > 0.01
