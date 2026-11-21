# =============================================================================
# run_bess_event_study.jl
#
# Solve a run of intervals with the zonal benchmark and write, per interval, the
# evidence needed to explain why a storage unit was dispatched the way it was:
# regional prices against AEMO's published ROP, per-unit dispatch beside AEMO's
# published target, each unit's LOCAL price decomposed into the regional price
# and the shadow-price adjustment of every binding network constraint, those
# constraints beside AEMO's own marginal values, the full ten-band offer stacks,
# and regional demand.
#
# WHY A UNIT'S LOCAL PRICE IS THE INTERESTING QUANTITY
#
# A participant is SETTLED at its region's reference price but DISPATCHED
# against its local price,
#
#     pi_u = lambda_r + sum_c f_uc * mu_c
#
# the regional price plus the shadow-price adjustment of every binding
# constraint carrying the unit. Nothing bounds the gap between the two. For a
# LOAD the dispatch test also inverts: bands fill from the highest price down,
# so a band is taken while its price EXCEEDS the local price. Together these let
# a battery be dispatched to charge while the regional price is at the cap.
#
# The defaults reproduce the New South Wales events of 20-21 November 2025, but
# nothing about the script is specific to them.
#
# ARGUMENTS
#   Positional      Env               Default            Meaning
#   --------------  ----------------  -----------------  ----------------------
#   1               NEMX_START        2025-11-20T00:05   first interval
#   2               NEMX_N            576                number of intervals
#
#   Options         Env               Default                Meaning
#   --------------  ----------------  ---------------------  -------------------
#   --data-dir=     NEMX_DATA_DIR     data/nemx_2025_11      MMS db + XML cache
#   --out-dir=      NEMX_OUT_DIR      ~/.nemx/nemx_2025_11   checkpoint directory
#   --region=       NEMX_REGION       NSW1                   region of interest
#   --threshold=    NEMX_THRESHOLD    300                    $/MWh above which an
#                                                            interval is "elevated"
#   --checkpoint=   NEMX_CHECKPOINT   24                     flush every N intervals
#   --solver=       NEMX_SOLVER       highs                  highs | ipopt | scs
#
#   Flags           Env               Meaning
#   --------------  ----------------  ------------------------------------------
#   --download      NEMX_DOWNLOAD     Fetch MMS tables and case files first
#   --no-download   NEMX_NO_DOWNLOAD  Never download, even if data looks missing
#
# OUTPUTS (in --out-dir, then copied into --data-dir)
#   bess_event_prices.csv       regional prices vs published ROP
#   bess_event_regional.csv     demand and price by region and interval
#   bess_event_storage.csv      per-unit dispatch, cost and local price
#   bess_event_local_terms.csv  per-(unit, constraint) contributions
#   bess_event_constraints.csv  binding constraints, ours vs AEMO
#   bess_event_bids.csv         ten-band offer stacks for storage units
#   bess_event_price_check.csv  the marginal-band diagnostic
#
# Analyse the results with scripts/zbenchmark/analyse_bess_event_study.jl.
#
# FIRST RUN downloads the month's MMS tables and one NEMDE bundle per day of the
# window. Both are idempotent, so an interrupted download resumes on re-run.
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

using DataFrames, Dates, Statistics, CSV, Printf

# --- Model configuration: IDENTICAL to the validated September-2025 benchmark --
# Both flags are set explicitly rather than inherited, so the configuration that
# produced these results is visible in the file that produced them. See
# script/run_historical_dispatch_sept2025.jl for the validation evidence behind
# each (22 matched intervals for the loss model; 1,532 BDU trapezium checks for
# the cross-side regulation sign).
ZB.LOSS_MODEL_FROM_XML[] = true
ZB.BDU_CROSS_SIDE_REG_LOWER_SUBTRACT[] = true

const DATA_DIR      = resolve_input_dir(joinpath(NEMX.PKG_DIR, "data", "nemx_2025_11"))
const MMS_DB_PATH   = joinpath(DATA_DIR, "historical_mms.db")
const XML_CACHE_DIR = joinpath(DATA_DIR, "xml_cache")

print_banner("Storage constrained-charging event — dispatch sweep",
             "data dir" => DATA_DIR)
mkpath(DATA_DIR); mkpath(XML_CACHE_DIR)

const YR = 2025; const MO = 11
const DAY_A = Date(2025, 11, 20)      # first spike: 13:25
const DAY_B = Date(2025, 11, 21)      # second spike: 09:10
const SPIKES = [DateTime(2025, 11, 20, 13, 25), DateTime(2025, 11, 21, 9, 10)]

# Both calendar days, inclusive: 00:05 on the 20th to 00:00 on the 22nd.
const DEFAULT_START = DateTime(2025, 11, 20, 0, 5)
const DEFAULT_N     = 576

const REGIONS = ["QLD1", "NSW1", "VIC1", "SA1", "TAS1"]
const FOCUS_REGION = script_option("region", "NSW1")

