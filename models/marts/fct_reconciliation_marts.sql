{{
    config(
        materialized = 'table',
        indexes = [
            {'columns': ['tracking_id'], 'unique': True},
            {'columns': ['audit_status']},
            {'columns': ['primary_invoice_number']},
        ]
    )
}}

-- ============================================================================
-- fct_reconciliation_marts -- the analytical core of the freight audit.
--
-- Cross-examines three independent data streams and applies five deterministic
-- verification gates, so every flag raised is backed by evidence a carrier
-- billing representative cannot wave away:
--
--   Pillar 1  Physical Reality   stg_wms_scans        -> int_package_physical_truth
--   Pillar 2  Contract Reality   seeds/carrier_*      -> int_contract_expectations
--   Pillar 3  Billed Reality     stg_carrier_invoices -> int_billed_charges
--
--   Gate 1  WEIGHT_INFLATION                     hub re-weigh / DIM divisor abuse
--   Gate 2  BASE_RATE_OVERCHARGE                 tariff drift off the rate card
--   Gate 3  UNAUTHORIZED_RESIDENTIAL_FEE         accessorials never owed
--           UNAUTHORIZED_ADDRESS_CORRECTION_FEE
--   Gate 4  DUPLICATE_BILLING_COLLISION          cross-channel double dipping
--   Gate 5  SLA_DELIVERY_FAILURE_REFUND          GSR refund on a late premium parcel
--
-- Pillar 1 is the spine of the join. A package that physically shipped is a real
-- liability whether or not an invoice ever arrived, so the billed side is joined
-- optionally and un-invoiced packages surface as AWAITING_INVOICE rather than
-- silently disappearing from the audit.
--
-- Grain: one row per package (tracking_id).
-- ============================================================================

with physical_truth as (

    select * from {{ ref('int_package_physical_truth') }}

),

contract_expectations as (

    select * from {{ ref('int_contract_expectations') }}

),

billed_charges as (

    select * from {{ ref('int_billed_charges') }}

),

