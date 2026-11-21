# =============================================================================
# run_zonal_benchmark.jl
#
# Sweep the zonal (copper-plate) dispatch reconstruction over a series of
# five-minute intervals and score every regional price against AEMO's published
# ROP, for energy and all ten FCAS services.
#
# This is the package's headline validation run. It replaces the two
# month-specific drivers of the reference implementation with one script whose
# month, window, interval selection, solver and behavioural flags are all
# arguments — nothing needs editing in the file to run a different period.
#
# -----------------------------------------------------------------------------
# WHAT IT PRODUCES  (in --out-dir, then copied into --data-dir)
#
#   zonal_prices_<tag>.csv     one row per (interval, region, service):
#                              modelled price, AEMO ROP, error, and the number
#                              of constraint terms that produced an FCAS price
#   zonal_energy_<tag>.csv     the energy-only subset, for convenience
#
# A console summary reports mean, median and tail error by service, plus the
# Queensland lower 6 s / 60 s pair scored JOINTLY — see the note at the end of
# this file for why those two are not separately identifiable.
#
# -----------------------------------------------------------------------------
# ARGUMENTS
#
#   Positional      Env               Default            Meaning
#   --------------  ----------------  -----------------  ------------------------
#   1               NEMX_MODE         consecutive        consecutive | random
#   2               NEMX_N            10                 number of intervals
#   3               NEMX_START        2025-09-01T00:05   first interval (consecutive)
#
#   Options         Env               Default            Meaning
#   --------------  ----------------  -----------------  ------------------------
#   --year=         NEMX_YEAR         from --start       MMS month to use
#   --month=        NEMX_MONTH        from --start       MMS month to use
#   --data-dir=     NEMX_DATA_DIR     data/nemx_<YYYY_MM>    MMS db + XML cache
#   --out-dir=      NEMX_OUT_DIR      ~/.nemx/<tag>      checkpoint directory
#   --tag=          NEMX_TAG          <YYYY_MM>          suffix for output names
#   --solver=       NEMX_SOLVER       highs              highs | ipopt | scs
#   --regions=      NEMX_REGIONS      QLD1,NSW1,VIC1,SA1,TAS1
#   --checkpoint=   NEMX_CHECKPOINT   25                 flush every N intervals
#   --seed=         NEMX_SEED         1                  RNG seed (random mode)
#
#   Flags           Env               Meaning
#   --------------  ----------------  --------------------------------------------
#   --download      NEMX_DOWNLOAD     Fetch MMS tables and NEMDE case files first
#   --no-fast-start NEMX_NO_FAST_START  Skip the fast-start second pass (faster,
#                                     NOT benchmark-valid for starting units)
#   --verbose-solver  NEMX_VERBOSE_SOLVER  Let the solver print
#
#   Behavioural flags (all default to the validated configuration)
#   --loss-model=       NEMX_LOSS_MODEL       xml | mms       (default xml)
#   --bdu-cross-side=   NEMX_BDU_CROSS_SIDE   subtract | add  (default subtract)
#   --keep-mlf-scaling  NEMX_KEEP_MLF_SCALING Leave the offer stack MLF-scaled
#                                             instead of referring it to the
#                                             regional reference node. Used to
#                                             produce the comparison baseline for
#                                             the nodal study; NOT the benchmark.
#
# -----------------------------------------------------------------------------
# EXAMPLES
#
#   # Ten pseudo-random intervals from September 2025, downloading first
#   julia --project=. scripts/zbenchmark/run_zonal_benchmark.jl random 10 --download
#
#   # A full trading day, consecutively
#   julia --project=. scripts/zbenchmark/run_zonal_benchmark.jl consecutive 288 2025-09-02T04:05
#
#   # The MLF-scaled variant used as the baseline for the nodal comparison
#   julia --project=. scripts/zbenchmark/run_zonal_benchmark.jl consecutive 288 \
#         2025-09-02T04:05 --keep-mlf-scaling --tag=2025_09_mlf
#
# -----------------------------------------------------------------------------
# FIRST RUN
#
# `--download` fetches the month's MMS tables (a few hundred MB) and one NEMDE
# case-file bundle per day of the window (~1.5 GB/day). Both are idempotent:
# days already cached are skipped, so an interrupted download resumes by
# re-running. Omit the flag on later runs.
# =============================================================================

