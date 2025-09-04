
# Script for OPFCAS with different formulations

using Pkg
Pkg.activate(".")

using JuMP
using Ipopt
# using SCS
# using MosekTools
using Gurobi
using Cbc
using HiGHS
using PowerModels
using PowerModelsACDC
using PowerModelsACDCsecurityconstrained
using Revise
# using JLD
using CSV
using PlotlyJS
using Dates
using DataFrames
using DataFramesMeta
using InfrastructureModels
using Memento
using Interpolations
using Statistics
using NEMX

file = pkgdir(NEMX.PowerModels,"test","data", "matpower", "case14.m")


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


_PM.silence();
Memento.setlevel!(Memento.getlogger(Gurobi), "error");
Memento.setlevel!(Memento.getlogger(PowerModelsACDC), "error");


file = "./test/data/matpower/snem2000_acdc.m"

data = parse_file(file, validate=true, import_all=false)
NEMX.process_scenario_data!(data, "s3")
_PMACDC.process_additional_data!(data)

# Defining generator areas sets: data["area_gens"]
set1 = Set{Int64}()
set2 = Set{Int64}()
set3 = Set{Int64}()
set4 = Set{Int64}()
set5 = Set{Int64}()

for i = 1:length(data["gen"])
    gen_bus = data["gen"]["$i"]["gen_bus"]
    if data["bus"]["$gen_bus"]["area"] == 1
        push!(set1, data["gen"]["$i"]["index"])
    elseif data["bus"]["$gen_bus"]["area"] == 2
        push!(set2, data["gen"]["$i"]["index"])
    elseif data["bus"]["$gen_bus"]["area"] == 3
        push!(set3, data["gen"]["$i"]["index"])
    elseif data["bus"]["$gen_bus"]["area"] == 4
        push!(set4, data["gen"]["$i"]["index"])
    elseif data["bus"]["$gen_bus"]["area"] == 5
        push!(set5, data["gen"]["$i"]["index"])
    end
end

data["area_gens"] = Dict{Int64, Set{Int64}}()
data["area_gens"][1] = set1
data["area_gens"][2] = set2
data["area_gens"][3] = set3
data["area_gens"][4] = set4
data["area_gens"][5] = set5

rrn = Dict("NSW"=>"130", "VIC"=>"1480", "QLD"=>"1274", "SA" => "1643", "TAS" => "1123")
# rrn = Dict("NSW"=>"130", "VIC"=>"1827", "QLD"=>"1616", "SA" => "642", "TAS" => "1123")

data["rrn"] = Dict{String, Any}()
data["rrn"] = rrn
data["bus_rr"] = Dict{String, Any}()
for (region, bus) in rrn
    data["bus_rr"]["$(bus)"] = data["bus"]["$(bus)"]
end
data["price_cap"] = 16600

    
data["branch_intc"] = Dict{String, Any}()
data["branch_intc"]["1"] = Dict{String, Any}("name" => "Regional_Intc_QL_to_NSW", "source_id" => Any["branch_intc", 1], "f_bus" => 1274, "br_status" => 1, "t_bus" => 130, "index" => 1, "pmin" => -21.7, "pmax" => 21.7, "min_fl" => 0, "imin_fl" => false)     
data["branch_intc"]["2"] = Dict{String, Any}("name" => "Regional_Intc_NSW_to_VIC", "source_id" => Any["branch_intc", 2], "f_bus" => 130, "br_status" => 1, "t_bus" => 1480, "index" => 2, "pmin" => -26.82, "pmax" => 26.82, "min_fl" => 4.00, "imin_fl" => false)  
data["branch_intc"]["3"] = Dict{String, Any}("name" => "Regional_Intc_VIC_to_TAS", "source_id" => Any["branch_intc", 3], "f_bus" => 1480, "br_status" => 1, "t_bus" => 1123, "index" => 3, "pmin" => -5.1, "pmax" => 5.1, "min_fl" => 0, "imin_fl" => false)  
data["branch_intc"]["4"] = Dict{String, Any}("name" => "Regional_Intc_VIC_to_SA", "source_id" => Any["branch_intc", 4], "f_bus" => 1480, "br_status" => 1, "t_bus" => 1643, "index" => 4, "pmin" => -12.579, "pmax" => 12.579, "min_fl" => 0, "imin_fl" => false)  


setting = Dict("output" => Dict("branch_flows" => true, "duals" => true), "conv_losses_mp" => true, "mlf" => false)
nlp_solver = optimizer_with_attributes(Ipopt.Optimizer, "print_level"=>0) # , "nlp_scaling_method" => "gradient-based"   "tol"=>1e-6, "mu_init"=>1e-4,
lp_solver = optimizer_with_attributes(Cbc.Optimizer, "logLevel" => 1)
# mosek_solver = optimizer_with_attributes(Mosek.Optimizer, "QUIET" => true)
# scs_solver = optimizer_with_attributes(SCS.Optimizer, "verbose"=>true)
gurobi_solver = optimizer_with_attributes(Gurobi.Optimizer, "OutputFlag" => 0, "QCPDual" => 1)  # , "NonConvex" => 2, "presolve" => 0, "FeasibilityTol" => 1E-2,"OptimalityTol" => 1E-2, "MIPGap" => 0.001 "NumericFocus" => 3, , "IntFeasTol" => 1E-5, 
# set_attribute(gurobi_solver, "QCPDual", 1);
# set_attribute(gurobi_solver, "presolve", "off")
highs_solver = optimizer_with_attributes(HiGHS.Optimizer) 