reconciled as (

    select
        -- ---------------------------------------------------------------
        -- Shipment identity
        -- ---------------------------------------------------------------
        physical_truth.tracking_id,
        physical_truth.package_id,
        physical_truth.carrier_code,
        physical_truth.contract_id,
        physical_truth.service_level,
        physical_truth.origin_warehouse,
        physical_truth.origin_zip,
        physical_truth.dest_zip,
        physical_truth.zone,
        physical_truth.scan_timestamp,
        physical_truth.scan_date,
        physical_truth.dock_departure_timestamp,

        -- ---------------------------------------------------------------
        -- Pillar 1: Physical Reality (WMS ground truth)
        -- ---------------------------------------------------------------
        physical_truth.actual_scale_weight_lbs,
        physical_truth.package_length_in,
        physical_truth.package_width_in,
        physical_truth.package_height_in,
        physical_truth.package_volume_cuin,
        physical_truth.dim_divisor,
        physical_truth.dim_weight_lbs,
        physical_truth.billable_weight_expected_lbs,
        physical_truth.rating_weight_lbs,
        physical_truth.billable_weight_basis,
        physical_truth.dest_address_type,
        physical_truth.is_dest_address_cass_validated,

        -- ---------------------------------------------------------------
        -- Pillar 2: Contractual Ground Truth (rate card / tariff)
        -- ---------------------------------------------------------------
        contract_expectations.weight_tier_min_lbs,
        contract_expectations.weight_tier_max_lbs,
        contract_expectations.contract_base_rate_usd,
        contract_expectations.fuel_index_week_start_date,
        contract_expectations.fuel_surcharge_pct,
        contract_expectations.expected_fuel_surcharge_usd,
        contract_expectations.has_rate_card_match,
        contract_expectations.has_fuel_index_match,
        physical_truth.guaranteed_transit_hours,
        physical_truth.is_gsr_eligible,
        physical_truth.guaranteed_delivery_timestamp,

        -- We owe the contracted transportation charge plus only those
        -- accessorials the contract actually authorizes.
        round(
            coalesce(contract_expectations.contract_base_rate_usd, 0)
            + coalesce(contract_expectations.expected_fuel_surcharge_usd, 0)
            + coalesce(billed_charges.authorized_accessorial_usd, 0)
        , 2) as expected_total_cost_usd,

        -- ---------------------------------------------------------------
        -- Pillar 3: Carrier Billed Reality (unified EDI 210 + portal PDFs)
        -- ---------------------------------------------------------------
        billed_charges.primary_invoice_number,
        billed_charges.primary_source_channel,
        billed_charges.primary_invoice_date,
        billed_charges.service_level_billed,
        billed_charges.zone_billed,
        billed_charges.billed_weight_lbs,
        billed_charges.billed_base_rate_usd,
        billed_charges.billed_fuel_surcharge_usd,
        billed_charges.billed_accessorial_usd,
        billed_charges.billed_total_usd,
        billed_charges.authorized_accessorial_usd,
        billed_charges.unauthorized_accessorial_usd,
        billed_charges.unauthorized_accessorial_codes,
        billed_charges.actual_delivery_timestamp,
        billed_charges.billed_line_count,
        billed_charges.distinct_invoice_number_count,
        billed_charges.distinct_source_channel_count,
        billed_charges.all_invoice_numbers,
        billed_charges.all_source_channels,
        billed_charges.billed_total_all_lines_usd,
        coalesce(billed_charges.duplicate_billed_amount_usd, 0)
            as duplicate_billed_amount_usd,

        billed_charges.tracking_id is not null as has_carrier_invoice,

        -- ===============================================================
        -- GATE 1 -- Weight Inflation & Volumetric Discrepancy
        --
        -- Carriers re-weigh parcels on high-speed hub scales and can override
        -- our certified weight, or quietly rate dimensional weight on the
        -- retail divisor instead of our negotiated one. Either way the parcel
        -- lands in a higher weight bracket than the contract allows.
        --
        --   DIM weight       = (L x W x H) / contracted divisor
        --   billable weight  = max(actual weight, DIM weight)
        --   weight variance  = billed weight - billable weight
        --
        -- Tolerance is 1.0 lb because legitimate rating rounds up to the next
        -- whole pound. Anything past that is not rounding.
        -- ===============================================================
        round(
            billed_charges.billed_weight_lbs
            - physical_truth.billable_weight_expected_lbs
        , 2) as weight_variance_lbs,

        coalesce(
            billed_charges.billed_weight_lbs
            - physical_truth.billable_weight_expected_lbs
            > {{ var('weight_variance_tolerance_lbs') }}
        , false) as is_weight_inflation,

        -- ===============================================================
        -- GATE 2 -- Rate Card Base Rate Tariff Drift
        --
        -- Carriers apply the annual General Rate Increase early, or map a
        -- tracking number to published list rates instead of our negotiated
        -- discount tier. Held against the rate card at the zone and weight tier
        -- derived from physical evidence, never from the invoice's own claims.
        --
        --   base rate variance = billed base rate - contract base rate
        -- ===============================================================
        round(
            billed_charges.billed_base_rate_usd
            - contract_expectations.contract_base_rate_usd
        , 2) as base_rate_variance_usd,

        coalesce(
            billed_charges.billed_base_rate_usd
            - contract_expectations.contract_base_rate_usd
            > {{ var('base_rate_variance_tolerance_usd') }}
        , false) as is_base_rate_overcharge,

        -- Fuel is a straight percentage of the base rate, so an inflated base
        -- rate silently inflates fuel as well. Tracked separately so a recovery
        -- claim itemizes the way a carrier's own credit memo will.
        round(
            billed_charges.billed_fuel_surcharge_usd
            - contract_expectations.expected_fuel_surcharge_usd
        , 2) as fuel_surcharge_variance_usd,

        coalesce(
            billed_charges.billed_fuel_surcharge_usd
            - contract_expectations.expected_fuel_surcharge_usd
            > {{ var('fuel_variance_tolerance_usd') }}
        , false) as is_fuel_surcharge_overcharge,

        -- ===============================================================
        -- GATE 3 -- Unauthorized Accessorial Surcharges
        --
        -- Adjudicated fee-by-fee in int_billed_accessorials against the WMS
        -- delivery address metadata: a residential surcharge billed to a
        -- commercial delivery point, and an address correction fee billed on an
        -- address USPS CASS software already verified.
        -- ===============================================================
        coalesce(billed_charges.is_unauthorized_residential_fee, false)
            as is_unauthorized_residential_fee,
        coalesce(billed_charges.unauthorized_residential_fee_usd, 0)
            as unauthorized_residential_fee_usd,

        coalesce(billed_charges.is_unauthorized_address_correction_fee, false)
            as is_unauthorized_address_correction_fee,
        coalesce(billed_charges.unauthorized_address_correction_fee_usd, 0)
            as unauthorized_address_correction_fee_usd,

        -- Any remaining unauthorized fee: a code the contract does not cover at
        -- all, or one whose authorization condition was not met. Carried
        -- explicitly so that no recoverable dollar can be counted at the
        -- shipment level and then go unclaimed in fct_billing_anomalies.
        round(
            coalesce(billed_charges.unauthorized_accessorial_usd, 0)
            - coalesce(billed_charges.unauthorized_residential_fee_usd, 0)
            - coalesce(billed_charges.unauthorized_address_correction_fee_usd, 0)
        , 2) as unauthorized_other_accessorial_usd,

        coalesce(
            coalesce(billed_charges.unauthorized_accessorial_usd, 0)
            - coalesce(billed_charges.unauthorized_residential_fee_usd, 0)
            - coalesce(billed_charges.unauthorized_address_correction_fee_usd, 0)
            > 0
        , false) as is_unauthorized_other_accessorial,

        -- ===============================================================
        -- GATE 4 -- Cross-Channel Duplicate Billing ("Double Dipping")
        --
        -- A shipment invoiced on the weekly EDI 210 feed, then invoiced again
        -- weeks later as a portal adjustment PDF. More than one distinct invoice
        -- number, or presence in both channels, proves it.
        -- ===============================================================
        coalesce(
            billed_charges.distinct_invoice_number_count > 1
            or billed_charges.distinct_source_channel_count > 1
        , false) as is_duplicate_billing_collision,

        -- ===============================================================
        -- GATE 5 -- SLA Failure / Late Delivery (Guaranteed Service Refund)
        --
        -- We bought premium air transit and the carrier missed the commitment.
        -- The GSR clause entitles us to a 100% refund of the transportation
        -- charge. Measured from physical dock departure, with a small grace
        -- window for clock skew between carrier scan guns and our WMS, and
        -- pursued only on GSR-eligible services because Ground carries no
        -- money-back guarantee.
        -- ===============================================================
        round(cast(
            extract(epoch from (
                billed_charges.actual_delivery_timestamp
                - physical_truth.guaranteed_delivery_timestamp
            )) / 3600.0
        as numeric), 2) as delivery_variance_hours,

        coalesce(
            physical_truth.is_gsr_eligible
            and billed_charges.actual_delivery_timestamp
                > physical_truth.guaranteed_delivery_timestamp
                  + ({{ var('sla_grace_minutes') }} * interval '1 minute')
        , false) as is_sla_delivery_failure,

        -- The carrier claiming a service level we did not buy is not one of the
        -- five gates, but it is corroborating evidence for a Gate 2 dispute.
        coalesce(
            billed_charges.service_level_billed <> physical_truth.service_level
        , false) as is_service_level_mismatch,

        coalesce(
            billed_charges.zone_billed <> physical_truth.zone
        , false) as is_zone_mismatch

    from physical_truth

    left join contract_expectations
        on physical_truth.tracking_id = contract_expectations.tracking_id

    left join billed_charges
        on physical_truth.tracking_id = billed_charges.tracking_id

),