# A price above this marks an interval as "elevated" for the event summary. It
# is a reporting threshold only -- nothing in the diagnosis depends on it.
const SPIKE_THRESHOLD = script_number(script_option("threshold", "300"))

# Flush every this many intervals: a 576-interval run is hours long and an
# interrupted run must still leave usable output.
const CHECKPOINT_EVERY = script_integer(script_option("checkpoint", "24"))

const RUN_START = script_datetime(script_positional(1, "NEMX_START", string(DEFAULT_START)))
const RUN_N     = script_integer(script_positional(2, "NEMX_N", string(DEFAULT_N)))

# =============================================================================
# Inputs
# =============================================================================
mms_db_manager    = DBManager(MMS_DB_PATH)
xml_cache_manager = XMLCacheManager(XML_CACHE_DIR)

# DISPATCHLOAD and DISPATCHCONSTRAINT are not in REQUIRED_TABLES (the model does
# not need them; it takes initial MW and SCADA ramp from the case file). They
# are downloaded here because the whole point of this run is to check our
# dispatch and our constraint duals against AEMO's published ones.
const EVENT_TABLES = vcat(REQUIRED_TABLES,
                          "DISPATCHLOAD", "DISPATCHCONSTRAINT", "GENCONDATA")

"""
    ensure_inputs!()

Download whatever is missing and nothing that is not.

`populate_by_day!` already skips any market day with >= 200 cached case files,
so it is always safe to call. The MMS download is the expensive one, so it is
gated on a cheap probe: whether DISPATCHPRICE can be read for a mid-event
interval. Set `NEMX_DOWNLOAD=0` to skip both (offline re-analysis of a cache
that is already populated), or `NEMX_DOWNLOAD=1` to force both.
"""
function ensure_inputs!()
    script_flag("no-download") && (@info "--no-download — skipping all downloads"; return)
    need_mms = script_flag("download")
    if !need_mms
        need_mms = try
            isempty(get_table(mms_db_manager, "DISPATCHPRICE"; interval=SPIKES[1]))
        catch
            true      # table absent entirely
        end
    end
    if need_mms
        @info "Downloading MMS tables for $YR-$MO (this is the ~1 GB step)"
        populate!(mms_db_manager; start_year=YR, start_month=MO,
                  end_year=YR, end_month=MO, tables=EVENT_TABLES)
    else
        @info "MMS tables for $YR-$MO already present — skipping"
    end
    populate_by_day!(xml_cache_manager;
                     start_year=year(DAY_A), start_month=month(DAY_A),
                     start_day=day(DAY_A),
                     end_year=year(DAY_B), end_month=month(DAY_B),
                     end_day=day(DAY_B))
    return
end

ensure_inputs!()
raw_inputs_loader = RawInputsLoader(xml_cache_manager, mms_db_manager)

# =============================================================================
# Published-data helpers
# =============================================================================
const SERVICE_ROP_COL = [
    "energy"      => :ROP,
    "raise_reg"   => :RAISEREGROP,
    "raise_6s"    => :RAISE6SECROP,
    "raise_60s"   => :RAISE60SECROP,
    "raise_5min"  => :RAISE5MINROP,
    "raise_1s"    => :RAISE1SECROP,
    "lower_reg"   => :LOWERREGROP,
    "lower_6s"    => :LOWER6SECROP,
    "lower_60s"   => :LOWER60SECROP,
    "lower_5min"  => :LOWER5MINROP,
    "lower_1s"    => :LOWER1SECROP,
]

_f64(x) = x isa Number ? float(x) :
          (x === missing ? NaN : (v = tryparse(Float64, string(x)); v === nothing ? NaN : v))

# A DataFrameRow supports neither `get(row, :col, default)` nor indexing by a
# column that is absent, and MMS table schemas vary between vintages -- so every
# published-data read goes through this.
_col(r, s::Symbol) = hasproperty(r, s) ? _f64(getproperty(r, s)) : NaN

"AEMO's published ROPs for one interval, keyed by (region, service)."
function get_published_rops(db, interval::DateTime)
    rop = Dict{Tuple{String,String},Float64}()
    hist = get_table(db, "DISPATCHPRICE"; interval=interval)
    isempty(hist) && return rop
    for r in eachrow(hist), (svc, col) in SERVICE_ROP_COL
        hasproperty(r, col) || continue
        v = _f64(r[col]); isfinite(v) && (rop[(string(r.REGIONID), svc)] = v)
    end
    return rop
end

"AEMO's published unit targets for one interval: DUID => (TOTALCLEARED, INITIALMW, AVAILABILITY)."
function get_published_targets(db, interval::DateTime)
    out = Dict{String,NTuple{3,Float64}}()
    df = try get_table(db, "DISPATCHLOAD"; interval=interval) catch; DataFrame() end
    isempty(df) && return out
    for r in eachrow(df)
        out[string(r.DUID)] = (_col(r, :TOTALCLEARED),
                               _col(r, :INITIALMW),
                               _col(r, :AVAILABILITY))
    end
    return out
end