# result_dc_acdc = _PMACDC.run_acdcopf(data, _PM.DCPPowerModel, gurobi_solver, setting=setting)



data["gen"]["137"]["cost"] = data["gen"]["12"]["cost"]
data["gen"]["138"]["cost"] = data["gen"]["1"]["cost"] 
data["gen"]["139"]["cost"] = data["gen"]["1"]["cost"]
data["gen"]["140"]["cost"] = data["gen"]["1"]["cost"]
data["gen"]["159"]["cost"] = data["gen"]["1"]["cost"]
data["gen"]["198"]["cost"] = data["gen"]["1"]["cost"]

data["gen"]["137"]["cost"][18] = 1800.22
data["gen"]["138"]["cost"][18] = 1800.22 
data["gen"]["139"]["cost"][18] = 1800.22 
data["gen"]["140"]["cost"][18] = 1800.22 
data["gen"]["159"]["cost"][18] = 1800.22 

# Scale regional fcas targets
for s in data["fcas_target"]
    s["p"] = 0.2*s["p"]
end

for (i, gen) in data["gen"]
    if haskey(gen, "fcas_cost")
        for s in gen["fcas_cost"]
            if !isempty(filter(!=(0), s[2]["cost"][2:2:20]))
                s[2]["cost"][2:2:20] .= s[2]["cost"][2:2:20] ./ 10000
            end
        end
    end
end

for (i, load) in data["load"]
    if haskey(load, "fcas_cost")
        for s in load["fcas_cost"]
            if !isempty(filter(!=(0), s[2]["cost"][2:2:20]))
                s[2]["cost"][2:2:20] .= s[2]["cost"][2:2:20] ./ 1000
            end
        end
    end
end 



s = 8
data["load"]["279"]["pd"] = s*data["load"]["279"]["pd"]
data["load"]["681"]["pd"] = s*data["load"]["681"]["pd"]  
data["load"]["60"]["pd"] = s*data["load"]["60"]["pd"] 
data["load"]["400"]["pd"] = s*data["load"]["400"]["pd"]  
data["load"]["731"]["pd"] = s*data["load"]["731"]["pd"]  
data["load"]["800"]["pd"] = s*data["load"]["800"]["pd"]   
data["load"]["884"]["pd"] = s*data["load"]["884"]["pd"]

s = 0.4
data["load"]["134"]["pd"] = s*data["load"]["134"]["pd"]
data["load"]["288"]["pd"] = s*data["load"]["288"]["pd"]
data["load"]["330"]["pd"] = s*data["load"]["330"]["pd"]
data["load"]["650"]["pd"] = s*data["load"]["650"]["pd"]
data["load"]["658"]["pd"] = s*data["load"]["658"]["pd"]

data["load"]["134"]["qd"] = s*data["load"]["134"]["qd"]  # nsw spike 1
data["load"]["288"]["qd"] = s*data["load"]["288"]["qd"]  # nsw spike 2
data["load"]["330"]["qd"] = s*data["load"]["330"]["qd"]  # nsw spike 3
data["load"]["650"]["qd"] = s*data["load"]["650"]["qd"]  # nsw spike 4
data["load"]["658"]["qd"] = s*data["load"]["658"]["qd"]

s = 0.15
data["load"]["328"]["pd"] = s*data["load"]["328"]["pd"]
data["load"]["337"]["pd"] = s*data["load"]["337"]["pd"]
data["load"]["471"]["pd"] = s*data["load"]["471"]["pd"]

s = 0.9
data["load"]["68"]["pd"] = s*data["load"]["68"]["pd"]
data["load"]["309"]["pd"] = s*data["load"]["309"]["pd"]
data["load"]["324"]["pd"] = s*data["load"]["324"]["pd"]
data["load"]["428"]["pd"] = s*data["load"]["428"]["pd"]
data["load"]["448"]["pd"] = s*data["load"]["448"]["pd"]
data["load"]["510"]["pd"] = s*data["load"]["510"]["pd"]
data["load"]["537"]["pd"] = s*data["load"]["537"]["pd"]
data["load"]["697"]["pd"] = s*data["load"]["697"]["pd"]
data["load"]["775"]["pd"] = s*data["load"]["775"]["pd"]
data["load"]["822"]["pd"] = s*data["load"]["822"]["pd"]
data["load"]["833"]["pd"] = s*data["load"]["833"]["pd"]
data["load"]["883"]["pd"] = s*data["load"]["883"]["pd"]




