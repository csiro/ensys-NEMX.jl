# =============================================================================
# run_network_day.jl
#
# Sweep the NETWORK-CONSTRAINED nodal dispatch over a run of five-minute
# intervals — one full NEM trading day by default — across any set of
# power-flow formulations, and write every price series, the LMP decomposition
# and the active-constraint ledger to CSV.
#
# The market inputs are the SAME ones the zonal benchmark uses. Only the network
# representation changes, so any difference in price is attributable to that and
# to nothing else. The window defaults to a day that sits inside the cached
# September-2025 span, so nodal and zonal runs are comparable interval for
# interval.
#
# -----------------------------------------------------------------------------
# OUTPUTS  (in --data-dir, stamped with the start interval)
#
#   network_day_prices_<stamp>.csv         (time, formulation, region): regional
#                                          reference price, losses, objective,
#                                          termination status, solve time
#   network_day_decomposition_<stamp>.csv  (time, formulation, region):
#                                          lmp = energy + congestion + loss
#   network_day_fcas_prices_<stamp>.csv    regional FCAS requirement duals
#   network_day_binding_<stamp>.csv        active-constraint shadow-price ledger
#   network_day_participant_<stamp>.csv    per-participant local prices against
#                                          the zonal benchmark
#   network_day_benchmark_<stamp>.csv      the MLF-scaled zonal reference run
#   network_day_lmp_<stamp>.csv            OPTIONAL per-bus LMPs (--with-lmp)
#
# -----------------------------------------------------------------------------
# ARGUMENTS
#
#   Positional      Env                Default              Meaning
#   --------------  -----------------  -------------------  --------------------
#   1               NEMX_NET_START     2025-09-02T04:05     first interval
#   2               NEMX_NET_N         288                  number of intervals
#   3               NEMX_NET_FORMS     DCP,LPACC,SOCWR,QCRM,ACP   formulations
#
#   Options         Env                Default              Meaning
#   --------------  -----------------  -------------------  --------------------
#   --data-dir=     NEMX_DATA_DIR      data/nempy_<month>   MMS db + XML cache
#   --mfile=        NEMX_MFILE         data/snem2000_fixed.m   network case
#   --checkpoint=   NEMX_CHECKPOINT    12                   flush every N intervals
#
#   Flags           Env                Meaning
#   --------------  -----------------  ------------------------------------------
#   --with-lmp      NEMX_NET_LMP       Also write the full per-bus LMP series.
#                                      About 2000 rows per interval per
#                                      formulation, so off by default.
#
# FORMULATIONS
#   DCP      linear DC, HiGHS                     seconds per interval
#   DCP_MLF  DC with MLF-scaled injections        seconds
#   LPACC    LP AC approximation, Ipopt           tens of seconds
#   SOCWR    second-order-cone relaxation, Ipopt  tens of seconds
#   QCRM     quadratic-convex relaxation, Ipopt   tens of seconds
#   ACP      full AC polar, Ipopt                 tens of seconds
#
# Each formulation carries its own solver, chosen in `NEMX.NBenchmark.FORMULATIONS`
# — an LP formulation gets HiGHS and a non-linear one gets Ipopt, because mixing
# them is never what you want. Override a formulation's solver by editing that
# registry rather than by passing a flag here.
#
# -----------------------------------------------------------------------------
# EXAMPLES
#
#   # A DC-only day: quick, and the right first run to validate a window
#   julia --project=. scripts/nbenchmark/run_network_day.jl 2025-09-02T04:05 288 DCP
#
#   # Every formulation, with per-bus LMPs — an overnight job
#   julia --project=. scripts/nbenchmark/run_network_day.jl 2025-09-02T04:05 288 \
#         DCP,LPACC,SOCWR,QCRM,ACP --with-lmp
#
#   # A single hour, to check a change
#   julia --project=. scripts/nbenchmark/run_network_day.jl 2025-09-02T12:00 12 DCP,ACP
#
# RUNTIME: DCP and DCP_MLF are LPs, seconds per interval. ACP and the convex
# relaxations are 2000-bus non-linear programs taking tens of seconds each, so a
# 288-interval sweep across all of them runs overnight. Results are checkpointed,
# so an interrupted run still leaves usable CSVs.
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

