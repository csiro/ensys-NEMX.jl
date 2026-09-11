# =============================================================================
# export_interval_csvs.jl
#
# Dump every market input for one dispatch interval to CSV: offers, availability,
# ramp rates, FCAS trapeziums, interconnector definitions and loss models,
# generic constraints and their violation prices, and regional demand.
#
# This is the tool for answering "what did the model actually see?" — for
# inspecting an interval by hand, for filing a reproducible bug report, and for
# building a fixture from a real interval.
#
# ARGUMENTS
#   Positional    Env               Default            Meaning
#   ------------  ----------------  -----------------  ------------------------
#   1             NEMX_INTERVAL     2025-09-02T12:05   the dispatch interval
#
#   Options       Env               Default                 Meaning
#   ------------  ----------------  ----------------------  -------------------
#   --data-dir=   NEMX_DATA_DIR     data/nempy_<month>      MMS db + XML cache
#   --out-dir=    NEMX_OUT_DIR      interval_<stamp>        where to write
#
# EXAMPLE
#   julia --project=. scripts/export_interval_csvs.jl 2025-09-02T13:25
# =============================================================================

using NEMX
using CSV
using DataFrames
using Dates
using JuMP
using Printf
using Statistics

const ZB = NEMX.ZBenchmark
const NB = NEMX.NBenchmark
using NEMX.ZBenchmark
using NEMX.NBenchmark
const SNAP_DATA_DIR = resolve_input_dir(joinpath(NEMX.PKG_DIR, "data", "nempy_2025_09"))

"Interval length in hours (NEM dispatch = 5 minutes)."
const SNAP_TAU = 5 / 60

print_banner("Export every market input for one interval",
             "data dir" => SNAP_DATA_DIR)

_f(x) = ismissing(x) ? missing : (x isa Number ? float(x) :
        (tryparse(Float64, string(x)) === nothing ? missing : parse(Float64, string(x))))

# NaN-tolerant minimum of bid and SCADA ramp rates (nempy's fmin semantics).
_fmin(a, b) = ismissing(b) ? a : (ismissing(a) ? b : min(a, b))