data["mlf"][144]["mlf"] = data["mlf"][144]["mlf"] + 0.1
data["mlf"][703]["mlf"] = data["mlf"][703]["mlf"] + 0.1
data["mlf"][753]["mlf"] = data["mlf"][753]["mlf"] + 0.1
data["mlf"][981]["mlf"] = data["mlf"][981]["mlf"] + 0.1
data["mlf"][1024]["mlf"] = data["mlf"][1024]["mlf"] + 0.1
data["mlf"][1148]["mlf"] = data["mlf"][1148]["mlf"] + 0.09
data["mlf"][1216]["mlf"] = data["mlf"][1216]["mlf"] + 0.1
data["mlf"][1548]["mlf"] = data["mlf"][1548]["mlf"] + 0.1
data["mlf"][1713]["mlf"] = data["mlf"][1713]["mlf"] + 0.1
data["mlf"][1814]["mlf"] = data["mlf"][1814]["mlf"] + 0.09
data["mlf"][1839]["mlf"] = data["mlf"][1839]["mlf"] + 0.1
data["mlf"][1940]["mlf"] = data["mlf"][1940]["mlf"] + 0.1



for (i,branch) in data["branch"]
    if branch["rate_a"] > branch["rate_b"] &&  branch["rate_a"] > branch["rate_c"]
        branch["rate_b"] = branch["rate_c"] = branch["rate_a"]
    elseif branch["rate_b"] > branch["rate_a"] &&  branch["rate_b"] > branch["rate_c"]
            branch["rate_a"] = branch["rate_c"] = branch["rate_b"]
        elseif branch["rate_c"] > branch["rate_a"] &&  branch["rate_c"] > branch["rate_b"]
            branch["rate_a"] = branch["rate_b"] = branch["rate_c"]
        end
end


# for (i,gen) in data["gen"]
#     gen["cost"] = [3.0, 500.0, 10.0, 1000.0]
#     gen["ncost"] = 2
# end



# run tests
dc_data = deepcopy(data);
delete!(dc_data, "mlf")
setting = Dict("output" => Dict("branch_flows" => true, "duals" => true), "conv_losses_mp" => true, "mlf" => false)
pm = _PM.instantiate_model(dc_data, _PM.DCPPowerModel, NEMX.build_acdcopfcas, ref_extensions=[_PMACDC.add_ref_dcgrid!], setting=setting);
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

ac_data = deepcopy(data);
delete!(ac_data, "mlf")
pm = _PM.instantiate_model(ac_data, _PM.ACPPowerModel, NEMX.build_acdcopfcas, ref_extensions=[_PMACDC.add_ref_dcgrid!], setting=setting);
ac_result = optimize_model!(pm, optimizer=nlp_solver)
JuMP.has_duals(pm.model)
for (i,b) in ac_data["bus"]
    b["lam_kcl_r"] = JuMP.shadow_price(pm.sol[:it][:pm][:nw][0][:bus][b["index"]][:lam_kcl_r])
end
for (i,b) in ac_data["bus_rr"]
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

# setting = Dict("output" => Dict("branch_flows" => true, "duals" => true), "conv_losses_mp" => true, "mlf" => true)
dc_data_mlf = deepcopy(data);
pm = _PM.instantiate_model(dc_data_mlf, _PM.DCPPowerModel, NEMX.build_acdcopfcas, ref_extensions=[_PMACDC.add_ref_dcgrid!], setting=setting);
dc_mlf_result = optimize_model!(pm, optimizer=nlp_solver);
JuMP.has_duals(pm.model)
for (i,b) in dc_data_mlf["bus"]
    b["lam_kcl_r"] = JuMP.shadow_price(pm.sol[:it][:pm][:nw][0][:bus][b["index"]][:lam_kcl_r])
end
for (i,b) in dc_data_mlf["bus_rr"]
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
# setting = Dict("output" => Dict("branch_flows" => true, "duals" => true), "conv_losses_mp" => true, "mlf" => false)

# Results
# T1 regional prices
rows_AC = NEMX.create_price_table_rows(ac_data, "AC")
rows_DC = NEMX.create_price_table_rows(dc_data, "DC")
rows_DC_MLF = NEMX.create_price_table_rows(dc_data_mlf, "DC_MLF")
T1 = NEMX.create_price_table(rows_AC, rows_DC, rows_DC_MLF)


# P1 state-wide prices
price_AC = NEMX.create_region_wise_nodal_prices(ac_data)
price_DC = NEMX.create_region_wise_nodal_prices(dc_data)
price_DC_MLF = NEMX.create_region_wise_nodal_prices(dc_data_mlf)
NEMX.plot_state_wide_prices(price_AC, price_DC, price_DC_MLF)



_PM.update_data!(dc_data, dc_result["solution"])
_PM.update_data!(ac_data, ac_result["solution"])
price_ac = [region => ac_data["bus"]["$(bus)"]["lam_kcl_r"] for (region, bus) in rrn]
price_dc = [region => dc_data["bus"]["$(bus)"]["lam_kcl_r"] for (region, bus) in rrn]
pg_cost_dc = [gen["pg_cost"] for (i,gen) in dc_result["solution"]["gen"]]
pg_cost_ac = [gen["pg_cost"] for (i,gen) in ac_result["solution"]["gen"]]
pd_cost_dc = [load["pd_cost"] for (i,load) in dc_result["solution"]["load"]]
pd_cost_ac = [load["pd_cost"] for (i,load) in ac_result["solution"]["load"]]
t_pg_cost = scatter(x=pg_cost_dc, y=pg_cost_ac, mode = "markers")
plot(pg_cost_ac, name="AC pg_cost")
plot(pg_cost_dc, title="DC pg_cost")
plot([t_pg_cost])
NEMX.plot_cost(dc_data)