# Both submodules' public names are brought into scope unqualified, because this
# script reads much better as `solve_network_dispatch(...)` than as
# `NB.solve_network_dispatch(...)` twenty times over. The `ZB`/`NB` aliases stay
# available for the handful of internal names that are not exported.
using NEMX.ZBenchmark
using NEMX.NBenchmark

# --- Configuration (positional args or environment variables) ----------------
const START     = script_datetime(script_positional(1, "NEMX_NET_START", "2025-09-02T04:05"))
const N         = script_integer(script_positional(2, "NEMX_NET_N", "288"))
const FORMS     = script_list(script_positional(3, "NEMX_NET_FORMS", "DCP,LPACC,SOCWR,QCRM,ACP")) # DC_MLF is a special case of DCP, so not included by default
const WITH_LMP  = script_flag("with-lmp")
const CHECKPOINT_EVERY = script_integer(script_option("checkpoint", "12"))  # an hour of dispatch

# The data directory follows the interval's month unless --data-dir says otherwise.
const DATA_DIR = resolve_input_dir(joinpath(NEMX.PKG_DIR, "data",
                     @sprintf("nempy_%04d_%02d", year(START), month(START))))
const MFILE = script_option("mfile", joinpath(NEMX.PKG_DIR, "data", "snem2000_fixed.m"))
isfile(MFILE) || error("missing network case $MFILE — pass --mfile=PATH, or build it with scripts/nbenchmark/fix_snem2000_case.jl")
isdir(DATA_DIR) || error("missing data directory $DATA_DIR")

intervals = [START + Minute(5 * (i - 1)) for i in 1:N]
stamp = Dates.format(START, "yyyymmdd_HHMM")
out(name) = joinpath(DATA_DIR, "network_day_$(name)_$(stamp).csv")

# ---------------------------------------------------------------------------
# SOLVER OVERRIDE
#
# By default each formulation uses the solver the registry pairs it with:
# HiGHS for a linear formulation, Ipopt for a non-linear one. Mixing them is
# never what is wanted, so a single --solver would be the wrong control.
#
# --lp-solver and --nlp-solver override the two halves independently. Leaving
# both unset -- the normal case -- uses the registry.
# ---------------------------------------------------------------------------

"The formulations that are linear programs, and so want an LP solver."
const LINEAR_FORMULATIONS = ("DCP", "DCP_MLF")

const LP_SOLVER_NAME  = script_option("lp-solver", "")
const NLP_SOLVER_NAME = script_option("nlp-solver", "")

"""
    solver_override(formulation) -> Union{Nothing,Any}

The optimizer to use for `formulation`, or `nothing` to use the registry's.

Picks the LP or the NLP override by whether the formulation is a linear
program, so that `--nlp-solver=ipopt` cannot accidentally be handed to a DC
model.
"""
function solver_override(formulation::AbstractString)
    name = formulation in LINEAR_FORMULATIONS ? LP_SOLVER_NAME : NLP_SOLVER_NAME
    if isempty(name)
        return nothing
    end
    return select_solver(name; silent = !script_flag("verbose-solver"))
end

print_banner("Network-constrained nodal dispatch sweep",
             "start" => START, "intervals" => N,
             "formulations" => join(FORMS, ","),
             "network case" => MFILE, "data dir" => DATA_DIR,
             "per-bus LMPs" => WITH_LMP,
             "checkpoint every" => CHECKPOINT_EVERY,
             "LP solver override" => isempty(LP_SOLVER_NAME) ? "(registry)" : LP_SOLVER_NAME,
             "NLP solver override" => isempty(NLP_SOLVER_NAME) ? "(registry)" : NLP_SOLVER_NAME)
print_flag_values(NB, :NODAL_MLF_PRICE_REFERRAL, :BALANCE_SLACK_ENABLED,
            :NLP_RETRY_ENABLED)

# --- Output frames -----------------------------------------------------------
# `first_status` and `attempts` record whether an interval was RECOVERED by the
# NLP retry rather than having solved outright, so a retry is visible in the
# results rather than silently absorbed.
prices  = DataFrame(time=DateTime[], formulation=String[], region=String[],
                    rrn_bus=Int[], price=Float64[], status=String[],
                    objective=Float64[], losses_mw=Float64[], solve_s=Float64[],
                    first_status=String[], attempts=Int[])
