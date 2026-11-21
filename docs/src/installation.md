# Installation

## Requirements

Julia 1.10 or later. Nothing else is required: every solver the package uses is
open source, so there is no licence to obtain and no separate installation step.

| Solver | Used for | Comes from |
|:-------|:---------|:-----------|
| HiGHS | Linear and mixed-integer problems — the zonal dispatch, the DC formulations | `HiGHS.jl` |
| Ipopt | Non-linear problems — the AC formulations, the IV rectangular form | `Ipopt.jl` |
| SCS | Conic relaxations where Ipopt is a poor fit | `SCS.jl` |

## Installing

```julia
using Pkg
Pkg.add(url = "https://github.com/csiro/ensys-NEMX.jl")
```

Or, for development:

```bash
git clone https://github.com/csiro/ensys-NEMX.jl
cd NEMX.jl
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

Check the installation with the example that needs no data:

```bash
julia --project=. scripts/zbenchmark/zonal_simple_example.jl
```

It should report unit A at 40 MW, unit B at 80 MW and a price of \$60/MWh.

## Running the tests

```julia
using Pkg; Pkg.test("NEMX")
```

About twenty seconds. Two environment switches widen the suite:

| Variable | Effect |
|:---------|:-------|
| `NEMX_TEST_SLOW=1` | Adds the AC and IVR regressions on the 2000-bus case. About two and a half minutes more. |
| `NEMX_TEST_NETWORK=1` | Adds tests that download from AEMO. Off by default, because a test suite should not depend on a third party's availability or on several hundred megabytes of transfer. |

## Optional: HSL linear solvers

Ipopt's default sparse factorisation is MUMPS, and it is the component most
implicated in AC solves that succeed on one machine and fail on another. If a
CoinHSL build is available, the AC path uses MA57 for the primary solve and
MUMPS for the retry, which makes the second attempt genuinely independent of the
first rather than a re-run of the same factorisation.

HSL is licensed by STFC and is not redistributable, so it is discovered at run
time and its absence is not an error — the package falls back to MUMPS
throughout.

To enable it, unpack a CoinHSL binary distribution so that the library sits at

```
<package root>/vendor/coinhsl/lib/libcoinhsl.{so,dylib,dll}
```

or point `NEMX_HSLLIB` at it directly:

```bash
export NEMX_HSLLIB=/opt/coinhsl/lib/libcoinhsl.so
```

Check what was found:

```julia
julia> NEMX.NBenchmark.hsl_library_path()
"/opt/coinhsl/lib/libcoinhsl.so"     # or "" if none is present
```

## Optional: security-constrained problems

`src/opffcas/scopf/` holds the security-constrained OPF family. It depends on
`PowerModelsACDCsecurityconstrained`, which is not in Julia's General registry,
so it is **not** on the default load path — that is what lets `Pkg.add` and
`Pkg.test` work with registered dependencies only.

To use it, install that package into your environment and then:

```julia
using NEMX, PowerModelsACDCsecurityconstrained
NEMX.OPFFCAS.load_security_constrained!()
```

The call throws with an explanatory message if the dependency is absent, and is
a no-op if the files are already loaded.