"AEMO's published constraint outcomes: CONSTRAINTID => (RHS, MARGINALVALUE, VIOLATIONDEGREE)."
function get_published_constraints(db, interval::DateTime)
    out = Dict{String,NTuple{3,Float64}}()
    df = try get_table(db, "DISPATCHCONSTRAINT"; interval=interval) catch; DataFrame() end
    isempty(df) && return out
    for r in eachrow(df)
        out[string(r.CONSTRAINTID)] = (_col(r, :RHS),
                                       _col(r, :MARGINALVALUE),
                                       _col(r, :VIOLATIONDEGREE))
    end
    return out
end

"Regional FCAS prices from the solved LP (see run_historical_dispatch_sept2025.jl)."
function get_regional_fcas_prices(market)
    out = Dict{Tuple{String,String},Tuple{Float64,Int}}()
    lhs = market.generic_region_lhs
    (lhs === nothing || isempty(lhs)) && return out
    gc = get_binding_generic_constraints(market)
    isempty(gc) && return out
    duals = Dict(string(r.set) => r.dual for r in eachrow(gc))
    for r in eachrow(lhs)
        d = get(duals, string(r.set), NaN); isfinite(d) || continue
        f = _f64(r.factor); (isfinite(f) && f != 0) || continue
        key = (string(r.region), string(r.service))
        p, n = get(out, key, (0.0, 0))
        out[key] = (p + f * d, n + 1)
    end
    return out
end

# =============================================================================
# The local price
# =============================================================================
"""
    constraint_contributions(market) -> (contrib, binds)

Per-unit shadow-price terms of the local price.

`contrib[u]` is a vector of `(set, factor, dual, factor*dual)`, one entry per
generic constraint carrying an ENERGY factor for unit `u` with a non-zero dual.
Only energy factors enter: an FCAS factor prices reserve, not the energy the
unit is dispatched to consume. `binds[set]` records whether that constraint was
actually binding, so a contribution can be told apart from a residual dual on a
slack constraint.
"""
function constraint_contributions(market)
    ulhs = market.generic_unit_lhs
    gc   = get_binding_generic_constraints(market)
    duals = isempty(gc) ? Dict{String,Float64}() :
            Dict(string(r.set) => _f64(r.dual) for r in eachrow(gc))
    binds = isempty(gc) ? Dict{String,Bool}() :
            Dict(string(r.set) => Bool(r.binds) for r in eachrow(gc))

    contrib = Dict{String,Vector{Tuple{String,Float64,Float64,Float64}}}()
    if !(ulhs === nothing || isempty(ulhs))
        for r in eachrow(ulhs)
            string(r.service) == "energy" || continue
            f = _f64(r.factor); (isfinite(f) && f != 0) || continue
            set = string(r.set)
            d = get(duals, set, NaN)
            (isfinite(d) && d != 0) || continue
            push!(get!(contrib, string(r.unit),
                       Tuple{String,Float64,Float64,Float64}[]), (set, f, d, f * d))
        end
    end
    return contrib, binds
end

"""
    local_price_frames(market, rrp, info, interval) -> (prices, terms)

  * `prices` — one row per unit: `rrp`, the shadow-price adjustment
    `sum_c f_uc * mu_c`, the local price in reference-node and connection-point
    terms, the number of binding constraints touching the unit, and the single
    constraint contributing the largest adjustment (`top_set`, `top_factor`,
    `top_dual`, `top_contrib`). The "one constraint did this" claim that a case
    study needs is thereby carried by the data, not by inspection.
  * `terms`  — one row per (unit, constraint) with a non-zero contribution, for
    units in `FOCUS_REGION` only, so the file stays a readable size.

`info` is `get_unit_info(unit_inputs)`: the `SpotMarket` struct does not expose
it, and keeping the lookup outside the arithmetic makes the identity above
independent of how a unit's region and loss factor happen to be found.
"""
function local_price_frames(market, rrp::Dict{String,Float64},
                            info::DataFrame, interval::DateTime)
    contrib, binds = constraint_contributions(market)

    # ONE ROW PER UNIT-DIRECTION, not per unit. The reference-node local price
    # is a property of the unit -- both directions face the same regional price
    # and the same constraint set, and the direction's sign is carried inside
    # the LP rather than in the price. The CONNECTION-POINT figure is not: a
    # bidirectional unit's two sides have different loss factors (the generator
    # side takes SECONDARY_TLF), so collapsing the two directions would quote a
    # charging battery's local price on its discharging loss factor. The
    # difference is a few per cent of a price that reaches five figures here.
    seen = Set{Tuple{String,String}}()
    prows = NamedTuple[]; trows = NamedTuple[]
    for r in eachrow(info)
        u = string(r.unit)
        dt = hasproperty(r, :dispatch_type) ? string(r.dispatch_type) : "generator"
        (u, dt) in seen && continue
        push!(seen, (u, dt))
        region = string(r.region); λ = _f64(r.loss_factor)
        p_reg = get(rrp, region, NaN)
        terms = get(contrib, u, Tuple{String,Float64,Float64,Float64}[])
        adj = isempty(terms) ? 0.0 : sum(t[4] for t in terms)
        nb = count(t -> get(binds, t[1], false), terms)
        top = isempty(terms) ? ("", NaN, NaN, 0.0) :
              terms[argmax([abs(t[4]) for t in terms])]
        lref = p_reg + adj
        push!(prows, (time=interval, unit=u, dispatch_type=dt, region=region,
                      loss_factor=λ, rrp=p_reg, adjustment=adj,
                      local_price_ref=lref, local_price_cp=lref * λ,
                      n_constraint_terms=length(terms), n_binding=nb,
                      top_set=String(top[1]), top_factor=_f64(top[2]),
                      top_dual=_f64(top[3]), top_contrib=_f64(top[4])))
        # The constraint terms are unit-level, so emit them once per unit.
        (region == FOCUS_REGION && dt == "generator") || continue
        for (set, f, d, c) in terms
            push!(trows, (time=interval, unit=u, set=String(set), factor=_f64(f),
                          dual=_f64(d), contribution=_f64(c),
                          binds=get(binds, set, false)))
        end
    end
    return DataFrame(prows), DataFrame(trows)