# The MLF-SCALED ZONAL REFERENCE. Every nodal formulation now runs on the
# reference-node-referred bid stack (NODAL_MLF_PRICE_REFERRAL), so the baseline
# they are measured against is a zonal dispatch of the SAME day built on the
# connection-point-scaled stack. Differences between a formulation and this
# series are then attributable to the power-flow model, not to the bid stack.
# This is a special RUN of the benchmark engine, never a change to it: the flag
# defaults off and nothing in script/run_historical_dispatch*.jl sets it.
bench   = DataFrame(time=DateTime[], region=String[], price=Float64[])
# PARTICIPANT-NODE LMPs against that baseline. The regional reference node is one
# bus of ~2000; what a participant actually faces is the price at ITS node, and
# the distribution of those deviations is what separates the formulations. Stored
# per (interval, formulation, unit) rather than per bus, so the file stays small
# while still supporting median/bias/over-under statistics.
partic  = DataFrame(time=DateTime[], formulation=String[], region=String[],
                    unit=String[], bus=Int[], gamma=Float64[], lmp=Float64[],
                    zonal=Float64[], zonal_cp=Float64[], dev=Float64[])
decomp  = DataFrame(time=DateTime[], formulation=String[], region=String[],
                    lmp=Float64[], energy=Float64[], congestion=Float64[], loss=Float64[])
fcasp   = DataFrame(time=DateTime[], formulation=String[], constraint=String[],
                    service=String[], region=String[], price=Float64[],
                    rhs=Float64[], binding=Bool[])
# `slack` and `at_bound` are the PRIMAL binding test: a constraint is active
# because it sits at its bound, not because its multiplier clears a magnitude
# threshold. Interior-point solves leave a large near-active set carrying
# multipliers of order 1e-5 that a dual test cannot distinguish from prices.
binding = DataFrame(time=DateTime[], formulation=String[], family=String[],
                    constraint=String[], service=String[], region=String[],
                    dual=Float64[], rhs=Float64[], lhs=Float64[],
                    slack=Float64[], at_bound=Bool[],
                    refs_interconnector=Bool[])
lmps    = DataFrame(time=DateTime[], formulation=String[], bus=Int[], lmp=Float64[])

function flush_all()
    CSV.write(out("prices"), prices)
    CSV.write(out("benchmark"), bench)
    CSV.write(out("participant"), partic)
    CSV.write(out("decomposition"), decomp)
    CSV.write(out("fcas_prices"), fcasp)
    CSV.write(out("binding"), binding)
    WITH_LMP && CSV.write(out("lmp"), lmps)
end

# Parse the network case ONCE; solve_network_dispatch deep-copies per solve.
net = NB.load_network(MFILE)

