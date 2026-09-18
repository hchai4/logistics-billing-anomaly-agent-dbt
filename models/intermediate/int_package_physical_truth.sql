-- Pillar 1 resolved against Pillar 2: what the package physically was, and what
-- billable weight the contract says that makes it.
--
-- The zone is resolved from the ZIP3 pair the warehouse actually recorded, never
-- from the zone the carrier printed on the invoice. That independence is what
-- lets Gate 2 contradict the carrier rather than merely restate it.
--
-- Grain: one row per package.

with scans as (

    select * from {{ ref('stg_wms_scans') }}

),

contract_terms as (

    select * from {{ ref('carrier_contract_terms') }}

),

zone_matrix as (

    select * from {{ ref('carrier_zone_matrix') }}

),

service_levels as (

    select * from {{ ref('carrier_service_levels') }}

),

joined as (

    select
        scans.package_id,
        scans.tracking_id,
        scans.carrier_code,
        scans.service_level,

        contract_terms.contract_id,
        contract_terms.dim_divisor,

        zone_matrix.zone,

        service_levels.guaranteed_transit_hours,
        service_levels.is_gsr_eligible,

        scans.actual_scale_weight_lbs,
        scans.package_length_in,
        scans.package_width_in,
        scans.package_height_in,
        scans.package_volume_cuin,

        scans.origin_warehouse,
        scans.origin_zip,
        scans.origin_zip3,
        scans.dest_zip,
        scans.dest_zip3,
        scans.dest_address_type,
        scans.is_dest_address_cass_validated,

        scans.scan_timestamp,
        scans.scan_date,
        scans.dock_departure_timestamp,

        -- Dimensional weight per the contracted divisor, from the dimensions the
        -- cubing laser recorded.
        round(scans.package_volume_cuin / contract_terms.dim_divisor, 2)
            as dim_weight_lbs

    from scans

    left join contract_terms
        on scans.carrier_code = contract_terms.carrier_code
       and scans.scan_date between contract_terms.effective_date
                               and contract_terms.expiration_date

    left join zone_matrix
        on scans.carrier_code = zone_matrix.carrier_code
       and scans.origin_zip3 = zone_matrix.origin_zip3
       and scans.dest_zip3 = zone_matrix.dest_zip3

    left join service_levels
        on scans.carrier_code = service_levels.carrier_code
       and scans.service_level = service_levels.service_level

),

billable as (

    select
        *,

        -- Carriers bill the greater of actual and dimensional weight. This is
        -- the contractual billable weight, expressed before rounding.
        greatest(actual_scale_weight_lbs, dim_weight_lbs)
            as billable_weight_expected_lbs,

        -- The weight the rate card is actually looked up at: carriers round the
        -- billable weight up to the next whole pound.
        cast(ceil(greatest(actual_scale_weight_lbs, dim_weight_lbs)) as integer)
            as rating_weight_lbs,

        -- Whether dimensional weight or scale weight governs. Useful context for
        -- a dispute letter, because DIM-governed packages are where divisor
        -- manipulation hides.
        case
            when dim_weight_lbs > actual_scale_weight_lbs then 'DIMENSIONAL'
            else 'ACTUAL_SCALE'
        end as billable_weight_basis,

        -- The SLA clock runs from physical trailer departure, not conveyor scan.
        dock_departure_timestamp
            + (guaranteed_transit_hours * interval '1 hour')
            as guaranteed_delivery_timestamp

    from joined

)

select * from billable