end

"""
    marginal_band_check(market, vb, pb, info, localp, interval) -> DataFrame

Test the local-price identity rather than assume it.

A unit whose energy dispatch lands STRICTLY INSIDE one of its ten offer bands is
strictly marginal: no bound is active on that band, so its stationarity
condition holds with equality and its offer price must equal its local price.
Writing the Lagrangian of the engine's own LP, for a GENERATION band `x` with
objective coefficient `p_cp/lambda` and for a LOAD band `y` with coefficient
`-p_cp/lambda`, and using the model's constraint orientation (load energy enters
generic constraints with `sgn = -1` and regional balance with `-1`), both
directions give the SAME condition:

    p_cp / lambda  =  lambda_region + sum_c f_uc * mu_c  =  local_price_ref.

So the test is one test, not two. The reference-node and connection-point
figures are the same quantity in different units -- `local_price_cp` is exactly
`local_price_ref * lambda` and `band_price_cp` exactly `band_price_ref * lambda`
-- and the residuals differ only by that factor. Both are reported because the
connection point is the basis on which offers are submitted and on which market
software quotes a "local price", while the reference node is the basis the
engine's objective is written in; neither is more correct.

What the test can fail is the identity itself: a sign error in the constraint
orientation, a missed constraint family, or a dual convention that is not
d(objective)/d(rhs) would all show up as residuals of order the price rather
than of order solver tolerance.

One row per strictly marginal unit-direction. `band_slack_mw` records how far
inside the band the dispatch sits, so near-degenerate cases can be excluded.
"""
function marginal_band_check(market, vb::DataFrame, pb::DataFrame,
                             info::DataFrame, localp::DataFrame,
                             interval::DateTime)
    disp = get_unit_dispatch(market)
    (disp === nothing || isempty(disp)) && return DataFrame()
    bands = Dict{Tuple{String,String},Tuple{Vector{Float64},Vector{Float64}}}()
    vmap = Dict((string(r.unit), string(r.dispatch_type)) =>
                Float64[coalesce(r[c], 0.0) for c in ZB.BAND_COLS]
                for r in eachrow(vb) if string(r.service) == "energy")
    for r in eachrow(pb)
        string(r.service) == "energy" || continue
        k = (string(r.unit), string(r.dispatch_type))
        haskey(vmap, k) || continue
        bands[k] = (vmap[k], Float64[coalesce(r[c], 0.0) for c in ZB.BAND_COLS])
    end
    # Keyed by (unit, direction): a bidirectional unit's two sides carry
    # different loss factors, so a unit-only key would test the load band
    # against the generator side's connection-point price.
    λ = Dict((string(r.unit), string(r.dispatch_type)) => _f64(r.loss_factor)
             for r in eachrow(info))
    lp = Dict((string(r.unit), string(r.dispatch_type)) =>
              (r.local_price_ref, r.local_price_cp) for r in eachrow(localp))

    rows = NamedTuple[]
    for r in eachrow(disp)
        string(r.service) == "energy" || continue
        k = (string(r.unit), string(r.dispatch_type))
        haskey(bands, k) || continue
        haskey(lp, k) || continue
        vols, pris = bands[k]
        mw = abs(float(r.dispatch))
        # Locate the band the dispatch lands in and require STRICT interiority:
        # a dispatch sitting exactly on a band edge is at a bound and its
        # stationarity condition is an inequality, so it proves nothing.
        #
        # Bands fill in order of OBJECTIVE cost, which for a load is the
        # negated offer price: a load takes its HIGHEST-priced band first,
        # because that is the megawatt it is most willing to pay for. Ordering
        # a load stack ascending would identify the wrong marginal band and
        # manufacture residuals that are an artefact of this function.
        order = string(r.dispatch_type) == "load" ? sortperm(pris; rev=true) :
                                                    sortperm(pris)
        cum = 0.0; hit = 0; slack_lo = 0.0; slack_hi = 0.0
        for b in order
            vols[b] <= 0 && continue
            if mw > cum + 1e-6 && mw < cum + vols[b] - 1e-6
                hit = b; slack_lo = mw - cum; slack_hi = cum + vols[b] - mw
                break
            end
            cum += vols[b]
        end
        hit == 0 && continue
        lref, lcp = lp[k]
        lam = get(λ, k, 1.0)
        p_cp = pris[hit]                 # as-processed: connection-point terms
        p_ref = lam == 0 ? NaN : p_cp / lam
        push!(rows, (time=interval, unit=k[1], dispatch_type=k[2], band=hit,
                     dispatch_mw=float(r.dispatch),
                     band_slack_mw=min(slack_lo, slack_hi),
                     band_price_cp=p_cp, band_price_ref=p_ref,
                     local_price_ref=lref, local_price_cp=lcp,
                     resid_ref=lref - p_ref, resid_cp=lcp - p_cp))
    end
    return DataFrame(rows)
