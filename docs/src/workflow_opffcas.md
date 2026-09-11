# OPF with FCAS

`NEMX.OPFFCAS` is a modelling library rather than a reconstruction: it extends
PowerModels and PowerModelsACDC with the variables, constraints and objectives
needed to co-optimise energy against the frequency control ancillary services on
an AC/DC network.

## The sequence

Every problem starts the same way, and the order matters.

```julia
using NEMX, PowerModels, PowerModelsACDC, JuMP, HiGHS
const OF = NEMX.OPFFCAS

data = PowerModels.parse_file("data/snem2000_acdc_fixed.m";
                              validate = true, import_all = false)

OF.process_scenario_data!(data, "s1")     # 1. market data onto the case
PowerModelsACDC.process_additional_data!(data)  # 2. build the converter model
OF.add_area_gens!(data)                   # 3. generator sets per area

# 4. regional reference nodes, by bus id in this case
rrn = Dict("NSW" => "130", "VIC" => "1480", "QLD" => "1274",
           "SA" => "1643", "TAS" => "1123")
data["rrn"] = rrn
data["bus_rr"] = Dict{String,Any}(b => data["bus"][b] for (_, b) in rrn)
data["price_cap"] = 16600

setting = Dict("output" => Dict("branch_flows" => true, "duals" => true),
               "conv_losses_mp" => true, "mlf" => true)

result = OF.run_acdcopfcas(data, PowerModels.DCPPowerModel,
                           optimizer_with_attributes(HiGHS.Optimizer,
                                                     "output_flag" => false);
                           setting = setting)
```

Scenario data must be attached **before** `process_additional_data!` builds the
converter model, and the area-generator map **after** both. Getting this wrong
produces a model that builds and is wrong rather than one that fails.

Or run it as a script, which also builds the regional price tables and plots:

```bash
julia --project=. scripts/opffcas/run_opffcas.jl --scenario=s1
julia --project=. scripts/opffcas/run_opffcas.jl --scenario=s3 --nlp-solver=ipopt
```

## Problem builders

| Function | Formulation family |
|:---------|:-------------------|
| `run_acdcopfcas` / `build_acdcopfcas` | Polar AC, DC, LPAC and the relaxations |
| `run_acdcopfcas_ivr` / `build_acdcopfcas_ivr` | Rectangular current (IV) |
| `run_acdcopfcas_bf` / `build_acdcopfcas_bf` | Branch flow, for radial and distribution-style cases |
| `run_mn_acdcopfcas` / `build_mn_acdcopfcas` | Multi-network, for problems coupled across periods |

They follow PowerModels' convention: `build_*` assembles a model on a `pm`
object, `run_*` wraps building and solving.

## Market scenarios

A scenario is a directory of `.m` files overlaying market data on a network case.
Any of them may be absent, and an absent file is skipped rather than being an
error — a case with no FCAS data simply produces a model with no FCAS.

| File | Carries |
|:-----|:--------|
| `gencost.m` | Generator offer curves, ten bands |
| `loadcost.m` | Load offer curves |
| `fcas.m` | FCAS offers and enablement limits |
| `mlf.m` | Marginal loss factors by bus |

!!! note "The bundled scenarios carry no FCAS data"
    The three scenarios shipped for the tests (`s1`, `s2`, `s3`) contain
    `gencost.m` and `mlf.m` only. The FCAS variables and constraints are built
    but inactive, so those regression tests exercise the energy, AC/DC and
    cost-overlay paths rather than the co-optimisation itself. Supply a scenario
    with `fcas.m` to exercise the FCAS path.

### Building a scenario from raw AEMO data

```bash
julia --project=. scripts/opffcas/build_market_scenario.jl --scenario=s1 \
      --market-dir=/data/aemo/2025-09
```

reads `participants.csv`, `BIDPEROFFER.csv` and `BIDDAYOFFER.csv`, matches
participants to network generators and loads, converts offers to piecewise-linear
cost curves, and writes `gencost.m`, `loadcost.m` and `fcas.m`.

## Marginal loss factors

```bash
julia --project=. scripts/opffcas/compute_marginal_loss_factors.jl --scenario=s3
```

computes an MLF per bus by finite-differencing an AC power flow: inject a small
load at a bus, re-solve, read the change in slack generation at the region's
reference node. That is one power flow per bus — about 2000 of them — so it is an
hours-long run. Start with one region.

This script needs `PowerModelsACDCsecurityconstrained`, which is not in the
General registry; see [Installation](@ref).

## Reading FCAS prices back

The regional FCAS prices are shadow prices on the reference-node constraints:

```julia
pm = PowerModels.instantiate_model(data, PowerModels.DCPPowerModel,
        OF.build_acdcopfcas;
        ref_extensions = [PowerModelsACDC.add_ref_dcgrid!,
                          PowerModelsACDC.ref_add_gendc!],
        setting = setting)
JuMP.optimize!(pm.model)

for (_, b) in data["bus_rr"]
    b["lam_R6S"] = JuMP.shadow_price(pm.sol[:it][:pm][:nw][0][:bus_rr][b["index"]][:lam_R6S])
end
```

`ref_add_gendc!` is required alongside `add_ref_dcgrid!`. PowerModelsACDC folded
DC-generator references into `add_ref_dcgrid!` up to 0.8 and split them into
their own extension from 0.10; the builders call `variable_dcgenerator_power`,
which needs it. Omitting it gives `KeyError: :bus_gens_dc` at build time.

## Visualisation

`OF.plot_state_wide_prices`, `OF.create_price_table` and the rest of `vis/` build
PlotlyJS figures. They **return** the figure and only display it in an
interactive session, so a script can call them on a headless machine and save the
result:

```julia
fig = OF.plot_state_wide_prices(price_AC, price_DC, price_DC_MLF)
PlotlyJS.savefig(fig, "prices.pdf")
```

Set `NEMX_NO_DISPLAY=1` to suppress the attempt even when interactive.
