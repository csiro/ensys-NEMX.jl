
function create_price_table_rows(data, name)
    rows = Dict()
    rrn = data["rrn"]
    rprice_e = Dict(region => data["bus"]["$(bus)"]["lam_kcl_r"] for (region, bus) in rrn)
    rprice_f_Lreg = Dict(region => data["bus_rr"]["$(bus)"]["lam_LReg"] for (region, bus) in rrn)
    rprice_f_Rreg = Dict(region => data["bus_rr"]["$(bus)"]["lam_RReg"] for (region, bus) in rrn)
    rprice_f_L1s = Dict(region => data["bus_rr"]["$(bus)"]["lam_L1S"] for (region, bus) in rrn)
    rprice_f_R1s = Dict(region => data["bus_rr"]["$(bus)"]["lam_R1S"] for (region, bus) in rrn)
    rprice_f_L6s = Dict(region => data["bus_rr"]["$(bus)"]["lam_L6S"] for (region, bus) in rrn)
    rprice_f_R6s = Dict(region => data["bus_rr"]["$(bus)"]["lam_R6S"] for (region, bus) in rrn)
    rprice_f_L60s = Dict(region => data["bus_rr"]["$(bus)"]["lam_L60S"] for (region, bus) in rrn)
    rprice_f_R60s = Dict(region => data["bus_rr"]["$(bus)"]["lam_R60S"] for (region, bus) in rrn)
    rprice_f_L5M = Dict(region => data["bus_rr"]["$(bus)"]["lam_L5M"] for (region, bus) in rrn)
    rprice_f_R5M = Dict(region => data["bus_rr"]["$(bus)"]["lam_R5M"] for (region, bus) in rrn)

    for (region, bus) in rrn 
        rows["row_$(name)_$region"] = (region, rprice_e["$region"], rprice_f_Lreg["$region"], 
        rprice_f_Rreg["$region"], rprice_f_L1s["$region"], rprice_f_R1s["$region"], rprice_f_L6s["$region"], 
        rprice_f_R6s["$region"], rprice_f_L60s["$region"], rprice_f_R60s["$region"], rprice_f_L5M["$region"], 
        rprice_f_R5M["$region"], name)
    end
    return rows
end


function create_price_table(rows_AC, rows_DC, rows_DC_MLF)
    T1 = DataFrame(State=String[], Energy=Float64[], Lreg=Float64[], Rreg=Float64[], L1s=Float64[], R1s=Float64[], L6s=Float64[], R6s=Float64[], L60s=Float64[], R60s=Float64[], L5m=Float64[], R5m=Float64[], Formulation=String[])
    push!(T1, rows_AC["row_AC_QLD"])
    push!(T1, rows_DC["row_DC_QLD"])
    push!(T1, rows_DC_MLF["row_DC_MLF_QLD"])

    push!(T1, rows_AC["row_AC_NSW"])
    push!(T1, rows_DC["row_DC_NSW"])
    push!(T1, rows_DC_MLF["row_DC_MLF_NSW"])

    push!(T1, rows_AC["row_AC_VIC"])
    push!(T1, rows_DC["row_DC_VIC"])
    push!(T1, rows_DC_MLF["row_DC_MLF_VIC"])

    push!(T1, rows_AC["row_AC_SA"])
    push!(T1, rows_DC["row_DC_SA"])
    push!(T1, rows_DC_MLF["row_DC_MLF_SA"])

    push!(T1, rows_AC["row_AC_TAS"])
    push!(T1, rows_DC["row_DC_TAS"])
    push!(T1, rows_DC_MLF["row_DC_MLF_TAS"])

    return T1
end

function create_region_wise_nodal_prices(data)
    price = Dict()
    gen_buses = [gen["gen_bus"] for (i, gen) in data["gen"]]
    load_buses = [load["load_bus"] for (i, load) in data["load"]]
    price_buses = gen_buses ∪ load_buses
    for (region, bus) in data["rrn"]
        r_area = data["bus"][bus]["area"] 
        price["$region"] = Dict(bus["index"] => bus["lam_kcl_r"] for (i, bus) in data["bus"] if bus["index"] in price_buses && bus["area"] == r_area)
    end
    return price
end