"""
    zonal_mlf_reference(iv, mkt) -> DataFrame(region, price)

Dispatch the ZONAL benchmark engine for `iv` with `ZONAL_MLF_KEEP_SCALING` set,
i.e. with the connection-point-scaled bid stack left in place rather than
referred back to the regional reference node.

This is the comparison baseline for the whole nodal study. It reuses the market
inputs already loaded for the interval, so only the interconnector and
constraint objects are rebuilt; the flag is restored afterwards so a later call
into the benchmark cannot inherit it.
"""
function zonal_mlf_reference(iv::DateTime, mkt)
    D  = "./" * DATA_DIR
    L  = RawInputsLoader(XMLCacheManager(joinpath(D, "xml_cache")),
                         DBManager(joinpath(D, "historical_mms.db")))
    set_interval!(L, iv)
    ic = InterconnectorData(L); con = ConstraintData(L)
    cvp = mkt.cvp
    prev = ZB.ZONAL_MLF_KEEP_SCALING[]
    ZB.ZONAL_MLF_KEEP_SCALING[] = true            # keep the scaled bid stack
    try
        m = SpotMarket(market_regions = ["QLD1","NSW1","VIC1","SA1","TAS1"],
                       unit_info = mkt.unit_info)
        set_unit_volume_bids!(m, mkt.vb); set_unit_price_bids!(m, mkt.pb)
        set_unit_bid_capacity_constraints!(m, mkt.avail; violation_cost=cvp["unit_capacity"])
        set_unconstrained_intermittent_generation_forecast_constraint!(m, mkt.uigf;
            violation_cost=cvp["uigf"])
        fsp1 = get_fast_start_profiles_for_dispatch(mkt.u)
        set_unit_ramp_rate_constraints!(m, mkt.ramp, get_scada_ramp_rates(mkt.u);
            fast_start_profiles=fsp1, run_type="fast_start_first_run",
            violation_cost=cvp["ramp_rate"])
        set_fcas_max_availability!(m, mkt.maxav; violation_cost=cvp["fcas_max_avail"])
        set_energy_and_regulation_capacity_constraints!(m, mkt.regtrap;
            violation_cost=cvp["fcas_profile"])
        set_joint_ramping_constraints_reg!(m, mkt.scada; fast_start_profiles=fsp1,
            run_type="fast_start_first_run", violation_cost=cvp["fcas_profile"])
        set_joint_capacity_constraints!(m, mkt.conttrap; violation_cost=cvp["fcas_profile"])
        set_interconnectors!(m, mkt.icdef)
        lossf, bpts = get_interconnector_loss_model(ic)
        set_interconnector_losses!(m, lossf, bpts)
        set_generic_constraints!(m, mkt.gc; violation_cost=mkt.gccost)
        link_units_to_generic_constraints!(m, mkt.ulhs)
        link_interconnectors_to_generic_constraints!(m, mkt.ilhs)
        link_regions_to_generic_constraints!(m, mkt.rlhs)
        set_demand_constraints!(m, mkt.demand; violation_cost=cvp["regional_demand"])
        set_tie_break_constraints!(m, cvp["tiebreak"])
        dispatch!(m)
        # Two-pass fast-start commitment, exactly as the benchmark driver does.
        fsp = get_fast_start_profiles_for_dispatch(mkt.u;
                  unconstrained_dispatch=get_unit_dispatch(m))
        if !isempty(fsp)
            set_fast_start_constraints!(m, fsp[:, [:unit,:end_mode,:time_in_end_mode,
                :mode_two_length,:mode_four_length,:min_loading]];
                violation_cost=cvp["fast_start"])
            fsp2 = fsp[:, [:unit,:end_mode,:time_since_end_of_mode_two,:min_loading]]
            set_unit_ramp_rate_constraints!(m, mkt.ramp, get_scada_ramp_rates(mkt.u);
                fast_start_profiles=fsp2, run_type="fast_start_second_run",
                violation_cost=cvp["ramp_rate"])
            set_joint_ramping_constraints_reg!(m, mkt.scada; fast_start_profiles=fsp2,
                run_type="fast_start_second_run", violation_cost=cvp["fcas_profile"])
        end
        if is_over_constrained_dispatch_rerun(con)
            dispatch!(m; allow_over_constrained_dispatch_re_run=true,
                     energy_market_floor_price=-1000.0,
                     energy_market_ceiling_price=cvp["voll"],
                     fcas_market_ceiling_price=1000.0)
        else
            dispatch!(m)
        end
        return get_energy_prices(m)
    finally
        ZB.ZONAL_MLF_KEEP_SCALING[] = prev
    end
end