quantified as (

    -- Attribution rule: every recoverable dollar is claimed exactly once.
    --
    -- Gates 1 and 2 are not independent. Inflating the weight pushes the parcel
    -- into a higher rate bracket, so a weight-inflated package also shows base
    -- rate variance. The dollars are therefore claimed once, through the base
    -- rate variance, and Gate 1 stands as the *reason code* that explains why
    -- the base rate was wrong. That is precisely the argument that survives
    -- carrier pushback: "your own scale record disagrees with our certified
    -- scale, and here is the resulting bracket change."
    --
    -- Gate 5 supersedes Gates 1 and 2 on the same charge. A GSR refund returns
    -- 100% of the transportation charge, so claiming the rate variance on top
    -- would be double recovery and would discredit the whole claim file.

    select
        *,

        case
            when is_sla_delivery_failure
            then round(
                coalesce(billed_base_rate_usd, 0)
                + coalesce(billed_fuel_surcharge_usd, 0)
            , 2)
            else 0
        end as gsr_refund_usd,

        case
            when is_sla_delivery_failure then 0
            else greatest(coalesce(base_rate_variance_usd, 0), 0)
        end as base_rate_recovery_usd,

        case
            when is_sla_delivery_failure then 0
            else greatest(coalesce(fuel_surcharge_variance_usd, 0), 0)
        end as fuel_recovery_usd,

        coalesce(unauthorized_accessorial_usd, 0) as accessorial_recovery_usd,

        duplicate_billed_amount_usd as duplicate_recovery_usd,

        round(
            coalesce(billed_total_all_lines_usd, 0) - expected_total_cost_usd
        , 2) as total_variance_usd,

        -- Reason codes, in gate order.
        array_to_string(
            array_remove(
                array[
                    case when is_weight_inflation
                         then 'WEIGHT_INFLATION' end,
                    case when is_base_rate_overcharge
                         then 'BASE_RATE_OVERCHARGE' end,
                    case when is_unauthorized_residential_fee
                         then 'UNAUTHORIZED_RESIDENTIAL_FEE' end,
                    case when is_unauthorized_address_correction_fee
                         then 'UNAUTHORIZED_ADDRESS_CORRECTION_FEE' end,
                    case when is_unauthorized_other_accessorial
                         then 'UNAUTHORIZED_ACCESSORIAL_OTHER' end,
                    case when is_duplicate_billing_collision
                         then 'DUPLICATE_BILLING_COLLISION' end,
                    case when is_sla_delivery_failure
                         then 'SLA_DELIVERY_FAILURE_REFUND' end
                ]::text[],
                null
            ),
            ' | '
        ) as anomaly_codes,

        (
            case when is_weight_inflation then 1 else 0 end
            + case when is_base_rate_overcharge then 1 else 0 end
            + case when is_unauthorized_residential_fee then 1 else 0 end
            + case when is_unauthorized_address_correction_fee then 1 else 0 end
            + case when is_unauthorized_other_accessorial then 1 else 0 end
            + case when is_duplicate_billing_collision then 1 else 0 end
            + case when is_sla_delivery_failure then 1 else 0 end
        ) as anomaly_count

    from reconciled

),

