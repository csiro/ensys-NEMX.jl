

# FCAS

const gen_fcas_columns = [
    ("gen", Int),
    ("service", Int),
    ("emin", Float64),
    ("lb", Float64),
    ("ub", Float64),
    ("emax", Float64),
    ("amax", Float64)
]

const load_fcas_columns = [
    ("load", Int),
    ("service", Int),
    ("emin", Float64),
    ("lb", Float64),
    ("ub", Float64),
    ("emax", Float64),
    ("amax", Float64)
]

const _fcas_target_columns = [
    ("service", Int),
    ("area", Int),
    ("p", Float64)
]

const _load_limit_columns = [
    ("load", Int),
    ("Pmax", Float64),
    ("Pmin", Float64)
]

const mlf_columns = [
    ("bus", Int),
    ("p", Float64),
    ("mlf", Float64),
    ("loss", Float64)
]

"""
    SCENARIO_DIR

Default root for market-scenario data read by [`process_scenario_data!`](@ref).

Resolved from the package's own location rather than from the caller's working
directory, so a scenario bundled with the package is found however the package
was loaded. Point `process_scenario_data!` at your own directory with its `dir`
keyword instead of changing this.
"""
const SCENARIO_DIR = normpath(joinpath(@__DIR__, "..", "..", "..",
                                       "test", "data", "nem_market"))

"""
    MARKET_DATA_DIR

Root directory for the raw AEMO market CSVs (`participants.csv`,
`BIDPEROFFER.csv`, `BIDDAYOFFER.csv`) that the scenario-building helpers read,
and for the `.m` scenario files they write.

This is a `Ref` rather than a constant because these helpers are a data
preparation pipeline run against whatever download the user has on disk, which
is not something the package can know at load time:

```julia
NEMX.OPFFCAS.MARKET_DATA_DIR[] = "/data/aemo/2025-09"
```

Every function that touches it also accepts a `dir` keyword, so a one-off can
override it without mutating global state. Nothing in the package writes to this
location unless you call an `export_*` function.
"""
const MARKET_DATA_DIR = Ref{String}(joinpath(homedir(), "nem_market_data"))

"""
    process_scenario_data!(data::Dict, scenario::AbstractString;
                           dir::AbstractString = SCENARIO_DIR) -> Dict

Extend a standard MATPOWER case with the market data a NEM dispatch needs:
generator and load cost curves, FCAS offers and enablement limits, and marginal
loss factors.

Each of the four inputs is optional. A file that is absent is skipped silently,
so a scenario can supply only what it has — a case with no FCAS data simply
produces a model with no FCAS.

# Arguments
- `data::Dict`: a parsed MATPOWER case, modified in place.
- `scenario::AbstractString`: scenario name, i.e. the subdirectory of `dir`
  holding that scenario's files (`"s1"`, `"s2"`, ...).

# Keywords
- `dir::AbstractString = SCENARIO_DIR`: root directory of the scenario library.
  Defaults to the scenarios bundled with the package.

# Files read
`\$dir/\$scenario/` may contain any of `fcas.m`, `gencost.m`, `loadcost.m` and
`mlf.m`.

# Returns
`data`, extended in place.

# Example
```julia
data = PowerModels.parse_file("case.m")
NEMX.OPFFCAS.process_scenario_data!(data, "s1")
NEMX.OPFFCAS.process_scenario_data!(data, "peak"; dir = "/path/to/my/scenarios")
```
"""
function process_scenario_data!(data::Dict, scenario::AbstractString;
                                dir::AbstractString = SCENARIO_DIR)
    fcas_file = joinpath(dir, scenario, "fcas.m")
    if isfile(fcas_file)
        scenario_fcas = _IM.parse_matlab_file(fcas_file)

        if haskey(scenario_fcas, "mpc.fcas_gen")
            fcas = []
            for (i, row) in enumerate(scenario_fcas["mpc.fcas_gen"])
                row_data = _IM.row_to_typed_dict(row, gen_fcas_columns)
                row_data["index"] = i
                row_data["source_id"] = ["fcas_gen", i]
                push!(fcas, row_data)
            end
            data["fcas_gen"] = fcas
        end

        if haskey(scenario_fcas, "mpc.fcas_load")
            fcas = []
            for (i, row) in enumerate(scenario_fcas["mpc.fcas_load"])
                row_data = _IM.row_to_typed_dict(row, load_fcas_columns)
                row_data["index"] = i
                row_data["source_id"] = ["fcas_load", i]
                push!(fcas, row_data)
            end
            data["fcas_load"] = fcas
        end

        if haskey(scenario_fcas, "mpc.fcas_cost_gen")
            fcas = []
            for (i, row) in enumerate(scenario_fcas["mpc.fcas_cost_gen"])
                row_data = map_fcas_cost_data(row)
                row_data["index"] = i
                row_data["source_id"] = ["fcas_cost_gen", i]
                push!(fcas, row_data)
            end
            data["fcas_cost_gen"] = fcas
        end

        if haskey(scenario_fcas, "mpc.fcas_cost_load")
            fcas = []
            for (i, row) in enumerate(scenario_fcas["mpc.fcas_cost_load"])
                row_data = map_fcas_cost_data(row)
                row_data["index"] = i
                row_data["source_id"] = ["fcas_cost_load", i]
                push!(fcas, row_data)
            end
            data["fcas_cost_load"] = fcas
        end

        if haskey(scenario_fcas, "mpc.fcas_target")
            fcas = []
            for (i, row) in enumerate(scenario_fcas["mpc.fcas_target"])
                row_data = _IM.row_to_typed_dict(row, _fcas_target_columns)
                row_data["index"] = i
                row_data["source_id"] = ["fcas_target", i]
                push!(fcas, row_data)
            end
            data["fcas_target"] = fcas
        end
    end

    gencost_file = joinpath(dir, scenario, "gencost.m")
    if isfile(gencost_file)
        scenario_gen_cost = _IM.parse_matlab_file(gencost_file)

        if haskey(scenario_gen_cost, "mpc.gencost")
            cost = []
            for (i, row) in enumerate(scenario_gen_cost["mpc.gencost"])
                row_data = map_cost_data(row)
                row_data["index"] = i
                row_data["source_id"] = ["gencost", i]
                push!(cost, row_data)
            end
            data["gen_cost"] = cost
        end
    end

    loadcost_file = joinpath(dir, scenario, "loadcost.m")
    if isfile(loadcost_file)
        scenario_load_cost = _IM.parse_matlab_file(loadcost_file)

        if haskey(scenario_load_cost, "mpc.load_limit")
            limit = []
            for (i, row) in enumerate(scenario_load_cost["mpc.load_limit"])
                row_data = _IM.row_to_typed_dict(row, _load_limit_columns)
                row_data["index"] = i
                row_data["source_id"] = ["load_limit", i]
                push!(limit, row_data)
            end
            data["load_limit"] = limit
        end

        if haskey(scenario_load_cost, "mpc.loadcost")
            cost = []
            for (i, row) in enumerate(scenario_load_cost["mpc.loadcost"])
                row_data = map_cost_data(row)
                row_data["index"] = i
                row_data["source_id"] = ["loadcost", i]
                push!(cost, row_data)
            end
            data["load_cost"] = cost
        end
    end

    mlf_file = joinpath(dir, scenario, "mlf.m")
    if isfile(mlf_file)
        scenario_mlf = _IM.parse_matlab_file(mlf_file)

        if haskey(scenario_mlf, "mpc.bus_mlf")
            mlf = []
            for (i, row) in enumerate(scenario_mlf["mpc.bus_mlf"])
                row_data = _IM.row_to_typed_dict(row, mlf_columns)
                row_data["index"] = i
                row_data["source_id"] = ["bus_mlf", i]
                push!(mlf, row_data)
            end
            data["mlf"] = mlf
        end
    end

    merge_cost_data!(data)
    merge_load_limit_data!(data)
    merge_fcas_data!(data)
    merge_fcas_cost_data!(data)
end