"""
    write_interval_csvs(interval::DateTime;
                        data_dir=SNAP_DATA_DIR,
                        outdir=nothing,
                        ramp_tol=1e-3) -> String

Rebuild and solve the dispatch for `interval` (full two-pass fast-start
procedure, OCD re-run when applicable), then write the snapshot CSVs described
in the file header. Returns the output directory path.
"""
function write_interval_csvs(interval::DateTime;
                             data_dir::String=SNAP_DATA_DIR,
                             outdir::Union{Nothing,String}=nothing,
                             ramp_tol::Real=1e-3)
    stamp = Dates.format(interval, dateformat"yyyymmdd_HHMM")
    out = outdir === nothing ? joinpath(data_dir, "snapshots", stamp) : outdir
    mkpath(out)

    # ------------------------------------------------------------------ inputs
    mms = DBManager(joinpath(data_dir, "historical_mms.db"))
    xml = XMLCacheManager(joinpath(data_dir, "xml_cache"))
    L = RawInputsLoader(xml, mms)
    set_interval!(L, interval)

    u   = UnitData(L)
    ic  = InterconnectorData(L)
    con = ConstraintData(L)
    dem = DemandData(L)
    cvp = get_constraint_violation_prices(con)

    unit_info = get_unit_info(u)
    market = SpotMarket(market_regions=["QLD1", "NSW1", "VIC1", "SA1", "TAS1"],
                        unit_info=unit_info)

    vb, pb = get_processed_bids(u)
    set_unit_volume_bids!(market, vb)
    set_unit_price_bids!(market, pb)
    set_unit_bid_capacity_constraints!(market, get_unit_bid_availability(u);
                                       violation_cost=cvp["unit_capacity"])
    set_unconstrained_intermittent_generation_forecast_constraint!(
        market, get_unit_uigf_limits(u); violation_cost=cvp["uigf"])
    fsp1 = get_fast_start_profiles_for_dispatch(u)
    set_unit_ramp_rate_constraints!(market, get_bid_ramp_rates(u), get_scada_ramp_rates(u);
        fast_start_profiles=fsp1, run_type="fast_start_first_run",
        violation_cost=cvp["ramp_rate"])
    add_fcas_trapezium_constraints!(u)
    set_fcas_max_availability!(market, get_fcas_max_availability(u);
                               violation_cost=cvp["fcas_max_avail"])
    set_energy_and_regulation_capacity_constraints!(
        market, get_fcas_regulation_trapeziums(u); violation_cost=cvp["fcas_profile"])
    set_joint_ramping_constraints_reg!(market,
        get_scada_ramp_rates(u; include_initial_output=true);
        fast_start_profiles=fsp1, run_type="fast_start_first_run",
        violation_cost=cvp["fcas_profile"])
    set_joint_capacity_constraints!(market, get_contingency_services(u);
                                    violation_cost=cvp["fcas_profile"])
    set_interconnectors!(market, get_interconnector_definitions(ic))
    lossf, bpts = get_interconnector_loss_model(ic)
    set_interconnector_losses!(market, lossf, bpts)
    gc, ulhs, ilhs, rlhs = get_generic_constraints(con)
    set_generic_constraints!(market, gc; violation_cost=get_violation_costs(con))
    link_units_to_generic_constraints!(market, ulhs)
    link_interconnectors_to_generic_constraints!(market, ilhs)
    link_regions_to_generic_constraints!(market, rlhs)
    set_demand_constraints!(market, get_operational_demand(dem);
                            violation_cost=cvp["regional_demand"])
    set_tie_break_constraints!(market, cvp["tiebreak"])

    # -------------------------------------------------------- two-pass solve
    dispatch!(market)
    fsp = get_fast_start_profiles_for_dispatch(u;
              unconstrained_dispatch=get_unit_dispatch(market))
    if !isempty(fsp)
        set_fast_start_constraints!(market,
            fsp[:, [:unit, :end_mode, :time_in_end_mode, :mode_two_length,
                    :mode_four_length, :min_loading]];
            violation_cost=cvp["fast_start"])
        fsp2 = fsp[:, [:unit, :end_mode, :time_since_end_of_mode_two, :min_loading]]
        set_unit_ramp_rate_constraints!(market, get_bid_ramp_rates(u), get_scada_ramp_rates(u);
            fast_start_profiles=fsp2, run_type="fast_start_second_run",
            violation_cost=cvp["ramp_rate"])
        set_joint_ramping_constraints_reg!(market,
            get_scada_ramp_rates(u; include_initial_output=true);
            fast_start_profiles=fsp2, run_type="fast_start_second_run",
            violation_cost=cvp["fcas_profile"])
    end
    if is_over_constrained_dispatch_rerun(con)
        dispatch!(market; allow_over_constrained_dispatch_re_run=true,
                  energy_market_floor_price=-1000.0,
                  energy_market_ceiling_price=17500.0,
                  fcas_market_ceiling_price=1000.0)
    else
        dispatch!(market)
    end

    disp   = get_unit_dispatch(market)
    prices = get_energy_prices(market)

    # ------------------------------------------------------- solved lookups
    # Energy set-point per (unit, dispatch_type) and per-unit NET (for BDUs).
    esp = Dict{Tuple{String,String},Float64}()
    fcas_tgt = Dict{Tuple{String,String,String},Float64}()
    for r in eachrow(disp)
        k = (string(r.unit), string(r.dispatch_type))
        if string(r.service) == "energy"
            esp[k] = get(esp, k, 0.0) + r.dispatch
        else
            fcas_tgt[(k[1], k[2], string(r.service))] = r.dispatch
        end
    end
    both = Set(un for (un, dt) in keys(esp) if haskey(esp, (un, "generator")) &&
                                               haskey(esp, (un, "load")))
    enet(un) = get(esp, (un, "generator"), 0.0) - get(esp, (un, "load"), 0.0)

    # Raw per-unit state.
    init_mw = Dict(string(r.unit) => _f(r.initial_mw)     for r in eachrow(u.initial))
    scada_up = Dict(string(r.unit) => _f(r.scada_ramp_up)  for r in eachrow(u.initial))
    scada_dn = Dict(string(r.unit) => _f(r.scada_ramp_down) for r in eachrow(u.initial))
    agc     = Dict(string(r.unit) => _f(r.agc_status)     for r in eachrow(u.initial))
    ttype   = Dict(string(r.unit) => string(r.trader_type) for r in eachrow(u.initial))
    uigf    = Dict(string(r.unit) => _f(r.capacity) for r in eachrow(get_unit_uigf_limits(u)))
    cap     = Dict((string(r.unit), string(r.dispatch_type)) => _f(r.capacity)
                   for r in eachrow(get_unit_bid_availability(u)))
    bid_rr  = Dict((string(r.unit), string(r.dispatch_type)) =>
                   (_f(r.ramp_up_rate), _f(r.ramp_down_rate))
                   for r in eachrow(get_bid_ramp_rates(u)))

    # ------------------------------------------------------ participants.csv
    P = DataFrame(unit=String[], dispatch_type=String[], region=String[],
                  trader_type=String[], mlf=Float64[],
                  energy_max_avail_mw=Union{Missing,Float64}[],
                  uigf_cap_mw=Union{Missing,Float64}[],
                  initial_mw=Union{Missing,Float64}[],
                  agc_status=Union{Missing,Float64}[],
                  bid_ramp_up_mw_per_h=Union{Missing,Float64}[],
                  bid_ramp_down_mw_per_h=Union{Missing,Float64}[],
                  scada_ramp_up_mw_per_h=Union{Missing,Float64}[],
                  scada_ramp_down_mw_per_h=Union{Missing,Float64}[],
                  effective_ramp_up_mw_per_h=Union{Missing,Float64}[],
                  effective_ramp_down_mw_per_h=Union{Missing,Float64}[],
                  ramp_window_low_mw=Union{Missing,Float64}[],
                  ramp_window_high_mw=Union{Missing,Float64}[],
                  energy_setpoint_mw=Float64[],
                  net_setpoint_mw=Union{Missing,Float64}[],
                  ramp_up_limited=Bool[], ramp_down_limited=Bool[],
                  binding_ramp_source_up=String[], binding_ramp_source_dn=String[])
    for r in eachrow(unit_info)
        un = string(r.unit); dt = string(r.dispatch_type)
        rr = get(bid_rr, (un, dt), (missing, missing))
        su = get(scada_up, un, missing); sd = get(scada_dn, un, missing)
        eu = _fmin(rr[1], su); ed = _fmin(rr[2], sd)
        e0 = get(init_mw, un, missing)
        # 5-minute movement window from the effective rates.
        lo = (ismissing(e0) || ismissing(ed)) ? missing : e0 - ed * SNAP_TAU
        hi = (ismissing(e0) || ismissing(eu)) ? missing : e0 + eu * SNAP_TAU
        sp = get(esp, (un, dt), 0.0)
        # BDU ramp constraints act on the NET set-point; others on the side's own.
        tgt = un in both ? enet(un) : (dt == "load" ? sp : sp)
        upl = (!ismissing(hi)) && abs(tgt - hi) <= ramp_tol
        dnl = (!ismissing(lo)) && abs(tgt - lo) <= ramp_tol
        srcu = upl ? ((!ismissing(su) && !ismissing(rr[1]) && su < rr[1]) ? "scada" :
                      (ismissing(rr[1]) ? "scada" : "bid")) : ""
        srcd = dnl ? ((!ismissing(sd) && !ismissing(rr[2]) && sd < rr[2]) ? "scada" :
                      (ismissing(rr[2]) ? "scada" : "bid")) : ""
        push!(P, (un, dt, string(r.region), get(ttype, un, ""),
                  float(r.loss_factor),
                  get(cap, (un, dt), missing), get(uigf, un, missing),
                  e0, get(agc, un, missing),
                  rr[1], rr[2], su, sd, eu, ed, lo, hi,
                  sp, un in both ? enet(un) : missing,
                  upl, dnl, srcu, srcd))
    end
    sort!(P, [:region, :unit, :dispatch_type])
    CSV.write(joinpath(out, "participants.csv"), P)

    # --------------------------------------------------------------- bids.csv
    B = DataFrame(unit=String[], dispatch_type=String[], service=String[])
    for i in 1:10; B[!, "volume_band_$(i)_mw"] = Float64[]; end
    for i in 1:10; B[!, "price_band_$(i)"] = Float64[]; end
    B[!, "dispatch_mw"] = Float64[]
    for i in 1:nrow(vb)
        un = string(vb.unit[i]); dt = string(vb.dispatch_type[i]); sv = string(vb.service[i])
        j = findfirst((pb.unit .== un) .& (pb.dispatch_type .== dt) .& (pb.service .== sv))
        vols = [float(vb[i, string(k)]) for k in 1:10]
        prc  = j === nothing ? zeros(10) : [float(pb[j, string(k)]) for k in 1:10]
        d = sv == "energy" ? get(esp, (un, dt), 0.0) : get(fcas_tgt, (un, dt, sv), 0.0)
        push!(B, (un, dt, sv, vols..., prc..., d))
    end
    sort!(B, [:unit, :dispatch_type, :service])
    CSV.write(joinpath(out, "bids.csv"), B)

    # ---------------------------------------------------- fcas_trapeziums.csv
    traps = vcat(get_fcas_regulation_trapeziums(u), get_contingency_services(u))
    T = DataFrame(unit=String[], dispatch_type=String[], service=String[],
                  max_availability_mw=Float64[], enablement_min_mw=Float64[],
                  low_break_point_mw=Float64[], high_break_point_mw=Float64[],
                  enablement_max_mw=Float64[], upper_slope_coeff=Float64[],
                  lower_slope_coeff=Float64[], fcas_target_mw=Float64[])
    for r in eachrow(traps)
        un = string(r.unit); dt = string(r.dispatch_type); sv = string(r.service)
        A = float(r.max_availability)
        su_ = A > 0 ? (float(r.enablement_max) - float(r.high_break_point)) / A : 0.0
        sl_ = A > 0 ? (float(r.low_break_point) - float(r.enablement_min)) / A : 0.0
        push!(T, (un, dt, sv, A, float(r.enablement_min), float(r.low_break_point),
                  float(r.high_break_point), float(r.enablement_max), su_, sl_,
                  get(fcas_tgt, (un, dt, sv), 0.0)))
    end
    sort!(T, [:unit, :dispatch_type, :service])
    CSV.write(joinpath(out, "fcas_trapeziums.csv"), T)

    # ------------------------------------------------------- fcas_targets.csv
    F = DataFrame(unit=String[], dispatch_type=String[], service=String[],
                  target_mw=Float64[])
    for ((un, dt, sv), v) in sort(collect(fcas_tgt); by=first)
        push!(F, (un, dt, sv, v))
    end
    CSV.write(joinpath(out, "fcas_targets.csv"), F)

    # ------------------------------------------------------ demand_prices.csv
    ddf = get_operational_demand(dem)
    rop = Dict{String,Float64}()
    try
        hist = get_table(mms, "DISPATCHPRICE"; interval=interval)
        for r in eachrow(hist)
            v = tryparse(Float64, string(r.ROP))
            v === nothing || (rop[string(r.REGIONID)] = v)
        end
    catch
    end
    D = DataFrame(region=String[], demand_mw=Float64[], price=Float64[],
                  aemo_rop=Union{Missing,Float64}[])
    pmap = Dict(string(r.region) => float(r.price) for r in eachrow(prices))
    for r in eachrow(ddf)
        rg = string(r.region)
        push!(D, (rg, float(r.demand), get(pmap, rg, NaN), get(rop, rg, missing)))
    end
    CSV.write(joinpath(out, "demand_prices.csv"), D)

    @printf("Snapshot for %s written to %s\n", string(interval), out)
    @printf("  participants: %d rows | bids: %d | trapeziums: %d | fcas targets: %d\n",
            nrow(P), nrow(B), nrow(T), nrow(F))
    n_ramp = sum(P.ramp_up_limited .| P.ramp_down_limited)
    @printf("  units with set-point on a ramp limit: %d\n", n_ramp)
    return out
end

# --- Command-line entry point ------------------------------------------------
if abspath(PROGRAM_FILE) == @__FILE__
    iv = length(ARGS) >= 1 ? DateTime(ARGS[1]) : DateTime(2024, 7, 8, 15, 30)
    write_interval_csvs(iv)
end