NEMX.plot_costs(dc_data, ac_data)

va_dc = [bus["va"] for (i,bus) in dc_result["solution"]["bus"]]
va_ac = [bus["va"] for (i,bus) in ac_result["solution"]["bus"]]
t_va = scatter(x=va_dc, y=va_ac, mode = "markers")
plot([t_va])

s_rate = [branch["rate_c"] for (i,branch) in dc_data["branch"]]
s_dc = [sqrt(branch["pf"]^2+branch["pt"]^2) for (i,branch) in dc_data["branch"]]
s_ac = [sqrt(branch["pf"]^2+branch["pt"]^2) for (i,branch) in ac_data["branch"]]
t_ac = scatter(x=[branch["index"] for (i,branch) in ac_data["branch"]], y=s_ac, mode = "markers")
t_dc = scatter(x=[branch["index"] for (i,branch) in dc_data["branch"]], y=s_dc, mode = "markers")
t_rate = scatter(x=[branch["index"] for (i,branch) in ac_data["branch"]], y=s_rate, mode = "markers")
plot([t_ac, t_dc, t_rate])
plot([t_ac, t_dc])


t_dc_diff = scatter(x=[branch["index"] for (i,branch) in dc_data["branch"]], y=s_dc.-s_rate, mode = "markers")
plot([t_dc_diff])

t_ac_diff = scatter(x=[branch["index"] for (i,branch) in ac_data["branch"]], y=s_ac.-s_rate, mode = "markers")
plot([t_ac_diff])

t_ac = scatter(x=1:1:length(s_ac), y=s_ac, mode = "markers", name="ac")
t_rate = scatter(x=1:1:length(rate), y=rate, mode = "markers", name ="rate")
plot([t_dc, t_ac, t_rate])

# result_dc_acdc = _PMACDC.run_acdcopf(dc_data, _PM.DCPPowerModel, gurobi_solver, setting=setting)
pm = _PM.instantiate_model(dc_data, _PM.DCPPowerModel, _PMACDC.build_acdcopf, ref_extensions=[_PMACDC.add_ref_dcgrid!], setting=setting);
dc_result = optimize_model!(pm, optimizer=nlp_solver)
JuMP.has_duals(pm.model)
for (i,b) in dc_data["bus"]
    b["lam_kcl_r"] = JuMP.shadow_price(pm.sol[:it][:pm][:nw][0][:bus][b["index"]][:lam_kcl_r])
end

#############################################################################################################################################################################################
# # multi-network
number_of_hours = 2
number_of_contingencies = 0
data["time_interval"] = 1 # 1 = 1hr
hour_ids = [];
for i in 1:number_of_hours
    push!(hour_ids, i)
end
mn_data = _IM.replicate(data, number_of_hours, Set{String}(["source_type", "name", "source_version", "per_unit"]))
mn_data["hour_ids"] = hour_ids
mn_data["number_of_hours"] = number_of_hours
mn_data["number_of_contingencies"] = number_of_contingencies
acp_mn_data = deepcopy(mn_data)
acp_mn_result = NEMX.run_mn_acdcopfcas(acp_mn_data, _PM.ACPPowerModel, nlp_solver, setting=setting)
update_data!(acp_mn_data, acp_mn_result["solution"])







#############################################################################################################################################################################################
# result_ac_acdc = _PMACDC.run_acdcopf(dc_data, _PM.ACPPowerModel, nlp_solver, setting=setting)
pm = _PM.instantiate_model(dc_data, _PM.ACPPowerModel, _PMACDC.build_acdcopf, ref_extensions=[_PMACDC.add_ref_dcgrid!], setting=setting);
ac_result = optimize_model!(pm, optimizer=nlp_solver)
JuMP.has_duals(pm.model)
for (i,b) in ac_data["bus"]
    b["lam_kcl_r"] = JuMP.shadow_price(pm.sol[:it][:pm][:nw][0][:bus][b["index"]][:lam_kcl_r])
end


# _PM.update_data!(dc_data, result_dc_acdc["solution"])
# _PM.update_data!(ac_data, result_ac_acdc["solution"])
price_ac = [region => ac_data["bus"]["$(bus)"]["lam_kcl_r"] for (region, bus) in rrn]
price_dc = [region => dc_data["bus"]["$(bus)"]["lam_kcl_r"] for (region, bus) in rrn]

pg_cost_dc = [gen["pg_cost"] for (i,gen) in dc_result["solution"]["gen"]]
pg_cost_ac = [gen["pg_cost"] for (i,gen) in ac_result["solution"]["gen"]]
t_pg_cost = scatter(x=pg_cost_dc, y=pg_cost_ac, mode = "markers")
plot(pg_cost_ac)


pg_ac = sum([gen["pg"] for (i,gen) in ac_result["solution"]["gen"]])
pg_dc = sum([gen["pg"] for (i,gen) in dc_result["solution"]["gen"]])

pg_ac = sum([load["pd"] for (i,load) in ac_result["solution"]["load"]])
pg_dc = sum([load["pd"] for (i,load) in dc_result["solution"]["load"]])

pg_ac = sum([gen["pg"] for (i,gen) in result_ac_acdc["solution"]["gen"]])
pg_dc = sum([gen["pg"] for (i,gen) in result_dc_acdc["solution"]["gen"]])

