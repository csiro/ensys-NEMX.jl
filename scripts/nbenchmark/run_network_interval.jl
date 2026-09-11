# =============================================================================
# run_network_interval.jl
#
# Solve ONE dispatch interval on the network model, under one or several
# power-flow formulations, and print the comparison. This is the interactive
# counterpart to `run_network_day.jl`: use it to look at a single interval in
# detail, or to check a change before committing to a sweep.
#
# ARGUMENTS
#   Positional    Env               Default            Meaning
#   ------------  ----------------  -----------------  ------------------------
#   1             NEMX_INTERVAL     2025-09-02T12:05   the dispatch interval
#   2             NEMX_NET_FORMS    DCP                comma-separated formulations
#
#   Options       Env               Default                 Meaning
#   ------------  ----------------  ----------------------  -------------------
#   --data-dir=   NEMX_DATA_DIR     data/nempy_<month>      MMS db + XML cache
#   --mfile=      NEMX_MFILE        data/snem2000_fixed.m   network case
#
# EXAMPLES
#   julia --project=. scripts/run_network_interval.jl
#   julia --project=. scripts/run_network_interval.jl 2025-09-02T18:05 DCP,ACP
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

using PlotlyJS

interval = length(ARGS) >= 1 ? DateTime(ARGS[1]) : DateTime(2025, 9, 3, 03, 10)
forms = length(ARGS) >= 2 ? String.(split(ARGS[2], ",")) :
        ["DCP", "DCP_MLF", "LPACC", "SOCWR", "QCRM", "ACP"]

mfile = joinpath("data", "snem2000_fixed.m")
isfile(mfile) || error("Run `julia network/fix_snem2000.jl` first to create $mfile")

out = joinpath("data", "nempy_2024_07",
               "network_comparison_" * Dates.format(interval, "yyyymmdd_HHMM") * ".csv")

#
f = "ACP"  # default formulation for the single-interval dispatch run
outfile = "network_formulation_comparison.csv"
mkt = load_market(interval; data_dir="./data/nempy_2025_09")
net = load_network(mfile)
rows = DataFrame(formulation=String[], status=String[], objective=Float64[],
                     losses_mw=Float64[], solve_time_s=Float64[],
                     NSW1=Float64[], QLD1=Float64[], SA1=Float64[],
                     TAS1=Float64[], VIC1=Float64[])

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

print_banner("Network dispatch — single interval",
             "interval" => interval,
             "network case" => MFILE,
             "data dir" => DATA_DIR,
             "LP solver" => isempty(LP_SOLVER_NAME) ? "(registry)" : LP_SOLVER_NAME,
             "NLP solver" => isempty(NLP_SOLVER_NAME) ? "(registry)" : NLP_SOLVER_NAME)

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

rDC = solve_network_dispatch(interval, "DCP"; mkt=mkt, net=net,
                             optimizer = solver_override("DCP"))
rAC = solve_network_dispatch(interval, "ACP"; mkt=mkt, net=net,
                             optimizer = solver_override("ACP"))
plot([gen["pg"] for (i,gen) in rDC["result"]["solution"]["gen"]])
[(i, rAC["data"]["gen"][i]["name"], rAC["data"]["gen"][i]["gen_bus"], gen["pg"]) for (i,gen) in rAC["result"]["solution"]["gen"] if gen["pg"] < -0.5]

[(i, rDC["data"]["gen"][i]["name"], rDC["data"]["gen"][i]["gen_bus"], gen["pg"]) for (i,gen) in rDC["result"]["solution"]["gen"] if gen["pg"] < -0.5]

plot([gen2["pg"] - gen1["pg"] for (i,gen1) in rDC["result"]["solution"]["gen"] for (j,gen2) in rAC["result"]["solution"]["gen"] if i == j])

plot([gen2["pmin"] - gen1["pmin"] for (i,gen1) in rDC["data"]["gen"] for (j,gen2) in rAC["data"]["gen"] if i == j])
plot([gen["pmin"] for (i,gen) in rDC["data"]["gen"]])
plot([gen["pmin"] for (i,gen) in rAC["data"]["gen"]])

sum([gen["pg"] for (i,gen) in rAC["result"]["solution"]["gen"] if rAC["data"]["bus"]["$(rAC["data"]["gen"][i]["gen_bus"])"]["area"] == 1])
sum([gen["pg"] for (i,gen) in rDC["result"]["solution"]["gen"] if rDC["data"]["bus"]["$(rDC["data"]["gen"][i]["gen_bus"])"]["area"] == 1])
pg_ac = [gen["pg"] for (i,gen) in rAC["result"]["solution"]["gen"] if rAC["data"]["bus"]["$(rAC["data"]["gen"][i]["gen_bus"])"]["area"] == 1]
gid_ac = [parse(Int, i) for (i,gen) in rAC["result"]["solution"]["gen"] if rAC["data"]["bus"]["$(rAC["data"]["gen"][i]["gen_bus"])"]["area"] == 1]
pg_dc = [gen["pg"] for (i,gen) in rDC["result"]["solution"]["gen"] if rDC["data"]["bus"]["$(rDC["data"]["gen"][i]["gen_bus"])"]["area"] == 1]
gid_dc = [parse(Int, i) for (i,gen) in rDC["result"]["solution"]["gen"] if rDC["data"]["bus"]["$(rDC["data"]["gen"][i]["gen_bus"])"]["area"] == 1]