function plot_state_wide_prices(price_AC, price_DC, price_DC_MLF)
    fig = make_subplots(rows=5, cols=1)
    t_qld_ac = bar(name="AC", x=keys(price_AC["QLD"]), y=collect(values(price_AC["QLD"])), marker=attr(color="blue", width=2), line=attr(color="blue"))
    t_qld_dc = bar(name="DC", x=keys(price_DC["QLD"]), y=collect(values(price_DC["QLD"])), marker=attr(color="red", width=2), line=attr(color="red"))
    t_qld_dc_mlf = bar(name="DC+MLF", x=keys(price_DC_MLF["QLD"]), y=collect(values(price_DC_MLF["QLD"])), marker=attr(color="yellow", width=2), line=attr(color="yellow"))

    t_nsw_ac = bar(name="AC", x=keys(price_AC["NSW"]), y=collect(values(price_AC["NSW"])), marker=attr(color="blue", width=2), line=attr(color="blue"), showlegend = false)
    t_nsw_dc = bar(name="DC", x=keys(price_DC["NSW"]), y=collect(values(price_DC["NSW"])), marker=attr(color="red", width=2), line=attr(color="red"), showlegend = false)
    t_nsw_dc_mlf = bar(name="DC_MLF", x=keys(price_DC_MLF["NSW"]), y=collect(values(price_DC_MLF["NSW"])), marker=attr(color="yellow", width=2), line=attr(color="yellow"), showlegend = false)

    t_vic_ac = bar(name="AC", x=keys(price_AC["VIC"]), y=collect(values(price_AC["VIC"])), marker=attr(color="blue", width=2), line=attr(color="blue"), showlegend = false)
    t_vic_dc = bar(name="DC", x=keys(price_DC["VIC"]), y=collect(values(price_DC["VIC"])), marker=attr(color="red", width=2), line=attr(color="red"), showlegend = false)
    t_vic_dc_mlf = bar(name="DC_MLF", x=keys(price_DC_MLF["VIC"]), y=collect(values(price_DC_MLF["VIC"])), marker=attr(color="yellow", width=2), line=attr(color="yellow"), showlegend = false)

    t_sa_ac = bar(name="AC", x=keys(price_AC["SA"]), y=collect(values(price_AC["SA"])), marker=attr(color="blue", width=2), line=attr(color="blue"), showlegend = false)
    t_sa_dc = bar(name="DC", x=keys(price_DC["SA"]), y=collect(values(price_DC["SA"])), marker=attr(color="red", width=2), line=attr(color="red"), showlegend = false)
    t_sa_dc_mlf = bar(name="DC_MLF", x=keys(price_DC_MLF["SA"]), y=collect(values(price_DC_MLF["SA"])), marker=attr(color="yellow", width=2), line=attr(color="yellow"), showlegend = false)

    t_tas_ac = bar(name="AC", x=keys(price_AC["TAS"]), y=collect(values(price_AC["TAS"])), marker=attr(color="blue", width=2), line=attr(color="blue"), showlegend = false)
    t_tas_dc = bar(name="DC", x=keys(price_DC["TAS"]), y=collect(values(price_DC["TAS"])), marker=attr(color="red", width=2), line=attr(color="red"), showlegend = false)
    t_tas_dc_mlf = bar(name="DC_MLF", x=keys(price_DC_MLF["TAS"]), y=collect(values(price_DC_MLF["TAS"])), marker=attr(color="yellow", width=2), line=attr(color="yellow"), showlegend = false)

    add_trace!(fig, t_qld_ac, row=1, col=1)
    add_trace!(fig, t_qld_dc, row=1, col=1)
    add_trace!(fig, t_qld_dc_mlf, row=1, col=1)

    add_trace!(fig, t_nsw_ac, row=2, col=1)
    add_trace!(fig, t_nsw_dc, row=2, col=1)
    add_trace!(fig, t_nsw_dc_mlf, row=2, col=1)

    add_trace!(fig, t_vic_ac, row=3, col=1)
    add_trace!(fig, t_vic_dc, row=3, col=1)
    add_trace!(fig, t_vic_dc_mlf, row=3, col=1)

    add_trace!(fig, t_sa_ac, row=4, col=1)
    add_trace!(fig, t_sa_dc, row=4, col=1)
    add_trace!(fig, t_sa_dc_mlf, row=4, col=1)

    add_trace!(fig, t_tas_ac, row=5, col=1)
    add_trace!(fig, t_tas_dc, row=5, col=1)
    add_trace!(fig, t_tas_dc_mlf, row=5, col=1)

    relayout!(fig, barmode="group", title_text="Regional Prices", template=:plotly_white, 
            xaxis=attr(showline=true, zeroline=true, linewidth=1, linecolor="black", mirror=false),
            xaxis2=attr(showline=true, zeroline=true, linewidth=1, linecolor="black", mirror=false),
            xaxis3=attr(showline=true, zeroline=true, linewidth=1, linecolor="black", mirror=false),
            xaxis4=attr(showline=true, zeroline=true, linewidth=1, linecolor="black", mirror=false),
            xaxis5=attr(showline=true, zeroline=true, linewidth=1, linecolor="black", mirror=false),
            xaxis5_title="bus (#)",
            yaxis=attr(showline=true, zeroline=true, linewidth=1, linecolor="black", mirror=false),
            yaxis2=attr(showline=true, zeroline=true, linewidth=1, linecolor="black", mirror=false),
            yaxis3=attr(showline=true, zeroline=true, linewidth=1, linecolor="black", mirror=false),
            yaxis4=attr(showline=true, zeroline=true, linewidth=1, linecolor="black", mirror=false),
            yaxis5=attr(showline=true, zeroline=true, linewidth=1, linecolor="black", mirror=false),
            yaxis_title="price (\$)",
            yaxis2_title="price (\$)",
            yaxis3_title="price (\$)",
            yaxis4_title="price (\$)",
            yaxis5_title="price (\$)",
        )
    display(fig)

end


# function area_wise_generation_aggregate_of_each_fuel(data, gens)
#     gen_area = Dict{String,Any}()
#     for id in gens
#         gen = data["gen"]["$id"]
#         if gen["fuel"] == "Coal"
#             gen_area["coal"] += gen["pg"]
#         end
#         if gen["fuel"] == "Wind"
#             gen_area["wind"] += gen["pg"]
#         end
#         if gen["fuel"] == "Solar"
#             gen_area["solar"] += gen["pg"]
#         end
#         if gen["fuel"] == "Water"
#             gen_area["water"] += gen["pg"]
#         end
#         if gen["fuel"] == "Biomass"
#             gen_area["biomass"] += gen["pg"]
#         end
#         if gen["fuel"] == "Gas"
#             gen_area["gas"] += gen["pg"]
#         end
#         if gen["fuel"] == "Battery"
#             gen_area["battery"] += gen["pg"]
#         end
#         if gen["fuel"] == "Distillate"
#             gen_area["distillate"] += gen["pg"]
#         end
#     end
#     return gen_area
# end

function area_wise_generation_aggregate_of_each_fuel(data, gens)
    fuel_types = ["coal", "wind", "solar", "water", "biomass", "gas", "battery", "distillate"]
    gen_area = Dict(fuel => 0.0 for fuel in fuel_types)

    for id in gens
        gen = data["gen"]["$id"]
        fuel = lowercase(gen["fuel"])
        if haskey(gen_area, fuel)
            gen_area[fuel] += gen["pg"]
        end
    end
    return gen_area
end