end

# =============================================================================
# Storage units
# =============================================================================
"""
    storage_units(info) -> Set{String}

Units that can consume as well as generate: those with BOTH a `generator` and a
`load` direction in the bid data. This is how the engine itself identifies a
bidirectional unit (`SpotMarket`'s `bdu` set), so the selection is the model's,
not a hand-written list of DUIDs -- which matters here, because the point of
the exercise is to find out WHICH units were caught, not to confirm a list.
"""
function storage_units(info::DataFrame)
    dirs = Dict{String,Set{String}}()
    for r in eachrow(info)
        push!(get!(dirs, string(r.unit), Set{String}()), string(r.dispatch_type))
    end
    return Set(u for (u, s) in dirs if length(s) > 1)
end

"Net energy target per unit (generation minus load), from the solved LP."
function net_energy_dispatch(market)
    disp = get_unit_dispatch(market)
    out = Dict{String,Float64}()
    (disp === nothing || isempty(disp)) && return out
    for r in eachrow(disp)
        string(r.service) == "energy" || continue
        sgn = string(r.dispatch_type) == "load" ? -1.0 : 1.0
        u = string(r.unit)
        out[u] = get(out, u, 0.0) + sgn * float(r.dispatch)
    end
    return out
end

# =============================================================================
# Accumulators
# =============================================================================
prices_out  = DataFrame(time=DateTime[], region=String[], service=String[],
                        price=Float64[], ROP=Float64[], n_terms=Int[])
regional_out = DataFrame(time=DateTime[], region=String[], demand=Float64[],
                         price=Float64[], ROP=Float64[])
units_out   = DataFrame()      # storage dispatch + local price, appended per interval
terms_out   = DataFrame()      # per-(unit, constraint) contributions, NSW1
constr_out  = DataFrame()      # binding constraints, ours vs AEMO
bids_out    = DataFrame()      # storage energy bid stacks
check_out   = DataFrame()      # marginal-band identity test

const OUT = Dict(
    "bess_event_prices.csv"        => () -> prices_out,
    "bess_event_regional.csv"      => () -> regional_out,
    "bess_event_storage.csv"       => () -> units_out,
    "bess_event_local_terms.csv"   => () -> terms_out,
    "bess_event_constraints.csv"   => () -> constr_out,
    "bess_event_bids.csv"          => () -> bids_out,
    "bess_event_price_check.csv"   => () -> check_out,
)

# Checkpoints go to a LOCAL scratch directory and are copied into DATA_DIR once
# at the end: DATA_DIR sits in a OneDrive-synced tree, and a file rewritten
# every few minutes for hours is not reliably served back at its newest version
# by the sync engine (observed truncating a completed run to its first 668
# intervals). Same arrangement as the September-2025 benchmark script.
const OUT_DIR = resolve_output_dir(joinpath(homedir(), ".nemx", "nemx_2025_11"))

function write_outputs()
    for (name, fetch_df) in OUT
        df = fetch_df()
        (df === nothing || isempty(df)) && continue
        CSV.write(joinpath(OUT_DIR, name), df)
    end
end

"""
    publish_outputs()

Copy the finished CSVs from the scratch directory into the project data
directory, exactly once, at the end of the run.

A failure is reported and survived, not thrown: the data directory may be
read-only or unreachable, and neither is a reason to lose a sweep's results. The
scratch copy is already on disk.
"""
function publish_outputs()
    for name in keys(OUT)
        source = joinpath(OUT_DIR, name)
        if !isfile(source)
            continue
        end
        destination = joinpath(DATA_DIR, name)
        try
            cp(source, destination; force = true)
        catch err
            @warn "could not copy the results into the data directory; " *
                  "they remain in the scratch directory" source destination err
        end
    end
    return nothing
end