using NEMX
using CSV
using DataFrames
using Dates
using JuMP
using Printf
using Random
using Statistics

const ZB = NEMX.ZBenchmark

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
const MODE = lowercase(script_positional(1, "NEMX_MODE", "consecutive"))
MODE in ("consecutive", "random") ||
    error("mode must be \"consecutive\" or \"random\", got \"$MODE\"")

const N_INTERVALS = script_integer(script_positional(2, "NEMX_N", "10"))
const START = script_datetime(script_positional(3, "NEMX_START", "2025-09-01T00:05"))

const YEAR = script_integer(script_option("year", string(year(START))))
const MONTH = script_integer(script_option("month", string(month(START))))
const TAG = script_option("tag", @sprintf("%04d_%02d", YEAR, MONTH))

const DATA_DIR = resolve_input_dir(joinpath("data", "nemx_" * TAG))
const OUT_DIR = resolve_output_dir(joinpath(homedir(), ".nemx", TAG))
const REGIONS = script_list(script_option("regions", join(ZB.DEFAULT_REGIONS, ",")))
const CHECKPOINT_EVERY = script_integer(script_option("checkpoint", "25"))
const SEED = script_integer(script_option("seed", "1"))
const SOLVER_NAME = script_option("solver", "highs")
const FAST_START = !script_flag("no-fast-start")

# The window the MMS month covers. Intervals outside it have no cached case file
# and no MMS row, so they are dropped rather than silently mis-solved.
const WINDOW_START = DateTime(YEAR, MONTH, 1)
const WINDOW_END = WINDOW_START + Month(1)

# ---------------------------------------------------------------------------
# Behavioural flags
#
# Each is set explicitly, never inherited, so the configuration that produced a
# result is visible in the log the result was written beside.
# ---------------------------------------------------------------------------
ZB.LOSS_MODEL_FROM_XML[] = lowercase(script_option("loss-model", "xml")) == "xml"
ZB.BDU_CROSS_SIDE_REG_LOWER_SUBTRACT[] =
    lowercase(script_option("bdu-cross-side", "subtract")) == "subtract"
ZB.ZONAL_MLF_KEEP_SCALING[] = script_flag("keep-mlf-scaling")
ZB.SOLVER_FACTORY[] = select_solver(SOLVER_NAME; silent = !script_flag("verbose-solver"))

print_banner("Zonal benchmark sweep",
             "mode" => MODE,
             "intervals" => N_INTERVALS,
             "start" => MODE == "consecutive" ? string(START) : "(random)",
             "MMS month" => @sprintf("%04d-%02d", YEAR, MONTH),
             "regions" => join(REGIONS, ","),
             "data dir" => DATA_DIR,
             "out dir" => OUT_DIR,
             "solver" => SOLVER_NAME,
             "fast-start two-pass" => FAST_START,
             "download first" => script_flag("download"))
print_flag_values(ZB, :LOSS_MODEL_FROM_XML, :BDU_CROSS_SIDE_REG_LOWER_SUBTRACT,
            :ZONAL_MLF_KEEP_SCALING, :LAZY_LOSS_TIGHTENING,
            :XML_PRICES_PRESCALED)

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------
mkpath(DATA_DIR)
const DB = ZB.DBManager(joinpath(DATA_DIR, "historical_mms.db"))
const CACHE = ZB.XMLCacheManager(joinpath(DATA_DIR, "xml_cache"))