function plot_energy_fuel(data)

    gens_nsw = [gen["index"] for (i,gen) in data["gen"] if data["bus"]["$(gen["gen_bus"])"]["area"] == 1]
    gens_vic = [gen["index"] for (i,gen) in data["gen"] if data["bus"]["$(gen["gen_bus"])"]["area"] == 2]
    gens_qld = [gen["index"] for (i,gen) in data["gen"] if data["bus"]["$(gen["gen_bus"])"]["area"] == 3]
    gens_sa = [gen["index"] for (i,gen) in data["gen"] if data["bus"]["$(gen["gen_bus"])"]["area"] == 4]
    gens_tas = [gen["index"] for (i,gen) in data["gen"] if data["bus"]["$(gen["gen_bus"])"]["area"] == 5]

    int_nsw_qld = [branch["index"] for (i,branch) in data["branch"] if data["bus"]["$(branch["f_bus"])"]["area"] == 1 && data["bus"]["$(branch["t_bus"])"]["area"] == 3]
    # 54, 55 leave 240, 241, connecting Directlink branchdc 2,3,4
    filter!(x -> x != 240, int_nsw_qld) 
    filter!(x -> x != 241, int_nsw_qld) 
    intdc_qld_nsw = [2,3,4]
    int_nsw_vic = [branch["index"] for (i,branch) in data["branch"] if data["bus"]["$(branch["f_bus"])"]["area"] == 1 && data["bus"]["$(branch["t_bus"])"]["area"] == 2]
    int_vic_sa = [branch["index"] for (i,branch) in data["branch"] if data["bus"]["$(branch["f_bus"])"]["area"] == 2 && data["bus"]["$(branch["t_bus"])"]["area"] == 4]
    # 527, 528, leave 1948, connecting Murraylink brnachdc 5
    filter!(x -> x != 1948, int_vic_sa)
    intdc_vic_sa = [5]
    intdc_vic_tas = [1]

    # area-wise aggregate of pg for each fuel type
    pg_fuel_qld = NEMX.area_wise_generation_aggregate_of_each_fuel(data, gens_qld)
    pg_fuel_nsw = NEMX.area_wise_generation_aggregate_of_each_fuel(data, gens_nsw)
    pg_fuel_vic = NEMX.area_wise_generation_aggregate_of_each_fuel(data, gens_vic)
    pg_fuel_sa = NEMX.area_wise_generation_aggregate_of_each_fuel(data, gens_sa)
    pg_fuel_tas = NEMX.area_wise_generation_aggregate_of_each_fuel(data, gens_tas)
    # area-wise aggregate of pg import
    pf_import_qld = 0.0
    pf_import_nsw = 0.0
    pf_import_vic = 0.0
    pf_import_sa = 0.0
    pf_import_tas = 0.0

    pf_nsw_qld = data["branch"]["54"]["pf"] + data["branch"]["55"]["pf"] + data["branchdc"]["2"]["pt"] + data["branchdc"]["3"]["pt"] + data["branchdc"]["4"]["pt"]
    if pf_nsw_qld >= 0
        pf_import_qld += pf_nsw_qld
    else
        pf_import_nsw += pf_nsw_qld
    end

    pf_nsw_vic = sum([branch["pf"] for (i,branch) in data["branch"] if branch["index"] in int_nsw_vic])
    if pf_nsw_vic >= 0
        pf_import_vic += pf_nsw_vic
    else
        pf_import_nsw += pf_nsw_vic
    end

    pf_vic_sa = data["branch"]["527"]["pf"] + data["branch"]["528"]["pf"] + data["branchdc"]["5"]["pf"]
    if pf_vic_sa >= 0
        pf_import_sa += pf_vic_sa
    else
        pf_import_vic += pf_vic_sa
    end
    
    pf_vic_tas = data["branchdc"]["1"]["pf"]
    if pf_vic_tas >= 0
        pf_import_tas += pf_vic_tas
    else
        pf_import_vic += pf_vic_tas
    end


    x_labels = ["QLD", "NSW", "VIC", "SA", "TAS"]

    t_coal = bar(;x=x_labels, y=[pg_fuel_qld["coal"], pg_fuel_nsw["coal"], pg_fuel_vic["coal"], pg_fuel_sa["coal"], pg_fuel_tas["coal"]], marker=attr(color= "chocolate"), name = "Coal", width = 0.6)
    t_water = bar(;x=x_labels, y=[pg_fuel_qld["water"], pg_fuel_nsw["water"], pg_fuel_vic["water"], pg_fuel_sa["water"], pg_fuel_tas["water"]], marker=attr(color= "skyblue"), name = "Water", width = 0.6)
    t_gas = bar(;x=x_labels, y=[pg_fuel_qld["gas"], pg_fuel_nsw["gas"], pg_fuel_vic["gas"], pg_fuel_sa["gas"], pg_fuel_tas["gas"]], marker=attr(color= "teal"), name = "Gas", width = 0.6)
    t_distillate = bar(;x=x_labels, y=[pg_fuel_qld["distillate"], pg_fuel_nsw["distillate"], pg_fuel_vic["distillate"], pg_fuel_sa["distillate"], pg_fuel_tas["distillate"]], marker=attr(color= "red3"), name = "Distillate", width = 0.6)
    t_wind = bar(;x=x_labels, y=[pg_fuel_qld["wind"], pg_fuel_nsw["wind"], pg_fuel_vic["wind"], pg_fuel_sa["wind"], pg_fuel_tas["wind"]], marker=attr(color= "lime"), name = "Wind", width = 0.6)
    t_solar = bar(;x=x_labels, y=[pg_fuel_qld["solar"], pg_fuel_nsw["solar"], pg_fuel_vic["solar"], pg_fuel_sa["solar"], pg_fuel_tas["solar"]], marker=attr(color= "gold"), name = "Solar", width = 0.6)
    t_biomass = bar(;x=x_labels, y=[pg_fuel_qld["biomass"], pg_fuel_nsw["biomass"], pg_fuel_vic["biomass"], pg_fuel_sa["biomass"], pg_fuel_tas["biomass"]], marker=attr(color= "orangered"), name = "Biomass", width = 0.6)
    t_battery = bar(;x=x_labels, y=[pg_fuel_qld["battery"], pg_fuel_nsw["battery"], pg_fuel_vic["battery"], pg_fuel_sa["battery"], pg_fuel_tas["battery"]], marker=attr(color= "navy"), name = "Battery", width = 0.6)
    t_import = bar(;x=x_labels, y=abs.([pf_import_qld, pf_import_nsw, pf_import_vic, pf_import_sa, pf_import_tas]), marker=attr(color= "purple"), name = "Imports", width = 0.6)

    plot([t_coal, t_water, t_gas, t_distillate, t_wind, t_solar, t_biomass, t_battery, t_import], 
        Layout(;barmode="stack", bargap = 0.05, opacity=0.7, template="simple_white", 
        xaxis_showline=true, xaxis_zeroline=true, xaxis_linewidth=1, xaxis_linecolor="black", xaxis_mirror=false,
        yaxis_showline=true, yaxis_zeroline=true, yaxis_linewidth=1, yaxis_linecolor="black", yaxis_mirror=false,
        xaxis_showgrid=true, yaxis_showgrid=true, xaxis_title="Region", yaxis_title="Energy (MW)", 
        margin = attr(l = 60), 
        legend = attr(x = 1, y = 1, xanchor = "right", yanchor = "top", bgcolor = "rgba(255,255,255,0.8)", bordercolor = "black", borderwidth = 1))       )
