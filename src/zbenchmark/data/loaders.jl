# =============================================================================
# loaders.jl
#
# Julia port of `nempy.historical_inputs.loaders.RawInputsLoader`.
#
# RawInputsLoader is the single object the four high-level data classes
# (UnitData, DemandData, InterconnectorData, ConstraintData) talk to. It hides
# whether a piece of data comes from the MMS SQLite database or the NEMDE XML
# case file, and it remembers which dispatch interval is "current".
# =============================================================================

"""
    RawInputsLoader(xml_cache_manager::XMLCacheManager, mms_db_manager::DBManager)

Bundle the NEMDE XML cache and the MMS SQLite database behind one interface.
Call [`set_interval!`](@ref) before reading any inputs.
"""
mutable struct RawInputsLoader
    xml::XMLCacheManager
    mms::DBManager
    interval::Union{Nothing,DateTime}
    RawInputsLoader(xml::XMLCacheManager, mms::DBManager) = new(xml, mms, nothing)
end

"""
    set_interval!(l::RawInputsLoader, interval)

Point the loader (and its XML cache) at a particular 5-minute dispatch
interval. `interval` may be a `DateTime` or an AEMO time string such as
"2024/07/01 12:35:00". Mirrors `RawInputsLoader.set_interval`.
"""
function set_interval!(l::RawInputsLoader, interval)
    l.interval = _to_datetime(interval)
    load_interval!(l.xml, l.interval)
    return l
end

# --- Thin pass-throughs used by the higher-level data classes ---------------
_mms(l::RawInputsLoader, table) = get_table(l.mms, table; interval=l.interval)
_xml_trader_periods(l::RawInputsLoader) = xml_trader_periods(l.xml)
_xml_trade_prices(l::RawInputsLoader) = xml_trade_prices(l.xml)
_xml_generic_constraints(l::RawInputsLoader) = xml_generic_constraints(l.xml)
_xml_violation_prices(l::RawInputsLoader) = xml_violation_prices(l.xml)
_xml_initial_conditions(l::RawInputsLoader) = xml_initial_conditions(l.xml)
_xml_fast_start_parameters(l::RawInputsLoader) = xml_fast_start_parameters(l.xml)
_xml_is_ocd(l::RawInputsLoader) = xml_is_ocd(l.xml)
_xml_mnsp_offers(l::RawInputsLoader) = xml_mnsp_offers(l.xml)
_xml_loss_model(l::RawInputsLoader)  = xml_loss_model(l.xml)
