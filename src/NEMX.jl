"""
    NEMX

Market dispatch and network-constrained optimal power flow for the Australian
National Electricity Market.

`NEMX` bundles three related but independently usable model families under one
package. They share a data layer and a set of conventions, and they are
deliberately kept as separate submodules so that a name defined for one cannot
silently collide with a name defined for another.

| Submodule | Folder | What it does |
|:----------|:-------|:-------------|
| `NEMX.ZBenchmark` | `src/zbenchmark/` | Zonal (copper-plate) reconstruction of the five-minute NEM dispatch from published AEMO data. Downloads the MMS tables and NEMDE case files, assembles a single-interval LP, and recovers regional energy and FCAS prices as its duals. |
| `NEMX.NBenchmark` | `src/nbenchmark/` | The same market inputs lifted onto a physical network model and re-solved as an optimal power flow, across the PowerModels formulation family. Yields nodal prices and an energy/congestion/loss decomposition. |
| `NEMX.OPFFCAS` | `src/opffcas/` | A modelling library for AC/DC optimal power flow with co-optimised frequency control ancillary services, built on PowerModels and PowerModelsACDC. |

# Getting started

```julia
using NEMX

const ZB = NEMX.ZBenchmark   # zonal reconstruction
const NB = NEMX.NBenchmark   # nodal dispatch
const OF = NEMX.OPFFCAS      # OPF with FCAS co-optimisation
```

Each submodule's docstring gives its layout, its behavioural flags and a worked
example; `docs/` carries the full manual, including the data-acquisition
workflow and a reference for every flag and script argument.

Runnable drivers live in `scripts/`, not in `src/`. Each takes its
configuration from command-line arguments or environment variables — including
which solver to use — and documents every one of them in its header.

# Reproducibility

Every model in this package is deterministic given its inputs. Behavioural
switches are module-level `Ref`s whose defaults reproduce the validated
configuration; none is changed implicitly by any function in the package, so a
result is reproducible from the flag values recorded alongside it. Scripts print
their full configuration before doing any work, for exactly that reason.
"""
module NEMX

"""
    PKG_DIR

Absolute path to the package root — the directory holding `Project.toml`.

Use this rather than `pwd()` when resolving anything that ships with the
package, so that behaviour does not depend on the caller's working directory.
"""
const PKG_DIR = dirname(@__DIR__)

"""
    version() -> VersionNumber

The package version, read from `Project.toml`.
"""
function version()
    project = joinpath(PKG_DIR, "Project.toml")
    for line in eachline(project)
        m = match(r"^version\s*=\s*\"(.*)\"", line)
        m === nothing || return VersionNumber(m.captures[1])
    end
    error("no version field in $project")
end

# Command-line plumbing for the driver scripts. Included first because it
# depends on nothing else in the package, and re-exported below so that a script
# needs only `using NEMX`.
include("scripting/Scripting.jl")

# The three model families. `NBenchmark` depends on `ZBenchmark` for its market
# inputs, so the include order matters here even though it does not within a
# submodule.
include("zbenchmark/ZBenchmark.jl")
include("nbenchmark/NBenchmark.jl")
include("opffcas/OPFFCAS.jl")

using .Scripting
using .ZBenchmark
using .NBenchmark
using .OPFFCAS

export Scripting, ZBenchmark, NBenchmark, OPFFCAS

# --- Re-exported script plumbing --------------------------------------------
# A driver script does `using NEMX` and has all of these. See `NEMX.Scripting`
# for what each does and how a script takes its configuration.
export script_option, script_flag, script_positional
export script_integer, script_number, script_datetime, script_list
export SOLVER_CHOICES, select_solver
export resolve_output_dir, resolve_input_dir
export print_banner, print_flag_values, print_progress

end # module NEMX