end

function plot_fuel(data)
    # region_map = 1 => "NSW1", 2 => "VIC1", 3 => "QLD1", 4 => "SA1", 5 => "TAS1"
    # fuel_types = "Wind" "Water" "Gas" "Biomass" "Distillate" "Coal" "Solar" "Battery"
    # interconnectors

    gens_nsw = [gen["index"] for (i,gen) in data["gen"] if data["bus"]["$(gen["gen_bus"])"]["area"] == 1]
    gens_vic = [gen["index"] for (i,gen) in data["gen"] if data["bus"]["$(gen["gen_bus"])"]["area"] == 2]
    gens_qld = [gen["index"] for (i,gen) in data["gen"] if data["bus"]["$(gen["gen_bus"])"]["area"] == 3]
    gens_sa = [gen["index"] for (i,gen) in data["gen"] if data["bus"]["$(gen["gen_bus"])"]["area"] == 4]
    gens_tas = [gen["index"] for (i,gen) in data["gen"] if data["bus"]["$(gen["gen_bus"])"]["area"] == 5]

    int_nsw_qld = [branch["index"] for (i,branch) in data["branch"] if data["bus"]["$(branch["f_bus"])"]["area"] == 1 && data["bus"]["$(branch["t_bus"])"]["area"] == 3]
    # 54, 55 leave 240, 241, connecting Directlink branchdc 2,3,4
    filter!(x -> x != 240, int_nsw_qld) 
    filter!(x -> x != 241, int_nsw_qld) 
    intdc_qld_nsw = [2,3,4]
    int_nsw_vic = [branch["index"] for (i,branch) in data["branch"] if data["bus"]["$(branch["f_bus"])"]["area"] == 1 && data["bus"]["$(branch["t_bus"])"]["area"] == 2]
    int_vic_sa = [branch["index"] for (i,branch) in data["branch"] if data["bus"]["$(branch["f_bus"])"]["area"] == 2 && data["bus"]["$(branch["t_bus"])"]["area"] == 4]
    # 527, 528, leave 1948, connecting Murraylink brnachdc 5
    filter!(x -> x != 1948, int_vic_sa)
    intdc_vic_sa = [5]
    intdc_vic_tas = branchdc[1]

    # area-wise aggregate of pg for each fuel type
    pg_fuel_qld = area_wise_generation_aggregate_of_each_fuel(data, gens_qld)
    pg_fuel_nsw = area_wise_generation_aggregate_of_each_fuel(data, gens_nsw)
    pg_fuel_vic = area_wise_generation_aggregate_of_each_fuel(data, gens_vic)
    pg_fuel_sa = area_wise_generation_aggregate_of_each_fuel(data, gens_sa)
    pg_fuel_tas = area_wise_generation_aggregate_of_each_fuel(data, gens_tas)
    # area-wise aggregate of pg import
    
    pf_nsw_qld = data["branch"]["54"]["pf"] + data["branch"]["55"]["pf"] + data["branchdc"]["2"]["pt"] + data["branchdc"]["3"]["pt"] + data["branchdc"]["4"]["pt"]
    if pf_nsw_qld >= 0
        pf_import_qld += pf_nsw_qld
    else
        pf_import_nsw += pf_nsw_qld
    end

    pf_nsw_vic = sum([branch["pf"] for (i,branch) in data["branch"] if branch["index"] in int_nsw_vic])
    if pf_nsw_vic >= 0
        pf_import_vic += pf_nsw_vic
    else
        pf_import_nsw += pf_nsw_vic
    end

    pf_vic_sa = data["branch"]["527"]["pf"] + data["branch"]["528"]["pf"] + data["branchdc"]["5"]["pf"]
    if pf_vic_sa >= 0
        pf_import_sa += pf_vic_sa
    else
        pf_import_vic += pf_vic_sa
    end
       
    pf_vic_tas = data["branchdc"]["1"]["pf"]
    if pf_vic_tas >= 0
        pf_import_tas += pf_vic_tas
    else
        pf_import_vic += pf_vic_tas
    end

    fig = make_subplots(rows=5, cols=1)

    t_qld_coal = scatter(;x=1, y=pg_fuel_qld["coal"], fill="tozeroy", name = "Coal")
    t_qld_water = scatter(;x=1, y=pg_fuel_qld["water"], fill="tonexty", name = "Hydro")
    t_qld_gas= scatter(;x=1, y=pg_fuel_qld["gas"], fill="tonexty", name = "Gas")
    t_qld_wind = scatter(;x=1, y=pg_fuel_qld["wind"], fill="tonexty", name = "Wind")
    t_qld_solar = scatter(;x=1, y=pg_fuel_qld["solar"], fill="tonexty", name = "Solar")
    t_qld_battery = scatter(;x=1, y=pg_fuel_qld["battery"], fill="tonexty", name = "Battery")
    t_qld_biomass = scatter(;x=1, y=pg_fuel_qld["biomass"], fill="tonexty", name = "Biomass")
    t_qld_distillate = scatter(;x=1, y=pg_fuel_qld["distillate"], fill="tonexty", name = "Distillate")
    t_qld_pf_import = scatter(;x=1, y=pf_import_qld, fill="tonexty", name = "Import")

    t_nsw_coal = scatter(;x=1, y=pg_fuel_nsw["coal"], fill="tozeroy", name = "Coal", showlegend = false)
    t_nsw_water = scatter(;x=1, y=pg_fuel_nsw["water"], fill="tonexty", name = "Hydro", showlegend = false)
    t_nsw_gas= scatter(;x=1, y=pg_fuel_nsw["gas"], fill="tonexty", name = "Gas", showlegend = false)
    t_nsw_wind = scatter(;x=1, y=pg_fuel_nsw["wind"], fill="tonexty", name = "Wind", showlegend = false)
    t_nsw_solar = scatter(;x=1, y=pg_fuel_nsw["solar"], fill="tonexty", name = "Solar", showlegend = false)
    t_nsw_battery = scatter(;x=1, y=pg_fuel_nsw["battery"], fill="tonexty", name = "Battery", showlegend = false)
    t_nsw_biomass = scatter(;x=1, y=pg_fuel_nsw["biomass"], fill="tonexty", name = "Biomass", showlegend = false)
    t_nsw_distillate = scatter(;x=1, y=pg_fuel_nsw["distillate"], fill="tonexty", name = "Distillate", showlegend = false)
    t_nsw_pf_import = scatter(;x=1, y=pf_import_nsw, fill="tonexty", name = "Import", showlegend = false)

    t_vic_coal = scatter(;x=1, y=pg_fuel_vic["coal"], fill="tozeroy", name = "Coal", showlegend = false)
    t_vic_water = scatter(;x=1, y=pg_fuel_vic["water"], fill="tonexty", name = "Hydro", showlegend = false)
    t_vic_gas= scatter(;x=1, y=pg_fuel_vic["gas"], fill="tonexty", name = "Gas", showlegend = false)
    t_vic_wind = scatter(;x=1, y=pg_fuel_vic["wind"], fill="tonexty", name = "Wind", showlegend = false)
    t_vic_solar = scatter(;x=1, y=pg_fuel_vic["solar"], fill="tonexty", name = "Solar", showlegend = false)
    t_vic_battery = scatter(;x=1, y=pg_fuel_vic["battery"], fill="tonexty", name = "Battery", showlegend = false)
    t_vic_biomass = scatter(;x=1, y=pg_fuel_vic["biomass"], fill="tonexty", name = "Biomass", showlegend = false)
    t_vic_distillate = scatter(;x=1, y=pg_fuel_vic["distillate"], fill="tonexty", name = "Distillate", showlegend = false)
    t_vic_pf_import = scatter(;x=1, y=pf_import_vic, fill="tonexty", name = "Import", showlegend = false)

    t_sa_coal = scatter(;x=1, y=pg_fuel_sa["coal"], fill="tozeroy", name = "Coal", showlegend = false)
    t_sa_water = scatter(;x=1, y=pg_fuel_sa["water"], fill="tonexty", name = "Hydro", showlegend = false)
    t_sa_gas= scatter(;x=1, y=pg_fuel_sa["gas"], fill="tonexty", name = "Gas", showlegend = false)
    t_sa_wind = scatter(;x=1, y=pg_fuel_sa["wind"], fill="tonexty", name = "Wind", showlegend = false)
    t_sa_solar = scatter(;x=1, y=pg_fuel_sa["solar"], fill="tonexty", name = "Solar", showlegend = false)
    t_sa_battery = scatter(;x=1, y=pg_fuel_sa["battery"], fill="tonexty", name = "Battery", showlegend = false)
    t_sa_biomass = scatter(;x=1, y=pg_fuel_sa["biomass"], fill="tonexty", name = "Biomass", showlegend = false)
    t_sa_distillate = scatter(;x=1, y=pg_fuel_sa["distillate"], fill="tonexty", name = "Distillate", showlegend = false)
    t_sa_pf_import = scatter(;x=1, y=pf_import_sa, fill="tonexty", name = "Import", showlegend = false)

    t_tas_coal = scatter(;x=1, y=pg_fuel_tas["coal"], fill="tozeroy", name = "Coal", showlegend = false)
    t_tas_water = scatter(;x=1, y=pg_fuel_tas["water"], fill="tonexty", name = "Hydro", showlegend = false)
    t_tas_gas = scatter(;x=1, y=pg_fuel_tas["gas"], fill="tonexty", name = "Gas", showlegend = false)
    t_tas_wind = scatter(;x=1, y=pg_fuel_tas["wind"], fill="tonexty", name = "Wind", showlegend = false)
    t_tas_solar = scatter(;x=1, y=pg_fuel_tas["solar"], fill="tonexty", name = "Solar", showlegend = false)
    t_tas_battery = scatter(;x=1, y=pg_fuel_tas["battery"], fill="tonexty", name = "Battery", showlegend = false)
    t_tas_biomass = scatter(;x=1, y=pg_fuel_tas["biomass"], fill="tonexty", name = "Biomass", showlegend = false)
    t_tas_distillate = scatter(;x=1, y=pg_fuel_tas["distillate"], fill="tonexty", name = "Distillate", showlegend = false)
    t_tas_pf_import = scatter(;x=1, y=pf_import_tas, fill="tonexty", name = "Import", showlegend = false)

    add_trace!(fig, t_qld_coal, row=1, col=1)
    add_trace!(fig, t_qld_water, row=1, col=1)
    add_trace!(fig, t_qld_gas, row=1, col=1)
    add_trace!(fig, t_qld_wind, row=1, col=1)
    add_trace!(fig, t_qld_solar, row=1, col=1)
    add_trace!(fig, t_qld_battery, row=1, col=1)
    add_trace!(fig, t_qld_biomass, row=1, col=1)
    add_trace!(fig, t_qld_distillate, row=1, col=1)
    add_trace!(fig, t_qld_pf_import, row=1, col=1)

    add_trace!(fig, t_nsw_coal, row=1, col=1)
    add_trace!(fig, t_nsw_water, row=1, col=1)
    add_trace!(fig, t_nsw_gas, row=1, col=1)
    add_trace!(fig, t_nsw_wind, row=1, col=1)
    add_trace!(fig, t_nsw_solar, row=1, col=1)
    add_trace!(fig, t_nsw_battery, row=1, col=1)
    add_trace!(fig, t_nsw_biomass, row=1, col=1)
    add_trace!(fig, t_nsw_distillate, row=1, col=1)
    add_trace!(fig, t_nsw_pf_import, row=1, col=1)

    add_trace!(fig, t_vic_coal, row=1, col=1)
    add_trace!(fig, t_vic_water, row=1, col=1)
    add_trace!(fig, t_vic_gas, row=1, col=1)
    add_trace!(fig, t_vic_wind, row=1, col=1)
    add_trace!(fig, t_vic_solar, row=1, col=1)
    add_trace!(fig, t_vic_battery, row=1, col=1)
    add_trace!(fig, t_vic_biomass, row=1, col=1)
    add_trace!(fig, t_vic_distillate, row=1, col=1)
    add_trace!(fig, t_vic_pf_import, row=1, col=1)

    add_trace!(fig, t_sa_coal, row=1, col=1)
    add_trace!(fig, t_sa_water, row=1, col=1)
    add_trace!(fig, t_sa_gas, row=1, col=1)
    add_trace!(fig, t_sa_wind, row=1, col=1)
    add_trace!(fig, t_sa_solar, row=1, col=1)
    add_trace!(fig, t_sa_battery, row=1, col=1)
    add_trace!(fig, t_sa_biomass, row=1, col=1)
    add_trace!(fig, t_sa_distillate, row=1, col=1)
    add_trace!(fig, t_sa_pf_import, row=1, col=1)

    add_trace!(fig, t_tas_coal, row=1, col=1)
    add_trace!(fig, t_tas_water, row=1, col=1)
    add_trace!(fig, t_tas_gas, row=1, col=1)
    add_trace!(fig, t_tas_wind, row=1, col=1)
    add_trace!(fig, t_tas_solar, row=1, col=1)
    add_trace!(fig, t_tas_battery, row=1, col=1)
    add_trace!(fig, t_tas_biomass, row=1, col=1)
    add_trace!(fig, t_tas_distillate, row=1, col=1)
    add_trace!(fig, t_tas_pf_import, row=1, col=1)

    relayout!(fig, title_text="Energy Fuel", template=:plotly_white, 
    xaxis=attr(showline=true, zeroline=true, linewidth=1, linecolor="black", mirror=false),
    xaxis2=attr(showline=true, zeroline=true, linewidth=1, linecolor="black", mirror=false),
    xaxis3=attr(showline=true, zeroline=true, linewidth=1, linecolor="black", mirror=false),
    xaxis4=attr(showline=true, zeroline=true, linewidth=1, linecolor="black", mirror=false),
    xaxis5=attr(showline=true, zeroline=true, linewidth=1, linecolor="black", mirror=false),
    xaxis5_title="bus (#)",
    yaxis=attr(showline=true, zeroline=true, linewidth=1, linecolor="black", mirror=false),
    yaxis2=attr(showline=true, zeroline=true, linewidth=1, linecolor="black", mirror=false),
    yaxis3=attr(showline=true, zeroline=true, linewidth=1, linecolor="black", mirror=false),
    yaxis4=attr(showline=true, zeroline=true, linewidth=1, linecolor="black", mirror=false),
    yaxis5=attr(showline=true, zeroline=true, linewidth=1, linecolor="black", mirror=false),
    yaxis_title="price (\$)",
    yaxis2_title="price (\$)",
    yaxis3_title="price (\$)",
    yaxis4_title="price (\$)",
    yaxis5_title="price (\$)",
            )
    display(fig)





