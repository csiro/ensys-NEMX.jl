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


# reading the newcastle site data
load_energy_centre = CSV.read("./test/data/ar-pst-topic-8-c/combined_oa_chiller_building_newcastle.csv", DataFrame)
chiller_power = load_energy_centre[!, 3]
site_total_load = load_energy_centre[!, 4]
number_of_steps = length(site_total_load)


# visuallize to select node for out load
using PowerPlots
using ColorSchemes

data_nsw = parse_file("./test/data/matpower/snemNSW.m")
PowerPlots.powerplot(data_nsw)

# reading synthetic coordinates to visuallize
xy_data = CSV.read("test/data/matpower/ac_lines.csv", DataFrame)

for (i,bus) in data_nsw["bus"]
    for j in eachindex(xy_data.f_bus)
        if xy_data.f_bus[j] == bus["index"]
            bus["xcoord_1"] = xy_data.f_bus_x[j]
            bus["ycoord_1"] = xy_data.f_bus_y[j]
        end
    end

    for k in eachindex(xy_data.t_bus)
        if xy_data.t_bus[k] == bus["index"]
            bus["xcoord_1"] = xy_data.t_bus_x[k]
            bus["ycoord_1"] = xy_data.t_bus_y[k]
        end
    end
end

for (i,bus) in data_nsw["bus"]
    if haskey(bus, "x") && haskey(bus, "y")
         bus["xcoord_1"] = bus["x"]
         bus["ycoord_1"] = bus["y"]
    end
end


for (i,branch) in data_nsw["branch"]
    branch["base_kv"] = data_nsw["bus"]["$(branch["f_bus"])"]["base_kv"]
end

for (i, gen) in data_nsw["gen"]
    gen["xcoord_1"] = data_nsw["bus"]["$(gen["gen_bus"])"]["xcoord_1"]
    gen["ycoord_1"] = data_nsw["bus"]["$(gen["gen_bus"])"]["ycoord_1"]
end

for (i, load) in data_nsw["load"]
    load["xcoord_1"] = data_nsw["bus"]["$(load["load_bus"])"]["xcoord_1"]
    load["ycoord_1"] = data_nsw["bus"]["$(load["load_bus"])"]["ycoord_1"]
end

for (i,gen_nsw) in data_nsw["gen"]
    for (j,gen) in data["gen"]
        if gen_nsw["name"] == gen["name"]
            gen_nsw["fuel"] = gen["fuel"]
        end
    end
end

p1 = powerplot(data_nsw; width=1000, height=1000, bus=(:size=>20), connected_components=[], gen=(:size=>0),load=(:size=>0), branch=(:size=>2), connector=(:size=>0, :color=>:white), shunt=(:size=>0), :branch=>(:data=>:base_kv, :color=>[:white, :blue], :data_type=>:quantitative), :storage=>(:color=>:yellow,:size=>0), fixed=true) 
p2 = powerplot(data_nsw; width=1000, height=1000, bus=(:size=>30), connected_components=[:gen, :storage, :load], gen=(:size=>50),load=(:size=>20, :color=>:red), branch=(:size=>2), connector=(:size=>1), shunt=(:size=>0, :color=>:white), :storage=>(:color=>:yellow,:size=>400), :branch=>(:data=>:base_kv, :color=>[:white, :blue], :data_type=>:quantitative, :transformer_color=> :red), :gen=>(:data=>:fuel, :color=>colorscheme2array(ColorSchemes.colorschemes[:seaborn_deep])), fixed=true) 
 
# node selected load at 11kv/ pd = 0.3 pu/ qd = 0.0437/ bus_1649
bus_id = [bus["index"] for (i,bus) in data["bus"] if bus["name"] == "bus_1649"][1]
load_id = [load["index"] for (i,load) in data["load"] if load["load_bus"] == bus_id][1]

# load 605 is already modelled as flex load, which we simplify
delete!(data["load"]["$load_id"], "fcas")
delete!(data["load"]["$load_id"], "fcas_cost")

price_NSW = []
load_605 = []
for i=1:1:number_of_steps
    data["load"]["605"]["cost"][1:2:9] .= (site_total_load[i] - chiller_power[i])/1E5
    data["load"]["605"]["cost"][2:2:10] .= 10
    data["load"]["605"]["cost"][11:2:19] .= site_total_load[i]/1E5
    data["load"]["605"]["cost"][12:2:20] .= 1000
    data["load"]["605"]["pmax"] = site_total_load[i]/1E5
    data["load"]["605"]["pmin"] = (site_total_load[i] - chiller_power[i])/1E5

    pm = _PM.instantiate_model(data, _PM.DCPPowerModel, NEMX.build_acdcopfcas, ref_extensions=[_PMACDC.add_ref_dcgrid!, _PMACDC.ref_add_gendc!], setting=setting);
    dc_result = optimize_model!(pm, optimizer=gurobi_solver)
    JuMP.has_duals(pm.model)
    for (i,b) in data["bus"]
        b["lam_kcl_r"] = JuMP.shadow_price(pm.sol[:it][:pm][:nw][0][:bus][b["index"]][:lam_kcl_r])
    end
    push!(price_NSW, data["bus"]["130"]["lam_kcl_r"])
    push!(load_605, dc_result["solution"]["load"]["605"]["pd"])
end

plot([p for p in price_NSW])

trace1 = scatter(y = site_total_load / 1e5, mode = "lines", name = "total_site_load")
trace2 = scatter(y = [p for p in load_605], mode = "lines", name = "scheduled_site_load")
plot([trace1, trace2])