plot([
    scatter(x=gid_ac, y=pg_ac, mode="markers", name="AC"),
    scatter(x=gid_dc, y=pg_dc, mode="markers", name="DC")
])
sum([load["pd"] for (i,load) in rAC["data"]["load"] if rAC["data"]["bus"]["$(load["load_bus"])"]["area"] == 1])
sum([load["pd"] for (i,load) in rDC["data"]["load"] if rDC["data"]["bus"]["$(load["load_bus"])"]["area"] == 1])

plot([bus["vm"] for (i,bus) in rAC["result"]["solution"]["bus"]])
plot([gen["pg"] for (i,gen) in rAC["result"]["solution"]["gen"]])

sum([gen["pg"] for (i,gen) in rDC["result"]["solution"]["gen"]])
sum([gen["pg"] for (i,gen) in rAC["result"]["solution"]["gen"]])

sum([gen["pd"] for (i,gen) in rDC["data"]["load"]])
sum([gen["pd"] for (i,gen) in rAC["data"]["load"]])

plot([bus["vmin"] for (i,bus) in rAC["data"]["bus"]])

plot([gen["gen_status"] for (i,gen) in rDC["data"]["gen"]])
plot([gen["qmax"] for (i,gen) in rDC["data"]["gen"]])

plot(scatter(x=first.(sort([(k,abs(v)) for (k,v) in rDC["lmp"] if abs(v)<=1000], by=first)),
            y=last.(sort([(k,abs(v)) for (k,v) in rDC["lmp"] if abs(v)<=1000], by=first)),
            mode="markers"))

if haskey(rDC, "objective")
    push!(rows, (f, rDC["status"], rDC["objective"], rDC["losses_mw"], rDC["solve_time"],
    get(rDC["rrn_price"], "NSW1", NaN), get(rDC["rrn_price"], "QLD1", NaN),
    get(rDC["rrn_price"], "SA1", NaN), get(rDC["rrn_price"], "TAS1", NaN),
    get(rDC["rrn_price"], "VIC1", NaN)))
else
    push!(rows, (f, rDC["status"], NaN, NaN, NaN, NaN, NaN, NaN, NaN, NaN))
end

                     # Solve the two validation formulations ONE BY ONE before the full sweep:
# DCP (lossless nodal analogue of the copper plate) and DCP_MLF (DC + MLF
# loss booking). With enforce_thermal=false and include_generic=false these
# should track the copper-plate benchmark; residual ramp/FCAS slack is
# printed with unit names for audit (r.ramp_slacks / r.slack_by_penalty).
for f0 in ("DCP", "DCP_MLF")
    r0 = solve_network_dispatch(interval, f0; mkt=mkt, net=net,
                               include_generic=false,
                               optimizer = solver_override(f0))
    println(f0, ": ", r0["rrn_price"])
end

#

rows = compare_formulations(interval; forms=forms, mfile=mfile,
                            data_dir=joinpath("data", "nempy_2024_07"), outfile=out)
println(rows)
println("\nwritten: $out")
println("""
Interpretation guide (what IS and is NOT considered):
  * losses_mw = sum(pg) - native scaled load. In DCP/DCP_MLF this equals
    dcline_losses_mw EXACTLY: DCP is lossless on AC branches, but PowerModels'
    dcline model carries explicit losses (loss1, capped at 3%) in EVERY
    formulation. AC branch I2R losses appear only under ACP/SOCWR/QCRM/LPACC.
  * MLFs are applied ONLY in DCP_MLF (pg*base = MLF*sum(bands), generators
    only); plain DCP uses no MLFs anywhere (prices are raw XML band prices in
    both, matching the copper-plate objective convention).
    mlf_booked_losses_mw reports the (1-MLF)/MLF * pg intra-regional losses
    booked on the BID side — they never enter the network balance, which is
    why DCP_MLF's network losses can be smaller than DCP's (different dcline
    flows between the two solutions).
  * NEGATIVE objectives are expected: the objective is as-bid cost, and
    negative-priced offers (wind/solar at -\$100/-\$1000, load-side benefits)
    dominate at high renewable output — the copper-plate benchmark objective
    is negative for the same intervals.
  * SOC/QC relaxations: objective(relax) <= objective(ACP); nonzero market
    slack under AC-feasibility means the mapped operating point strains
    voltage/reactive limits — inspect result.slack_by_penalty before reading
    prices, and note ACP prices are LOCAL (Ipopt KKT multipliers).
  * NOT modelled here: fast-start two-pass, tie-break constraints, the OCD
    rerun, and AEMO's interconnector loss curves (the cause of the residual
    regional price spread vs the benchmark under lossless DCP).
""")