# =============================================================================
# One interval
# =============================================================================
"""
    solve_interval!(loader, db, interval)

Build and dispatch one interval with the benchmark model, then extract prices,
storage dispatch, local prices, constraint duals and bid stacks.

The model-building sequence below is copied verbatim from
`run_historical_dispatch_sept2025.jl`, including the fast-start two-pass and the
over-constrained-dispatch re-run. It is repeated rather than factored out on
purpose: this script must be demonstrably the same engine, and a shared helper
that later drifts would silently break that guarantee.
"""
function solve_interval!(loader, db, interval::DateTime)
    unit_inputs           = UnitData(loader)
    interconnector_inputs = InterconnectorData(loader)
    constraint_inputs     = ConstraintData(loader)
    demand_inputs         = DemandData(loader)

    info = get_unit_info(unit_inputs)
    market = SpotMarket(market_regions=REGIONS, unit_info=info)
    vb, pb = get_processed_bids(unit_inputs)
    set_unit_volume_bids!(market, vb); set_unit_price_bids!(market, pb)
    cvp = get_constraint_violation_prices(constraint_inputs)
    set_unit_bid_capacity_constraints!(market, get_unit_bid_availability(unit_inputs);
                                       violation_cost=cvp["unit_capacity"])
    set_unconstrained_intermittent_generation_forecast_constraint!(
        market, get_unit_uigf_limits(unit_inputs); violation_cost=cvp["uigf"])
    fsp1 = get_fast_start_profiles_for_dispatch(unit_inputs)
    set_unit_ramp_rate_constraints!(market, get_bid_ramp_rates(unit_inputs),
        get_scada_ramp_rates(unit_inputs);
        fast_start_profiles=fsp1, run_type="fast_start_first_run",
        violation_cost=cvp["ramp_rate"])
    add_fcas_trapezium_constraints!(unit_inputs)
    set_fcas_max_availability!(market, get_fcas_max_availability(unit_inputs);
                               violation_cost=cvp["fcas_max_avail"])
    set_energy_and_regulation_capacity_constraints!(
        market, get_fcas_regulation_trapeziums(unit_inputs);
        violation_cost=cvp["fcas_profile"])
    set_joint_ramping_constraints_reg!(market,
        get_scada_ramp_rates(unit_inputs; include_initial_output=true);
        fast_start_profiles=fsp1, run_type="fast_start_first_run",
        violation_cost=cvp["fcas_profile"])
    set_joint_capacity_constraints!(market, get_contingency_services(unit_inputs);
                                    violation_cost=cvp["fcas_profile"])
    set_interconnectors!(market, get_interconnector_definitions(interconnector_inputs))
    lossf, bpts = get_interconnector_loss_model(interconnector_inputs)
    set_interconnector_losses!(market, lossf, bpts)
    gc, ulhs, ilhs, rlhs = get_generic_constraints(constraint_inputs)
    set_generic_constraints!(market, gc;
                             violation_cost=get_violation_costs(constraint_inputs))
    link_units_to_generic_constraints!(market, ulhs)
    link_interconnectors_to_generic_constraints!(market, ilhs)
    link_regions_to_generic_constraints!(market, rlhs)
    demand = get_operational_demand(demand_inputs)
    set_demand_constraints!(market, demand; violation_cost=cvp["regional_demand"])
    set_tie_break_constraints!(market, cvp["tiebreak"])

    dispatch!(market)
    fsp = get_fast_start_profiles_for_dispatch(unit_inputs;
              unconstrained_dispatch=get_unit_dispatch(market))
    if !isempty(fsp)
        set_fast_start_constraints!(market,
            fsp[:, [:unit, :end_mode, :time_in_end_mode, :mode_two_length,
                    :mode_four_length, :min_loading]];
            violation_cost=cvp["fast_start"])
        fsp2 = fsp[:, [:unit, :end_mode, :time_since_end_of_mode_two, :min_loading]]
        set_unit_ramp_rate_constraints!(market, get_bid_ramp_rates(unit_inputs),
            get_scada_ramp_rates(unit_inputs);
            fast_start_profiles=fsp2, run_type="fast_start_second_run",
            violation_cost=cvp["ramp_rate"])
        set_joint_ramping_constraints_reg!(market,
            get_scada_ramp_rates(unit_inputs; include_initial_output=true);
            fast_start_profiles=fsp2, run_type="fast_start_second_run",
            violation_cost=cvp["fcas_profile"])
    end
    if is_over_constrained_dispatch_rerun(constraint_inputs)
        dispatch!(market; allow_over_constrained_dispatch_re_run=true,
                  energy_market_floor_price=-1000.0,
                  energy_market_ceiling_price=cvp["voll"],
                  fcas_market_ceiling_price=1000.0)
    else
        dispatch!(market)
    end

    # --- 1. Regional prices vs published ROP ---------------------------------
    rop = get_published_rops(db, interval)
    eprices = get_energy_prices(market)
    rrp = Dict{String,Float64}()
    for r in eachrow(eprices)
        isfinite(r.price) && (rrp[string(r.region)] = float(r.price))
        key = (string(r.region), "energy")
        haskey(rop, key) && isfinite(r.price) &&
            push!(prices_out, (time=interval, region=string(r.region), service="energy",
                               price=float(r.price), ROP=rop[key], n_terms=0))
    end
    fcasp = get_regional_fcas_prices(market)
    for reg in REGIONS, (svc, _) in SERVICE_ROP_COL
        svc == "energy" && continue
        key = (reg, svc); haskey(rop, key) || continue
        p, n = get(fcasp, key, (0.0, 0)); isfinite(p) || continue
        push!(prices_out, (time=interval, region=reg, service=svc,
                           price=p, ROP=rop[key], n_terms=n))
    end

    # --- 2. Regional demand, the conditioning variable ------------------------
    for r in eachrow(demand)
        reg = string(r.region)
        push!(regional_out, (time=interval, region=reg, demand=_f64(r.demand),
                             price=get(rrp, reg, NaN),
                             ROP=get(rop, (reg, "energy"), NaN)))
    end

    # --- 3. Local prices ------------------------------------------------------
    localp, terms = local_price_frames(market, rrp, info, interval)
    global terms_out = isempty(terms_out) ? terms : vcat(terms_out, terms; cols=:union)

    # --- 4. Storage dispatch beside AEMO's published target -------------------
    stor = storage_units(info)
    net = net_energy_dispatch(market)
    targets = get_published_targets(db, interval)
    lpmap = Dict((string(r.unit), string(r.dispatch_type)) => r
                 for r in eachrow(localp))
    srows = NamedTuple[]
    for u in sort(collect(stor))
        gen = get(lpmap, (u, "generator"), nothing)
        lod = get(lpmap, (u, "load"), nothing)
        lr = gen === nothing ? lod : gen
        lr === nothing && continue
        mw = get(net, u, NaN)
        aemo = get(targets, u, (NaN, NaN, NaN))
        # Cost of the interval to the unit, on the regional price it settles at.
        # Charging (mw < 0) is a payment out; the sign convention below makes a
        # cost POSITIVE so the event totals read as losses.
        cost = isfinite(mw) && isfinite(lr.rrp) ? -mw * lr.rrp * (5 / 60) : NaN
        push!(srows, (time=interval, unit=u, region=String(lr.region),
                      loss_factor_gen = gen === nothing ? NaN : gen.loss_factor,
                      loss_factor_load = lod === nothing ? NaN : lod.loss_factor,
                      net_mw=mw, aemo_totalcleared=aemo[1],
                      aemo_initialmw=aemo[2], aemo_availability=aemo[3],
                      rrp=lr.rrp, adjustment=lr.adjustment,
                      local_price_ref=lr.local_price_ref,
                      local_price_cp_gen = gen === nothing ? NaN : gen.local_price_cp,
                      local_price_cp_load = lod === nothing ? NaN : lod.local_price_cp,
                      n_binding=lr.n_binding, top_set=lr.top_set,
                      top_factor=lr.top_factor, top_dual=lr.top_dual,
                      top_contrib=lr.top_contrib,
                      cost_dollars=cost,
                      charging=isfinite(mw) && mw < -0.1))
    end
    if !isempty(srows)
        global units_out = isempty(units_out) ? DataFrame(srows) :
                           vcat(units_out, DataFrame(srows); cols=:union)
    end

    # --- 5. Binding constraints, ours vs AEMO's MARGINALVALUE -----------------
    gcs = get_binding_generic_constraints(market)
    if !isempty(gcs)
        pub = get_published_constraints(db, interval)
        keep = gcs[(gcs.binds .== true) .| (abs.(coalesce.(gcs.dual, 0.0)) .> 1e-6), :]
        crows = NamedTuple[]
        for r in eachrow(keep)
            a = get(pub, string(r.set), (NaN, NaN, NaN))
            push!(crows, (time=interval, set=String(r.set), type=String(r.type),
                          dual=_f64(r.dual), lhs=_f64(r.lhs), rhs=_f64(r.rhs),
                          binds=Bool(r.binds), service=String(r.service),
                          region=String(r.region),
                          aemo_rhs=a[1], aemo_marginalvalue=a[2],
                          aemo_violationdegree=a[3]))
        end
        global constr_out = isempty(constr_out) ? DataFrame(crows) :
                            vcat(constr_out, DataFrame(crows); cols=:union)
    end

    # --- 6. Storage energy bid stacks, for the rebidding trace ----------------
    brows = NamedTuple[]
    vmap = Dict((string(r.unit), string(r.dispatch_type)) => r
                for r in eachrow(vb) if string(r.service) == "energy")
    for r in eachrow(pb)
        string(r.service) == "energy" || continue
        u = string(r.unit); u in stor || continue
        k = (u, string(r.dispatch_type))
        lr = get(lpmap, k, nothing)
        (lr === nothing || lr.region != FOCUS_REGION) && continue
        haskey(vmap, k) || continue
        vrow = vmap[k]
        for (i, c) in enumerate(ZB.BAND_COLS)
            v = _f64(coalesce(vrow[c], 0.0)); p = _f64(coalesce(r[c], 0.0))
            v == 0 && continue
            push!(brows, (time=interval, unit=u, dispatch_type=k[2], band=i,
                          volume_mw=v, price=p))
        end
    end
    if !isempty(brows)
        global bids_out = isempty(bids_out) ? DataFrame(brows) :
                          vcat(bids_out, DataFrame(brows); cols=:union)
    end

    # --- 7. Local-price identity test ----------------------------------------
    chk = marginal_band_check(market, vb, pb, info, localp, interval)
    if !isempty(chk)
        global check_out = isempty(check_out) ? chk : vcat(check_out, chk; cols=:union)
    end
    return
