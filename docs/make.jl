# =============================================================================
# docs/make.jl
#
# Build the NEMX manual with Documenter.
#
# Locally:
#     julia --project=docs -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
#     julia --project=docs docs/make.jl
#
# The build is STRICT: a broken cross-reference, a docstring listed in an @docs
# block that does not exist, or a docstring that exists and is not listed
# anywhere all fail the build rather than producing a quietly incomplete manual.
# =============================================================================

using Documenter
using NEMX

# `NEMX_NO_DISPLAY` keeps PlotlyJS from trying to open an Electron window while
# docstrings are being evaluated on a headless machine.
ENV["NEMX_NO_DISPLAY"] = "1"

DocMeta.setdocmeta!(NEMX, :DocTestSetup, :(using NEMX); recursive = true)

makedocs(
    modules  = [NEMX, NEMX.ZBenchmark, NEMX.NBenchmark, NEMX.OPFFCAS],
    authors  = "Ghulam Mohy ud Din",
    sitename = "NEMX.jl",
    format = Documenter.HTML(;
        canonical = "https://ghulam41.github.io/NEMX.jl",
        edit_link = "main",
        assets = String[],
        sidebar_sitename = false,
    ),
    pages = [
        "Home" => "index.md",
        "Getting started" => [
            "Installation" => "installation.md",
            "Quick start" => "quickstart.md",
            "Market data" => "data.md",
            "The data pipeline" => "data_pipeline.md",
        ],
        "Concepts" => [
            "Architecture" => "architecture.md",
            "Prices and duals" => "prices.md",
            "Behavioural flags" => "flags.md",
        ],
        "Workflows" => [
            "Zonal benchmarking" => "workflow_zonal.md",
            "Network-resolved dispatch" => "workflow_network.md",
            "OPF with FCAS" => "workflow_opffcas.md",
            "BESS investigation study" => "bess_study.md",
        ],
        "Reference" => [
            "Scripts" => "scripts.md",
            "ZBenchmark API" => "api_zbenchmark.md",
            "NBenchmark API" => "api_nbenchmark.md",
            "OPFFCAS API" => "api_opffcas.md",
        ],
        "Contributing" => "contributing.md",
        "Citing NEMX" => "citing.md",
    ],
    checkdocs = :exports,
    warnonly = false,
)

deploydocs(
    repo = "github.com/ghulam41/NEMX.jl",
    devbranch = "main",
    push_preview = true,
)
