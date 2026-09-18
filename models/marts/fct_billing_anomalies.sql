{{
    config(
        materialized = 'table',
        indexes = [
            {'columns': ['tracking_id']},
            {'columns': ['anomaly_code']},
        ]
    )
}}

-- ============================================================================
-- fct_billing_anomalies -- fct_reconciliation_marts unpivoted to one row per
-- proven violation.
--
-- The reconciliation mart is one row per shipment with independent gate flags,
-- which is the right shape for auditing but the wrong shape for disputing: a
-- claim is filed per violation, not per package. This model explodes compound
-- findings into individual claims and attaches the `dispute_evidence` sentence
-- that states the violation in the terms a carrier billing representative has
-- to answer -- which is what the dispute agent needs as LLM input.
--
-- Recovery dollars are attributed exactly as the reconciliation mart attributes
-- them, so SUM(recoverable_usd) here equals
-- SUM(total_recoverable_usd) there. Reason-code-only findings (Gate 1 where the
-- inflated weight never crossed a rate bracket) correctly carry 0.00.
--
-- Grain: one row per package per anomaly code.
-- ============================================================================

with reconciliation as (

    select * from {{ ref('fct_reconciliation_marts') }}

),

gate_1_weight_inflation as (

    select
        tracking_id,
        1                                       as gate_number,
        'WEIGHT_INFLATION'                      as anomaly_code,
        'Gate 1: Weight Inflation & Volumetric Discrepancy' as gate_name,
        -- Gate 1 is a reason code. The dollars it causes are claimed through the
        -- resulting rate bracket change under Gate 2, so claiming them here too
        -- would be double recovery.
        0.00                                    as recoverable_usd,
        'Carrier billed ' || billed_weight_lbs || ' lb against a certified scale weight of '
            || actual_scale_weight_lbs || ' lb and a contractual dimensional weight of '
            || dim_weight_lbs || ' lb (' || package_length_in || 'x' || package_width_in
            || 'x' || package_height_in || ' in / divisor ' || dim_divisor
            || '). Contractual billable weight is ' || billable_weight_expected_lbs
            || ' lb, a variance of ' || weight_variance_lbs || ' lb.'
                                                as dispute_evidence
    from reconciliation
    where is_weight_inflation

),

gate_2_base_rate as (

    select
        tracking_id,
        2                                       as gate_number,
        'BASE_RATE_OVERCHARGE'                  as anomaly_code,
        'Gate 2: Rate Card Base Rate Tariff Drift' as gate_name,
        round(base_rate_recovery_usd + fuel_recovery_usd, 2) as recoverable_usd,
        'Carrier billed a base rate of $' || billed_base_rate_usd
            || ' for a ' || service_level || ' parcel in zone ' || zone
            || ' at ' || rating_weight_lbs || ' lb (tariff tier '
            || weight_tier_min_lbs || '-' || weight_tier_max_lbs
            || ' lb). Contract ' || contract_id || ' rates this at $'
            || contract_base_rate_usd || ', a variance of $'
            || base_rate_variance_usd || '. Fuel billed at $'
            || billed_fuel_surcharge_usd || ' against $'
            || expected_fuel_surcharge_usd || ' expected at the '
            || fuel_index_week_start_date || ' index of '
            || fuel_surcharge_pct || '.'
                                                as dispute_evidence
    from reconciliation
    where is_base_rate_overcharge

),

gate_3_residential as (

    select
        tracking_id,
        3                                       as gate_number,
        'UNAUTHORIZED_RESIDENTIAL_FEE'          as anomaly_code,
        'Gate 3: Unauthorized Accessorial Surcharges' as gate_name,
        round(unauthorized_residential_fee_usd, 2) as recoverable_usd,
        'Carrier applied a residential delivery surcharge of $'
            || unauthorized_residential_fee_usd || ' to ZIP ' || dest_zip
            || ', which our order management system classifies as '
            || dest_address_type
            || '. The contracted tariff authorizes this fee only for residential '
            || 'delivery points.'
                                                as dispute_evidence
    from reconciliation
    where is_unauthorized_residential_fee

),

gate_3_address_correction as (

    select
        tracking_id,
        3                                       as gate_number,
        'UNAUTHORIZED_ADDRESS_CORRECTION_FEE'   as anomaly_code,
        'Gate 3: Unauthorized Accessorial Surcharges' as gate_name,
        round(unauthorized_address_correction_fee_usd, 2) as recoverable_usd,
        'Carrier applied an address correction fee of $'
            || unauthorized_address_correction_fee_usd || ' to ZIP ' || dest_zip
            || ', but the delivery address was verified by USPS CASS software at '
            || 'label print time. No correction was required.'
                                                as dispute_evidence
    from reconciliation
    where is_unauthorized_address_correction_fee

),

