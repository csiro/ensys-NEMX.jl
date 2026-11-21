"""
    NEMX.Scripting

Command-line plumbing shared by every driver script: argument parsing, solver
selection, output paths, and the configuration banner.

This lives in the package rather than in a file each script `include`s, so that
a script needs only `using NEMX` to have all of it, and so that the behaviour is
tested with the rest of the library instead of being duplicated seventeen times.

# Why it exists

Scripts are where reproducibility usually goes wrong. A configuration edited in
place leaves no record of what produced a result. A solver hard-coded into a
script makes that script unusable to anyone without that solver's licence. And
the same flag spelled three different ways across three scripts guarantees that
one of them is stale.

So every driver in this package takes its configuration the same way, selects
its solver the same way, and prints the whole configuration before doing any
work.

# How a script takes configuration

Three mechanisms, in decreasing order of precedence:

| Form | Example |
|:-----|:--------|
| Named option | `--solver=ipopt`, `--data-dir=/mnt/nem`, `--forms=DCP,ACP` |
| Bare flag | `--download`, `--with-lmp`, `--verbose-solver` |
| Environment variable | `NEMX_SOLVER=ipopt`, `NEMX_DATA_DIR=/mnt/nem` |

An option's environment variable is its name upper-cased, with hyphens turned
into underscores, prefixed `NEMX_`. So `--out-dir` reads `NEMX_OUT_DIR`.

Bare flags are always OFF by default. A switch that ought to default to ON is
exposed as `--no-something`, so that the default is visible on the command line
rather than hidden in the file.

# Typical use

```julia
using NEMX

const START  = script_datetime(script_positional(1, "NEMX_START", "2025-09-02T04:05"))
const N      = script_integer(script_positional(2, "NEMX_N", "288"))
const SOLVER = select_solver(script_option("solver", "highs"))

print_banner("Zonal benchmark sweep", "start" => START, "intervals" => N)
```
"""
module Scripting

using Dates
using JuMP
using Printf

export script_option, script_flag, script_positional
export script_integer, script_number, script_datetime, script_list
export SOLVER_CHOICES, select_solver
export resolve_output_dir, resolve_input_dir
export print_banner, print_flag_values, print_progress

# ---------------------------------------------------------------------------
# SECTION 1.  ARGUMENT ACCESS
# ---------------------------------------------------------------------------

"""
    environment_name(option_name::AbstractString) -> String

The environment variable that backs a given command-line option.

The rule is fixed and mechanical: upper-case the option name, replace hyphens
with underscores, prefix `NEMX_`. So `--out-dir` is backed by `NEMX_OUT_DIR`.

# Arguments
- `option_name`: the option name WITHOUT its leading `--`.

# Returns
The environment variable name.
"""
function environment_name(option_name::AbstractString)
    upper = uppercase(option_name)
    underscored = replace(upper, "-" => "_")
    return "NEMX_" * underscored
end

"""
    script_option(name::AbstractString, default::AbstractString = "") -> String

Value of a `--name=value` command-line option.

Falls back to the backing environment variable (see [`environment_name`](@ref)),
and then to `default`.

# Arguments
- `name`: the option name without its leading `--`.
- `default`: value to use when neither the option nor the variable is set.

# Returns
The option value, as a string. Convert it with [`script_integer`](@ref),
[`script_number`](@ref), [`script_datetime`](@ref) or [`script_list`](@ref).

# Example
```
julia --project=. scripts/nbenchmark/run_network_day.jl --solver=ipopt
NEMX_SOLVER=ipopt julia --project=. scripts/nbenchmark/run_network_day.jl
```
"""
function script_option(name::AbstractString, default::AbstractString = "")
    prefix = "--" * name * "="
    for argument in ARGS
        if startswith(argument, prefix)
            return String(argument[(length(prefix) + 1):end])
        end
    end
    return get(ENV, environment_name(name), default)
end

"""
    script_flag(name::AbstractString) -> Bool

Whether the bare flag `--name` was passed on the command line, or its backing
environment variable was set to `"1"`.

Bare flags are always off by default. A switch that should default to ON is
exposed as `--no-something` instead, so the default stays visible.

# Arguments
- `name`: the flag name without its leading `--`.

# Returns
`true` if the flag was given, `false` otherwise.
"""
function script_flag(name::AbstractString)
    if ("--" * name) in ARGS
        return true
    end
    return get(ENV, environment_name(name), "0") == "1"
end

"""
    script_positional(index::Integer, variable::AbstractString,
                      default::AbstractString) -> String

The `index`-th positional argument, ignoring anything beginning with `--`.

Falls back to the named environment `variable`, and then to `default`. The
environment variable is named explicitly here rather than derived, because
positional arguments have no option name to derive it from.

# Arguments
- `index`: 1-based position among the bare (non-`--`) arguments.
- `variable`: environment variable to consult when the argument is absent.
- `default`: value to use when neither is present.

# Returns
The argument value, as a string.
"""
function script_positional(index::Integer, variable::AbstractString,
                           default::AbstractString)
    bare = String[]
    for argument in ARGS
        if !startswith(argument, "--")
            push!(bare, String(argument))
        end
    end
    if length(bare) >= index
        return bare[index]
    end
    return get(ENV, variable, default)