"""
    map_cost_data(cost_row) 

Cost data in a MatPower file does not have column names due to the variable width of the 
cost data. This function converts the parsed MatPower cost data and maps it to a standard
cost data dictionary format.
"""
function map_cost_data(cost_row)
    ncost = _IM.check_type(Int, cost_row[4])
    model = _IM.check_type(Int, cost_row[1])

    if model == 1
        nr_parameters = ncost * 2
    elseif model == 2
        nr_parameters = ncost
    end

    cost_data = Dict(
        "model" => model,
        "startup" => _IM.check_type(Float64, cost_row[2]),
        "shutdown" => _IM.check_type(Float64, cost_row[3]),
        "ncost" => ncost,
        "cost" => [_IM.check_type(Float64, cost_row[x]) for x in 5:5+nr_parameters-1]
    )

    return cost_data
end

"""
    map_fcas_cost_data(cost_row) 

Cost data in a MatPower file does not have column names due to the variable width of the 
cost data. This function converts the parsed MatPower cost data and maps it to fcas
cost data dictionary format.
"""
function map_fcas_cost_data(cost_row)
    participant = _IM.check_type(Int, cost_row[1])
    service = _IM.check_type(Int, cost_row[2])
    ncost = _IM.check_type(Int, cost_row[3])

    nr_parameters = ncost * 2

    cost_data = Dict(
        "participant" => participant,
        "service" => service,
        "ncost" => ncost,
        "cost" => [_IM.check_type(Float64, cost_row[x]) for x in 4:4+nr_parameters-1]
    )

    return cost_data
end

"""
    merge_cost_data!(cost_row) 

Converts cost quantity values to p.u and merges the data with the gen/load dictionaries
"""
function merge_cost_data!(data::Dict{String,Any})
    if haskey(data, "gen_cost")
        gen = data["gen"]
        gen_cost = data["gen_cost"]

        if length(gen) != length(gen_cost)
            if length(gen_cost) > length(gen)
                Memento.warn(_LOGGER, "The last $(length(gen_cost) - length(gen)) gen offer records will be ignored due to too few gen records.")
                gen_cost = gen_cost[1:length(gen)]
            else
                Memento.warn(_LOGGER, "The number of generators ($(length(gen))) does not match the number of generator offer records ($(length(gen_cost))).")
            end
        end

        MVAbase = data["baseMVA"]
        cost_pu!(gen_cost, MVAbase)

        for (i, gc) in enumerate(gen_cost)
            g = gen["$(i)"]
            merge!(g, gc)
        end

        delete!(data, "gen_cost")
    end

    if haskey(data, "load_cost")
        load = data["load"]
        load_cost = data["load_cost"]

        if length(load) != length(load_cost)
            if length(load_cost) > length(load)
                Memento.warn(_LOGGER, "The last $(length(load_cost) - length(load)) load bid records will be ignored due to too few load records.")
                gen_cost = gen_cost[1:length(gen)]
            else
                Memento.warn(_LOGGER, "The number of loads ($(length(load))) does not match the number of load bid records ($(length(load_cost))).")
            end
        end

        MVAbase = data["baseMVA"]
        cost_pu!(load_cost, MVAbase)

        for (i, lc) in enumerate(load_cost)
            l = load["$(i)"]
            merge!(l, lc)
        end

        delete!(data, "load_cost")
    end
end

"""
    merge_load_limit_data!(data)

Merges scheduled load limit data with the load data dictionary
"""
function merge_load_limit_data!(data)
    MVAbase = data["baseMVA"]
    rescale_power = x -> x / MVAbase

    if haskey(data, "load_limit")
        limits = data["load_limit"]
        for limit in values(limits)
            load = data["load"]["$(limit["load"])"]
            load["pmin"] = _PM._apply_func!(limit, "Pmin", rescale_power)
            load["pmax"] = _PM._apply_func!(limit, "Pmax", rescale_power)
        end
    end

end

"""
    merge_fcas_data!(data)

Merges fcas trapezium data with generator/load dictionaries
"""
function merge_fcas_data!(data)
    MVAbase = data["baseMVA"]


    if haskey(data, "fcas_gen")
        fcas_gen = data["fcas_gen"]
        for fcas_data in fcas_gen
            gen = data["gen"]["$(fcas_data["gen"])"]

            if !haskey(gen, "fcas")
                gen["fcas"] = Dict{Int,Any}()
            end

            set_fcas_pu!(fcas_data, MVAbase)
            calculate_slope_coefficients!(fcas_data)

            gen["fcas"][fcas_data["service"]] = fcas_data
        end
    end

    if haskey(data, "fcas_load")
        fcas_load = data["fcas_load"]
        for fcas_data in fcas_load
            load = data["load"]["$(fcas_data["load"])"]

            if !haskey(load, "fcas")
                load["fcas"] = Dict{Int,Any}()
            end

            set_fcas_pu!(fcas_data, MVAbase)
            calculate_slope_coefficients!(fcas_data)

            load["fcas"][fcas_data["service"]] = fcas_data
        end
    end

    if haskey(data, "fcas_target")
        targets = data["fcas_target"]
        for target in targets
            set_fcas_targets_pu!(target, MVAbase)
        end
    else
        data["fcas_target"] = Dict()
    end

end

function merge_fcas_cost_data!(data)
    if haskey(data, "fcas_cost_gen")
        merge_fcas_cost_data!(data, "fcas_cost_gen", "gen")
    end

    if haskey(data, "fcas_cost_load")
        merge_fcas_cost_data!(data, "fcas_cost_load", "load")
    end
end

"""
    merge_fcas_data!(data)

Merges fcas cost data with generator/load dictionaries
"""
function merge_fcas_cost_data!(data, name::String, participant_type::String)
    participants = data[participant_type]
    costs = data[name]

    MVAbase = data["baseMVA"]
    cost_pu!(costs, MVAbase)

    for (i, item) in participants
        participant_key = parse(Int, i)
        participant_costs = filter(p -> haskey(p, "participant") && p["participant"] == participant_key, collect(values(costs)))

        item["fcas_cost"] = Dict{Int,Dict}()
        for cost in participant_costs
            item["fcas_cost"][cost["service"]] = cost
            delete!(cost, "participant")
            delete!(cost, "service")
        end
    end

    delete!(data, name)
end

function set_fcas_pu!(data, MVAbase)
    rescale_power = x -> x / MVAbase

    _PM._apply_func!(data, "emin", rescale_power)
    _PM._apply_func!(data, "lb", rescale_power)
    _PM._apply_func!(data, "ub", rescale_power)
    _PM._apply_func!(data, "emax", rescale_power)
    _PM._apply_func!(data, "amax", rescale_power)
end

function set_fcas_targets_pu!(data, MVAbase)
    rescale_power = x -> x / MVAbase

    _PM._apply_func!(data, "p", rescale_power)
end

function cost_pu!(costs, MVAbase)
    for n in keys(costs)
        cost = costs[n]["cost"]
        for i in 1:2:length(cost)
            cost[i] = cost[i] / MVAbase
        end
    end
end

function calculate_slope_coefficients!(fcas)
    fcas["lower_slope"] = fcas["amax"] > 0.0 ? (fcas["lb"] - fcas["emin"]) / fcas["amax"] : 0.0
    fcas["upper_slope"] = fcas["amax"] > 0.0 ? (fcas["emax"] - fcas["ub"]) / fcas["amax"] : 0.0
end


"""
    get_dispatchable_participants(participants)

Returns only dispatchable participants (generators/loads)
"""
function get_dispatchable_participants(participants::Dict)
    return filter(x -> is_dispatchable(x[2]), participants)
end

"""
    is_dispatchable(participants)

Returns true if a participant is dispatchable
"""
function is_dispatchable(participant::Dict)
    return haskey(participant, "pmin") || haskey(participant, "pmax")
end




"""
    set_reference_bus(data, refs)

Set each bus in the refs argument as reference/slack buses

# Arguments
- `data::Dict{String, Any}`: The network data dictionary
- `refs::Vector{String}`: A list of references bus indexes
"""
function set_reference_bus(data, ref::String)
    area_data = deepcopy(data)

    for bus in [bus for (i, bus) in area_data["bus"] if bus["bus_type"] == 3]
        if bus["index"] != parse(Int, ref)
            bus["bus_type"] = 2
        end
    end

    # for ref in refs
    area_data["bus"][ref]["bus_type"] = 3
    gens = filter(x -> x[2]["gen_bus"] == parse(Int, ref), area_data["gen"])
    if isempty(gens)
        gen_count = length(area_data["gen"])
        area_data["gen"]["$(gen_count + 1)"] = Dict("index" => gen_count + 1, "gen_status" => 1, "gen_bus" => parse(Int, ref), "pg" => 0.0, "qg" => 0.0, "pmin" => 0.0, "pmax" => 0.0, "qmin" => 0.0, "qmax" => 0.0, "model" => 1, "ncost" => 2, "cost" => [10.0, 1.0, 10.0, 1.0])
    end
    # end

    return area_data