############################################################# plot fuel ####################################################################
gens_nsw = [gen["index"] for (i,gen) in data["gen"] if data["bus"]["$(gen["gen_bus"])"]["area"] == 1]
gens_vic = [gen["index"] for (i,gen) in data["gen"] if data["bus"]["$(gen["gen_bus"])"]["area"] == 2]
gens_qld = [gen["index"] for (i,gen) in data["gen"] if data["bus"]["$(gen["gen_bus"])"]["area"] == 3]
gens_sa = [gen["index"] for (i,gen) in data["gen"] if data["bus"]["$(gen["gen_bus"])"]["area"] == 4]
gens_tas = [gen["index"] for (i,gen) in data["gen"] if data["bus"]["$(gen["gen_bus"])"]["area"] == 5]

int_nsw_qld = [branch["index"] for (i,branch) in data["branch"] if data["bus"]["$(branch["f_bus"])"]["area"] == 1 && data["bus"]["$(branch["t_bus"])"]["area"] == 3]
# 54, 55 leave 240, 241, connecting Directlink branchdc 2,3,4
filter!(x -> x != 240, int_nsw_qld) 
filter!(x -> x != 241, int_nsw_qld) 
intdc_qld_nsw = [2,3,4]
int_nsw_vic = [branch["index"] for (i,branch) in data["branch"] if data["bus"]["$(branch["f_bus"])"]["area"] == 1 && data["bus"]["$(branch["t_bus"])"]["area"] == 2]
int_vic_sa = [branch["index"] for (i,branch) in data["branch"] if data["bus"]["$(branch["f_bus"])"]["area"] == 2 && data["bus"]["$(branch["t_bus"])"]["area"] == 4]
# 527, 528, leave 1948, connecting Murraylink brnachdc 5
filter!(x -> x != 1948, int_vic_sa)
intdc_vic_sa = [5]
intdc_vic_tas = [1]

