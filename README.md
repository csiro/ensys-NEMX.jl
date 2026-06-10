[![DOI](https://zenodo.org/badge/DOI/10.25919/v33w-8011.svg)](https://doi.org/10.25919/v33w-8011)

# NEMX.jl
 `NEMX.jl` is an [open source](https://github.com/csiro-internal/NEMX.jl/blob/main/LICENSE) package developed in [Julia](http://julialang.org/) using [JuMP](http://jump.dev/) based on [PowerModelsACDC.jl](https://github.com/Electa-Git/PowerModelsACDC.jl) that provides physics-based co-optimized electricity and frequency control ancillary services (FCAS) market clearing models for the Australian National Electricty Market (NEM) incorporating AC as well as HVDC network representation. The package uses the synthetic NEM system dataset [Synthetic-NEM-2000bus-Data](https://github.com/csiro-energy-systems/Synthetic-NEM-2000bus-Data). Some of the features of these models are listed as follows.

* Power and FCAS Bids in terms of price and quantity bands.
* FCAS trapizium constraints including enablement limits, bounds, and availability.
* Dispatchable loads particiaption in power and FCAS markets.
* Dispatchable bidirectional units such as storage systems and aggregators.
* Regional reference node spot pricing for power and FCAS.
* Power and FCAS unit power dispatch.
* Nodal locational marginal pricing (LMP).
* Marginal Loss Factor (MLF) modelling. 
* Regional FCAS targets.
* Transmission system and AC as well as HVDC interconnector flows.

The FCAS markets modelled in the `NEMX.jl` are as follows.


| Service Name         | Name Tag | Response Time Description                         |
|:--------------------:|:--------:|:-------------------------------------------------:|
| Regulation Raise     | RReg     | Minor frequency drop – primary frequency response |
| Regulation Lower     | LReg     | Minor frequency rise – primary frequency response |
| Very Fast Raise      | R1S      | Major frequency drop – 1s                         |
| Very Fast Lower      | L1S      | Major frequency rise – 1s                         |
| Fast Raise           | R6S      | Major frequency drop – 6s                         |
| Fast Lower           | L6S      | Major frequency rise – 6s                         |
| Slow Raise           | R60S     | Stabilise after major drop – 60s                  |
| Slow Lower           | L60S     | Stabilise after major rise – 60s                  |
| Delayed Raise        | R5M      | Return to normal operating band – 5m              |
| Delayed Lower        | L5M      | Return to normal operating band – 5m              |

The spot price regions in the NEMX.jl are as follows.

| Region Code | Region Name            |
|:-----------:|:----------------------:|
| area 1      | New South Wales (NSW)  |
| area 4      | Queensland (QLD)       |
| area 2      | Victoria (VIC)         |
| area 3      | South Australia (SA)   |
| area 5      | Tasmania (TAS)         |

## Formulations

The following [PowerModelsACDC.jl](https://github.com/Electa-Git/PowerModelsACDC.jl) formulations are available.

* ACPPowerModel
* IVRPowerModel
* DCPPowerModel

## Solver

`NEMX.jl` integrates with any [JuMP](https://jump.dev)-supported solver.
Reference benchmarks are provided for:

| Solver  | License     | Typical use                         |
|---------|-------------|-------------------------------------|
| HiGHS   | Open-source | LP / MILP, default reference solver |
| Gurobi  | Commercial  | Large-scale MILP, production runs   |
| Juniper | Open-Source | Large-scale MINLP, heuristic        |
| Ipopt   | Open-source | Continuous LP, NLP solves           |

Install your chosen solver via the corresponding Julia package
(`HiGHS.jl`, `Gurobi.jl`, `Juniper.jl`, `Ipopt.jl`) and configure it in your
run script.

## Usage

Clone the package and add it to your julia environment using: 

```julia
] develop https://github.com/csiro-internal/NEMX.jl
```

Add all dependencies, such as, PowerModels, PowerModelsACDC etc. using:

```julia
] add PowerModels
```

Make sure that your Julia registry is up to date. To detect and download the latest version of the packages use:

```julia
] update
```

## Contributors

* Ghulam Mohy ud din (CSIRO): Main developer
* Mark-Colquhoun (CSIRO): OPFCAS model and MLF calculation

## Citation
Mohy Ud Din, Ghulam; & Colquhoun, Mark (2025): NEMX.jl. CSIRO. v1. Software. https://doi.org/10.25919/v33w-8011


## License

`NEMX.jl` is distributed under the CSIRO Open Source Software Licence 
Agreement (BSD 3 Clause Licence), — see [LICENSE](LICENSE).

