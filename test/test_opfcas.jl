

file = "./test/data/matpower/snem2000_acdc.m"
setting = Dict("output" => Dict("branch_flows" => true, "duals" => true), "conv_losses_mp" => true, "mlf" => true)

data = parse_file(file, validate=true, import_all=false)
NEMX.process_scenario_data!(data, "s1")
_PMACDC.process_additional_data!(data)
NEMX.add_area_gens!(data)

rrn = Dict("NSW"=>"130", "VIC"=>"1480", "QLD"=>"1274", "SA" => "1643", "TAS" => "1123")
data["rrn"] = Dict{String, Any}()
data["rrn"] = rrn
data["bus_rr"] = Dict{String, Any}()
for (region, bus) in rrn
    data["bus_rr"]["$(bus)"] = data["bus"]["$(bus)"]
end
data["price_cap"] = 16600
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

@testset "snem2000_acdc s1 ac polar formulation" begin
    result = NEMX.run_acdcopfcas(data, _PM.ACPPowerModel, nlp_solver, setting=setting)

    @test result["termination_status"] == LOCALLY_SOLVED
    @test isapprox(result["objective"], 5.948878799365816e6; atol = 1e0)
end

@testset "snem2000_acdc s1 dc polar formulation" begin
    result = NEMX.run_acdcopfcas(data, _PM.DCPPowerModel, gurobi_solver, setting=setting)

    @test result["termination_status"] == OPTIMAL
    @test isapprox(result["objective"], 6.945518904965966e6; atol = 1e0)
end

@testset "snem2000_acdc s1 iv rectangular formulation" begin
    result = NEMX.run_acdcopfcas_ivr(data, _PM.IVRPowerModel, nlp_solver, setting=setting)

    @test result["termination_status"] == LOCALLY_SOLVED
    @test isapprox(result["objective"], 5.948873023830866e6; atol = 1e0)
end


data = parse_file(file, validate=true, import_all=false)
NEMX.process_scenario_data!(data, "s2")
_PMACDC.process_additional_data!(data)
NEMX.add_area_gens!(data)

rrn = Dict("NSW"=>"130", "VIC"=>"1480", "QLD"=>"1274", "SA" => "1643", "TAS" => "1123")
data["rrn"] = Dict{String, Any}()
data["rrn"] = rrn
data["bus_rr"] = Dict{String, Any}()
for (region, bus) in rrn
    data["bus_rr"]["$(bus)"] = data["bus"]["$(bus)"]
end
data["price_cap"] = 16600
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

data = parse_file(file, validate=true, import_all=false)
NEMX.process_scenario_data!(data, "s2")
_PMACDC.process_additional_data!(data)
NEMX.add_area_gens!(data)

rrn = Dict("NSW"=>"130", "VIC"=>"1480", "QLD"=>"1274", "SA" => "1643", "TAS" => "1123")
data["rrn"] = Dict{String, Any}()
data["rrn"] = rrn
data["bus_rr"] = Dict{String, Any}()
for (region, bus) in rrn
    data["bus_rr"]["$(bus)"] = data["bus"]["$(bus)"]
end
data["price_cap"] = 16600
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

@testset "snem2000_acdc s2 ac polar formulation" begin
    result = NEMX.run_acdcopfcas(data, _PM.ACPPowerModel, nlp_solver, setting=setting)

    @test result["termination_status"] == LOCALLY_SOLVED
    @test isapprox(result["objective"], 5.966794401900445e6; atol = 1e0)
end

@testset "snem2000_acdc s2 dc polar formulation" begin
    result = NEMX.run_acdcopfcas(data, _PM.DCPPowerModel, gurobi_solver, setting=setting)

    @test result["termination_status"] == OPTIMAL
    @test isapprox(result["objective"], 5.961439703692706e6; atol = 1e0)
end

@testset "snem2000_acdc s2 iv rectangular formulation" begin
    result = NEMX.run_acdcopfcas_ivr(data, _PM.IVRPowerModel, nlp_solver, setting=setting)

    @test result["termination_status"] == LOCALLY_SOLVED
    @test isapprox(result["objective"], 5.966787079146418e6; atol = 1e0)
end

data = parse_file(file, validate=true, import_all=false)
NEMX.process_scenario_data!(data, "s3")
_PMACDC.process_additional_data!(data)
NEMX.add_area_gens!(data)

rrn = Dict("NSW"=>"130", "VIC"=>"1480", "QLD"=>"1274", "SA" => "1643", "TAS" => "1123")
data["rrn"] = Dict{String, Any}()
data["rrn"] = rrn
data["bus_rr"] = Dict{String, Any}()
for (region, bus) in rrn
    data["bus_rr"]["$(bus)"] = data["bus"]["$(bus)"]
end
data["price_cap"] = 16600
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

@testset "snem2000_acdc s3 dc polar formulation" begin
    result = NEMX.run_acdcopfcas(data, _PM.DCPPowerModel, gurobi_solver, setting=setting)

    @test result["termination_status"] == OPTIMAL
    @test isapprox(result["objective"], 6.764733719064058e6; atol = 1e0)
end

@testset "snem2000_acdc s3 ac polar formulation" begin
    result = NEMX.run_acdcopfcas(data, _PM.ACPPowerModel, nlp_solver, setting=setting)

    @test result["termination_status"] == LOCALLY_SOLVED
    @test isapprox(result["objective"], 6.000207951331199e6; atol = 1e0)
end

@testset "snem2000_acdc s3 iv rectangular formulation" begin
    result = NEMX.run_acdcopfcas_ivr(data, _PM.IVRPowerModel, nlp_solver, setting=setting)

    @test result["termination_status"] == LOCALLY_SOLVED
    @test isapprox(result["objective"], 6.000208593732356e6; atol = 1e0)
end