# =============================================================================
# build_market_scenario.jl
#
# Turn raw AEMO bid data into a market scenario the OPFFCAS models can read:
# match participants to network generators and loads, join their offers and
# prices, convert each to a piecewise-linear cost curve, and write `gencost.m`,
# `loadcost.m` and `fcas.m`.
#
# INPUTS  (under --market-dir)
#   participants.csv          participant to DUID mapping
#   <scenario>/BIDPEROFFER.csv   per-period offer volumes
#   <scenario>/BIDDAYOFFER.csv   daily offer prices
#
# OUTPUTS (under --market-dir/<scenario>)
#   gencost.m, loadcost.m, fcas.m
#
# ARGUMENTS
#   Options          Env               Default                 Meaning
#   ---------------  ----------------  ----------------------  -----------------
#   --scenario=      NEMX_SCENARIO     s1                      scenario name
#   --case=          NEMX_CASE         test/data/matpower/snem2000_acdc.m
#   --market-dir=    NEMX_MARKET_DIR   ~/nem_market_data       raw AEMO CSVs
#
# EXAMPLE
#   julia --project=. scripts/build_market_scenario.jl --scenario=s1 \
#         --market-dir=/data/aemo/2025-09
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
const SCENARIO  = script_option("scenario", "s1")
const CASE_FILE = script_option("case", joinpath(NEMX.PKG_DIR, "test", "data",
                                          "matpower", "snem2000_acdc.m"))
const PRICE_CAP = script_number(script_option("price-cap", "16600"))
const VERBOSE   = script_flag("verbose-solver")

_PM.silence()

# Raw AEMO CSVs and the .m files written from them live here. Set it once rather
# than threading a directory through every call below.
OF.MARKET_DATA_DIR[] = script_option("market-dir", OF.MARKET_DATA_DIR[])

nlp_solver = select_solver(script_option("nlp-solver", "ipopt"); silent = !VERBOSE)
lp_solver  = select_solver(script_option("lp-solver", "highs");  silent = !VERBOSE)

print_banner("OPF with FCAS co-optimisation",
             "scenario" => SCENARIO, "case" => CASE_FILE,
             "NLP solver" => script_option("nlp-solver", "ipopt"),
             "LP solver" => script_option("lp-solver", "highs"),
             "price cap (\$/MWh)" => PRICE_CAP)

file = CASE_FILE
data = PowerModels.parse_file(file, validate=true, import_all=false)

gens = OF.get_df_from_dict(data["gen"], ["index", "gen_bus", "pmax", "startup", "shutdown", "ncost", "cost", "type"])

gens = OF.assign_participant(gens, "Generator", OF.gen_filter)
gens = OF.join_offers(gens, SCENARIO)

gens_energy = OF.join_energy_prices(gens, SCENARIO)
gens_energy = @orderby gens_energy :index
OF.gen_convert_to_pwl!(gens_energy)
OF.export_gen_cost(gens_energy, SCENARIO)

gens_fcas = OF.join_fcas_prices(gens, SCENARIO)
gens_fcas = @orderby gens_fcas :index
OF.gen_convert_to_pwl!(gens_fcas)

loads = OF.get_df_from_dict(data["load"], ["index", "pd"],  ["pd" => "pmax"])
loads = OF.assign_participant(loads, "Load", OF.load_filter)
loads = OF.join_offers(loads, SCENARIO)

loads_energy = OF.join_energy_prices(loads, SCENARIO)
loads_energy = @orderby loads_energy :index
OF.load_convert_to_pwl!(loads_energy)
OF.export_load_data(loads_energy, SCENARIO)

load_fcas = OF.join_fcas_prices(loads, SCENARIO)
load_fcas = @orderby load_fcas :index
OF.load_convert_to_pwl!(load_fcas)

OF.export_fcas_data(SCENARIO, gens_fcas, load_fcas)