for (i,gen) in data["gen"]
    if gen["cost"][1] > gen["cost"][3] || gen["cost"][3] > gen["cost"][5] || gen["cost"][5] > gen["cost"][7] || gen["cost"][7] > gen["cost"][9] || gen["cost"][9] > gen["cost"][11] ||
       gen["cost"][9] > gen["cost"][11] || gen["cost"][11] > gen["cost"][13] || gen["cost"][13] > gen["cost"][15] || gen["cost"][15] > gen["cost"][17] || gen["cost"][17] > gen["cost"][19]
        println("$(gen["index"]) ... $(gen["cost"]')")
    end
end

data["gen"]["1"]["pg"]
data["gen"]["1"]["pmax"]

for (i,gen) in data["gen"]
    for num in gen["cost"][2:2:20]
        if num > 16600
            num = 16600
        end
    end
end



x = [0.0, -828.9, 0.86, -43.11, 1.72, -43.11, 1.72, -43.11, 1.72, -43.11, 1.72, -43.11, 1.72, -43.11, 1.72, -43.11, 1.72, -43.11, 1.72, -43.11]
new_x = NEMX.process_flat_segments_xyvec(x)
NEMX.slope_intercepts(new_x)


for (i,gen) in data["gen"]
    gen["pg_cost"] = linear_interpolation(1:1:20, gen["cost"])
end

lint_cost = linear_interpolation(1:1:20, data["gen"]["1"]["cost"])
obj = interpolate(data["gen"]["1"]["cost"], BSpline(Linear()))
knots =([2, 2.5, 2.75, 3, 3.5, 3.75, 3.8, 4, 4.5, 4.75, 4.8, 5, 5.5, 5.75, 6, 6.5, 6.75, 7, 7.5, 7.75],);
obj = interpolate(knots, data["gen"]["1"]["cost"], Gridded(Linear()))


i=2
p=[]
for num in data["gen"]["1"]["cost"][1:2:19]
    println("$(lint_cost(num)) ....... $num ....... $(data["gen"]["1"]["cost"][i])")
    push!(p, lint_cost(num))
    i += 2
end

# for (i,gen)  in data["gen"]
#     gen["cost"] = NEMX.process_flat_segments_xyvec(gen["cost"])
# end

##

# cp_data = deepcopy(data);
# cp_result = NEMX.run_acdcopfcas_cp(cp_data, NEMX.CPPowerModel, gurobi_solver, setting=setting)
# _PM.update_data!(cp_data, cp_result["solution"])
# price_cp = [region => cp_data["bus"]["$(bus)"]["lam_kcl_r"] for (region, bus) in rrn]

dc_data = deepcopy(data);
dc_result = NEMX.run_acdcopfcas(dc_data, _PM.DCPPowerModel, gurobi_solver, setting=setting)
_PM.update_data!(dc_data, dc_result["solution"])
price_dc = [region => dc_data["bus"]["$(bus)"]["lam_kcl_r"] for (region, bus) in rrn]
plot([bus["lam_kcl_r"] for (i,bus) in dc_result["solution"]["bus"] ])




pg = [gen["pg"] for (i,gen) in dc_result["solution"]["gen"]]
pmax = [gen["pmax"] for (i,gen) in dc_data["gen"]]
e = pmax .- pg
plot(e)

setting = Dict("output" => Dict("branch_flows" => true, "duals" => true), "conv_losses_mp" => true, "mlf" => true)
dc_data_mlf = deepcopy(data);
dc_result_mlf = NEMX.run_acdcopfcas(dc_data_mlf, _PM.DCPPowerModel, gurobi_solver, setting=setting)
_PM.update_data!(dc_data_mlf, dc_result_mlf["solution"])
price_dc_mlf = [region => dc_data_mlf["bus"]["$(bus)"]["lam_kcl_r"] for (region, bus) in rrn]
plot([bus["lam_kcl_r"] for (i,bus) in dc_result_mlf["solution"]["bus"] ])
setting = Dict("output" => Dict("branch_flows" => true, "duals" => true), "conv_losses_mp" => true, "mlf" => false)






gen_buses = [gen["gen_bus"] for (i, gen) in data["gen"]]
load_buses = [load["load_bus"] for (i, load) in data["load"]]
ploads = Dict(i => load for (i,load) in dc_data["load"] for pload in dc_data["load_limit"] if load["index"] == pload["load"])

pload_buses = [load["load_bus"] for (i, load) in data["load"] if load["index"] in ploads]
# price_nodes = gen_buses ∪ load_buses ∪ pload_buses
# price_nsw = [ac_data["bus"]["$(gen["gen_bus"])"]["lam_kcl_r"] for (i, gen) in ac_data["gen"] if ac_data["bus"]["$(gen["gen_bus"])"]["area"] == s]

# gen_areas = keys(data["area_gens"])
# bus_rr = data["bus_rr"]
# area_bus = Dict(area => bus["index"] for (area, gens) in area_gens for (i,bus) in bus_rr if area == bus["area"])






