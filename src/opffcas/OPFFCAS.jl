"""
    NEMX.OPFFCAS

Optimal power flow with co-optimised frequency control ancillary services, on
AC/DC networks.

Where `NEMX.ZBenchmark` and `NEMX.NBenchmark` reconstruct an
existing market's dispatch from published data, this submodule is a *modelling*
library: it extends PowerModels and PowerModelsACDC with the variables,
constraints and objectives needed to co-optimise energy and the eight-to-ten
FCAS products against a network model, across several power-flow formulations
and a branch-flow (`bf`) family suitable for distribution-style cases.

# Layout

| Folder  | Contents                                                        |
|:--------|:----------------------------------------------------------------|
| `core/` | Model types, variable and constraint declarations, constraint templates, objectives, and the data layer that reads NEM market CSVs into a PowerModels case |
| `form/` | Formulation-specific method definitions — `acp`, `dcp`, `lpac`, `ivr`, `bf`, `wr`, and cross-formulation `shared` |
| `prob/` | Problem builders: `opfcas`, `opfcas_bf`, `opfcas_ivr`, `mn_opfcas` (multi-network) |
| `itr/`  | Iterative drivers built on those problems |
| `eval/` | Post-solve evaluation, including contingency checking |
| `util/` | Small helpers (solution selection, shift-factor evaluation) |
| `vis/`  | PlotlyJS result plotting |
| `scopf/`| Security-constrained variants — **not loaded by default**, see below |

# Model types

`CPPowerModel` and the `FCASService` type hierarchy (`FCASRegulatingService`,
`FCASContingencyService`) are declared in `core/types.jl`. Problem builders
follow the PowerModels convention: `build_*` assembles a model on a `pm` object,
`run_*`/`solve_*` wraps building and solving.

# Optional: security-constrained problems

`prob/scopfcas_bf.jl`, `itr/scopfcas_bf_itr.jl` and `eval/scopf_cont_check.jl`
depend on `PowerModelsACDCsecurityconstrained`, which is not in Julia's General
registry. They are therefore kept in `scopf/` and are **not** included when the
package loads, so that `Pkg.add("NEMX")` and `Pkg.test("NEMX")` work with
registered dependencies only.

To use them, install that package into your environment and call:

```julia
using NEMX, PowerModelsACDCsecurityconstrained
NEMX.OPFFCAS.load_security_constrained!()
```

which evaluates the three files into this module. The call throws with an
explanatory message if the dependency is absent, and is a no-op if the files
have already been loaded.
"""
module OPFFCAS

import InfrastructureModels
import JuMP
import Memento
import PowerModels
import PowerModelsACDC
import PowerModelsSecurityConstrained

using CSV
using DataFrames
using DataFramesMeta
using Dates
using PlotlyJS
using Statistics

const _IM = InfrastructureModels
const _PM = PowerModels
const _PMACDC = PowerModelsACDC
const _PMSC = PowerModelsSecurityConstrained

# Memento logger for this submodule. Assigned in `__init__` rather than at
# top level because `Memento.getlogger` registers into a global registry, which
# must not happen during precompilation.
_LOGGER = Memento.getlogger(@__MODULE__)

function __init__()
    global _LOGGER = Memento.getlogger(@__MODULE__)
    return nothing
end

# ---------------------------------------------------------------------------
# Core: types, variables, constraints, objectives, data.
# ---------------------------------------------------------------------------
include("core/types.jl")
include("core/variable.jl")
include("core/constraint_template.jl")
include("core/constraint.jl")
include("core/objective.jl")
include("core/data.jl")

# ---------------------------------------------------------------------------
# Formulation-specific methods.
# ---------------------------------------------------------------------------
include("form/acp.jl")
include("form/dcp.jl")
include("form/lpac.jl")
include("form/shared.jl")
include("form/ivr.jl")
include("form/bf.jl")
include("form/wr.jl")

# ---------------------------------------------------------------------------
# Problem builders.
# ---------------------------------------------------------------------------
include("prob/opfcas.jl")
include("prob/opfcas_bf.jl")
include("prob/opfcas_ivr.jl")
include("prob/mn_opfcas.jl")

# ---------------------------------------------------------------------------
# Utilities and visualisation.
# ---------------------------------------------------------------------------
include("util/sf_eval.jl")
include("vis/opfcas.jl")
include("vis/results.jl")

"""
    load_security_constrained!() -> Bool

Load the security-constrained problem family into this module.

These problems depend on `PowerModelsACDCsecurityconstrained`, which is not in
the General registry, so they are not part of the default load path — see the
module docstring. This function evaluates them into `NEMX.OPFFCAS`, after which
`build_scopfcas_bf`, the iterative driver and the contingency checker are
available exactly as if they had always been included.

# Returns
`true` when the files are loaded (or were already loaded).

# Throws
`ErrorException` if `PowerModelsACDCsecurityconstrained` is not importable, with
a message naming the missing dependency.

# Example
```julia
using NEMX, PowerModelsACDCsecurityconstrained
NEMX.OPFFCAS.load_security_constrained!()
```
"""
function load_security_constrained!()
    isdefined(@__MODULE__, :_PMACDCsc) && return true

    pkg = Base.PkgId(Base.UUID("bf5a9aac-8200-4ea2-86f6-b4ae0f6a6384"),
                     "PowerModelsACDCsecurityconstrained")
    mod = try
        Base.require(pkg)
    catch err
        error("""
              The security-constrained problems need PowerModelsACDCsecurityconstrained,
              which is not in Julia's General registry and is not installed in this
              environment. Add it from its source repository, then call
              NEMX.OPFFCAS.load_security_constrained!() again.

              Underlying error: $(sprint(showerror, err))
              """)
    end

    @eval OPFFCAS const _PMACDCsc = $mod
    for f in ("scopf/scopfcas_bf.jl", "scopf/scopfcas_bf_itr.jl",
              "scopf/scopf_cont_check.jl")
        Base.include(@__MODULE__, joinpath(@__DIR__, f))
    end
    return true
end

end # module OPFFCAS