end


"""
    inject_load(extra_p, idx, ref, data, solver, setting)

Inject a small load at the bus specified by idx and measure the change in generation
at the reference bus specified by the ref argument
"""
function inject_load(extra_p::Float64, idx::String, ref::String, data, nlp_solver, setting)
    data_cp = deepcopy(data)
    load_count = length(keys(data_cp["load"]))

    i = parse(Int, idx)

    if extra_p > 0.0
        data_cp["load"]["$(load_count + 1)"] = Dict("index" => load_count + 1, "status" => 1, "load_bus" => i, "pd" => extra_p, "qd" => 0.0)
    end

    result = _PMACDC.run_acdcpf(data_cp, _PM.ACPPowerModel, nlp_solver, setting=setting)
    PowerModels.update_data!(data_cp, result["solution"])

    generation = get_slack_generation(ref, data_cp)
    return generation
end

"""
    finite_difference(fx, f, x, [h])

Used to estimate the change in a function (in this case the generation at the reference bus)
based on a change the input (in this case a small injection of power at a specified load)
"""
function finite_difference(fx, f, x, h=1e-6)
    fxh = f(x + h)
    df = (fxh - fx) / (h)
    return (fxh, df)
end

"""
    get_slack_generation(ref, data)

Calculates the change in generation at the reference bus specified by the ref argument.
"""
function get_slack_generation(ref::String, data)
    gens = filter(x -> x[2]["gen_bus"] == parse(Int, ref), data["gen"])
    # gens = filter(x -> data["bus"]["$(x[2]["gen_bus"])"]["bus_type"] == 3, data["gen"])
    return sum(x -> x[2]["pg"], gens)
end

"""
    export_mlfs(mlfs, scenario)

Generates a file in MatPower case format containing the calculated MLF values.

# Arguments
- `mlfs::Vector{Tuple{Float64,Float64}}`: List of power and mlf values for each node
- `scenario::String`: The scenario to store the MLF values against
"""
function export_mlfs(mlfs::Vector{Tuple{Float64,Float64}}, scenario::String;
                     dir::AbstractString = MARKET_DATA_DIR[])
    mlf_line(bus, values) = """
    $(bus)\t\
    $(values[1])\t\
    $(values[2]);\
    """

    lines = map(x -> mlf_line(x...), enumerate(mlfs))

    template = """
    %%-----  MLF Data  -----%%
    %column_names% 	bus	p mlf
    mpc.bus_mlf = [
    $(join(lines, "\n"))
    ];
    """

    open(joinpath(dir, scenario, "mlf.m"), "w+") do io
        print(io, template)
    end
end


"""
    solution_processor(pm, solution)

Can be used to add extra values to the solution result set
"""
function solution_processor(pm::_PM.AbstractPowerModel, solution::Dict{String, Any})
    solution["dual_objective"] = JuMP.dual_objective_value(pm.model)
    # solution["lambda1"] = JuMP.value(JuMP.variable_by_name(pm.model, "0_2_pg_cost_lambda[1]"))
    # solution["lambda2"] = JuMP.value(JuMP.variable_by_name(pm.model, "0_2_pg_cost_lambda[2]"))
    # solution["lambda3"] = JuMP.value(JuMP.variable_by_name(pm.model, "0_2_pg_cost_lambda[3]"))
    # solution["lambda4"] = JuMP.value(JuMP.variable_by_name(pm.model, "0_2_pg_cost_lambda[4]"))
    # solution["lambda5"] = JuMP.value(JuMP.variable_by_name(pm.model, "0_2_pg_cost_lambda[5]"))
    # solution["lambda6"] = JuMP.value(JuMP.variable_by_name(pm.model, "0_2_pg_cost_lambda[6]"))
    # solution["lambda7"] = JuMP.value(JuMP.variable_by_name(pm.model, "0_2_pg_cost_lambda[7]"))
    # solution["lambda8"] = JuMP.value(JuMP.variable_by_name(pm.model, "0_2_pg_cost_lambda[8]"))
    # solution["lambda9"] = JuMP.value(JuMP.variable_by_name(pm.model, "0_2_pg_cost_lambda[9]"))
    # solution["lambda10"] = JuMP.value(JuMP.variable_by_name(pm.model, "0_2_pg_cost_lambda[10]"))
end





##


duid = :DUID
region = Symbol("Region")
type = Symbol("Dispatch Type")
fuel = Symbol("Fuel Source - Primary")
region_map = Dict(1 => "NSW1", 2 => "VIC1", 3 => "QLD1", 4 => "SA1", 5 => "TAS1")

gen_filter = (participant) -> (capacity, region, fuel) -> capacity / 100 <= participant.pmax && participant.type == fuel
load_filter = (participant) -> (capacity, region, fuel) -> capacity / 100 <= participant.pmax

# gen_filter = (participant) -> (capacity, region, fuel) -> capacity / 100 <= participant.pmax && participant.type == fuel && region_map[participant.area] == region
# load_filter = (participant) -> (capacity, region, fuel) -> capacity / 100 <= participant.pmax && region_map[participant.area] == region

"""
    get_capacity(participant_type::String)

Reads the maximum capacity for each participant and adds it to the Data Frame.

# Arguments
- `participant_type::String`: eg. Generator/Load
"""
function get_capacity(participant_type::String;
                      dir::AbstractString = MARKET_DATA_DIR[])
    participants = CSV.read(joinpath(dir, "participants.csv"), DataFrame)
    participants[!, :"Max Cap (MW)"] = something.(tryparse.(Float64, participants[!, :"Max Cap (MW)"]), 0.0)

    participants = groupby(participants, [duid, region, type, fuel])
    participants = combine(participants, :"Max Cap (MW)" => sum => :capacity)

    participants = @orderby participants -:capacity
    participants = filter([type, :capacity, fuel] => (type, capacity, fuel) -> type == participant_type && capacity > 0 && !ismissing(fuel), participants)

    return participants
end

"""
    assign_participant(participants, participant_type, selector)

Maps an NEM participant DUID to a generator/load

# Arguments
- `selector::Function`: used to select participants based on their type
"""
function assign_participant(participants::DataFrame, participant_type::String, selector::Function)
    df = copy(participants)
    df.DUID .= ""
    df.Region .= ""
    df.MaxCap .= 0.0
    df.Fuel .= ""

    capacity = get_capacity(participant_type)
    @orderby df -:"pmax"

    for participant in eachrow(df)
        filtered = filter([:capacity, region, fuel] => selector(participant), capacity)
        if nrow(filtered) > 0
            value = first(filtered)
            filter!(duid => row -> row != value.DUID, capacity)
            participant.DUID = value[duid]
            participant.MaxCap = value.capacity
            participant.Fuel = value[fuel]
            participant.Region = value[region]
        end
    end

    return df
end

"""
    join_offers(participants, scenario)

Joins BIDPEROFFER table values to a generator/load based on the assigned DUID
"""
function join_offers(participants::DataFrame, scenario::String;
                     dir::AbstractString = MARKET_DATA_DIR[])
    dateformat = "dd/mm/yyyy HH:MM"
    columns = Dict(
        :DUID => String,
        :BIDTYPE => String,
        :MAXAVAIL => Float64,
        :ENABLEMENTMIN => Float64,
        :ENABLEMENTMAX => Float64,
        :LOWBREAKPOINT => Float64,
        :HIGHBREAKPOINT => Float64,
        :BANDAVAIL1 => Float64,
        :BANDAVAIL2 => Float64,
        :BANDAVAIL3 => Float64,
        :BANDAVAIL4 => Float64,
        :BANDAVAIL5 => Float64,
        :BANDAVAIL6 => Float64,
        :BANDAVAIL7 => Float64,
        :BANDAVAIL8 => Float64,
        :BANDAVAIL9 => Float64,
        :BANDAVAIL10 => Float64
    )

    offers = CSV.read(joinpath(dir, scenario, "BIDPEROFFER.csv"), DataFrame, dateformat=dateformat, select=collect(keys(columns)), types=columns)
    return leftjoin(participants, offers, on=:DUID, matchmissing=:notequal)