# area-wise aggregate of pg for each fuel type
pg_fuel_qld = NEMX.area_wise_generation_aggregate_of_each_fuel(data, gens_qld)
pg_fuel_nsw = NEMX.area_wise_generation_aggregate_of_each_fuel(data, gens_nsw)
pg_fuel_vic = NEMX.area_wise_generation_aggregate_of_each_fuel(data, gens_vic)
pg_fuel_sa = NEMX.area_wise_generation_aggregate_of_each_fuel(data, gens_sa)
pg_fuel_tas = NEMX.area_wise_generation_aggregate_of_each_fuel(data, gens_tas)
# area-wise aggregate of pg import
pf_import_qld = 0.0
pf_import_nsw = 0.0
pf_import_vic = 0.0
pf_import_sa = 0.0
pf_import_tas = 0.0

pf_nsw_qld = data["branch"]["54"]["pf"] + data["branch"]["55"]["pf"] + data["branchdc"]["2"]["pt"] + data["branchdc"]["3"]["pt"] + data["branchdc"]["4"]["pt"]
if pf_nsw_qld >= 0
    pf_import_qld += pf_nsw_qld
else
    pf_import_nsw += pf_nsw_qld
end

pf_nsw_vic = sum([branch["pf"] for (i,branch) in data["branch"] if branch["index"] in int_nsw_vic])
if pf_nsw_vic >= 0
    pf_import_vic += pf_nsw_vic