if script_flag("download")
    @info "Downloading MMS tables for $YEAR-$MONTH"
    ZB.populate!(DB; start_year = YEAR, start_month = MONTH,
                 end_year = YEAR, end_month = MONTH,
                 tables = vcat(ZB.REQUIRED_TABLES, "DISPATCHCONSTRAINT",
                               "DISPATCHLOAD"))
    last_day = Date(WINDOW_END - Day(1))
    @info "Downloading NEMDE case files for $(Date(WINDOW_START)) .. $last_day"
    ZB.populate_by_day!(CACHE;
                        start_year = year(WINDOW_START),
                        start_month = month(WINDOW_START),
                        start_day = day(WINDOW_START),
                        end_year = year(last_day), end_month = month(last_day),
                        end_day = day(last_day))
end

const LOADER = ZB.RawInputsLoader(CACHE, DB)

# ---------------------------------------------------------------------------
# Interval selection
# ---------------------------------------------------------------------------

"""
    consecutive_intervals(from, count) -> Vector{DateTime}

`count` back-to-back five-minute intervals from `from`, clipped to the MMS
month. Intervals outside the window are dropped with a warning rather than
attempted, because there is no cached input for them.
"""
function consecutive_intervals(from::DateTime, count::Int)
    all = [from + Minute(5 * (i - 1)) for i in 1:count]
    kept = filter(t -> WINDOW_START + Minute(5) <= t <= WINDOW_END, all)
    length(kept) < count &&
        @warn "$(count - length(kept)) interval(s) fall outside $(Date(WINDOW_START))–$(Date(WINDOW_END)) and were dropped"
    return kept
end

"""
    random_intervals(count; seed) -> Vector{DateTime}

`count` pseudo-random intervals from the month, sorted, from a fixed seed so the
sample is reproducible. Use this for an unbiased error estimate; use
consecutive mode when the sequence matters (ramping, storage, an event study).
"""
function random_intervals(count::Int; seed::Int = 1)
    total = Int(div(Millisecond(WINDOW_END - WINDOW_START),
                    Millisecond(5 * 60 * 1000)))
    Random.seed!(seed)
    idx = sort(randperm(total - 1)[1:min(count, total - 1)])
    return [WINDOW_START + Minute(5 * i) for i in idx]
end

const INTERVALS = MODE == "random" ?
                  random_intervals(N_INTERVALS; seed = SEED) :
                  consecutive_intervals(START, N_INTERVALS)

isempty(INTERVALS) && error("no intervals to solve after clipping to the MMS month")

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
results = DataFrame(time = DateTime[], region = String[], service = String[],
                    price = Float64[], ROP = Float64[], n_terms = Int[])

const PRICES_CSV = "zonal_prices_$(TAG).csv"
const ENERGY_CSV = "zonal_energy_$(TAG).csv"

"Write both output files to the scratch directory."
function write_outputs(df::DataFrame)
    isempty(df) && return
    out = copy(df)
    out.error = out.price .- out.ROP
    sort!(out, [:time, :region, :service])
    CSV.write(joinpath(OUT_DIR, PRICES_CSV), out)
    CSV.write(joinpath(OUT_DIR, ENERGY_CSV),
              out[out.service .== "energy", [:time, :region, :price, :ROP, :error]])
    return
end

"""
    publish_outputs()

Copy the finished outputs from the scratch directory into the project data
directory, exactly once, at the end of the run.

A failure here is REPORTED AND SURVIVED rather than thrown. The data directory
may be read-only, on a full disk, or on a network share that has gone away, and
none of those is a reason to lose the results of a sweep that may have taken
hours. The scratch copy is already on disk; the operator is told where.
"""
function publish_outputs()
    for name in (PRICES_CSV, ENERGY_CSV)
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

"""
    score_interval!(results, interval)

Solve one interval and append its energy and regional FCAS prices, each beside
AEMO's published ROP.
"""
function score_interval!(results::DataFrame, interval::DateTime)
    ZB.set_interval!(LOADER, interval)
    market, _ = ZB.dispatch_interval!(LOADER; regions = REGIONS,
                                      fast_start = FAST_START)

    published = ZB.get_published_rops(DB, interval)

    for r in eachrow(ZB.get_energy_prices(market))
        key = (string(r.region), "energy")
        (haskey(published, key) && isfinite(r.price)) || continue
        push!(results, (time = interval, region = string(r.region),
                        service = "energy", price = float(r.price),
                        ROP = published[key], n_terms = 0))
    end

    fcas = ZB.get_regional_fcas_prices(market)
    for region in REGIONS, (service, _) in ZB.SERVICE_ROP_COL
        service == "energy" && continue
        key = (region, service)
        haskey(published, key) || continue
        price, n = get(fcas, key, (0.0, 0))
        isfinite(price) || continue
        push!(results, (time = interval, region = region, service = service,
                        price = price, ROP = published[key], n_terms = n))
    end
    return