end

"""
    join_energy_prices(participants, scenario)

Joins BIDDAYOFFER energy bid/offeres to a generator/load based on the assigned DUID
"""
function join_energy_prices(participants::DataFrame, scenario::String;
                            dir::AbstractString = MARKET_DATA_DIR[])
    dateformat = "dd/mm/yyyy HH:MM"
    columns = Dict(
        :DUID => String,
        :BIDTYPE => String,
        :PRICEBAND1 => Float64,
        :PRICEBAND2 => Float64,
        :PRICEBAND3 => Float64,
        :PRICEBAND4 => Float64,
        :PRICEBAND5 => Float64,
        :PRICEBAND6 => Float64,
        :PRICEBAND7 => Float64,
        :PRICEBAND8 => Float64,
        :PRICEBAND9 => Float64,
        :PRICEBAND10 => Float64,
        :LASTCHANGED => DateTime
    )

    prices = CSV.read(joinpath(dir, scenario, "BIDDAYOFFER.csv"), DataFrame, dateformat=dateformat, select=collect(keys(columns)), types=columns)
    filter!([:BIDTYPE] => (type) -> type == "ENERGY", prices)

    # get latest entry for each participant (maybe DAILY or REBID)

    combine(groupby(prices, [:DUID, :BIDTYPE])) do sdf
        sdf[argmax(sdf.LASTCHANGED), :]
    end

    df = filter([:BIDTYPE] => (type) -> ismissing(type) || type == "ENERGY", participants)
    return leftjoin(df, prices, on=[:DUID, :BIDTYPE], matchmissing=:notequal)
end

"""
    join_fcas_prices(participants, scenario)

Joins BIDDAYOFFER FCAS bid/offeres to a generator/load based on the assigned DUID
"""
function join_fcas_prices(participants::DataFrame, scenario::String;
                          dir::AbstractString = MARKET_DATA_DIR[])
    dateformat = "dd/mm/yyyy HH:MM"
    columns = Dict(
        :DUID => String,
        :BIDTYPE => String,
        :PRICEBAND1 => Float64,
        :PRICEBAND2 => Float64,
        :PRICEBAND3 => Float64,
        :PRICEBAND4 => Float64,
        :PRICEBAND5 => Float64,
        :PRICEBAND6 => Float64,
        :PRICEBAND7 => Float64,
        :PRICEBAND8 => Float64,
        :PRICEBAND9 => Float64,
        :PRICEBAND10 => Float64,
        :LASTCHANGED => DateTime
    )

    services = collect(keys(fcas_services))

    prices = CSV.read(joinpath(dir, scenario, "BIDDAYOFFER.csv"), DataFrame, dateformat=dateformat, select=collect(keys(columns)), types=columns)
    filter!([:BIDTYPE] => (type) -> type in services, prices)

    prices
    # get latest entry for each participant (maybe DAILY or REBID)

    combine(groupby(prices, [:DUID, :BIDTYPE])) do sdf
        sdf[argmax(sdf.LASTCHANGED), :]
    end

    df = filter([:BIDTYPE] => (type) -> ismissing(type) || type in services, participants)
    return innerjoin(df, prices, on=[:DUID, :BIDTYPE], matchmissing=:notequal)
end

"""
    gen_convert_to_pwl!(participants)

Converts generator offer bands (each containing a quantity and price) to Piecewise Linear functions
"""
function gen_convert_to_pwl!(participants::DataFrame)
    # calculate breakpoints using cummulative sum of bands.

    breakpoint_MW1 = participants.BANDAVAIL1
    breakpoint_MW2 = breakpoint_MW1 + participants.BANDAVAIL2
    breakpoint_MW3 = breakpoint_MW2 + participants.BANDAVAIL3
    breakpoint_MW4 = breakpoint_MW3 + participants.BANDAVAIL4
    breakpoint_MW5 = breakpoint_MW4 + participants.BANDAVAIL5
    breakpoint_MW6 = breakpoint_MW5 + participants.BANDAVAIL6
    breakpoint_MW7 = breakpoint_MW6 + participants.BANDAVAIL7
    breakpoint_MW8 = breakpoint_MW7 + participants.BANDAVAIL8
    breakpoint_MW9 = breakpoint_MW8 + participants.BANDAVAIL9
    breakpoint_MW10 = breakpoint_MW9 + participants.BANDAVAIL10

    # find the midpoint between consecutive breakpoints.

    participants.midpoint_MW1 = 0.0 .+ ((breakpoint_MW1 .- 0.0) / 2)
    participants.midpoint_MW2 = breakpoint_MW1 + ((breakpoint_MW2 - breakpoint_MW1) / 2)
    participants.midpoint_MW3 = breakpoint_MW2 + ((breakpoint_MW3 - breakpoint_MW2) / 2)
    participants.midpoint_MW4 = breakpoint_MW3 + ((breakpoint_MW4 - breakpoint_MW3) / 2)
    participants.midpoint_MW5 = breakpoint_MW4 + ((breakpoint_MW5 - breakpoint_MW4) / 2)
    participants.midpoint_MW6 = breakpoint_MW5 + ((breakpoint_MW6 - breakpoint_MW5) / 2)
    participants.midpoint_MW7 = breakpoint_MW6 + ((breakpoint_MW7 - breakpoint_MW6) / 2)
    participants.midpoint_MW8 = breakpoint_MW7 + ((breakpoint_MW8 - breakpoint_MW7) / 2)
    participants.midpoint_MW9 = breakpoint_MW8 + ((breakpoint_MW9 - breakpoint_MW8) / 2)
    participants.midpoint_MW10 = breakpoint_MW9 + ((breakpoint_MW10 - breakpoint_MW9) / 2)

    # If availability bands are zero, the cost curve will be vertical and the slope
    # will be Inf which causes errors. If an availability band is zero, take the previous
    # band's price. This will cause duplicate breakpoints which can easily be handled
    # by the PowerModels calc_pwl_points function.

    transform!(participants, [:PRICEBAND1, :PRICEBAND2, :BANDAVAIL2] => ByRow((p1, p2, mw) -> coalesce(mw, 0) == 0.0 ? p1 : p2) => :PRICEBAND2)
    transform!(participants, [:PRICEBAND2, :PRICEBAND3, :BANDAVAIL3] => ByRow((p1, p2, mw) -> coalesce(mw, 0) == 0.0 ? p1 : p2) => :PRICEBAND3)
    transform!(participants, [:PRICEBAND3, :PRICEBAND4, :BANDAVAIL4] => ByRow((p1, p2, mw) -> coalesce(mw, 0) == 0.0 ? p1 : p2) => :PRICEBAND4)
    transform!(participants, [:PRICEBAND4, :PRICEBAND5, :BANDAVAIL5] => ByRow((p1, p2, mw) -> coalesce(mw, 0) == 0.0 ? p1 : p2) => :PRICEBAND5)
    transform!(participants, [:PRICEBAND5, :PRICEBAND6, :BANDAVAIL6] => ByRow((p1, p2, mw) -> coalesce(mw, 0) == 0.0 ? p1 : p2) => :PRICEBAND6)
    transform!(participants, [:PRICEBAND6, :PRICEBAND7, :BANDAVAIL7] => ByRow((p1, p2, mw) -> coalesce(mw, 0) == 0.0 ? p1 : p2) => :PRICEBAND7)
    transform!(participants, [:PRICEBAND7, :PRICEBAND8, :BANDAVAIL8] => ByRow((p1, p2, mw) -> coalesce(mw, 0) == 0.0 ? p1 : p2) => :PRICEBAND8)
    transform!(participants, [:PRICEBAND8, :PRICEBAND9, :BANDAVAIL9] => ByRow((p1, p2, mw) -> coalesce(mw, 0) == 0.0 ? p1 : p2) => :PRICEBAND9)
    transform!(participants, [:PRICEBAND9, :PRICEBAND10, :BANDAVAIL10] => ByRow((p1, p2, mw) -> coalesce(mw, 0) == 0.0 ? p1 : p2) => :PRICEBAND10)