else
    pf_import_nsw += pf_nsw_vic
end

pf_vic_sa = data["branch"]["527"]["pf"] + data["branch"]["528"]["pf"] + data["branchdc"]["5"]["pf"]
if pf_vic_sa >= 0
    pf_import_sa += pf_vic_sa
else
    pf_import_vic += pf_vic_sa
end
   
pf_vic_tas = data["branchdc"]["1"]["pf"]
if pf_vic_tas >= 0
    pf_import_tas += pf_vic_tas
else
    pf_import_vic += pf_vic_tas
end

fig = make_subplots(rows=5, cols=1)

t_qld_coal = scatter(;x=1, y=pg_fuel_qld["coal"], fill="tozeroy", name = "Coal", stackgroup="one", mode="lines", hoverinfo="x+y", groupnorm="percent")
t_qld_water = scatter(;x=1, y=pg_fuel_qld["water"], fill="tonexty", name = "Hydro", stackgroup="one", mode="lines", hoverinfo="x+y", groupnorm="percent")
t_qld_gas= scatter(;x=1, y=pg_fuel_qld["gas"], fill="tonexty", name = "Gas", stackgroup="one", mode="lines", hoverinfo="x+y", groupnorm="percent")
t_qld_wind = scatter(;x=1, y=pg_fuel_qld["wind"], fill="tonexty", name = "Wind", stackgroup="one", mode="lines", hoverinfo="x+y", groupnorm="percent")
t_qld_solar = scatter(;x=1, y=pg_fuel_qld["solar"], fill="tonexty", name = "Solar", stackgroup="one", mode="lines", hoverinfo="x+y", groupnorm="percent")
t_qld_battery = scatter(;x=1, y=pg_fuel_qld["battery"], fill="tonexty", name = "Battery", stackgroup="one", mode="lines", hoverinfo="x+y", groupnorm="percent")
t_qld_biomass = scatter(;x=1, y=pg_fuel_qld["biomass"], fill="tonexty", name = "Biomass", stackgroup="one", mode="lines", hoverinfo="x+y", groupnorm="percent")
t_qld_distillate = scatter(;x=1, y=pg_fuel_qld["distillate"], fill="tonexty", name = "Distillate", stackgroup="one", mode="lines", hoverinfo="x+y", groupnorm="percent")
t_qld_pf_import = scatter(;x=1, y=pf_import_qld, fill="tonexty", name = "Import", stackgroup="one", mode="lines", hoverinfo="x+y", groupnorm="percent")

plot([t_qld_coal, t_qld_water, t_qld_gas, t_qld_wind , t_qld_solar, t_qld_battery, t_qld_biomass, t_qld_distillate, t_qld_pf_import], Layout(yaxis=attr(ticksuffix="%", range=(0, 100))))


t_nsw_coal = scatter(;x=1, y=pg_fuel_nsw["coal"], fill="tozeroy", name = "Coal", showlegend = false)
t_nsw_water = scatter(;x=1, y=pg_fuel_nsw["water"], fill="tonexty", name = "Hydro", showlegend = false)
t_nsw_gas= scatter(;x=1, y=pg_fuel_nsw["gas"], fill="tonexty", name = "Gas", showlegend = false)
t_nsw_wind = scatter(;x=1, y=pg_fuel_nsw["wind"], fill="tonexty", name = "Wind", showlegend = false)
t_nsw_solar = scatter(;x=1, y=pg_fuel_nsw["solar"], fill="tonexty", name = "Solar", showlegend = false)
t_nsw_battery = scatter(;x=1, y=pg_fuel_nsw["battery"], fill="tonexty", name = "Battery", showlegend = false)
t_nsw_biomass = scatter(;x=1, y=pg_fuel_nsw["biomass"], fill="tonexty", name = "Biomass", showlegend = false)
t_nsw_distillate = scatter(;x=1, y=pg_fuel_nsw["distillate"], fill="tonexty", name = "Distillate", showlegend = false)
t_nsw_pf_import = scatter(;x=1, y=pf_import_nsw, fill="tonexty", name = "Import", showlegend = false)

t_vic_coal = scatter(;x=1, y=pg_fuel_vic["coal"], fill="tozeroy", name = "Coal", showlegend = false)
t_vic_water = scatter(;x=1, y=pg_fuel_vic["water"], fill="tonexty", name = "Hydro", showlegend = false)
t_vic_gas= scatter(;x=1, y=pg_fuel_vic["gas"], fill="tonexty", name = "Gas", showlegend = false)
t_vic_wind = scatter(;x=1, y=pg_fuel_vic["wind"], fill="tonexty", name = "Wind", showlegend = false)
t_vic_solar = scatter(;x=1, y=pg_fuel_vic["solar"], fill="tonexty", name = "Solar", showlegend = false)
t_vic_battery = scatter(;x=1, y=pg_fuel_vic["battery"], fill="tonexty", name = "Battery", showlegend = false)
t_vic_biomass = scatter(;x=1, y=pg_fuel_vic["biomass"], fill="tonexty", name = "Biomass", showlegend = false)
t_vic_distillate = scatter(;x=1, y=pg_fuel_vic["distillate"], fill="tonexty", name = "Distillate", showlegend = false)
t_vic_pf_import = scatter(;x=1, y=pf_import_vic, fill="tonexty", name = "Import", showlegend = false)

t_sa_coal = scatter(;x=1, y=pg_fuel_sa["coal"], fill="tozeroy", name = "Coal", showlegend = false)
t_sa_water = scatter(;x=1, y=pg_fuel_sa["water"], fill="tonexty", name = "Hydro", showlegend = false)
t_sa_gas= scatter(;x=1, y=pg_fuel_sa["gas"], fill="tonexty", name = "Gas", showlegend = false)
t_sa_wind = scatter(;x=1, y=pg_fuel_sa["wind"], fill="tonexty", name = "Wind", showlegend = false)
t_sa_solar = scatter(;x=1, y=pg_fuel_sa["solar"], fill="tonexty", name = "Solar", showlegend = false)
t_sa_battery = scatter(;x=1, y=pg_fuel_sa["battery"], fill="tonexty", name = "Battery", showlegend = false)
t_sa_biomass = scatter(;x=1, y=pg_fuel_sa["biomass"], fill="tonexty", name = "Biomass", showlegend = false)
t_sa_distillate = scatter(;x=1, y=pg_fuel_sa["distillate"], fill="tonexty", name = "Distillate", showlegend = false)
t_sa_pf_import = scatter(;x=1, y=pf_import_sa, fill="tonexty", name = "Import", showlegend = false)