end

# ---------------------------------------------------------------------------
# SECTION 2.  ARGUMENT CONVERSION
#
# Each of these fails with the offending text and the expected form. A mistyped
# argument otherwise surfaces much later as an empty result set or a stack trace
# from deep inside `parse`, neither of which tells the operator what to fix.
# ---------------------------------------------------------------------------

"""
    script_integer(text::AbstractString) -> Int

Parse an integer argument.

# Throws
`ErrorException` quoting the offending text if it is not an integer.
"""
function script_integer(text::AbstractString)
    value = tryparse(Int, strip(text))
    if value === nothing
        error("expected an integer, got \"$text\"")
    end
    return value
end

"""
    script_number(text::AbstractString) -> Float64

Parse a floating-point argument.

# Throws
`ErrorException` quoting the offending text if it is not a number.
"""
function script_number(text::AbstractString)
    value = tryparse(Float64, strip(text))
    if value === nothing
        error("expected a number, got \"$text\"")
    end
    return value
end

"""
    script_datetime(text::AbstractString) -> DateTime

Parse an ISO-8601 dispatch interval, for example `2025-09-02T04:05`.

# Throws
`ErrorException` quoting the offending text and the expected format.
"""
function script_datetime(text::AbstractString)
    try
        return DateTime(strip(text))
    catch
        error("expected an ISO datetime such as 2025-09-02T04:05, got \"$text\"")
    end
end

"""
    script_list(text::AbstractString) -> Vector{String}

Split a comma-separated argument, trimming whitespace and dropping empties.

# Example
```julia
script_list("DCP, ACP ,, LPACC")     # ["DCP", "ACP", "LPACC"]
```
"""
function script_list(text::AbstractString)
    items = String[]
    for piece in split(text, ',')
        trimmed = strip(piece)
        if !isempty(trimmed)
            push!(items, String(trimmed))
        end
    end
    return items
end

# ---------------------------------------------------------------------------
# SECTION 3.  SOLVER SELECTION
# ---------------------------------------------------------------------------

"""
    SOLVER_CHOICES

Solver names accepted by [`select_solver`](@ref), and what each is for.

| Name    | Package | Use |
|:--------|:--------|:----|
| `highs` | HiGHS   | Linear and mixed-integer problems. The default wherever an LP is solved. |
| `ipopt` | Ipopt   | Non-linear problems: the AC formulations and the IV rectangular form. |
| `scs`   | SCS     | Conic relaxations, where Ipopt is a poor fit. |

All three are open source. No script in this package requires a licensed solver.
A commercial solver can still be used by passing its optimizer straight to the
library functions, which take an optimizer object rather than a name.
"""
const SOLVER_CHOICES = ("highs", "ipopt", "scs")

"""
    select_solver(name::AbstractString = "highs";
                  silent::Bool = true,
                  attributes::Vector{<:Pair} = Pair{String,Any}[])

Build a JuMP optimizer factory from a solver name.

# Arguments
- `name`: one of [`SOLVER_CHOICES`](@ref). Case-insensitive.

# Keywords
- `silent`: suppress the solver's own output. `true` by default, because these
  scripts print their own progress. Pass `--verbose-solver` in a script when
  diagnosing a bad solve.
- `attributes`: extra solver attributes, appended AFTER the defaults so that
  they win. For example `["max_iter" => 20_000]` for a stubborn AC interval.

# Returns
An `OptimizerWithAttributes`, ready to hand to any library function.

# Throws
`ErrorException` naming the valid choices, rather than a `MethodError` several
frames deeper.

# Example
```julia
solver = select_solver("ipopt"; attributes = ["max_iter" => 20_000])
```
"""
function select_solver(name::AbstractString = "highs";
                       silent::Bool = true,
                       attributes::Vector{<:Pair} = Pair{String,Any}[])
    key = lowercase(strip(name))
    if !(key in SOLVER_CHOICES)
        error("unknown solver \"$name\"; choose one of " *
              join(SOLVER_CHOICES, ", ") * " (pass --solver=NAME)")
    end

    # The solver packages are loaded on demand. Importing all three at package
    # load time would cost every user the load time of solvers they are not
    # going to use.
    if key == "highs"
        @eval Main import HiGHS
        defaults = Pair{String,Any}["output_flag" => !silent]
        return JuMP.optimizer_with_attributes(Main.HiGHS.Optimizer,
                                              vcat(defaults, attributes)...)
    elseif key == "ipopt"
        @eval Main import Ipopt
        defaults = Pair{String,Any}["print_level" => silent ? 0 : 5]
        return JuMP.optimizer_with_attributes(Main.Ipopt.Optimizer,
                                              vcat(defaults, attributes)...)
    else
        @eval Main import SCS
        defaults = Pair{String,Any}["verbose" => silent ? 0 : 1]
        return JuMP.optimizer_with_attributes(Main.SCS.Optimizer,
                                              vcat(defaults, attributes)...)
    end
