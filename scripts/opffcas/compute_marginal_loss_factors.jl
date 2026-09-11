# =============================================================================
# compute_marginal_loss_factors.jl
#
# Compute marginal loss factors for every bus, one region at a time, by finite
# differencing an AC power flow: inject a small load at a bus, re-solve, and
# read the change in slack generation at that region's reference node.
#
# REQUIRES AN UNREGISTERED PACKAGE
#   The finite-difference and load-injection machinery lives in
#   `PowerModelsACDCsecurityconstrained`, which is not in Julia's General
#   registry. Install it from its source repository before running this. Nothing
#   else in NEMX depends on it, which is why it is not a dependency of the
#   package — see the `NEMX.OPFFCAS` docstring.
#
# ARGUMENTS
#   Options          Env               Default                 Meaning
#   ---------------  ----------------  ----------------------  -----------------
#   --scenario=      NEMX_SCENARIO     s3                      market scenario
#   --case=          NEMX_CASE         test/data/matpower/snem2000_acdc.m
#   --nlp-solver=    NEMX_NLP_SOLVER   ipopt                   ipopt | scs
#   --out-dir=       NEMX_OUT_DIR      <market data dir>       where mlf.m goes
#
# RUNTIME
#   One AC power flow per bus, about 2000 of them. This is an hours-long run;
#   start with a single region to check the setup.
#
# EXAMPLE
#   julia --project=. scripts/compute_marginal_loss_factors.jl --scenario=s3
# =============================================================================

using NEMX
using DataFrames
using DataFramesMeta
using InfrastructureModels
using JuMP
using PowerModels
using PowerModelsACDC

const OF = NEMX.OPFFCAS
const _PM = PowerModels
const _PMACDC = PowerModelsACDC
const _IM = InfrastructureModels

# --- Configuration ----------------------------------------------------------
const SCENARIO  = script_option("scenario", "s3")
const CASE_FILE = script_option("case", joinpath(NEMX.PKG_DIR, "test", "data",
                                          "matpower", "snem2000_acdc.m"))
const PRICE_CAP = script_number(script_option("price-cap", "16600"))
const VERBOSE   = script_flag("verbose-solver")

_PM.silence()

# Not a NEMX dependency: this package is unregistered, and only this script and
# the security-constrained problems need it. Loading it here, with a message
# that names it, is better than an UndefVarError forty lines down.
try
    @eval using PowerModelsACDCsecurityconstrained
catch err
    error("""
          This script needs PowerModelsACDCsecurityconstrained, which is not in
          Julia's General registry and is not installed in this environment.
          Add it from its source repository and re-run.

          Underlying error: $(sprint(showerror, err))
          """)
end
const _PMACDCsc = PowerModelsACDCsecurityconstrained

nlp_solver = select_solver(script_option("nlp-solver", "ipopt"); silent = !VERBOSE)
lp_solver  = select_solver(script_option("lp-solver", "highs");  silent = !VERBOSE)

print_banner("OPF with FCAS co-optimisation",
             "scenario" => SCENARIO, "case" => CASE_FILE,
             "NLP solver" => script_option("nlp-solver", "ipopt"),
             "LP solver" => script_option("lp-solver", "highs"),
             "price cap (\$/MWh)" => PRICE_CAP)

file = CASE_FILE
data = parse_file(file, validate=true, import_all=false)
scenario = SCENARIO
_PMACDC.process_additional_data!(data)
_PMACDCsc.process_scenario_data!(data, scenario)
setting = Dict("output" => Dict("branch_flows" => true, "duals" => true), "conv_losses_mp" => true, "mlf" => false)

bus_count = length(data["bus"])
result = Array{Tuple{Float64,Float64}}(undef, bus_count)

rrn = ["130", "1827", "1616", "642", "1123"]
count = 1

for region in 1:5
    area_data = _PMACDCsc.set_reference_bus(data, rrn[region])   # set all rrn as slack buses

    output = _PMACDC.run_acdcopf(area_data, PowerModels.ACPPowerModel, nlp_solver, setting=setting)
    _PM.update_data!(area_data, output["solution"])
    _PMACDCsc.update_data_converter_setpoints!(area_data, output["solution"])

    buses = filter(x -> x[2]["area"] == region, area_data["bus"])
    fx = _PMACDCsc.inject_load(0.0, rrn[region], rrn[region], area_data, nlp_solver, setting)

    for (i, bus) in sort(collect(buses), by=x -> parse(Int, x[1]))
        idx = parse(Int, i)
        p, mlf = _PMACDCsc.finite_difference(fx, x -> _PMACDCsc.inject_load(x, i, rrn[region], area_data, nlp_solver, setting), 0.0)
        result[idx] = (p, mlf)

        @show "$(count) of $(bus_count)", mlf
        count += 1
    end
end

# Calculate MLF for single node

# area_data = PM_acdc_sc.set_reference_bus(data, rrn[1])
# length(data["gen"])
# length([bus for (i, bus) in data["bus"] if bus["bus_type"] == 3])
# length(area_data["gen"])
# length([bus for (i, bus) in area_data["bus"] if bus["bus_type"] == 3])
# PM_acdc_sc.mlf_initialise!(area_data)
# fx = PM_acdc_sc.inject_load(0.0, rrn[1], rrn[1], area_data)
# p, mlf = PM_acdc_sc.finite_difference(fx, x -> PM_acdc_sc.inject_load(x, "3", rrn[1], area_data), 0.0)
# PM_acdc_sc.get_slack_generation(rrn[1], area_data)

_PMACDCsc.export_mlfs(result, scenario;
                      dir = resolve_output_dir(OF.MARKET_DATA_DIR[]))