t_tas_coal = scatter(;x=1, y=pg_fuel_tas["coal"], fill="tozeroy", name = "Coal", showlegend = false)
t_tas_water = scatter(;x=1, y=pg_fuel_tas["water"], fill="tonexty", name = "Hydro", showlegend = false)
t_tas_gas = scatter(;x=1, y=pg_fuel_tas["gas"], fill="tonexty", name = "Gas", showlegend = false)
t_tas_wind = scatter(;x=1, y=pg_fuel_tas["wind"], fill="tonexty", name = "Wind", showlegend = false)
t_tas_solar = scatter(;x=1, y=pg_fuel_tas["solar"], fill="tonexty", name = "Solar", showlegend = false)
t_tas_battery = scatter(;x=1, y=pg_fuel_tas["battery"], fill="tonexty", name = "Battery", showlegend = false)
t_tas_biomass = scatter(;x=1, y=pg_fuel_tas["biomass"], fill="tonexty", name = "Biomass", showlegend = false)
t_tas_distillate = scatter(;x=1, y=pg_fuel_tas["distillate"], fill="tonexty", name = "Distillate", showlegend = false)
t_tas_pf_import = scatter(;x=1, y=pf_import_tas, fill="tonexty", name = "Import", showlegend = false)

add_trace!(fig, t_qld_coal, row=1, col=1)
add_trace!(fig, t_qld_water, row=1, col=1)
add_trace!(fig, t_qld_gas, row=1, col=1)
add_trace!(fig, t_qld_wind, row=1, col=1)
add_trace!(fig, t_qld_solar, row=1, col=1)
add_trace!(fig, t_qld_battery, row=1, col=1)
add_trace!(fig, t_qld_biomass, row=1, col=1)
add_trace!(fig, t_qld_distillate, row=1, col=1)
add_trace!(fig, t_qld_pf_import, row=1, col=1)

add_trace!(fig, t_nsw_coal, row=2, col=1)
add_trace!(fig, t_nsw_water, row=2, col=1)
add_trace!(fig, t_nsw_gas, row=2, col=1)
add_trace!(fig, t_nsw_wind, row=2, col=1)
add_trace!(fig, t_nsw_solar, row=2, col=1)
add_trace!(fig, t_nsw_battery, row=2, col=1)
add_trace!(fig, t_nsw_biomass, row=2, col=1)
add_trace!(fig, t_nsw_distillate, row=2, col=1)
add_trace!(fig, t_nsw_pf_import, row=2, col=1)

add_trace!(fig, t_vic_coal, row=3, col=1)
add_trace!(fig, t_vic_water, row=3, col=1)
add_trace!(fig, t_vic_gas, row=3, col=1)
add_trace!(fig, t_vic_wind, row=3, col=1)
add_trace!(fig, t_vic_solar, row=3, col=1)
add_trace!(fig, t_vic_battery, row=3, col=1)
add_trace!(fig, t_vic_biomass, row=3, col=1)
add_trace!(fig, t_vic_distillate, row=3, col=1)
add_trace!(fig, t_vic_pf_import, row=3, col=1)

add_trace!(fig, t_sa_coal, row=4, col=1)
add_trace!(fig, t_sa_water, row=4, col=1)
add_trace!(fig, t_sa_gas, row=4, col=1)
add_trace!(fig, t_sa_wind, row=4, col=1)
add_trace!(fig, t_sa_solar, row=4, col=1)
add_trace!(fig, t_sa_battery, row=4, col=1)
add_trace!(fig, t_sa_biomass, row=4, col=1)
add_trace!(fig, t_sa_distillate, row=4, col=1)
add_trace!(fig, t_sa_pf_import, row=4, col=1)

add_trace!(fig, t_tas_coal, row=5, col=1)
add_trace!(fig, t_tas_water, row=5, col=1)
add_trace!(fig, t_tas_gas, row=5, col=1)
add_trace!(fig, t_tas_wind, row=5, col=1)
add_trace!(fig, t_tas_solar, row=5, col=1)
add_trace!(fig, t_tas_battery, row=5, col=1)
add_trace!(fig, t_tas_biomass, row=5, col=1)
add_trace!(fig, t_tas_distillate, row=5, col=1)
add_trace!(fig, t_tas_pf_import, row=5, col=1)

relayout!(fig, title_text="Energy Fuel", template=:plotly_white,
        )
display(fig)
end





function create_single_price_table(rows_DC::Dict{Any, Any})
    # Column headers with units
    col_names = [
        "State",
        "Energy(\$/MW)", "Lreg(¢/MW)", "Rreg(¢/MW)",
        "L1s(¢/MW)", "R1s(¢/MW)", "L6s(¢/MW)", "R6s(¢/MW)",
        "L60s(¢/MW)", "R60s(¢/MW)", "L5m(¢/MW)", "R5m(¢/MW)",
        "Formulation"
    ]

    # Extract and flatten each tuple into a row
    data = [
        Tuple(rows_DC["row_DC_QLD"]),
        Tuple(rows_DC["row_DC_NSW"]),
        Tuple(rows_DC["row_DC_VIC"]),
        Tuple(rows_DC["row_DC_SA"]),
        Tuple(rows_DC["row_DC_TAS"])
    ]

    # Create the DataFrame with rows as observations
    return DataFrame(data, Symbol.(col_names))
end





function plot_state_wide_nodal_lmps(price, state)

    x = [n for (n, p) in price[state]]
    y = [p for (n, p) in price[state]]

    # Create the bar trace
    trace = bar(x = string.(x), y = y, name = state)

    # Define layout
    layout = Layout(
        title = "$state Node Prices",
        xaxis_title = "Node ID",
        yaxis_title = "Price",
        barmode = "group"
    )

    # Display the plot
    plot(trace, layout)
end