end

"""
    load_convert_to_pwl!(participants)

Converts load bid bands (each containing a quantity and price) to Piecewise Linear functions
"""
function load_convert_to_pwl!(participants::DataFrame)
    # calculate breakpoints using cummulative sum of bands.

    breakpoint_MW1 = participants.BANDAVAIL10
    breakpoint_MW2 = breakpoint_MW1 + participants.BANDAVAIL9
    breakpoint_MW3 = breakpoint_MW2 + participants.BANDAVAIL8
    breakpoint_MW4 = breakpoint_MW3 + participants.BANDAVAIL7
    breakpoint_MW5 = breakpoint_MW4 + participants.BANDAVAIL6
    breakpoint_MW6 = breakpoint_MW5 + participants.BANDAVAIL5
    breakpoint_MW7 = breakpoint_MW6 + participants.BANDAVAIL4
    breakpoint_MW8 = breakpoint_MW7 + participants.BANDAVAIL3
    breakpoint_MW9 = breakpoint_MW8 + participants.BANDAVAIL2
    breakpoint_MW10 = breakpoint_MW9 + participants.BANDAVAIL1

    # find the midpoint between consecutive breakpoints.

    participants.midpoint_MW1 = 0.0 .+ ((breakpoint_MW1 .- 0.0) / 2)
    participants.midpoint_MW2 = breakpoint_MW1 + ((breakpoint_MW2 - breakpoint_MW1) / 2)
    participants.midpoint_MW3 = breakpoint_MW2 + ((breakpoint_MW3 - breakpoint_MW2) / 2)
    participants.midpoint_MW4 = breakpoint_MW3 + ((breakpoint_MW4 - breakpoint_MW3) / 2)
    participants.midpoint_MW5 = breakpoint_MW4 + ((breakpoint_MW5 - breakpoint_MW4) / 2)
    participants.midpoint_MW6 = breakpoint_MW5 + ((breakpoint_MW6 - breakpoint_MW5) / 2)
    participants.midpoint_MW7 = breakpoint_MW6 + ((breakpoint_MW7 - breakpoint_MW6) / 2)
    participants.midpoint_MW8 = breakpoint_MW7 + ((breakpoint_MW8 - breakpoint_MW7) / 2)
    participants.midpoint_MW9 = breakpoint_MW8 + ((breakpoint_MW9 - breakpoint_MW8) / 2)
    participants.midpoint_MW10 = breakpoint_MW9 + ((breakpoint_MW10 - breakpoint_MW9) / 2)

    # If availability bands are zero, the cost curve will be vertical and the slope
    # will be Inf which causes errors. If an availability band is zero, take the previous
    # band's price. This will cause duplicate breakpoints which can easily be handled
    # by the PowerModels calc_pwl_points function.

    transform!(participants, [:PRICEBAND10, :PRICEBAND9, :BANDAVAIL9] => ByRow((p1, p2, mw) -> coalesce(mw, 0) == 0.0 ? p1 : p2) => :PRICEBAND9)
    transform!(participants, [:PRICEBAND9, :PRICEBAND8, :BANDAVAIL8] => ByRow((p1, p2, mw) -> coalesce(mw, 0) == 0.0 ? p1 : p2) => :PRICEBAND8)
    transform!(participants, [:PRICEBAND8, :PRICEBAND7, :BANDAVAIL7] => ByRow((p1, p2, mw) -> coalesce(mw, 0) == 0.0 ? p1 : p2) => :PRICEBAND7)
    transform!(participants, [:PRICEBAND7, :PRICEBAND6, :BANDAVAIL6] => ByRow((p1, p2, mw) -> coalesce(mw, 0) == 0.0 ? p1 : p2) => :PRICEBAND6)
    transform!(participants, [:PRICEBAND6, :PRICEBAND5, :BANDAVAIL5] => ByRow((p1, p2, mw) -> coalesce(mw, 0) == 0.0 ? p1 : p2) => :PRICEBAND5)
    transform!(participants, [:PRICEBAND5, :PRICEBAND4, :BANDAVAIL4] => ByRow((p1, p2, mw) -> coalesce(mw, 0) == 0.0 ? p1 : p2) => :PRICEBAND4)
    transform!(participants, [:PRICEBAND4, :PRICEBAND3, :BANDAVAIL3] => ByRow((p1, p2, mw) -> coalesce(mw, 0) == 0.0 ? p1 : p2) => :PRICEBAND3)
    transform!(participants, [:PRICEBAND3, :PRICEBAND2, :BANDAVAIL2] => ByRow((p1, p2, mw) -> coalesce(mw, 0) == 0.0 ? p1 : p2) => :PRICEBAND2)
    transform!(participants, [:PRICEBAND2, :PRICEBAND1, :BANDAVAIL1] => ByRow((p1, p2, mw) -> coalesce(mw, 0) == 0.0 ? p1 : p2) => :PRICEBAND1)
end

"""
    export_gen_cost(participants, scenario)

Generates a file in MatPower case format containing the generator cost data.
"""
function export_gen_cost(participants::DataFrame, scenario::String;
                         dir::AbstractString = MARKET_DATA_DIR[])
    cost_pwl(participant) = """
    1\t\
    $(coalesce(participant.startup, 0))\t\
    $(coalesce(participant.shutdown, 0))\t\
    10\t\
    $(coalesce(participant.midpoint_MW1, 0))\t\
    $(coalesce(participant.PRICEBAND1, 0))\t\
    $(coalesce(participant.midpoint_MW2, 0))\t\
    $(coalesce(participant.PRICEBAND2, 0))\t\
    $(coalesce(participant.midpoint_MW3, 0))\t\
    $(coalesce(participant.PRICEBAND3, 0))\t\
    $(coalesce(participant.midpoint_MW4, 0))\t\
    $(coalesce(participant.PRICEBAND4, 0))\t\
    $(coalesce(participant.midpoint_MW5, 0))\t\
    $(coalesce(participant.PRICEBAND5, 0))\t\
    $(coalesce(participant.midpoint_MW6, 0))\t\
    $(coalesce(participant.PRICEBAND6, 0))\t\
    $(coalesce(participant.midpoint_MW7, 0))\t\
    $(coalesce(participant.PRICEBAND7, 0))\t\
    $(coalesce(participant.midpoint_MW8, 0))\t\
    $(coalesce(participant.PRICEBAND8, 0))\t\
    $(coalesce(participant.midpoint_MW9, 0))\t\
    $(coalesce(participant.PRICEBAND9, 0))\t\
    $(coalesce(participant.midpoint_MW10, 0))\t\
    $(coalesce(participant.PRICEBAND10, 0));\
    """

    lines = cost_pwl.(eachrow(participants))

    template = """
    %%-----  OPF Data  -----%%
    %% cost data
    %    1    startup    shutdown    n    x1    y1    ...    xn    yn
    %    2    startup    shutdown    n    c(n-1)    ...    c0
    mpc.gencost = [
    $(join(lines, "\n"))
    ];
    """

    open(joinpath(dir, scenario, "gencost.m"), "w+") do io
        print(io, template)
    end
end

"""
    export_load_data(participants, scenario)

Generates a file in MatPower case format containing the load limits and cost data.
"""
function export_load_data(participants::DataFrame, scenario::String;
                          dir::AbstractString = MARKET_DATA_DIR[])
    open(joinpath(dir, scenario, "loadcost.m"), "w+") do io
        export_load_limits(participants, io)
        println(io)
        export_load_cost(participants, io)
    end
end

