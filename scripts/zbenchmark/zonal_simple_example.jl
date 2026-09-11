# =============================================================================
# zonal_simple_example.jl
#
# The smallest complete NEMX example: two generators, one region, one dispatch.
#
# WHAT IT DOES
#   Builds a `SpotMarket` by hand, dispatches it, and prints the resulting unit
#   targets and regional price. No data is downloaded and no solver licence is
#   needed, so this runs anywhere the package installs — it is the first thing
#   to run after installing, to confirm the toolchain works.
#
# THE MARKET
#   Unit A offers  20 MW @ $50,  20 MW @ $60,   5 MW @ $100
#   Unit B offers  50 MW @ $50,  30 MW @ $55,  10 MW @ $80
#   NSW1 demand:  120 MW (by default)
#
#   Cheapest first: the two $50 bands (70 MW), then B's $55 band (30 MW), then
#   20 MW of A's $60 band. So A = 40 MW, B = 80 MW, and the price is $60/MWh —
#   the price of the band the last megawatt came from.
#
# ARGUMENTS
#   Positional          Env               Default   Meaning
#   ------------------  ----------------  --------  ----------------------------
#   1                   NEMX_DEMAND       120       Regional demand, MW
#
#   Options             Env               Default   Meaning
#   ------------------  ----------------  --------  ----------------------------
#   --solver=NAME       NEMX_SOLVER       highs     highs | ipopt | scs
#   --verbose-solver    NEMX_VERBOSE_SOLVER  off    Let the solver print
#
# RUN
#   julia --project=. scripts/zonal_simple_example.jl
#   julia --project=. scripts/zonal_simple_example.jl 130
#   julia --project=. scripts/zonal_simple_example.jl --solver=highs
# =============================================================================

using NEMX
using DataFrames
using JuMP

const ZB = NEMX.ZBenchmark

const DEMAND = script_number(script_positional(1, "NEMX_DEMAND", "120"))
const SOLVER_NAME = script_option("solver", "highs")

print_banner("Zonal benchmark — minimal example",
             "demand (MW)" => DEMAND,
             "solver" => SOLVER_NAME)

# The optimizer is a module-level setting on the market model rather than an
# argument to `dispatch!`, so it is set once here.
ZB.SOLVER_FACTORY[] = select_solver(SOLVER_NAME;
                                  silent = !script_flag("verbose-solver"))

"""
    bid_row(unit, service, values; dispatch_type = "generator")

One row of a ten-band offer table.

Every NEM offer carries exactly ten bands, whether or not the participant uses
them all. This pads a short list of band values with zeros so an example can
write out only the bands it cares about.
"""
function bid_row(unit, service, values; dispatch_type = "generator")
    padded = [i <= length(values) ? float(values[i]) : 0.0 for i in 1:ZB.N_BANDS]
    return (; unit, dispatch_type, service,
            (Symbol(string(i)) => padded[i] for i in 1:ZB.N_BANDS)...)
end

# --- Offers -----------------------------------------------------------------
volume_bids = DataFrame([bid_row("A", "energy", [20.0, 20.0, 5.0]),
                         bid_row("B", "energy", [50.0, 30.0, 10.0])])

price_bids = DataFrame([bid_row("A", "energy", [50.0, 60.0, 100.0]),
                        bid_row("B", "energy", [50.0, 55.0, 80.0])])

# --- Unit metadata ----------------------------------------------------------
# `loss_factor` is the combined transmission x distribution loss factor. At 1.0
# the connection point and the regional reference node are the same place, which
# keeps this example's arithmetic obvious.
unit_info = DataFrame(unit = ["A", "B"],
                      region = ["NSW1", "NSW1"],
                      dispatch_type = ["generator", "generator"],
                      loss_factor = [1.0, 1.0])

# --- Build, set, dispatch ---------------------------------------------------
market = ZB.SpotMarket(market_regions = ["NSW1"], unit_info = unit_info)
ZB.set_unit_volume_bids!(market, volume_bids)
ZB.set_unit_price_bids!(market, price_bids)
ZB.set_demand_constraints!(market, DataFrame(region = ["NSW1"], demand = [DEMAND]))

ZB.dispatch!(market)

# --- Results ----------------------------------------------------------------
println("Unit dispatch (MW):")
println(ZB.get_unit_dispatch(market))

println("\nRegional energy price (\$/MWh) — the dual of the demand balance:")
println(ZB.get_energy_prices(market))

println("\nLocal prices at each connection point:")
println(ZB.local_prices(market, unit_info)[:, [:unit, :region, :rrp,
                                               :adjustment, :local_price_cp]])
println("\nWith no binding network constraint the adjustment is zero and the ",
        "local\nprice is the regional price. See scripts/run_bess_event_study.jl ",
        "for the\ncase where it is not.")