ac_data = deepcopy(data);
ac_result = NEMX.run_acdcopfcas(ac_data, _PM.ACPPowerModel, nlp_solver, setting=setting)
_PM.update_data!(ac_data, ac_result["solution"])
price_ac = [region => ac_data["bus"]["$(bus)"]["lam_kcl_r"] for (region, bus) in rrn]
plot([bus["lam_kcl_r"] for (i,bus) in ac_result["solution"]["bus"] ])








# socc_data = deepcopy(data);
# socc_result = NEMX.run_acdcopfcas(socc_data, _PM.SOCWRConicPowerModel, mosek_solver, setting=setting)
# _PM.update_data!(socc_data, socc_result["solution"])
# price_socc = [region => socc_data["bus"]["$(bus)"]["lam_kcl_r"] for (region, bus) in rrn]


# soc_data = deepcopy(data);
# soc_result = NEMX.run_acdcopfcas(soc_data, _PM.SOCWRPowerModel, nlp_solver, setting=setting)
# _PM.update_data!(soc_data, soc_result["solution"])
# price_soc = [region => soc_data["bus"]["$(bus)"]["lam_kcl_r"] for (region, bus) in rrn]


# socbfc_data = deepcopy(data);
# socbfc_result = NEMX.run_acdcopfcas_bf(socbfc_data, _PM.SOCBFConicPowerModel, nlp_solver, setting=setting)
# _PM.update_data!(socbfc_data, socbfc_result["solution"])
# price_socbfc = [region => socbfc_data["bus"]["$(bus)"]["lam_kcl_r"] for (region, bus) in rrn]





# data["bus"]["1123"]["vmin"] = data["bus"]["1123"]["vmax"]
for (i,bus) in data["bus"]
    bus["vmax"] = 1.1
    bus["vmin"] = 0.9
end
data["bus"]["130"]["vmin"] = data["bus"]["130"]["vmax"]
##
socbf_data = deepcopy(data);

_PM.update_data!(socbf_data, ac_result["solution"])

_PM.set_ac_pf_start_values!(socbf_data)

# socbf_result = NEMX.run_acdcopfcas_bf(socbf_data, _PM.SOCBFPowerModel, nlp_solver, setting=setting)
# _PM.update_data!(socbf_data, socbf_result["solution"])
# price_socbf = [region => socbf_data["bus"]["$(bus)"]["lam_kcl_r"] for (region, bus) in rrn]
# socbf_obj = socbf_result["objective"]
# plot([bus["lam_kcl_r"] for (i,bus) in socbf_result["solution"]["bus"] ])
##


[(gen["gen_bus"], gen["index"], gen["pmax"], gen["pg"], ac_data["bus"]["$(gen["gen_bus"])"]["lam_kcl_r"]) for (i, gen) in ac_data["gen"] if ac_data["bus"]["$(gen["gen_bus"])"]["area"] == 1]
[(load["load_bus"], load["index"], load["pd"], ac_data["bus"]["$(load["load_bus"])"]["lam_kcl_r"]) for (i, load) in ac_data["load"] if ac_data["bus"]["$(load["load_bus"])"]["area"] == 1 && haskey(load, "pmax")]

[gen["index"] for (i, gen) in socbf_data["gen"] if gen["gen_bus"] == 130]
[load["index"] for (i, load) in socbf_data["load"] if load["load_bus"] == 130]
socbf_data["load"]["63"]["pd"] += 1 
socbf_result = NEMX.run_acdcopfcas_bf(socbf_data, _PM.SOCBFPowerModel, gurobi_solver, setting=setting)
socbf_obj_new = socbf_result["objective"]
socbf_obj_new - socbf_obj
trace = bar(;x=[bus["index"] for (i, bus) in socbf_data["bus"]], y=[bus["lam_kcl_r"] for (i, bus) in socbf_data["bus"]], mode="lines", marker=attr(color="red"))
plot([trace])


# qc_data = deepcopy(data);
# qc_result = NEMX.run_acdcopfcas(qc_data, _PM.QCRMPowerModel, nlp_solver, setting=setting)
# _PM.update_data!(qc_data, qc_result["solution"])
# price_qc = [region => qc_data["bus"]["$(bus)"]["lam_kcl_r"] for (region, bus) in rrn]

# sdp_data = deepcopy(data)
# sdp_result = NEMX.run_acdcopfcas(sdp_data, _PM.SDPWRMPowerModel, nlp_solver, setting=setting)
# _PM.update_data!(sdp_data, sdp_result["solution"])
# price_socbf = [region => sdp_data["bus"]["$(bus)"]["lam_kcl_r"] for (region, bus) in rrn]


# qcd_data = deepcopy(data);
# qcd_result = NEMX.run_acdcopfcas(qcd_data, _PM.DCPLLPowerModel, nlp_solver, setting=setting)
# _PM.update_data!(qcd_data, qcd_result["solution"])
# price_qcd = [region => qcd_data["bus"]["$(bus)"]["lam_kcl_r"] for (region, bus) in rrn]



dcm_data = deepcopy(data);
dcm_result = NEMX.run_acdcopfcas(dcm_data, _PM.DCMPPowerModel, gurobi_solver, setting=setting)
_PM.update_data!(dcm_data, dcm_result["solution"])
price_dcm = [region => dcm_data["bus"]["$(bus)"]["lam_kcl_r"] for (region, bus) in rrn]
plot([bus["lam_kcl_r"] for (i,bus) in dcm_result["solution"]["bus"] ])





