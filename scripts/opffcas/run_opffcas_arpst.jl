# =============================================================================
# run_opffcas_arpst.jl
#
# As run_opffcas.jl, but with phase-shifting transformers and their control
# variables active, to study how angle control interacts with the FCAS
# co-optimisation and with regional prices.
#
# ARGUMENTS
#   Options            Env                 Default                Meaning
#   -----------------  ------------------  ---------------------  ---------------
#   --scenario=        NEMX_SCENARIO       s3                     market scenario
#   --case=            NEMX_CASE           test/data/matpower/snem2000_acdc.m
#   --nlp-solver=      NEMX_NLP_SOLVER     ipopt                  ipopt | scs
#   --lp-solver=       NEMX_LP_SOLVER      highs                  highs
#   --price-cap=       NEMX_PRICE_CAP      16600                  $/MWh
#
#   Flags              Env                 Meaning
#   -----------------  ------------------  --------------------------------------
#   --verbose-solver   NEMX_VERBOSE_SOLVER Let the solver print its own progress
#
# EXAMPLE
#   julia --project=. scripts/run_opffcas_arpst.jl --scenario=s3
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

nlp_solver = select_solver(script_option("nlp-solver", "ipopt"); silent = !VERBOSE)
lp_solver  = select_solver(script_option("lp-solver", "highs");  silent = !VERBOSE)

print_banner("OPF with FCAS co-optimisation",
             "scenario" => SCENARIO, "case" => CASE_FILE,
             "NLP solver" => script_option("nlp-solver", "ipopt"),
             "LP solver" => script_option("lp-solver", "highs"),
             "price cap (\$/MWh)" => PRICE_CAP)

# Solvers come from --nlp-solver / --lp-solver; see this file's header.
# read/parse data
file = CASE_FILE

data = parse_file(file, validate=true, import_all=false)
OF.process_scenario_data!(data, "s3")
_PMACDC.process_additional_data!(data)
# Defining generator areas sets: data["area_gens"]
OF.add_area_gens!(data)

# define regional reference nodes
rrn = Dict("NSW"=>"130", "VIC"=>"1480", "QLD"=>"1274", "SA" => "1643", "TAS" => "1123")
# rrn = Dict("NSW"=>"130", "VIC"=>"1827", "QLD"=>"1616", "SA" => "642", "TAS" => "1123")
data["rrn"] = Dict{String, Any}()
data["rrn"] = rrn
data["bus_rr"] = Dict{String, Any}()
for (region, bus) in rrn
    data["bus_rr"]["$(bus)"] = data["bus"]["$(bus)"]
end
# set a price cap
data["price_cap"] = PRICE_CAP
    

# define solver

# Scale regional fcas targets
# for s in data["fcas_target"]
#     s["p"] = 0.25*s["p"]
# end

# Scale fcas prices to cents
for (i, gen) in data["gen"]
    if haskey(gen, "fcas_cost")
        for s in gen["fcas_cost"]
            if !isempty(filter(!=(0), s[2]["cost"][2:2:20]))
                s[2]["cost"][2:2:20] .= s[2]["cost"][2:2:20] ./ 100
            end
        end
    end
end

# settings
setting = Dict("output" => Dict("branch_flows" => true, "duals" => true), "conv_losses_mp" => true, "mlf" => true)

# run dispatch with duals (1)
dc_data = deepcopy(data);
dc_result = OF.run_acdcopfcas(dc_data, _PM.DCPPowerModel, lp_solver, setting=setting)
_PM.update_data!(dc_data, dc_result["solution"])
price_dc = [region => dc_data["bus"]["$(bus)"]["lam_kcl_r"] for (region, bus) in rrn]

# run dispatch with shadow prices (2)
pm = _PM.instantiate_model(dc_data, _PM.DCPPowerModel, OF.build_acdcopfcas, ref_extensions=[_PMACDC.add_ref_dcgrid!, _PMACDC.ref_add_gendc!], setting=setting);
dc_result = optimize_model!(pm, optimizer=lp_solver)
JuMP.has_duals(pm.model)
for (i,b) in dc_data["bus"]
    b["lam_kcl_r"] = JuMP.shadow_price(pm.sol[:it][:pm][:nw][0][:bus][b["index"]][:lam_kcl_r])
end
for (i,b) in dc_data["bus_rr"]
    b["lam_LReg"] = JuMP.shadow_price(pm.sol[:it][:pm][:nw][0][:bus_rr][b["index"]][:lam_LReg])
    b["lam_RReg"] = JuMP.shadow_price(pm.sol[:it][:pm][:nw][0][:bus_rr][b["index"]][:lam_RReg])
    b["lam_L1S"] = JuMP.shadow_price(pm.sol[:it][:pm][:nw][0][:bus_rr][b["index"]][:lam_L1S])
    b["lam_R1S"] = JuMP.shadow_price(pm.sol[:it][:pm][:nw][0][:bus_rr][b["index"]][:lam_R1S])
    b["lam_L6S"] = JuMP.shadow_price(pm.sol[:it][:pm][:nw][0][:bus_rr][b["index"]][:lam_L6S])
    b["lam_R6S"] = JuMP.shadow_price(pm.sol[:it][:pm][:nw][0][:bus_rr][b["index"]][:lam_R6S])
    b["lam_L60S"] = JuMP.shadow_price(pm.sol[:it][:pm][:nw][0][:bus_rr][b["index"]][:lam_L60S])
    b["lam_R60S"] = JuMP.shadow_price(pm.sol[:it][:pm][:nw][0][:bus_rr][b["index"]][:lam_R60S])
    b["lam_L5M"] = JuMP.shadow_price(pm.sol[:it][:pm][:nw][0][:bus_rr][b["index"]][:lam_L5M])
    b["lam_R5M"] = JuMP.shadow_price(pm.sol[:it][:pm][:nw][0][:bus_rr][b["index"]][:lam_R5M])
end

# Results
# Table regional prices
rows_DC = OF.create_price_table_rows(dc_data, "DC")
T1 = OF.create_single_price_table(rows_DC)

# state-wide nodal prices
price_DC = OF.create_region_wise_nodal_prices(dc_data)
plot_state_wide_nodal_lmps(price_DC, "NSW")

# extra
using PowerPlots
using ColorSchemes

data_nsw = parse_file("./test/data/matpower/snemNSW.m")
PowerPlots.powerplot(data_nsw)