final as (

    select
        *,

        round(
            gsr_refund_usd
            + base_rate_recovery_usd
            + fuel_recovery_usd
            + accessorial_recovery_usd
            + duplicate_recovery_usd
        , 2) as total_recoverable_usd,

        case
            when not has_carrier_invoice then 'AWAITING_INVOICE'
            when not has_rate_card_match then 'UNRATEABLE_NO_TARIFF_MATCH'
            when anomaly_count > 0 then 'ANOMALY_DETECTED'
            else 'CLEAN'
        end as audit_status,

        -- Recovery economics drive triage: a claim costs staff time to file, so
        -- low-dollar findings are aggregated rather than disputed individually.
        --
        -- P4 is the honest answer to a real case: a parcel can be re-weighed
        -- well outside tolerance and still land inside the same rate bracket, so
        -- the carrier's weight record is provably wrong but cost us nothing.
        -- There is no invoice to dispute, yet it is exactly the evidence that
        -- wins a scale-calibration argument at contract renewal, so it is
        -- reported rather than discarded.
        case
            when not has_carrier_invoice or not has_rate_card_match then 'REVIEW'
            when anomaly_count = 0 then 'NONE'
            when gsr_refund_usd
                 + base_rate_recovery_usd
                 + fuel_recovery_usd
                 + accessorial_recovery_usd
                 + duplicate_recovery_usd <= 0 then 'P4_NO_COST_VARIANCE'
            when gsr_refund_usd
                 + base_rate_recovery_usd
                 + fuel_recovery_usd
                 + accessorial_recovery_usd
                 + duplicate_recovery_usd >= 25.00 then 'P1_FILE_IMMEDIATELY'
            when gsr_refund_usd
                 + base_rate_recovery_usd
                 + fuel_recovery_usd
                 + accessorial_recovery_usd
                 + duplicate_recovery_usd >= 10.00 then 'P2_FILE_WEEKLY_BATCH'
            else 'P3_AGGREGATE_FOR_QBR'
        end as dispute_priority

    from quantified

)

select * from final