end

# =============================================================================
# Driver
# =============================================================================
intervals = [RUN_START + Minute(5 * (i - 1)) for i in 1:RUN_N]
println("NSW battery event study — $(length(intervals)) interval(s), " *
        "$(first(intervals)) .. $(last(intervals))")
println("Spike intervals of interest: ", join(string.(SPIKES), ", "))

t_start = time(); n_solved = 0; failed = DateTime[]
for (c, interval) in enumerate(intervals)
    try
        set_interval!(raw_inputs_loader, interval)
        solve_interval!(raw_inputs_loader, mms_db_manager, interval)
        global n_solved += 1
    catch err
        err isa InterruptException && rethrow()
        @warn "Skipping $interval" exception = (err, catch_backtrace())
        push!(failed, interval)
    end
    if c % CHECKPOINT_EVERY == 0 || c == length(intervals)
        write_outputs()
        el = time() - t_start; eta = el / c * (length(intervals) - c)
        @printf("  [%3d/%3d] %s  elapsed %.1f min, ETA %.1f min\n",
                c, length(intervals), interval, el / 60, eta / 60)
        flush(stdout)
    end
end

write_outputs(); publish_outputs()

println("\nSolved $n_solved of $(length(intervals)) intervals in " *
        "$(round((time() - t_start) / 60, digits=1)) min.")
