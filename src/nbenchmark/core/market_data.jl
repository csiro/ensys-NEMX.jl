# =============================================================================
# market_data.jl
#
# Per-interval market inputs, taken unchanged from the zonal benchmark so both
# models are driven by byte-identical offers, availabilities and constraints.
#
# Split out of the single-file `NetworkDispatch.jl` of the reference
# implementation. The code is unchanged apart from module-qualification of
# names that now live in `NEMX.ZBenchmark`; only its location has moved. All
# of these files are `include`d into the same `NBenchmark` module, so
# definition order across them does not matter.
# =============================================================================


# ---------------------------------------------------------------------------
# Market inputs for one interval (straight from nemjl, identical to benchmark)
# ---------------------------------------------------------------------------
function load_market(interval::DateTime; data_dir::String="./data/nempy_2024_07")
    mms = DBManager(joinpath(data_dir, "historical_mms.db"))
    xml = XMLCacheManager(joinpath(data_dir, "xml_cache"))
    L = RawInputsLoader(xml, mms)
    set_interval!(L, interval)
    u = UnitData(L); ic = InterconnectorData(L)
    con = ConstraintData(L); dem = DemandData(L)
    vb, pb = get_processed_bids(u)
    add_fcas_trapezium_constraints!(u)
    gc, ulhs, ilhs, rlhs = get_generic_constraints(con)
    return (interval=interval, u=u,
            unit_info=get_unit_info(u), vb=vb, pb=pb,
            avail=get_unit_bid_availability(u), uigf=get_unit_uigf_limits(u),
            ramp=get_bid_ramp_rates(u), scada=get_scada_ramp_rates(u; include_initial_output=true),
            regtrap=get_fcas_regulation_trapeziums(u), conttrap=get_contingency_services(u),
            maxav=get_fcas_max_availability(u),
            icdef=get_interconnector_definitions(ic),
            gc=gc, ulhs=ulhs, ilhs=ilhs, rlhs=rlhs,
            cvp=get_constraint_violation_prices(con),
            gccost=get_violation_costs(con),
            demand=get_operational_demand(dem), mms=mms)
end