end

# ---------------------------------------------------------------------------
# SECTION 4.  OUTPUT AND INPUT PATHS
# ---------------------------------------------------------------------------

"""
    resolve_output_dir(default::AbstractString) -> String

Directory for a script's output, from `--out-dir=` or `NEMX_OUT_DIR`, else
`default`. The directory is created if it does not exist.

A script that writes a large result set should default to a LOCAL scratch path
rather than a cloud-synced folder. A file rewritten every few minutes for hours
is not reliably served back at its newest version by a sync client — a completed
sweep has been observed leaving only its first two thirds on disk. The pattern
to follow is: checkpoint to scratch, then copy into the project tree once, at
the end.

# Arguments
- `default`: directory to use when neither the option nor the variable is set.

# Returns
The resolved directory path, which now exists.
"""
function resolve_output_dir(default::AbstractString)
    directory = script_option("out-dir", default)
    mkpath(directory)
    return directory
end

"""
    resolve_input_dir(default::AbstractString) -> String

Directory a script reads its inputs from, via `--data-dir=` or `NEMX_DATA_DIR`.

The directory is NOT created. A missing input directory is an error the script
should report, not paper over.

# Arguments
- `default`: directory to use when neither the option nor the variable is set.

# Returns
The resolved directory path, which may or may not exist.
"""
function resolve_input_dir(default::AbstractString)
    return script_option("data-dir", default)
end

# ---------------------------------------------------------------------------
# SECTION 5.  REPORTING
# ---------------------------------------------------------------------------

"""
    print_banner(title::AbstractString, settings::Pair...)

Print a script's full configuration before it does any work.

Every result this package produces should be reproducible from the banner
printed above it: the script, the package version, the resolved arguments, and
the behavioural flags in force. Scripts call this once, at the top, after
resolving their arguments and before the first solve.

# Arguments
- `title`: one line naming what is about to run.
- `settings`: `"label" => value` pairs, printed one per line in the order given.

# Example
```julia
print_banner("Network day sweep",
             "start" => START, "intervals" => N,
             "formulations" => join(FORMS, ","), "solver" => SOLVER_NAME)
```
"""
function print_banner(title::AbstractString, settings::Pair...)
    rule = "=" ^ 74
    println()
    println(rule)
    println(title)
    println(rule)
    @printf("  %-22s %s\n", "package", "NEMX v" * string(package_version()))
    @printf("  %-22s %s\n", "julia", string(VERSION))
    @printf("  %-22s %s\n", "started", Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))
    for (label, value) in settings
        @printf("  %-22s %s\n", label, string(value))
    end
    println(rule)
    println()
    flush(stdout)
    return nothing
end

"""
    package_version() -> VersionNumber

The NEMX version, read from `Project.toml`.

Defined here rather than taken from the parent module, so that `Scripting` has
no dependency on the load order of the rest of the package.
"""
function package_version()
    root = normpath(joinpath(@__DIR__, "..", ".."))
    project = joinpath(root, "Project.toml")
    for line in eachline(project)
        matched = match(r"^version\s*=\s*\"(.*)\"", line)
        if matched !== nothing
            return VersionNumber(matched.captures[1])
        end
    end
    error("no version field in $project")
end

"""
    print_flag_values(mod::Module, names::Symbol...)

Print the current value of the behavioural flags a script depends on.

Flags are `Ref`s whose defaults reproduce a validated configuration. A script
that changes one must say so in its output, or its results are not reproducible
from the log. Call this after any flag assignment.

# Arguments
- `mod`: the module holding the flags, e.g. `NEMX.ZBenchmark`.
- `names`: flag names. A name that does not exist in `mod` is skipped, so a
  script need not know which flags a given version defines.
"""
function print_flag_values(mod::Module, names::Symbol...)
    println("  behavioural flags (", nameof(mod), "):")
    for name in names
        if isdefined(mod, name)
            @printf("    %-34s %s\n", name, string(getfield(mod, name)[]))
        end
    end
    println()
    flush(stdout)
    return nothing
end

"""
    print_progress(done::Integer, total::Integer, started::Float64,
                   label::AbstractString = "")

One line of progress, with elapsed time and an estimate of what remains.

Long sweeps run for hours. Without this there is no way to tell a slow interval
from a hung one.

# Arguments
- `done`: intervals completed so far.
- `total`: intervals in the whole run.
- `started`: the value `time()` returned when the run began.
- `label`: short text identifying the current item, e.g. the interval.
"""
function print_progress(done::Integer, total::Integer, started::Float64,
                        label::AbstractString = "")
    elapsed = time() - started
    if done == 0
        remaining = 0.0
    else
        remaining = (total - done) * elapsed / done
    end
    @printf("  [%4d/%4d] %-24s elapsed %6.1f min, eta %6.1f min\n",
            done, total, label, elapsed / 60, remaining / 60)
    flush(stdout)
    return nothing
end

end # module Scripting