gate_3_other_accessorial as (

    select
        tracking_id,
        3                                       as gate_number,
        'UNAUTHORIZED_ACCESSORIAL_OTHER'        as anomaly_code,
        'Gate 3: Unauthorized Accessorial Surcharges' as gate_name,
        round(unauthorized_other_accessorial_usd, 2) as recoverable_usd,
        'Carrier applied $' || unauthorized_other_accessorial_usd
            || ' in accessorial fees (' || coalesce(unauthorized_accessorial_codes, 'unspecified')
            || ') whose contractual authorization conditions were not met for this '
            || 'shipment.'
                                                as dispute_evidence
    from reconciliation
    where is_unauthorized_other_accessorial

),

gate_4_duplicate as (

    select
        tracking_id,
        4                                       as gate_number,
        'DUPLICATE_BILLING_COLLISION'           as anomaly_code,
        'Gate 4: Cross-Channel Duplicate Billing' as gate_name,
        round(duplicate_recovery_usd, 2)        as recoverable_usd,
        'Tracking ID billed ' || billed_line_count || ' times across '
            || distinct_source_channel_count || ' channel(s) under '
            || distinct_invoice_number_count || ' invoice number(s): '
            || all_invoice_numbers || ' (' || all_source_channels
            || '). Total billed $' || billed_total_all_lines_usd
            || ' against a single shipment charge of $' || billed_total_usd
            || ', leaving $' || duplicate_billed_amount_usd
            || ' billed in duplicate.'
                                                as dispute_evidence
    from reconciliation
    where is_duplicate_billing_collision

),

gate_5_sla as (

    select
        tracking_id,
        5                                       as gate_number,
        'SLA_DELIVERY_FAILURE_REFUND'           as anomaly_code,
        'Gate 5: SLA Failure / Guaranteed Service Refund' as gate_name,
        round(gsr_refund_usd, 2)                as recoverable_usd,
        'Parcel shipped ' || service_level || ' with a '
            || guaranteed_transit_hours || '-hour guarantee, departing the dock at '
            || dock_departure_timestamp || ' for a commitment of '
            || guaranteed_delivery_timestamp || '. Carrier delivered at '
            || actual_delivery_timestamp || ', '
            || delivery_variance_hours
            || ' hours late. The Guaranteed Service Refund clause entitles us to '
            || 'a 100% refund of the $' || round(gsr_refund_usd, 2)
            || ' transportation charge.'
                                                as dispute_evidence
    from reconciliation
    where is_sla_delivery_failure

),

all_anomalies as (

    select * from gate_1_weight_inflation
    union all
    select * from gate_2_base_rate
    union all
    select * from gate_3_residential
    union all
    select * from gate_3_address_correction
    union all
    select * from gate_3_other_accessorial
    union all
    select * from gate_4_duplicate
    union all
    select * from gate_5_sla

)

select
    all_anomalies.tracking_id || '::' || all_anomalies.anomaly_code
                                            as anomaly_id,
    all_anomalies.tracking_id,
    reconciliation.package_id,
    reconciliation.carrier_code,
    reconciliation.contract_id,
    reconciliation.primary_invoice_number,
    reconciliation.primary_source_channel,
    reconciliation.primary_invoice_date,
    reconciliation.service_level,
    reconciliation.origin_warehouse,
    reconciliation.dest_zip,
    reconciliation.zone,
    reconciliation.scan_date,

    all_anomalies.gate_number,
    all_anomalies.anomaly_code,
    all_anomalies.gate_name,
    all_anomalies.recoverable_usd,
    all_anomalies.dispute_evidence,

    -- Shipment-level context so a dispute letter can be generated from this row
    -- alone, without rejoining the reconciliation mart.
    reconciliation.expected_total_cost_usd,
    reconciliation.billed_total_all_lines_usd,
    reconciliation.total_variance_usd,
    reconciliation.total_recoverable_usd  as shipment_total_recoverable_usd,
    reconciliation.anomaly_codes          as shipment_anomaly_codes,
    reconciliation.anomaly_count          as shipment_anomaly_count,
    reconciliation.dispute_priority

from all_anomalies

inner join reconciliation
    on all_anomalies.tracking_id = reconciliation.tracking_id
