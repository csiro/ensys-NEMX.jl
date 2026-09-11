# =============================================================================
# demand.jl
#
# Julia port of `nempy.historical_inputs.demand.DemandData`.
#
# AEMO's "operational demand" for a region (the RHS of the regional energy
# balance) is simply DISPATCHREGIONSUM.TOTALDEMAND — verified against nempy's
# demand._format_regional_demand, where `demand = TOTALDEMAND`.
#
# DEMANDFORECAST is NOT added to demand; nempy only uses it (with INITIALSUPPLY)
# to form `loss_function_demand` for the interconnector loss model. Adding it to
# demand — as an earlier version of this port did — biases the energy balance.
# =============================================================================

"""
    DemandData(loader::RawInputsLoader)

Reads regional demand for the current interval. Mirrors `demand.DemandData`.
"""
mutable struct DemandData
    loader::RawInputsLoader
    df::DataFrame
end

function DemandData(loader::RawInputsLoader)
    raw = _mms(loader, "DISPATCHREGIONSUM")
    if isempty(raw)
        return DemandData(loader, DataFrame(region=String[], demand=Float64[]))
    end
    total = _to_float.(raw.TOTALDEMAND)
    df = DataFrame(
        region = string.(raw.REGIONID),
        # Operational demand the spot market must balance = TOTALDEMAND (only).
        demand = coalesce.(total, 0.0),
    )
    return DemandData(loader, df)
end

"""
    get_operational_demand(d::DemandData) -> DataFrame

Return `region, demand` (MW) for the current interval. Mirrors
`get_operational_demand`.
"""
get_operational_demand(d::DemandData) = d.df
