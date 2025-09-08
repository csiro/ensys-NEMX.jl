using Pkg
Pkg.activate(".")

using JuMP
using Ipopt
using Gurobi
using Cbc
using PowerModels
using PowerModelsACDC
using PowerModelsACDCsecurityconstrained
using Revise
using CSV
using PlotlyJS
using Dates
using DataFrames
using DataFramesMeta
using InfrastructureModels
using Memento
using NEMX


const _PM = PowerModels
const _PMACDC = PowerModelsACDC
const _IM = InfrastructureModels
const _PMACDCsc = PowerModelsACDCsecurityconstrained

### Assign solvers: make sure the path is right
# Mac
ENV["GUROBI_HOME"] = "/Library/gurobi952/macos_universal2"
ENV["GRB_LICENSE_FILE"] = "/Users/moh050/Library/CloudStorage/OneDrive-CSIRO/solvers/gurobi952lic/gurobi.lic"
# Win
# ENV["GUROBI_HOME"] = "C:\\gurobi952\\win64"
# ENV["GRB_LICENSE_FILE"] = "C:\\gurobi952lic\\gurobi.lic"

# ENV["MOSEKBINDIR"] = "C:\\Program Files\\Mosek\\10.2\\tools\\platform\\win64x86\\bin"
# ENV["MOSEKLM_LICENSE_FILE"] = "C:\\Users\\moh050\\mosek\\mosek.lic"

# silence unnecessary warnings
_PM.silence();
Memento.setlevel!(Memento.getlogger(Gurobi), "error");
Memento.setlevel!(Memento.getlogger(PowerModelsACDC), "error");

# read/parse data
file = "./test/data/matpower/snem2000_acdc.m"

data = parse_file(file, validate=true, import_all=false)
NEMX.process_scenario_data!(data, "s3")
_PMACDC.process_additional_data!(data)
# Defining generator areas sets: data["area_gens"]
NEMX.add_area_gens!(data)



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
data["price_cap"] = 16600
    

# define solver
nlp_solver = optimizer_with_attributes(Ipopt.Optimizer, "print_level"=>0) # , "nlp_scaling_method" => "gradient-based"   "tol"=>1e-6, "mu_init"=>1e-4,
lp_solver = optimizer_with_attributes(Cbc.Optimizer, "logLevel" => 1)
gurobi_solver = optimizer_with_attributes(Gurobi.Optimizer, "OutputFlag" => 0, "QCPDual" => 1)  # , "NonConvex" => 2, "presolve" => 0, "FeasibilityTol" => 1E-2,"OptimalityTol" => 1E-2, "MIPGap" => 0.001 "NumericFocus" => 3, , "IntFeasTol" => 1E-5, 


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
dc_result = NEMX.run_acdcopfcas(dc_data, _PM.DCPPowerModel, gurobi_solver, setting=setting)
_PM.update_data!(dc_data, dc_result["solution"])
price_dc = [region => dc_data["bus"]["$(bus)"]["lam_kcl_r"] for (region, bus) in rrn]


# run dispatch with shadow prices (2)
pm = _PM.instantiate_model(dc_data, _PM.DCPPowerModel, NEMX.build_acdcopfcas, ref_extensions=[_PMACDC.add_ref_dcgrid!, _PMACDC.ref_add_gendc!], setting=setting);
dc_result = optimize_model!(pm, optimizer=gurobi_solver)
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
rows_DC = NEMX.create_price_table_rows(dc_data, "DC")
T1 = NEMX.create_single_price_table(rows_DC)


# state-wide nodal prices
price_DC = NEMX.create_region_wise_nodal_prices(dc_data)
NEMX.plot_state_wide_nodal_lmps(price_DC, "NSW")