"""
    export_load_cost(participants, io)

Generates data in MatPower case format containing the load costs.
"""
function export_load_cost(participants::DataFrame, io::IO)
    cost_pwl(participant) = """
    1\t\
    0\t\
    0\t\
    10\t\
    $(coalesce(participant.midpoint_MW1, 0))\t\
    $(coalesce(participant.PRICEBAND10, 0))\t\
    $(coalesce(participant.midpoint_MW2, 0))\t\
    $(coalesce(participant.PRICEBAND9, 0))\t\
    $(coalesce(participant.midpoint_MW3, 0))\t\
    $(coalesce(participant.PRICEBAND8, 0))\t\
    $(coalesce(participant.midpoint_MW4, 0))\t\
    $(coalesce(participant.PRICEBAND7, 0))\t\
    $(coalesce(participant.midpoint_MW5, 0))\t\
    $(coalesce(participant.PRICEBAND6, 0))\t\
    $(coalesce(participant.midpoint_MW6, 0))\t\
    $(coalesce(participant.PRICEBAND5, 0))\t\
    $(coalesce(participant.midpoint_MW7, 0))\t\
    $(coalesce(participant.PRICEBAND4, 0))\t\
    $(coalesce(participant.midpoint_MW8, 0))\t\
    $(coalesce(participant.PRICEBAND3, 0))\t\
    $(coalesce(participant.midpoint_MW9, 0))\t\
    $(coalesce(participant.PRICEBAND2, 0))\t\
    $(coalesce(participant.midpoint_MW10, 0))\t\
    $(coalesce(participant.PRICEBAND1, 0));\
    """

    lines = cost_pwl.(eachrow(participants))

    template = """
    %% load cost data
    %	1	startup	shutdown	n	x1	y1	...	xn	yn
    %	2	startup	shutdown	n	c(n-1)	...	c0
    mpc.loadcost = [
    $(join(lines, "\n"))
    ];
    """

    print(io, template)
end

"""
    export_load_limits(participants, io)

Generates data in MatPower case format containing the load power limits.
"""
function export_load_limits(participants::DataFrame, io::IO)
    participants = filter([:DUID] => x -> x != "", participants)

    limits(load) = """
    $(load.index)\t\
    $(load.MaxCap)\t\
    0;\
    """

    lines = limits.(eachrow(participants))

    template = """
    %% load limit data
    %column_names% 	bus	Pmax	Pmin
    mpc.load_limit = [
    $(join(lines, "\n"))
    ];
    """

    print(io, template)
end

"""
    export_fcas_data(scenario, gens, loads)

Generates a file in MatPower case format containing FCAS trapezium and cost data.
"""
function export_fcas_data(scenario::String, gens::DataFrame=DataFrame(),
                          loads::DataFrame=DataFrame();
                          dir::AbstractString = MARKET_DATA_DIR[])
    open(joinpath(dir, scenario, "fcas.m"), "w+") do io
        if nrow(gens) > 0
            export_gen_fcas_trapezium(gens, io)
            println(io)
            export_gen_fcas_cost(gens, io)
            println(io)
        end

        if nrow(loads) > 0       
            export_load_fcas_trapezium(loads, io)
            println(io)
            export_load_fcas_cost(loads, io)
            println(io)
        end

        export_fcas_target(io)
    end
end

"""
    export_gen_fcas_trapezium(gens, io)

Generates data in MatPower case format containing the generator FCAS trapezium.
"""
function export_gen_fcas_trapezium(gens::DataFrame, io::IO)
    trapezium(participant) = """
    $(participant.index)\t\
    $(fcas_services[participant.BIDTYPE].id)\t\
    $(coalesce(participant.ENABLEMENTMIN, 0))\t\
    $(coalesce(participant.LOWBREAKPOINT, 0))\t\
    $(coalesce(participant.HIGHBREAKPOINT, 0))\t\
    $(coalesce(participant.ENABLEMENTMAX, 0))\t\
    $(coalesce(participant.MAXAVAIL, 0));\
    """

    lines = trapezium.(eachrow(gens))

    template = """%% generator fcas trapezium
    % service (1=LReg, 2=RReg, 3=L1S, 4=R1S, 5=L6S, 6=R6S, 7=L60S, 8=R60S, 9=L5M, 10=R5M)
    %column_names%   gen  service emin    lb  ub  emax  amax
    mpc.fcas_gen = [
    $(join(lines, "\n"))     
    ];
    """

    print(io, template)
end

"""
    export_load_fcas_trapezium(loads, io)

Generates data in MatPower case format containing the load FCAS trapezium.
"""
function export_load_fcas_trapezium(loads::DataFrame, io::IO)
    trapezium(participant) = """
    $(participant.index)\t\
    $(fcas_services[participant.BIDTYPE].id)\t\
    $(coalesce(participant.ENABLEMENTMIN, 0))\t\
    $(coalesce(participant.LOWBREAKPOINT, 0))\t\
    $(coalesce(participant.HIGHBREAKPOINT, 0))\t\
    $(coalesce(participant.ENABLEMENTMAX, 0))\t\
    $(coalesce(participant.MAXAVAIL, 0));\
    """

    lines = trapezium.(eachrow(loads))

    template = """
    %% load fcas trapezium
    % service (1=RReg, 2=LReg, 3=L1S, 4=R1S, 5=L6S, 6=R6S, 7=L60S, 8=R60S, 9=L5M, 10=R5M)
    %column_names%   load  service emin    lb  ub  emax  amax
    mpc.fcas_load = [
    $(join(lines, "\n"))     
    ];
    """

    print(io, template)
end

"""
    export_gen_fcas_cost(participants, io)

Generates data in MatPower case format containing the generator FCAS costs.
"""
function export_gen_fcas_cost(participants::DataFrame, io::IO)
    cost_pwl(participant) = """
    $(participant.index)\t\
    $(fcas_services[participant.BIDTYPE].id)\t\
    10\t\
    $(coalesce(participant.midpoint_MW1, 0))\t\
    $(coalesce(participant.PRICEBAND1, 0))\t\
    $(coalesce(participant.midpoint_MW2, 0))\t\
    $(coalesce(participant.PRICEBAND2, 0))\t\
    $(coalesce(participant.midpoint_MW3, 0))\t\
    $(coalesce(participant.PRICEBAND3, 0))\t\
    $(coalesce(participant.midpoint_MW4, 0))\t\
    $(coalesce(participant.PRICEBAND4, 0))\t\
    $(coalesce(participant.midpoint_MW5, 0))\t\
    $(coalesce(participant.PRICEBAND5, 0))\t\
    $(coalesce(participant.midpoint_MW6, 0))\t\
    $(coalesce(participant.PRICEBAND6, 0))\t\
    $(coalesce(participant.midpoint_MW7, 0))\t\
    $(coalesce(participant.PRICEBAND7, 0))\t\
    $(coalesce(participant.midpoint_MW8, 0))\t\
    $(coalesce(participant.PRICEBAND8, 0))\t\
    $(coalesce(participant.midpoint_MW9, 0))\t\
    $(coalesce(participant.PRICEBAND9, 0))\t\
    $(coalesce(participant.midpoint_MW10, 0))\t\
    $(coalesce(participant.PRICEBAND10, 0));\
    """

    lines = cost_pwl.(eachrow(participants))

    template = """
    %% generator fcas cost
    % service (1=LReg, 2=RReg, 3=L1S, 4=R1S, 5=L6S, 6=R6S, 7=L60S, 8=R60S, 9=L5M, 10=R5M)
    %	gen    service n	x1	y1	...	xn	yn
    mpc.fcas_cost_gen = [
    $(join(lines, "\n"))
    ];
    """

    print(io, template)
end

"""
    export_load_fcas_cost(participants, io)

Generates data in MatPower case format containing the load FCAS costs.
"""
function export_load_fcas_cost(participants::DataFrame, io::IO)
    cost_pwl(participant) = """
    $(participant.index)\t\
    $(fcas_services[participant.BIDTYPE].id)\t\
    10\t\
    $(coalesce(participant.midpoint_MW1, 0))\t\
    $(coalesce(participant.PRICEBAND10, 0))\t\
    $(coalesce(participant.midpoint_MW2, 0))\t\
    $(coalesce(participant.PRICEBAND9, 0))\t\
    $(coalesce(participant.midpoint_MW3, 0))\t\
    $(coalesce(participant.PRICEBAND8, 0))\t\
    $(coalesce(participant.midpoint_MW4, 0))\t\
    $(coalesce(participant.PRICEBAND7, 0))\t\
    $(coalesce(participant.midpoint_MW5, 0))\t\
    $(coalesce(participant.PRICEBAND6, 0))\t\
    $(coalesce(participant.midpoint_MW6, 0))\t\
    $(coalesce(participant.PRICEBAND5, 0))\t\
    $(coalesce(participant.midpoint_MW7, 0))\t\
    $(coalesce(participant.PRICEBAND4, 0))\t\
    $(coalesce(participant.midpoint_MW8, 0))\t\
    $(coalesce(participant.PRICEBAND3, 0))\t\
    $(coalesce(participant.midpoint_MW9, 0))\t\
    $(coalesce(participant.PRICEBAND2, 0))\t\
    $(coalesce(participant.midpoint_MW10, 0))\t\
    $(coalesce(participant.PRICEBAND1, 0));\
    """

    lines = cost_pwl.(eachrow(participants))

    template = """
    %% load fcas cost
    %	load    service n	x1	y1	...	xn	yn
    mpc.fcas_cost_load = [
    $(join(lines, "\n"))
    ];
    """

    print(io, template)