using PlotlyJS
trace = PlotlyJS.bar(;x=[bus["index"] for (i, bus) in ac_data["bus"]], y=[bus["lam_kcl_r"] for (i, bus) in ac_data["bus"]], mode="lines", marker=attr(color="red"))
trace = PlotlyJS.bar(;x=[bus["index"] for (i, bus) in dc_data["bus"]], y=[bus["lam_kcl_r"] for (i, bus) in dc_data["bus"]], mode="lines", marker=attr(color="red"))

PlotlyJS.plot([trace])
plot!([bus["lam_kcl_r"] for (i, bus) in dc_data["bus"]])

# state wise
s = 1
price_nsw = [ac_data["bus"]["$(gen["gen_bus"])"]["lam_kcl_r"] for (i, gen) in ac_data["gen"] if ac_data["bus"]["$(gen["gen_bus"])"]["area"] == s]
node_nsw = [gen["gen_bus"] for (i, gen) in ac_data["gen"] if ac_data["bus"]["$(gen["gen_bus"])"]["area"] == s]
trace_nsw = PlotlyJS.bar(;x=node_nsw, y=price_nsw, mode="lines", marker=attr(color="red"))
PlotlyJS.plot([trace_nsw])

price_nsw = [ac_data["bus"]["$(load["load_bus"])"]["lam_kcl_r"] for (i, load) in ac_data["load"] if ac_data["bus"]["$(load["load_bus"])"]["area"] == s]
node_nsw = [load["load_bus"] for (i, load) in ac_data["load"] if ac_data["bus"]["$(load["load_bus"])"]["area"] == s]
trace_nsw = PlotlyJS.bar(;x=node_nsw, y=price_nsw, mode="lines", marker=attr(color="red"))
PlotlyJS.plot([trace_nsw])

price_nsw = [ac_data["bus"]["$(load["load_bus"])"]["lam_kcl_r"] for (i, load) in ac_data["load"] if ac_data["bus"]["$(load["load_bus"])"]["area"] == s && load["load_bus"] in price_nodes]
node_nsw = [load["load_bus"] for (i, load) in ac_data["load"] if ac_data["bus"]["$(load["load_bus"])"]["area"] == s && load["load_bus"] in price_nodes]
trace_nsw = PlotlyJS.bar(;x=node_nsw, y=price_nsw, mode="lines", marker=attr(color="red"))
PlotlyJS.plot([trace_nsw])



for (i, branch) in data["branch"]
    if branch["f_bus"] == 243 || branch["t_bus"] == 243
        println("$(branch["index"]), ..., $(branch["f_bus"]), ..., $(branch["t_bus"])")
    end
end






data["gen"]["1"]["cost"]


##
gen_buses = [gen["gen_bus"] for (i, gen) in data["gen"]]
load_buses = [load["load_bus"] for (i, load) in data["load"]]
ploads = [load["load"] for load in data["load_limit"]]
pload_buses = [load["load_bus"] for (i, load) in data["load"] if load["index"] in ploads]

price_nodes = gen_buses ∪ load_buses ∪ pload_buses
trace2 = bar(;x=[bus["index"] for (i, bus) in ac_data["bus"] if bus["index"] in price_nodes], y=[bus["lam_kcl_r"] for (i, bus) in ac_data["bus"] if bus["index"] in price_nodes], mode="lines", marker=attr(color="red"))
plot([trace2])
trace3 = scatter(;x=gen_buses, y=0*gen_buses, mode="markers")
plot([trace2, trace3])

# sdp_data = deepcopy(data)
# sdp_result = NEMX.run_acdcopfcas(sdp_data, _PM.SDPWRMPowerModel, sdp_solver2, setting=setting)
# update_data!(sdp_data, sdp_result["solution"])

# sdp_sp_data = deepcopy(data)
# sdp_sp_result = NEMX.run_acdcopfcas(sdp_sp_data, _PM.SparseSDPWRMPowerModel, sdp_solver2, setting=setting)
# update_data!(sdp_sp_data, sdp_sp_result["solution"])

[gen["fuel"] for (i, gen) in data["gen"]]
[bus["index"] for (i, bus) in data["bus"] if bus["bus_type"] == 3]



### validation plots
gen_buses = [gen["gen_bus"] for (i, gen) in data["gen"]]
load_buses = [load["load_bus"] for (i, load) in data["load"]]
price_nodes = gen_buses ∪ load_buses

e_price_ac = abs.([bus["lam_kcl_r"] for (i, bus) in ac_data["bus"] if bus["index"] in price_nodes])
e_price_dc = abs.([bus["lam_kcl_r"] for (i, bus) in dc_data["bus"] if bus["index"] in price_nodes])
e_price_dc_mlf = abs.([bus["lam_kcl_r"] for (i, bus) in dc_data_mlf["bus"] if bus["index"] in price_nodes])

t_e_price_ac = bar(;x=price_nodes, y=e_price_ac, marker=attr(color="red", width = 2.5, opacity=1))

plot(t_e_price_ac)

