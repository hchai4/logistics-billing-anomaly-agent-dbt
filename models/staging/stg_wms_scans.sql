-- Pillar 1: Physical Reality.
--
-- Cleans and types the raw warehouse scale scans. Nothing here is derived or
-- judged; this model only makes the warehouse's own measurements trustworthy to
-- join against. Dimensional weight and billable weight are deliberately left to
-- int_package_physical_truth, because they require the contracted divisor.

with source as (

    select * from {{ source('source_enterprise', 'raw_wms_package_scans') }}

),

cleaned as (

    select
        trim(package_id)                                    as package_id,
        upper(replace(trim(tracking_id), ' ', ''))          as tracking_id,

        coalesce(upper(trim(carrier_code)), '{{ var("audit_carrier_code") }}')
                                                            as carrier_code,
        upper(trim(service_level))                          as service_level,

        -- Physical measurements
        cast(actual_scale_weight as numeric(10, 2))         as actual_scale_weight_lbs,
        cast(package_length_in as numeric(10, 2))           as package_length_in,
        cast(package_width_in as numeric(10, 2))            as package_width_in,
        cast(package_height_in as numeric(10, 2))           as package_height_in,
        cast(
            package_length_in * package_width_in * package_height_in
            as numeric(14, 2)
        )                                                   as package_volume_cuin,

        -- Geography. ZIP3 is the grain the carrier zone matrix is published at.
        upper(trim(origin_warehouse))                       as origin_warehouse,
        trim(origin_zip)                                    as origin_zip,
        left(trim(origin_zip), 3)                           as origin_zip3,
        trim(dest_zip)                                      as dest_zip,
        left(trim(dest_zip), 3)                             as dest_zip3,

        -- Delivery-point metadata: the evidence base for Gate 3.
        upper(trim(dest_address_type))                      as dest_address_type,
        coalesce(dest_address_cass_validated, false)        as is_dest_address_cass_validated,

        -- Timestamps. Dock departure, not conveyor scan, starts the SLA clock.
        cast(scan_timestamp as timestamp)                   as scan_timestamp,
        cast(scan_timestamp as date)                         as scan_date,
        cast(dock_departure_timestamp as timestamp)         as dock_departure_timestamp,

        cast(expected_cost as numeric(12, 2))               as legacy_expected_cost_usd

    from source
    where tracking_id is not null

)

select * from cleaned