isempty(failed) || println("Failed: ", join(string.(failed), ", "))
println("Wrote to $OUT_DIR and copied into $DATA_DIR:")
for name in sort(collect(keys(OUT)))
    df = OUT[name]()
    println("  ", rpad(name, 30), isempty(df) ? "(empty)" : "$(nrow(df)) rows")
end

# --- Run-level checks --------------------------------------------------------
# These print at the end of every run. They are the difference between a result
# and a number: if the price reconstruction is off, or the local-price identity
# fails, everything downstream of it is uninterpretable and the run should say
# so before anyone reads the storage file.
if !isempty(prices_out)
    e = prices_out[prices_out.service .== "energy", :]
    err = e.price .- e.ROP
    @printf("\nEnergy price vs published ROP: n=%d  MAE=%.4f  median=%.4f  max|e|=%.4f \$/MWh\n",
            length(err), mean(abs.(err)), median(err), maximum(abs.(err)))
    for t in SPIKES
        d = e[(e.time .== t) .& (e.region .== FOCUS_REGION), :]
        isempty(d) && continue
        @printf("  %s %s: ours %.2f  AEMO ROP %.2f  (error %.4f)\n",
                t, FOCUS_REGION, d.price[1], d.ROP[1], d.price[1] - d.ROP[1])
    end
end

if !isempty(check_out)
    ok = count(r -> abs(r.resid_ref) <= 1e-4 * max(1.0, abs(r.band_price_ref)),
               eachrow(check_out))
    n = nrow(check_out)
    @printf("\nLocal-price identity over %d strictly marginal unit-intervals:\n", n)
    @printf("  passing: %d/%d (%.1f%%)   median |resid| %.4g  p95 %.4g  max %.4g \$/MWh\n",
            ok, n, 100ok / n, median(abs.(check_out.resid_ref)),
            quantile(abs.(check_out.resid_ref), 0.95),
            maximum(abs.(check_out.resid_ref)))
    if ok < n
        bad = check_out[abs.(check_out.resid_ref) .>
                        1e-4 .* max.(1.0, abs.(check_out.band_price_ref)), :]
        println("  worst offenders (the identity should hold to solver tolerance; " *
                "if these are systematic, the local prices below are NOT safe to read):")
        show(first(sort(bad, :resid_ref, by=abs, rev=true), 5), allrows=true)
        println()
    end
end

if !isempty(units_out)
    ch = units_out[units_out.charging .& (units_out.rrp .> SPIKE_THRESHOLD), :]
    if isempty(ch)
        println("\nNo storage unit charged in an interval priced above " *
                "\$$(SPIKE_THRESHOLD)/MWh.")
    else
        println("\nStorage charging while the regional price exceeded " *
                "\$$(SPIKE_THRESHOLD)/MWh — $(nrow(ch)) unit-intervals, " *
                "$(length(unique(ch.unit))) distinct units:")
        g = combine(groupby(ch, :unit),
                    :net_mw => (x -> minimum(x)) => :max_charge_mw,
                    :rrp => maximum => :max_rrp,
                    :local_price_cp_load => minimum => :min_local_price_load,
                    :cost_dollars => sum => :total_cost,
                    nrow => :intervals)
        sort!(g, :total_cost, rev=true)
        println(g)
    end
end