end

# ---------------------------------------------------------------------------
# Sweep
# ---------------------------------------------------------------------------
println("Solving $(length(INTERVALS)) interval(s): ",
        first(INTERVALS), " .. ", last(INTERVALS), "\n")

started = time()
solved = 0
failed = DateTime[]

# Each interval is isolated. Over a long sweep, one unsolvable or malformed
# interval must cost that interval and not the run.
for (i, interval) in enumerate(INTERVALS)
    try
        score_interval!(results, interval)
        global solved += 1
    catch err
        err isa InterruptException && rethrow()
        @warn "skipping $interval" exception = (err, catch_backtrace())
        push!(failed, interval)
    end
    if i % CHECKPOINT_EVERY == 0 || i == length(INTERVALS)
        write_outputs(results)
        print_progress(i, length(INTERVALS), started, Dates.format(interval, "dd HH:MM"))
    end
end

write_outputs(results)
publish_outputs()

@printf("\nSolved %d of %d interval(s) in %.1f min.\n",
        solved, length(INTERVALS), (time() - started) / 60)
isempty(failed) || println("Failed: ", join(string.(failed), ", "))
println("Wrote $(nrow(results)) rows to:")
println("  ", joinpath(DATA_DIR, PRICES_CSV))
println("  ", joinpath(DATA_DIR, ENERGY_CSV))

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if isempty(results)
    println("\nNo results — nothing to summarise.")
else
    results.error = results.price .- results.ROP
    println("\nError against AEMO's published ROP — the price before any ",
            "post-dispatch\nscaling or capping, which is the right comparison ",
            "for a dispatch model.\n")
    @printf("%-12s%6s%12s%12s%12s%12s\n", "service", "n", "mean", "median",
            "p5", "p95")
    for (service, _) in ZB.SERVICE_ROP_COL
        e = results[results.service .== service, :error]
        isempty(e) && continue
        @printf("%-12s%6d%12.4f%12.4f%12.4f%12.4f\n", service, length(e),
                mean(e), quantile(e, 0.5), quantile(e, 0.05), quantile(e, 0.95))
    end

    # --- Queensland lower 6 s / 60 s: score JOINTLY --------------------------
    # F_Q++BCDM_L6 and F_Q++BCDM_L60 are structurally identical constraints —
    # one QNI factor, one regional factor, the same right-hand side. The shared
    # flow variable pins only the SUM of their duals; the split between them is
    # free along a segment whenever no unit is strictly marginal, so it is a
    # solver-basis artefact rather than a market outcome. The sum is the
    # identifiable quantity, so that is what is scored. A large separate error
    # beside a near-zero joint error is the signature of the split, not a defect.
    qld = results[(results.region .== "QLD1") .&
                  ((results.service .== "lower_6s") .|
                   (results.service .== "lower_60s")), :]
    if !isempty(qld)
        joint = combine(groupby(qld, :time),
                        :price => sum => :ours, :ROP => sum => :aemo)
        joint.error = joint.ours .- joint.aemo
        @printf("\nQLD lower 6s/60s — non-identifiable split, scored jointly (%d intervals):\n",
                nrow(joint))
        @printf("   separate  MAE %.4f   max %.4f \$/MW\n",
                mean(abs.(qld.error)), maximum(abs.(qld.error)))
        @printf("   JOINT SUM MAE %.4f   max %.4f \$/MW\n",
                mean(abs.(joint.error)), maximum(abs.(joint.error)))
    end
end