end

"""
    export_fcas_target(io)

Generates data in MatPower case format containing the FCAS service targets.
"""
function export_fcas_target(io::IO)
    target(service) = """
    $(service)\t\
    0;\
    """

    lines = target.(1:10)

    template = """
    %% fcas targets
    % service (1=LReg, 2=RReg, 3=L1S, 4=R1S, 5=L6S, 6=R6S, 7=L60S, 8=R60S, 9=L5M, 10=R5M)
    %column_names%   service p
    mpc.fcas_target = [
    $(join(lines, "\n"))
    ];
    """

    print(io, template)
end

"""
    get_df_from_dict(data::Dict, columns::Vector{String}, mapping::Vector{Pair{String, String}}=Pair{String, String}[])

Creates a DataFrame from a dictionary

# Arguments
- `columns::Vector{String}`: dictionary keys to using in DataFrame
- `mapping::Vector{Pair{String, String}}`: maps a key in the dict to a new name in the DataFrame
"""
function get_df_from_dict(data::Dict, columns::Vector{String}, mapping::Vector{Pair{String, String}}=Pair{String, String}[])
    mapping_dict = Dict(mapping)
    df = [Dict([get(mapping_dict, key, key) => value for (key, value) in entry]) for (i, entry) in data]
    
    columns = append!(columns, values(mapping_dict))
    selected = filter.(p -> p[1] in columns, df)
    return DataFrame(selected)
end

# function create_multinetwork_model!(data, number_of_hours, g_series, l_series)

#     generator_contingencies = length(data["gen"])
#     tie_line_contingencies = length(data["tie_lines"]) 
#     converter_contingencies = length(data["convdc"]) 
#     dc_branch_contingencies = length(data["branchdc"]) 
#     number_of_contingencies = generator_contingencies + tie_line_contingencies + converter_contingencies +  dc_branch_contingencies + 1 # to also add the N case



#     # This for loop determines which "network" belongs to an hour, and which to a contingency, for book-keeping of the network ids
#     # Format: [h1, c1 ... cn, h2, c1 ... cn, .... , hn, c1 ... cn]
#     hour_ids = [];
#     cont_ids = [];
#     for i in 1:number_of_hours * number_of_contingencies
#         if mod(i, number_of_contingencies) == 1
#             push!(hour_ids, i)
#         else
#             push!(cont_ids, i)
#         end
#     end

#     ########### Using _IM.replicate networks

#     mn_data = _IM.replicate(data, number_of_hours * number_of_contingencies, Set{String}(["source_type", "name", "source_version", "per_unit"]))

#     # Add hour_ids and contingency_ids to the data dictionary 
#     mn_data["hour_ids"] = hour_ids
#     mn_data["cont_ids"] = cont_ids
#     mn_data["number_of_hours"] = number_of_hours
#     mn_data["number_of_contingencies"] = number_of_contingencies

#     create_contingencies!(mn_data, number_of_hours, number_of_contingencies)

#     # This loop writes the generation and demand time series data
#     iter = 0
#     for nw = 1:number_of_hours * number_of_contingencies
#         if mod(nw, number_of_contingencies) == 1
#             iter += 1
#             h_idx = Int(nw - number_of_contingencies + 1)
#         end
#         h_idx = iter
#         for (g, gen) in mn_data["nw"]["$nw"]["gen"]
#             if gen["res"] == true
#                 gen["pmax"] = g_series[h_idx] * gen["pmax"]
#             end
#         end
#         for (l, load) in mn_data["nw"]["$nw"]["load"]
#             load["pd"] = l_series[h_idx] * load["pd"]
#         end
#     end

#     _PMACDC.process_additional_data!(mn_data)




#     return mn_data
# end

function get_previous_hour_network_id(pm::_PM.AbstractPowerModel, nw::Int)
    number_of_contingencies = pm.ref[:it][:pm][:number_of_contingencies]

    if number_of_contingencies == 0
        previous_hour_id = Int((nw - 1))
        previous_hour_network = pm.ref[:it][:pm][:hour_ids][previous_hour_id]
    else
        previous_hour_id = Int((nw - 1) / number_of_contingencies)
        previous_hour_network = pm.ref[:it][:pm][:hour_ids][previous_hour_id]
    end

    return previous_hour_network
end


function generate_n_1_branch_contingencies(data::Dict{String, Any}, min_base_kv::Int, tranformer::Bool=false)
    branch_for_cont = Dict{String, Any}()

    for (i, branch1) in data["branch"]
        if branch1["name"][1] != 'x' || !tranformer == false
            if data["bus"]["$(branch1["f_bus"])"]["base_kv"] >= min_base_kv || data["bus"]["$(branch1["t_bus"])"]["base_kv"] > min_base_kv
                for (j, branch2) in data["branch"]
                    if branch1["f_bus"] == branch2["f_bus"] && branch1["t_bus"] == branch2["t_bus"] && branch1["index"] != branch2["index"]
                        branch_for_cont[i] = branch1
                    end
                end
            end
        end
    end
    branch_contingencies = Vector{Any}(undef, length(branch_for_cont))
    n = 1
    for (i, br) in branch_for_cont
        branch_contingencies[n] = (idx = br["index"], label = br["name"], type = "branch")
        n +=1
    end

    return branch_contingencies

end