nfail = 0
for (k, iv) in enumerate(intervals)
    # Market inputs are interval-specific: load once, reuse across formulations.
    mkt = try
        NB.load_market(iv; data_dir = DATA_DIR)
    catch err
        @warn "skipping $iv (market inputs unavailable)" err
        global nfail += 1
        continue
    end

    # MLF-scaled zonal reference for this interval (the comparison baseline).
    try
        for r in eachrow(zonal_mlf_reference(iv, mkt))
            push!(bench, (iv, string(r.region), float(r.price)))
        end
    catch err
        @warn "  $iv / MLF-scaled zonal reference failed" err
    end

    for f in FORMS
        r = try
            solve_network_dispatch(iv, f;
                                   mkt = mkt, net = net,
                                   data_dir = DATA_DIR,
                                   optimizer = solver_override(f))
        catch err
            @warn "  $iv / $f failed" err
            global nfail += 1
            continue
        end
        # Participant-node LMP against the zonal baseline, BOTH AT THE
        # CONNECTION POINT. The nodal LMP is already a connection-point price;
        # the zonal regional price is at the regional reference node, and a
        # participant is settled on it as RRP x MLF. Comparing the nodal LMP
        # with the bare regional price would therefore charge the whole fleet a
        # spurious (1 - gamma), which is a ~2% systematic offset on the median
        # unit and up to 20% on the extremes. The like-for-like baseline is
        # `zonal x gamma`.
        if string(get(r, "status", "")) in ("OPTIMAL", "LOCALLY_SOLVED")
            lmpd = get(r, "lmp", Dict{Int,Float64}())
            mp   = get(r, "mapping", DataFrame())
            zp   = Dict(string(x.region) => float(x.price)
                        for x in eachrow(bench) if x.time == iv)
            gam  = Dict((string(x.unit), string(x.dispatch_type)) => float(x.loss_factor)
                        for x in eachrow(mkt.unit_info))
            seen = Set{Tuple{String,Int}}()
            for row in eachrow(mp)
                u = string(row.unit); bus = Int(row.bus); rg = string(row.region)
                dt = ("dispatch_type" in names(mp)) ? string(row.dispatch_type) : "generator"
                (u, bus) in seen && continue
                push!(seen, (u, bus))
                (haskey(lmpd, bus) && haskey(zp, rg)) || continue
                l = lmpd[bus]
                (isnan(l) || isinf(l)) && continue
                g = get(gam, (u, dt), get(gam, (u, "generator"), 1.0))
                zcp = zp[rg] * g                      # connection-point baseline
                push!(partic, (iv, f, rg, u, bus, g, l, zp[rg], zcp, l - zcp))
            end
        end

        status = get(r, "status", "ERROR")
        first  = get(r, "first_status", status)
        natt   = get(r, "solve_attempts", 1)
        if natt > 1
            @info "  $iv / $f recovered by retry" first_status=first final_status=status
        end
        obj    = get(r, "objective", NaN)
        loss   = get(r, "losses_mw", NaN)
        tsol   = get(r, "solve_time", NaN)
        rrn    = get(r, "rrn", Dict{String,Int}())
        for (reg, p) in sort(collect(get(r, "rrn_price", Dict{String,Float64}())))
            push!(prices, (iv, f, reg, get(rrn, reg, 0), p, status, obj, loss, tsol,
                           first, natt))
        end
        for row in eachrow(get(r, "price_decomposition", DataFrame()))
            push!(decomp, (iv, f, row.region, row.lmp, row.energy,
                           row.congestion, row.loss))
        end
        for row in eachrow(get(r, "fcas_prices", DataFrame()))
            push!(fcasp, (iv, f, row.set, row.service, row.region,
                          row.price, row.rhs, row.binding))
        end
        for row in eachrow(get(r, "binding_constraints", DataFrame()))
            push!(binding, (iv, f, row.family, row.constraint, row.service,
                            row.region, row.dual, row.rhs, row.lhs, row.slack,
                            row.at_bound, row.refs_interconnector))
        end
        if WITH_LMP
            for (b, v) in get(r, "lmp", Dict{Int,Float64}())
                push!(lmps, (iv, f, b, v))
            end
        end
    end

    if k % CHECKPOINT_EVERY == 0
        flush_all()
        @info "checkpoint" interval=iv done="$k/$N" price_rows=nrow(prices) failures=nfail
    end
end

flush_all()

println("\n=== network-day sweep complete ===")
println("  intervals requested : $N  (from $START)")
println("  formulations        : ", join(FORMS, ", "))
println("  price rows          : ", nrow(prices))
println("  decomposition rows  : ", nrow(decomp))
println("  FCAS price rows     : ", nrow(fcasp))
println("  binding-ledger rows : ", nrow(binding))
WITH_LMP && println("  per-bus LMP rows    : ", nrow(lmps))
println("  failures            : ", nfail)
println("  written to          : ", DATA_DIR)

# --- Per-formulation summary -------------------------------------------------
if !isempty(prices)
    println("\nmean RRN price by formulation and region (\$/MWh):")
    g = combine(groupby(dropmissing(prices, :price), [:formulation, :region]),
                :price => (x -> round(sum(x) / length(x); digits = 2)) => :mean_price,
                :price => length => :n)
    show(sort(g, [:formulation, :region]); allrows = true, allcols = true)
    println()
end
if !isempty(decomp)
    println("\nmean decomposition by region (\$/MWh), first formulation:")
    f1 = first(FORMS)
    d1 = decomp[decomp.formulation .== f1, :]
    if !isempty(d1)
        g2 = combine(groupby(d1, :region),
                     :energy     => (x -> round(sum(x)/length(x); digits=2)) => :energy,
                     :congestion => (x -> round(sum(x)/length(x); digits=2)) => :congestion,
                     :loss       => (x -> round(sum(x)/length(x); digits=2)) => :loss)
        show(sort(g2, :region); allrows = true, allcols = true); println()
    end
end