e_trace_ac_dc = PlotlyJS.scatter(;x=e_price_ac, y=e_price_dc, mode="markers", xaxis_title = "acp", yaxis_title = "dcp")
PlotlyJS.plot([e_trace_ac_dc])

e_trace_ac_dc_mlf = PlotlyJS.scatter(;x=e_price_ac, y=e_price_dc_mlf, mode="markers", xaxis_title = "acp", yaxis_title = "dcp")
PlotlyJS.plot([e_trace_ac_dc_mlf])

e_trace_dc_dc_mlf = PlotlyJS.scatter(;x=e_price_dc, y=e_price_dc_mlf, mode="markers", xaxis_title = "acp", yaxis_title = "dcp")
PlotlyJS.plot([e_trace_dc_dc_mlf])

plot([m["mlf"] for m in data["mlf"] if m["bus"] in gen_buses])
plot([m["mlf"] for m in data["mlf"] if m["bus"] in load_buses])

rprice_dc_e = Dict(region => dc_data["bus"]["$(bus)"]["lam_kcl_r"] for (region, bus) in rrn)
rprice_dc_mlf_e = Dict(region => dc_data_mlf["bus"]["$(bus)"]["lam_kcl_r"] for (region, bus) in rrn)


for load in data["load_limit"]
    load["Pmax"] == load["Pmin"]
end

for (i,load) in data["load"]
    if haskey(load, "pmax")
        load["pmax"] == load["pmin"]
    end
end



data = ac_data
NEMX.plot_energy_fuel(data)


############################################################# plot fuel ####################################################################




using PlotlyJS

using PlotlyJS

# Node positions (x, y)
positions = Dict(
    "QLD" => (0, 2),
    "NSW" => (2, 2),
    "SA"  => (0, 0),
    "VIC" => (2, 0),
    "TAS" => (2, -2)
)

# Node data (price, demand, generation)
state_data = Dict(
    "QLD" => (223.73, 7552, 7820),
    "NSW" => (222.61, 8871, 8603),
    "SA"  => (73.44, 1312, 1456),
    "VIC" => (77.30, 5541, 5824),
    "TAS" => (100.20, 1212, 785)
)

# Edges: (from, to, flow)
edges = [
    ("QLD", "NSW", -9),
    ("NSW", "QLD", -259),
    ("NSW", "VIC", 0),
    ("SA", "VIC", -152),
    ("VIC", "SA", 9),
    ("VIC", "TAS", -427)
]

# Node trace
node_traces = []
for (state, (x, y)) in positions
    price, demand, gen = state_data[state]

    # Tooltip and label
    hover = "$state<br>Price: \$$(price)<br>Demand: $(demand)<br>Gen: $(gen)"
    label = "$state\n\$$(price)"

    push!(node_traces, scatter(
        x=[x], y=[y],
        mode="markers+text",
        text=[label],
        textposition="bottom center",
        marker=attr(size=50, color="lightgray", line=attr(color="black", width=2)),
        hoverinfo="text",
        hovertext=hover
    ))
end

# Bar plots for demand vs generation
bar_traces = []
for (state, (x, y)) in positions
    _, demand, gen = state_data[state]
    bar_y = y + 0.25

    # Demand bar (purple)
    push!(bar_traces, scatter(
        x=[x - 0.2, x + 0.2],
        y=[bar_y, bar_y],
        mode="lines",
        line=attr(width=10, color="purple"),
        showlegend=false
    ))

    # Generation bar (teal)
    push!(bar_traces, scatter(
        x=[x - 0.2, x + 0.2],
        y=[bar_y - 0.2, bar_y - 0.2],
        mode="lines",
        line=attr(width=10, color="turquoise"),
        showlegend=false
    ))
end

edge_traces = []
annotations = []

for (from, to, flow) in edges
    x0, y0 = positions[from]
    x1, y1 = positions[to]

    # Line trace
    push!(edge_traces, scatter(
        x=[x0, x1],
        y=[y0, y1],
        mode="lines",
        line=attr(width=2, color="gray"),
        hoverinfo="none",
        showlegend=false
    ))

    # Arrow annotation (midpoint with small offset)
    dx = x1 - x0
    dy = y1 - y0
    mx, my = x0 + 0.5dx, y0 + 0.5dy
    label_offset = 0.2

    push!(annotations, attr(
        x=x1, y=y1,
        ax=x0, ay=y0,
        xref="x", yref="y",
        axref="x", ayref="y",
        showarrow=true,
        arrowhead=3,
        arrowsize=1,
        arrowwidth=2,
        arrowcolor="black"
    ))

    # Add flow label above the arrow
    push!(annotations, attr(
        x=mx,
        y=my + label_offset,
        text=string(flow),
        showarrow=false,
        font=attr(size=14, color=flow < 0 ? "red" : "black")
    ))
end

layout = 

plot(vcat(node_traces..., bar_traces..., edge_traces...), 
Layout(
    width=800,
    height=600,
    title="State-based Electricity Flow Map",
    xaxis=attr(visible=false),
    yaxis=attr(visible=false),
    showlegend=false,
    annotations=annotations
))






d=DataFrame(bus=Float64[], kv=Float64[])
for (i,bus) in data["bus"]
    push!(d, Dict(:bus => bus["index"], :kv => bus["base_kv"]))
end
CSV.write("bus_kv.csv", d)