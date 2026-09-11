# Citing NEMX

If NEMX contributes to published work, please cite it.

```bibtex
@software{nemx,
  author  = {Mohy ud Din, Ghulam},
  title   = {{NEMX.jl}: Market dispatch and network-constrained optimal power
             flow for the Australian National Electricity Market},
  year    = {2026},
  url     = {https://github.com/csiro/ensys-NEMX.jl},
  version = {0.2.0},
  note    = {Commonwealth Scientific and Industrial Research Organisation (CSIRO)}
}
```

The same entry is in `CITATION.bib` at the repository root.

## Please cite the work NEMX is built on

NEMX would not exist without these, and their authors deserve the citation as
much as this package does.

The zonal reconstruction follows the modelling approach of **nempy**:

```bibtex
@article{gorman2022nempy,
  author  = {Gorman, Nicholas and Bruce, Anna and MacGill, Iain},
  title   = {nempy: A {Python} package for modelling the {Australian National
             Electricity Market} dispatch procedure},
  journal = {SoftwareX},
  volume  = {17},
  pages   = {100895},
  year    = {2022},
  doi     = {10.1016/j.softx.2021.100895}
}
```

The network layer is built on **PowerModels.jl**:

```bibtex
@inproceedings{coffrin2018powermodels,
  author    = {Coffrin, Carleton and Bent, Russell and Sundar, Kaarthik and
               Ng, Yeesian and Lubin, Miles},
  title     = {{PowerModels.jl}: An Open-Source Framework for Exploring Power
               Flow Formulations},
  booktitle = {Power Systems Computation Conference (PSCC)},
  year      = {2018},
  doi       = {10.23919/PSCC.2018.8442948}
}
```

and, for the AC/DC problems, on **PowerModelsACDC.jl**:

```bibtex
@article{ergun2019pmacdc,
  author  = {Ergun, Hakan and Dave, Jay and Van Hertem, Dirk and Geth, Frederik},
  title   = {Optimal Power Flow for {AC--DC} Grids: Formulation, Convex
             Relaxation, Linear Approximation, and Implementation},
  journal = {IEEE Transactions on Power Systems},
  volume  = {34},
  number  = {4},
  pages   = {2980--2990},
  year    = {2019},
  doi     = {10.1109/TPWRS.2019.2897835}
}
```

## Data

Market data is AEMO's, published through the NEMWeb portal. Cite AEMO as the
source of any market data underlying a result, and state the period used — the
data is revised, so a result is reproducible only against a stated vintage.

The synthetic 2000-bus network is a public synthetic case for the NEM and is not
AEMO data. See the warning in [Market data](@ref) about what it is and is not.