function update_fcas!(data, solution)
    for (i, gen) in solution["gen"]
        if haskey(gen, "gen_L5M")
            data["gen"][i]["gen_L5M"] = gen["gen_L5M"]
            data["gen"][i]["gen_L5M_cost"] = gen["gen_L5M_cost"]
        else
            data["gen"][i]["gen_L5M"] = 0.0
            data["gen"][i]["gen_L5M_cost"] = 0.0
        end
    
        if haskey(gen, "gen_R5M")
            data["gen"][i]["gen_R5M"] = gen["gen_R5M"]
            data["gen"][i]["gen_R5M_cost"] = gen["gen_R5M_cost"]
        else
            data["gen"][i]["gen_R5M"] = 0.0
            data["gen"][i]["gen_R5M_cost"] = 0.0
        end
    
        if haskey(gen, "gen_L6S")
            data["gen"][i]["gen_L6S"] = gen["gen_L6S"]
            data["gen"][i]["gen_L6S_cost"] = gen["gen_L6S_cost"]
        else
            data["gen"][i]["gen_L6S"] = 0.0
            data["gen"][i]["gen_L6S_cost"] = 0.0
        end
        
        if haskey(gen, "gen_R6S")
            data["gen"][i]["gen_R6S"] = gen["gen_R6S"]
            data["gen"][i]["gen_R6S_cost"] = gen["gen_R6S_cost"]
        else
            data["gen"][i]["gen_R6S"] = 0.0
            data["gen"][i]["gen_R6S_cost"] = 0.0
        end
    
        if haskey(gen, "gen_L60S")
            data["gen"][i]["gen_L60S"] = gen["gen_L60S"]
            data["gen"][i]["gen_L60S_cost"] = gen["gen_L60S_cost"]
        else
            data["gen"][i]["gen_L60S"] = 0.0
            data["gen"][i]["gen_L60S_cost"] = 0.0 
        end
    
        if haskey(gen, "gen_R60S")
            data["gen"][i]["gen_R60S"] = gen["gen_R60S"]
            data["gen"][i]["gen_R60S_cost"] = gen["gen_R60S_cost"]
        else
            data["gen"][i]["gen_R60S"] = 0.0
            data["gen"][i]["gen_R60S_cost"] = 0.0
        end
    
        if haskey(gen, "gen_LReg")
            data["gen"][i]["gen_LReg"] = gen["gen_LReg"]
            data["gen"][i]["gen_LReg_cost"] = gen["gen_LReg_cost"]
        else
            data["gen"][i]["gen_LReg"] = 0.0
            data["gen"][i]["gen_LReg_cost"] = 0.0
        end
    
        if haskey(gen, "gen_RReg")
            data["gen"][i]["gen_RReg"] = gen["gen_RReg"]
            data["gen"][i]["gen_RReg_cost"] = gen["gen_RReg_cost"]
        else
            data["gen"][i]["gen_RReg"] = 0.0
            data["gen"][i]["gen_RReg_cost"] = 0.0
        end
    
        if haskey(gen, "gen_L1S")
            data["gen"][i]["gen_L1S"] = gen["gen_L1S"]
            data["gen"][i]["gen_L1S_cost"] = gen["gen_L1S_cost"]
        else
            data["gen"][i]["gen_L1S"] = 0.0
            data["gen"][i]["gen_L1S_cost"] = 0.0
        end
        
        if haskey(gen, "gen_R1S")
            data["gen"][i]["gen_R1S"] = gen["gen_R1S"]
            data["gen"][i]["gen_R1S_cost"] = gen["gen_R1S_cost"]
        else
            data["gen"][i]["gen_R1S"] = 0.0
            data["gen"][i]["gen_R1S_cost"] = 0.0
        end
    end
    
    for (i, load) in data["load"]
        if haskey(solution["load"], i) && haskey(solution["load"][i], "load_L5M")
            load["load_L5M"] = solution["load"][i]["load_L5M"]
            load["load_L5M_cost"] = solution["load"][i]["load_L5M_cost"]
        end
        if !haskey(solution["load"], i) || !haskey(solution["load"][i], "load_L5M")
            load["load_L5M"] = 0.0
            load["load_L5M_cost"] = 0.0
        end
    
        if haskey(solution["load"], i) && haskey(solution["load"][i], "load_R5M")
            load["load_R5M"] = solution["load"][i]["gen_R5M"]
            load["load_R5M_cost"] = solution["load"][i]["load_R5M_cost"]
        end
        if !haskey(solution["load"], i) || !haskey(solution["load"][i], "load_R5M")
            load["load_R5M"] = 0.0
            load["load_R5M_cost"] = 0.0
        end
    
        if haskey(solution["load"], i) && haskey(solution["load"][i], "load_L6S")
            load["load_L6S"] = solution["load"][i]["load_L6S"]
            load["load_L6S_cost"] = solution["load"][i]["load_L6S_cost"]
        end
        if !haskey(solution["load"], i) || !haskey(solution["load"][i], "load_L6S")
            load["load_L6S"] = 0.0
            load["load_L6S_cost"] = 0.0
        end
        
        if haskey(solution["load"], i) && haskey(solution["load"][i], "load_R6S")
            load["load_R6S"] = solution["load"][i]["load_R6S"]
            load["load_R6S_cost"] = solution["load"][i]["load_R6S_cost"]
        end
        if !haskey(solution["load"], i) || !haskey(solution["load"][i], "load_R6S")
            load["load_R6S"] = 0.0
            load["load_R6S_cost"] = 0.0
        end
    
        if haskey(solution["load"], i) && haskey(solution["load"][i], "load_L60S")
            load["load_L60S"] = solution["load"][i]["load_L60S"]
            load["load_L60S_cost"] = solution["load"][i]["load_L60S_cost"]
        end
        if !haskey(solution["load"], i) || !haskey(solution["load"][i], "load_L60S")
            load["load_L60S"] = 0.0
            load["load_L60S_cost"] = 0.0 
        end
    
        if haskey(solution["load"], i) && haskey(solution["load"][i], "load_R60S")
            load["load_R60S"] = solution["load"][i]["load_R60S"]
            load["load_R60S_cost"] = solution["load"][i]["load_R60S_cost"]
        end
        if !haskey(solution["load"], i) || !haskey(solution["load"][i], "load_R60S")
            load["load_R60S"] = 0.0
            load["load_R60S_cost"] = 0.0
        end
    
        if haskey(solution["load"], i) && haskey(solution["load"][i], "load_LReg")
            load["load_LReg"] = solution["load"][i]["load_LReg"]
            load["load_LReg_cost"] = solution["load"][i]["load_LReg_cost"]
        end
        if !haskey(solution["load"], i) || !haskey(solution["load"][i], "load_LReg")
            load["load_LReg"] = 0.0
            load["load_LReg_cost"] = 0.0
        end
    
        if haskey(solution["load"], i) && haskey(solution["load"][i], "load_RReg")
            load["load_RReg"] = solution["load"][i]["load_RReg"]
            load["load_RReg_cost"] = solution["load"][i]["load_RReg_cost"]
        end
        if !haskey(solution["load"], i) || !haskey(solution["load"][i], "load_RReg")
            load["load_RReg"] = 0.0
            load["load_RReg_cost"] = 0.0
        end
    
        if haskey(solution["load"], i) && haskey(solution["load"][i], "load_L1S")
            load["load_L1S"] = solution["load"][i]["load_L1S"]
            load["load_L1S_cost"] = solution["load"][i]["load_L1S_cost"]
        end
        if !haskey(solution["load"], i) || !haskey(solution["load"][i], "load_L1S")
            load["load_L1S"] = 0.0
            load["load_L1S_cost"] = 0.0
        end
        
        if haskey(solution["load"], i) && haskey(solution["load"][i], "load_R1S")
            load["load_R1S"] = solution["load"][i]["load_R1S"]
            load["load_R1S_cost"] = solution["load"][i]["load_R1S_cost"]
        end
        if !haskey(solution["load"], i) || !haskey(solution["load"][i], "load_R1S")
            load["load_R1S"] = 0.0
            load["load_R1S_cost"] = 0.0
        end
    end
    return data
end



"""
cleans up raw pwl cost points in preparation for building a mathamatical model.

The key mathematical properties,
- the first and last points are strictly outside of the pmin-to-pmax range
- pmin and pmax occur in the first and last line segments.
"""
function calc_pwl_points(ncost::Int, cost::Vector{<:Real}, pmin::Real, pmax::Real, price_cap; tolerance=1e-2)
    @assert ncost >= 1 && length(cost) >= 2
    @assert 2*ncost == length(cost)
    @assert pmin <= pmax

    if isinf(pmin) || isinf(pmax)
        Memento.error(_LOGGER, "a bounded operating range is required for modeling pwl costs.  Given active power range in $(pmin) - $(pmax)")
    end

    points = []
    for i in 1:ncost
        push!(points, (mw=cost[2*i-1], cost=cost[2*i]))
    end

    first_active = 0
    for i in 1:(ncost-1)
        #mw_0 = points[i].mw
        mw_1 = points[i+1].mw
        first_active = i
        if pmin <= mw_1
            break
        end
    end

    last_active = 0
    for i in 1:(ncost-1)
        mw_0 = points[end - i].mw
        #mw_1 = points[end - i + 1].mw
        last_active = ncost - i + 1
        if pmax >= mw_0
            break
        end
    end

    points = points[first_active : last_active]


    x1 = points[1].mw
    y1 = points[1].cost
    x2 = points[2].mw
    y2 = points[2].cost

    if x1 > pmin
        x0 = pmin - tolerance

        m = (y2 - y1)/(x2 - x1)

        if !isnan(m)
            y0 = y2 - m*(x2 - x0)
            points[1] = (mw=x0, cost=y0)
        else
            points[1] = (mw=x0, cost=y1)
        end

        modified = true
    end


    x1 = points[end-1].mw
    y1 = points[end-1].cost
    x2 = points[end].mw
    y2 = points[end].cost

    if x2 < pmax
        x3 = pmax + tolerance

        m = (y2 - y1)/(x2 - x1)

        if !isnan(m)
            y3 = m*(x3 - x1) + y1
            if y3 < price_cap
                points[end] = (mw=x3, cost=y3)
            else
                points[end] = (mw=x3, cost=y2)
            end
        else
            points[end] = (mw=x3, cost=y2)
        end
    end

    return points
end


function add_area_gens!(data)
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

    return data
end