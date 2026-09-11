# =============================================================================
# plot_network_day.jl
#
# Publication figures and tables for a network-day sweep: regional price
# tracking across formulations, error distributions and solve status, losses and
# the loss component of price, implied marginal loss factors, the congestion
# ledger, and the price decomposition.
#
# HONEST TREATMENT OF OUT-OF-SCALE AND NON-CONVERGED RESULTS
#
# The formulations are not equally well behaved on a 2000-bus synthetic network.
# Deleting the bad points would flatter the comparison; keeping them on a linear
# axis would compress every other series into a flat line. So nothing is ever
# silently dropped:
#
#   * a value outside a panel's window is drawn as a caret pinned to the frame
#     edge it left, in the series colour, so the reader sees THAT it left, in
#     WHICH direction, and at WHICH interval;
#   * an interval whose solve did not converge is left as a GAP in the line and
#     marked on the status strip — absent is shown as absent, not interpolated;
#   * the display window is a robust quantile of the REFERENCE series, so a
#     badly behaved formulation cannot widen the axis and hide the others.
#
# ARGUMENTS
#   Positional    Env            Default   Meaning
#   ------------  -------------  --------  ----------------------------------
#   1..n          -              all       which figures/tables to draw
#                                          (N1 N1B N2 ... T1 T2 T3)
#
#   Options       Env               Default                Meaning
#   ------------  ----------------  ---------------------  --------------------
#   --data-dir=   NEMX_DATA_DIR     data/nempy_2025_09     where the CSVs are
#   --out-dir=    NEMX_OUT_DIR      figures                where output goes
#   --day-tag=    NEMX_NETWORK_DAY  20250902_0405          which sweep to plot
#
# OUTPUT
#   Each figure as PDF (the vector master for LaTeX), PNG at 600 dpi, and HTML
#   (interactive). Tables as booktabs .tex.
#
# EXAMPLES
#   julia --project=. scripts/nbenchmark/plot_network_day.jl
#   julia --project=. scripts/nbenchmark/plot_network_day.jl N1 T1
# =============================================================================

using NEMX
using CSV
using DataFrames
using Dates
using PlotlyJS
using Printf
using Statistics

const ROOT = NEMX.PKG_DIR

const DAY_TAG  = script_option("day-tag", "20250902_0405")
const DATA_DIR = resolve_input_dir(joinpath(ROOT, "data", "nempy_2025_09"))

print_banner("Network-day figures",
             "day tag" => DAY_TAG,
             "data dir" => DATA_DIR)
const PRICES_CSV = joinpath(DATA_DIR, "network_day_prices_$(DAY_TAG).csv")
const DECOMP_CSV = joinpath(DATA_DIR, "network_day_decomposition_$(DAY_TAG).csv")
const BIND_CSV   = joinpath(DATA_DIR, "network_day_binding_$(DAY_TAG).csv")
const ROP_CSV    = joinpath(DATA_DIR, "nem_prices_vs_rop_sept2025.csv")
# The comparison baseline for the whole nodal study: a zonal dispatch of the same
# day built on the MLF-SCALED bid stack (see run_network_day.jl). Every nodal
# formulation now runs on the reference-node-referred stack, so measuring against
# this series isolates the power-flow model; measuring against AEMO's published
# ROP would additionally carry the zonal-vs-nodal difference and the bid-stack
# convention. Falls back to ROP, with a warning, if the file is absent.
const BENCH_CSV  = joinpath(DATA_DIR, "network_day_benchmark_$(DAY_TAG).csv")
# Participant-node LMP deviations from that baseline (interval, formulation,
# unit). The regional reference node is one bus of ~2000; this is the price a
# participant actually faces at its own connection point.
const PARTIC_CSV = joinpath(DATA_DIR, "network_day_participant_$(DAY_TAG).csv")
const FIG_DIR    = resolve_output_dir(joinpath(ROOT, "figures"))
mkpath(FIG_DIR)

# --- IEEE geometry and type ---------------------------------------------------
const PX_PER_IN = 96
const COL1 = round(Int, 3.50 * PX_PER_IN)
const COL2 = round(Int, 7.16 * PX_PER_IN)
pt(x) = x * 96 / 72
const PNG_SCALE = 600 / PX_PER_IN
const FONT = "Times New Roman, Times, serif"

# --- Ink ----------------------------------------------------------------------
const INK   = "#0b0b0b"
const INK_2 = "#52514e"
const MUTED = "#898781"
const GRID  = "#e1e0d9"
const AXIS  = "#c3c2b7"
const C_CRIT = "#d03b3b"

# --- Domain vocabulary --------------------------------------------------------
const REGIONS = ["NSW1", "QLD1", "SA1", "TAS1", "VIC1"]
region_label(r) = replace(r, "1" => "")

# Display order: the DC pair first (the reference formulations for market
# dispatch), then the AC model, then its convex relaxations.
# DCP_MLF is deliberately EXCLUDED from the figure set. It is not a replica of
# NEMDE's treatment of loss factors: NEMDE refers offer PRICES by the MLF (a
# no-op once the case-file prices are already referred) and does not scale
# injected QUANTITIES, whereas DCP_MLF scales injections by gamma. Measured over
# this day it also degraded agreement with the published price (median absolute
# error 49.00 vs 7.90 $/MWh). It remains available in the model as a sensitivity
# variant; it is not reported as a candidate power-flow formulation.
const FORMS = ["DCP", "ACP", "LPACC", "SOCWR", "QCRM"]
# Solver-level names, used verbatim in figures and tables so a reader can map a
# series straight onto the formulation registry rather than a prose paraphrase.
const FORM_LABEL = Dict(
    "DCP"     => "DCP",
    "ACP"     => "ACP",
    "LPACC"   => "LPACC",
    "SOCWR"   => "SOCWR",
    "QCRM"    => "QCRM")
const FORM_COLOR = Dict(
    "DCP"     => "#2a78d6",   # blue    - DC reference
    "ACP"     => "#008300",   # green
    "LPACC"   => "#eda100",   # amber
    "SOCWR"   => "#e87ba4",   # magenta
    "QCRM"    => "#5b6b7a")   # slate
# Dash carries the same information as hue, so the figure survives greyscale
# printing and colour-vision deficiency.
const FORM_DASH = Dict(
    "DCP" => "solid", "ACP" => "solid",
    "LPACC" => "dot", "SOCWR" => "dashdot", "QCRM" => "longdash")
const C_AEMO = "#eb6834"      # orange - the comparison baseline series
"Label for the baseline series, set by `load_network_day` from which file it found."
const REF_LABEL = Ref("Zonal benchmark")

const REGION_COLOR = Dict("NSW1"=>"#2a78d6", "QLD1"=>"#eda100", "SA1"=>"#e87ba4",
                          "TAS1"=>"#008300", "VIC1"=>"#4a3aa7")

# A solve is usable only if the solver reported a genuine optimum. Everything
# else becomes a gap: `ITERATION_LIMIT` and `ALMOST_LOCALLY_SOLVED` returns are
# NOT prices in any meaningful sense, and `INFEASIBLE` rows carry whatever was
# in the variable when the solve gave up.
const OK_STATUS = Set(["OPTIMAL", "LOCALLY_SOLVED"])
const MARGINAL_STATUS = Set(["ALMOST_LOCALLY_SOLVED"])

# Units, stated once and reused so no axis can drift from its quantity.
const U_PRICE = "\$/MWh"
const U_MW    = "MW"

# --- Physical reference values for the loss comparison ------------------------
# Measured directly from the NEMDE case files over the same window (287 of the
# 288 intervals have a locally cached case file): the sum of
# InterconnectorSolution/@Losses per interval, and the sum of
# RegionSolution/@FixedDemand across the five regions.
#
# These are the anchor of Table T1's loss columns. NEMDE books INTER-regional
# losses ONLY -- verified independently at 2025-09-02 04:15, where its own
# energy balance closes as net generation 20 259.09 MW against demand
# 20 204.08 MW, a difference of 55.01 MW against 52.36 MW of published
# interconnector losses. There are no intra-regional losses in the market
# formulation, which is why a nodal AC model that solves them physically must
# sit above this figure and a DC model that models neither must sit below it.
const NEMDE_LOSS_MED = 135.33   # MW, median published interconnector losses
const NEMDE_LOSS_P95 = 200.04   # MW, 95th percentile
const NEM_DEMAND_MW  = 20844.5  # MW, median total NEM demand over the window

# =============================================================================
# Data
# =============================================================================
"""
Parse the ISO timestamps written by the Julia drivers. They carry a fractional
second (`2025-09-02T04:05:00.0`) which `DateTime` accepts, but CSV.jl may also
have typed the column already - so this is a no-op on a `DateTime`.
"""
parse_ts(x::DateTime) = x
function parse_ts(x)
    s = String(x)
    try
        return DateTime(s)
    catch
        return DateTime(replace(s, r"\.\d+$" => ""))
    end
end

"""
    load_network_day() -> (prices, decomp, rop)

Join the nodal run to AEMO's published ROP on (time, region). `ok` marks rows
whose solve converged; `price` is left untouched so nothing is hidden, and the
figure builders decide what to draw for a non-converged row.
"""
function load_network_day()
    isfile(PRICES_CSV) || error("Missing $PRICES_CSV - run scripts/nbenchmark/run_network_day.jl first.")
    p = CSV.read(PRICES_CSV, DataFrame)
    p.time = parse_ts.(p.time)
    p.formulation = String.(p.formulation)
    p.region = String.(p.region)
    p.status = String.(p.status)
    p.ok = [s in OK_STATUS for s in p.status]

    d = CSV.read(DECOMP_CSV, DataFrame)
    d.time = parse_ts.(d.time)
    d.formulation = String.(d.formulation)
    d.region = String.(d.region)

    if isfile(BENCH_CSV)
        r = CSV.read(BENCH_CSV, DataFrame)          # region, price
        r.time = parse_ts.(r.time)
        r.region = String.(r.region)
        rename!(r, :price => :ROP)                  # column name kept for reuse
        REF_LABEL[] = "Zonal benchmark"
    else
        @warn "No $(basename(BENCH_CSV)); falling back to AEMO ROP as the baseline. " *
              "Error columns will then conflate the power-flow model with the " *
              "zonal/nodal difference."
        r = CSV.read(ROP_CSV, DataFrame)
        r = r[r.service .== "energy", [:time, :region, :ROP]]
        r.time = parse_ts.(r.time)
        r.region = String.(r.region)
        REF_LABEL[] = "AEMO published ROP"
    end

    # Clip the AEMO reference to the window the nodal run actually covers. The
    # ROP file spans 1000 intervals (3.5 days); without this the reference line
    # runs across the whole span while the model series occupy a third of the
    # panel, and the shared time axis repeats each hour label three times.
    t0, t1 = extrema(p.time)
    r = r[(r.time .>= t0) .& (r.time .<= t1), :]

    p = leftjoin(p, r, on = [:time, :region])
    p.err = [(ismissing(rop) || !ok) ? missing : pr - rop
             for (pr, rop, ok) in zip(p.price, p.ROP, p.ok)]
    d = leftjoin(d, select(p, [:time, :formulation, :region, :ok]),
                 on = [:time, :formulation, :region])
    sort!(p, [:time, :formulation, :region])
    sort!(d, [:time, :formulation, :region])
    return p, d, r
end

"""
    load_binding(; families) -> DataFrame

The shadow-price ledger is the largest artefact of the run (tens of MB), so
only the columns the congestion figure needs are read.
"""
function load_binding(; families = ["network_security", "interconnector_limit", "unit_cap"])
    isfile(BIND_CSV) || return DataFrame()
    # `at_bound` is the PRIMAL binding test and is preferred wherever the sweep
    # recorded it. Filtering on |dual| instead admits the interior-point
    # near-active set: measured at 2025-09-02 12:05, LP-AC reports 447 active
    # network-security constraints by the dual test against 6 that are actually
    # at their bound, while the summed shadow price is identical either way.
    # The economics were never wrong; the active set was.
    cols = [:time, :formulation, :family, :constraint, :dual]
    hdr  = String.(propertynames(CSV.read(BIND_CSV, DataFrame; limit = 1)))
    haspb = "at_bound" in hdr
    haspb && push!(cols, :at_bound)
    b = CSV.read(BIND_CSV, DataFrame; select = cols)
    if haspb
        b = b[b.at_bound, :]
    else
        @warn "Binding ledger has no `at_bound` column; falling back to the " *
              "|dual| > 0 test. Constraint COUNTS will overstate the active set " *
              "for the interior-point formulations (shadow prices are unaffected). " *
              "Re-run the sweep to record the primal test."
    end
    b.family = String.(b.family)
    b = b[in.(b.family, Ref(Set(families))), :]
    b.time = parse_ts.(b.time)
    b.formulation = String.(b.formulation)
    b.constraint = String.(b.constraint)
    return b
end

# --- Robust statistics --------------------------------------------------------
# The mean and the maximum are dominated by a handful of failed AC solves, so
# every headline statistic here is a quantile. The raw mean/max are still
# reported in T1 - they are the evidence for the fragility, not a summary of
# typical behaviour.
"Drop `missing` AND NaN - a NaN from a failed solve is not a datum either."
nz(x) = [v for v in skipmissing(x) if !(v isa Real && isnan(v))]
q(x, p) = (v = nz(x); isempty(v) ? NaN : quantile(v, p))
med(x) = q(x, 0.5)
safemean(x) = (v = nz(x); isempty(v) ? NaN : mean(v))
safemax(x) = (v = nz(x); isempty(v) ? NaN : maximum(v))
"First usable value of a group (losses are a system quantity, repeated per region)."
safefirst(x) = (v = nz(x); isempty(v) ? NaN : first(v))

# =============================================================================
# Layout helpers (shared vocabulary with plot_benchmark_figures_sept2025.jl)
# =============================================================================
function ieee_layout(sp=nothing; width, height, kwargs...)
    base = (paper_bgcolor="white", plot_bgcolor="white",
            font=attr(family=FONT, size=pt(8), color=INK),
            margin=attr(l=56, r=14, t=34, b=44),
            hoverlabel=attr(font=attr(family=FONT, size=pt(8))))
    return sp === nothing ? Layout(; width=width, height=height, base..., kwargs...) :
                            Layout(sp; width=width, height=height, base..., kwargs...)
end

axkey(kind, k) = Symbol(kind, k == 1 ? "" : string(k))

const AXIS_STYLE = (showgrid=true, gridcolor=GRID, gridwidth=0.6,
                    zeroline=false, showline=true, linecolor=AXIS, linewidth=0.8,
                    ticks="outside", ticklen=3, tickwidth=0.6, tickcolor=AXIS,
                    tickfont=attr(family=FONT, size=pt(7.5), color=INK_2),
                    automargin=true)

figtitle(text; height) =
    attr(text=text, x=0.5, xanchor="center", y=1 - 18/height, yanchor="top",
         yref="container", font=attr(family=FONT, size=pt(9.5), color=INK))

"Boxed horizontal legend with constant-size swatches (see the benchmark script)."
function boxed_leg(y=1.012; itemwidth=34, ncol::Union{Nothing,Int}=nothing)
    a = attr(orientation="h", x=0.5, xanchor="center", y=y, yanchor="bottom",
             traceorder="normal", itemsizing="constant", itemwidth=itemwidth,
             font=attr(family=FONT, size=pt(7.5), color=INK),
             bgcolor="rgba(255,255,255,0.92)", bordercolor=AXIS, borderwidth=0.7)
    if ncol !== nothing
        # `entrywidth` in fraction-of-plot units is how a horizontal Plotly
        # legend is wrapped into a fixed number of columns: n entries per row
        # means each entry occupies 1/n of the legend width.
        a[:entrywidth] = 1 / ncol
        a[:entrywidthmode] = "fraction"
    end
    return a
end

axtitle(text; standoff=6) =
    attr(text=text, standoff=standoff, font=attr(family=FONT, size=pt(8.5), color=INK))

function style_all_axes!(p)
    for key in collect(keys(p.layout.fields))
        s = String(key)
        (startswith(s, "xaxis") || startswith(s, "yaxis")) || continue
        for (k, v) in pairs(AXIS_STYLE)
            p.layout[key][k] = v
        end
    end
    return p
end

"Generated subplot titles arrive with Plotly's default font; restyle them to IEEE."
function style_panel_titles!(p)
    haskey(p.layout.fields, :annotations) || return p
    for a in p.layout[:annotations]
        a[:font] = attr(family=FONT, size=pt(8.5), color=INK)
    end
    return p
end

"Merge properties into subplot k's axis (field-level, so nothing else is lost)."
function set_axis!(p, kind, k; kw...)
    key = axkey(kind, k)
    haskey(p.layout.fields, key) || (p.layout[key] = attr())
    for (kk, vv) in kw
        p.layout[key][kk] = vv
    end
    return p
end

"""
    legend_proxy!(p; kind, name, color, row, col, at, ...)

Data-free trace that owns a legend entry, so the key can use a large readable
swatch while the plotted series stays at the small marks IEEE column width
demands. One point at a REAL x with a NaN y: `[nothing]` would type a shared
axis numeric and blank the DateTime panels, and a fully empty vector makes
Plotly drop the legend entry.
"""
function legend_proxy!(p; kind::Symbol, name, color, row, col, at, size=9, width=2.0,
                       dash="solid", symbol="circle", group=name)
    tr = kind === :marker ?
        scatter(x=[at], y=[NaN], mode="markers", name=name,
                legendgroup=group, showlegend=true, hoverinfo="skip",
                marker=attr(color=color, size=size, symbol=symbol, line=attr(width=0))) :
        scatter(x=[at], y=[NaN], mode="lines", name=name,
                legendgroup=group, showlegend=true, hoverinfo="skip",
                line=attr(color=color, width=width, dash=dash))
    add_trace!(p, tr, row=row, col=col)
    return p
end

"Panel letter, placed just inside the panel's top-left corner."
panel_tag(text, xref, yref; x=0.012, y=0.985) =
    attr(text=text, xref=xref, yref=yref, x=x, y=y, xanchor="left", yanchor="top",
         showarrow=false, font=attr(family=FONT, size=pt(8.5), color=INK))

const CAPTIONS = Dict{String,String}()

function save_figure(p, name; width, height)
    base = joinpath(FIG_DIR, name)
    try
        savefig(p, base * ".pdf"; width=width, height=height)
        savefig(p, base * ".png"; width=width, height=height, scale=PNG_SCALE)
    catch e
        # Kaleido is absent in some environments. The interactive HTML is
        # always written, so a missing static renderer never costs the figure.
        @warn "Static export failed for $name ($(typeof(e))); HTML still written."
    end
    open(base * ".html", "w") do io
        PlotlyBase.to_html(io, p; include_plotlyjs="cdn", full_html=true)
    end
    @printf("  %-34s %4d x %4d px\n", name, width, height)
    return base
end

# =============================================================================
# Out-of-scale handling
# =============================================================================
"""
    clipped(x, y, lo, hi) -> (y_in, x_hi, x_lo, n_hi, n_lo)

Split a series against a display window. `y_in` keeps in-window values and
substitutes NaN elsewhere, so the line breaks rather than running to the frame;
`x_hi`/`x_lo` are the abscissae at which the series left the window through the
top/bottom, to be drawn as caret glyphs pinned to that edge.

Missing values (non-converged solves) are NaN in `y_in` and are NOT counted as
out of scale - an absent result and an extreme result are different facts and
the figure distinguishes them.
"""
function clipped(x, y, lo, hi)
    yin = Vector{Float64}(undef, length(y))
    xhi = eltype(x)[]; xlo = eltype(x)[]
    for i in eachindex(y)
        v = y[i]
        if v === missing || (v isa Real && isnan(v))
            yin[i] = NaN
        elseif v > hi
            yin[i] = NaN; push!(xhi, x[i])
        elseif v < lo
            yin[i] = NaN; push!(xlo, x[i])
        else
            yin[i] = float(v)
        end
    end
    return yin, xhi, xlo, length(xhi), length(xlo)
end

"""
    add_clipped_series!(p, x, y; lo, hi, color, dash, row, col, width)

Draw one series against a display window: the in-window line (with gaps left
open) plus the two glyph layers that record where it went off scale. Returns
the (above, below) out-of-scale counts so the caller can report them.
"""
function add_clipped_series!(p, x, y; lo, hi, color, dash, row, col, width=1.1,
                             name="", showlegend=false)
    yin, xhi, xlo, nhi, nlo = clipped(x, y, lo, hi)
    add_trace!(p, scatter(x=x, y=yin, mode="lines", name=name,
                          showlegend=showlegend, connectgaps=false,
                          line=attr(color=color, width=width, dash=dash),
                          hovertemplate="%{x|%H:%M}  %{y:.2f}<extra>$name</extra>"),
               row=row, col=col)
    if nhi > 0
        add_trace!(p, scatter(x=xhi, y=fill(hi, nhi), mode="markers",
                              showlegend=false, hoverinfo="skip",
                              marker=attr(color=color, size=4.5, symbol="triangle-up",
                                          line=attr(width=0))),
                   row=row, col=col)
    end
    if nlo > 0
        add_trace!(p, scatter(x=xlo, y=fill(lo, nlo), mode="markers",
                              showlegend=false, hoverinfo="skip",
                              marker=attr(color=color, size=4.5, symbol="triangle-down",
                                          line=attr(width=0))),
                   row=row, col=col)
    end
    return nhi, nlo
end

"""
    window(ref; pad, floor_span) -> (lo, hi)

Display window from a ROBUST spread of the REFERENCE series only. Taking the
window from the reference (AEMO's ROP) rather than from the model output is
what stops one badly behaved formulation from rescaling the panel and flattening
every other series into the axis.
"""
function window(ref; pad=0.14, floor_span=20.0)
    v = nz(ref)
    isempty(v) && return (-100.0, 500.0)
    lo, hi = quantile(v, 0.01), quantile(v, 0.99)
    span = max(hi - lo, floor_span)
    return (lo - pad * span, hi + pad * span)
end

# =============================================================================
# N1 - Regional price tracking, five regions x six formulations vs AEMO ROP
# =============================================================================
"""
One row per region. Each panel carries AEMO's published ROP as the reference
series and all six formulations over it, on a window set by the ROP so the
comparison is legible even where a formulation diverges by four orders of
magnitude. Divergences are not removed: they leave the window as caret glyphs
on the frame, and non-converged intervals appear as breaks in the line.
"""
function figure_N1(P, D, R, B; clip::Bool=true)
    w, h = COL2, 900
    sp = PlotlyJS.Subplots(rows=5, cols=1, shared_xaxes=true,
                           vertical_spacing=0.028,
                           subplot_titles=reshape(["(" * "abcde"[i:i] * ") " * region_label(REGIONS[i])
                                                   for i in 1:length(REGIONS)], 1, :))
    # No in-figure title: the caption carries it, and an IEEE figure should not
    # repeat itself. The margin drops accordingly so the legend sits just above
    # the first panel rather than under an empty band.
    p = PlotlyJS.Plot(ieee_layout(sp; width=w, height=h,
        # 4 columns: 6 entries wrap to 4 + 2 (clipped variant) or 6 entries to
        # 4 + 2, keeping the legend block compact above the first panel.
        legend=boxed_leg(1.028; ncol=4), showlegend=true,
        margin=attr(l=62, r=16, t=92, b=52)))

    ts = sort(unique(P.time))
    at = ts[1]
    offscale = Dict{String,Int}()

    for (i, rg) in enumerate(REGIONS)
        ref = R[R.region .== rg, :]
        sort!(ref, :time)
        if clip
            lo, hi = window(ref.ROP)
        else
            # Full-range variant: the window spans every value actually plotted,
            # so nothing is clipped and no caret glyph is drawn. The cost is that
            # one diverging formulation sets the scale for the whole panel - which
            # is exactly what the clipped variant exists to prevent, and why both
            # are reported rather than one being chosen.
            vals = Float64[nz(ref.ROP)...]
            for f in FORMS
                s = P[(P.formulation .== f) .& (P.region .== rg), :]
                append!(vals, [pr for (ok, pr) in zip(s.ok, s.price) if ok])
            end
            lo, hi = extrema(vals)
            pad = 0.04 * max(hi - lo, 1.0)
            lo -= pad; hi += pad
        end

        # AEMO reference first, so the formulations draw over it.
        add_trace!(p, scatter(x=ref.time, y=ref.ROP, mode="lines",
                              showlegend=false, connectgaps=false,
                              line=attr(color=C_AEMO, width=2.1),
                              hovertemplate="%{x|%H:%M}  %{y:.2f}<extra>baseline</extra>"),
                   row=i, col=1)

        for f in FORMS
            s = P[(P.formulation .== f) .& (P.region .== rg), :]
            sort!(s, :time)
            y = [ok ? pr : missing for (ok, pr) in zip(s.ok, s.price)]
            nhi, nlo = add_clipped_series!(p, s.time, y; lo=lo, hi=hi,
                                           color=FORM_COLOR[f], dash=FORM_DASH[f],
                                           row=i, col=1, width=1.0,
                                           name=FORM_LABEL[f])
            offscale[f] = get(offscale, f, 0) + nhi + nlo
        end

        set_axis!(p, "yaxis", i; range=[lo, hi],
                  title=axtitle("Price ($U_PRICE)"))
    end

    # Legend proxies: full-size swatches for a key that stays readable at 7.5 pt.
    legend_proxy!(p; kind=:line, name=REF_LABEL[], color=C_AEMO, row=1, col=1,
                  at=at, width=2.6)
    for f in FORMS
        legend_proxy!(p; kind=:line, name=FORM_LABEL[f], color=FORM_COLOR[f],
                      row=1, col=1, at=at, width=2.2, dash=FORM_DASH[f])
    end
    clip && legend_proxy!(p; kind=:marker, name="off scale (see T1)", color=MUTED,
                          row=1, col=1, at=at, symbol="triangle-up", size=8)

    set_axis!(p, "xaxis", 5; title=axtitle("Time of day (AEST), 2025-09-02 04:05 → 09-03 04:00"),
              tickformat="%H:%M", dtick=2*3600*1000)
    style_panel_titles!(p); style_all_axes!(p)

    noff = sum(values(offscale))
    CAPTIONS[clip ? "N1" : "N1B"] = clip ? "Regional reference-node price over one NEM trading day " *
        "(288 five-minute intervals, 2025-09-02 04:05 to 2025-09-03 04:00), for the " *
        "network-constrained nodal dispatch solved under six power-flow formulations, " *
        "against AEMO's published regional reference price (ROP, orange). " *
        "The vertical window of each panel is set by the 1st--99th percentile of the ROP, " *
        "not of the model output, so that a diverging formulation cannot rescale the panel. " *
        "Values leaving the window are retained as caret glyphs on the frame edge they " *
        "exited (\\(\\triangle\\) above, \\(\\triangledown\\) below); intervals whose solve " *
        "did not converge appear as breaks in the line. $(noff) of " *
        "$(length(ts) * length(REGIONS) * length(FORMS)) plotted values lie off scale, " *
        "almost all of them from the QC relaxation; magnitudes are given in Table~I." :
        "Regional reference-node price over the same trading day and the same five " *
        "formulations as Fig.~\\ref{fig:n1}, plotted at FULL RANGE: each panel's " *
        "window spans every value actually solved, so nothing is clipped and no " *
        "caret glyphs appear. The two figures are the same data under two reading " *
        "rules. Here the excursions are shown at their true magnitude, which is the " *
        "honest view of how far a formulation departs; the cost is that a single " *
        "diverging series sets the scale for the whole panel and compresses the " *
        "agreement of the others into the axis. Fig.~\\ref{fig:n1} inverts that " *
        "trade, windowing on the published price so the bulk stays legible. Neither " *
        "view is sufficient alone, which is the point of showing both."
    return p, w, h
end

"Full-range variant of N1: no clipping, no caret glyphs, no in-figure title."
figure_N1B(P, D, R, B) = figure_N1(P, D, R, B; clip=false)

# =============================================================================
# N2 - Accuracy and reliability
# =============================================================================
"""
Accuracy and reliability read together, because on this network they are the
same story: the formulations that diverge are also the ones that fail to solve.

(a) signed error distribution per formulation, on a symmetric-log axis so a
    \$10^6 outlier and a \$1 error can share one frame;
(b) absolute error by region and formulation (median, robust);
(c) solve-status strip - one cell per interval per formulation, so a reader can
    see WHEN the solver failed, not just how often.
"""
function figure_N2(P, D, R, B)
    w, h = COL2, 720
    sp = PlotlyJS.Subplots(rows=3, cols=1, vertical_spacing=0.105,
                           row_heights=[0.40, 0.30, 0.30],
                           subplot_titles=reshape(["(a) Absolute price error vs AEMO ROP",
                                                    "(b) Median absolute error by region",
                                                    "(c) Solve status by interval"], 1, :))
    p = PlotlyJS.Plot(ieee_layout(sp; width=w, height=h,
        title=figtitle("Accuracy and numerical reliability across formulations",
                       height=h),
        legend=boxed_leg(1.055), showlegend=true,
        margin=attr(l=64, r=16, t=118, b=48)))

    # (a) error distribution, symmetric log
    for f in FORMS
        # Log axis cannot represent sign or zero: the box is drawn on |error|
        # (exact matches, |e| < 1e-9, are excluded from the log view and are
        # instead reported as the median bias column of Table I).
        e = filter(>(1e-9), abs.(nz(P[P.formulation .== f, :err])))
        isempty(e) && continue
        add_trace!(p, box(y=e, name=FORM_LABEL[f], showlegend=false,
                          boxpoints="outliers", marker=attr(size=2.2, color=FORM_COLOR[f]),
                          line=attr(color=FORM_COLOR[f], width=1.0),
                          fillcolor="rgba(0,0,0,0)",
                          hovertemplate="%{y:.3f}<extra>$(FORM_LABEL[f])</extra>"),
                   row=1, col=1)
    end
    set_axis!(p, "yaxis", 1; type="log",
              title=axtitle("Absolute error ($U_PRICE), log scale"))

    # (b) median |error| by region x formulation
    for f in FORMS
        ys = Float64[]
        for rg in REGIONS
            e = abs.(nz(P[(P.formulation .== f) .& (P.region .== rg), :err]))
            push!(ys, isempty(e) ? NaN : median(e))
        end
        add_trace!(p, bar(x=[region_label(r) for r in REGIONS], y=ys,
                          name=FORM_LABEL[f], showlegend=false,
                          marker=attr(color=FORM_COLOR[f], line=attr(width=0)),
                          hovertemplate="%{x}  %{y:.3f}<extra>$(FORM_LABEL[f])</extra>"),
                   row=2, col=1)
    end
    set_axis!(p, "yaxis", 2; type="log", title=axtitle("Median |error| ($U_PRICE)"))
    set_axis!(p, "xaxis", 2; title=axtitle("Region"))

    # (c) status strip: one marker per interval per formulation
    ts = sort(unique(P.time))
    for (k, f) in enumerate(FORMS)
        s = P[P.formulation .== f, :]
        # A formulation is counted as converged for an interval only if EVERY
        # region converged - a partial solve is not a usable market result.
        g = combine(groupby(s, :time), :ok => all => :ok)
        sort!(g, :time)
        bad = g[.!g.ok, :time]
        add_trace!(p, scatter(x=g.time, y=fill(k, nrow(g)), mode="markers",
                              showlegend=false, hoverinfo="skip",
                              marker=attr(color=FORM_COLOR[f], size=3.0, symbol="square")),
                   row=3, col=1)
        if !isempty(bad)
            add_trace!(p, scatter(x=bad, y=fill(k, length(bad)), mode="markers",
                                  showlegend=false,
                                  marker=attr(color=C_CRIT, size=4.6, symbol="x-thin",
                                              line=attr(width=1.1, color=C_CRIT)),
                                  hovertemplate="%{x|%H:%M} not converged<extra>$(FORM_LABEL[f])</extra>"),
                       row=3, col=1)
        end
    end
    set_axis!(p, "yaxis", 3; tickmode="array", tickvals=collect(1:length(FORMS)),
              ticktext=[FORM_LABEL[f] for f in FORMS], range=[0.4, length(FORMS)+0.6],
              title=axtitle(""))
    set_axis!(p, "xaxis", 3; title=axtitle("Time of day (AEST)"),
              tickformat="%H:%M", dtick=2*3600*1000)

    at = ts[1]
    for f in FORMS
        legend_proxy!(p; kind=:marker, name=FORM_LABEL[f], color=FORM_COLOR[f],
                      row=2, col=1, at=region_label(REGIONS[1]), size=9, symbol="square")
    end
    legend_proxy!(p; kind=:marker, name="not converged", color=C_CRIT, row=2, col=1,
                  at=region_label(REGIONS[1]), size=9, symbol="x-thin")
    style_panel_titles!(p); style_all_axes!(p)

    CAPTIONS["N2"] = "Accuracy and numerical reliability of the six formulations over the " *
        "same trading day. (a) Distribution of the absolute reference-node price error " *
        "against AEMO's ROP, pooled over the five regions, on a logarithmic axis so that " *
        "errors spanning six orders of magnitude share one frame; whiskers are Tukey and " *
        "outliers are drawn individually rather than suppressed. (b) Median absolute error " *
        "by region -- the median, not the mean, because a handful of failed solves dominates " *
        "the mean (Table~I reports both). (c) Solve status for every interval: a square marks " *
        "a converged solve and a red cross an interval where at least one region did not " *
        "reach optimality, so the reader can see when in the day each formulation failed. " *
        "Accuracy and reliability degrade together, in the order DC, DC+MLF, LP-AC, SOC, AC, QC."
    return p, w, h
end

# =============================================================================
# N3 - Losses
# =============================================================================
"""
(a) total network losses over the day by formulation - the physical quantity the
    formulations disagree about most;
(b) the loss component of each regional price under the DC model, which is where
    losses enter the SETTLEMENT rather than the power flow;
(c) loss distribution per formulation.
"""
function figure_N3(P, D, R, B)
    w, h = COL2, 760
    sp = PlotlyJS.Subplots(rows=3, cols=1, vertical_spacing=0.095,
                           subplot_titles=reshape(["(a) Total network losses",
                                                    "(b) Loss component of regional price (DC)",
                                                    "(c) Distribution of total losses"], 1, :))
    p = PlotlyJS.Plot(ieee_layout(sp; width=w, height=h,
        title=figtitle("Network losses and their price signature", height=h),
        legend=boxed_leg(1.05), showlegend=true,
        margin=attr(l=64, r=16, t=116, b=48)))

    # (a) system losses, one series per formulation (losses are a system
    #     quantity, so take the first region's row per (time, formulation)).
    lw = combine(groupby(P, [:formulation, :time]),
                 :losses_mw => safefirst => :losses,
                 :ok => all => :ok)
    lref = nz(lw[lw.formulation .== "DCP", :losses])
    lo = min(-50.0, isempty(lref) ? -50.0 : minimum(lref) - 50)
    hi = 1600.0
    for f in FORMS
        s = lw[lw.formulation .== f, :]; sort!(s, :time)
        y = [ok ? v : missing for (ok, v) in zip(s.ok, s.losses)]
        add_clipped_series!(p, s.time, y; lo=lo, hi=hi, color=FORM_COLOR[f],
                            dash=FORM_DASH[f], row=1, col=1, width=1.1,
                            name=FORM_LABEL[f])
    end
    set_axis!(p, "yaxis", 1; range=[lo, hi], title=axtitle("Losses ($U_MW)"))
    set_axis!(p, "xaxis", 1; tickformat="%H:%M", dtick=3*3600*1000)

    # (b) loss component of the LMP, DC formulation
    dd = D[D.formulation .== "DCP", :]
    for rg in REGIONS
        s = dd[dd.region .== rg, :]; sort!(s, :time)
        y = [ok === true ? v : missing for (ok, v) in zip(s.ok, s.loss)]
        add_trace!(p, scatter(x=s.time, y=y, mode="lines", showlegend=false,
                              connectgaps=false,
                              line=attr(color=REGION_COLOR[rg], width=1.0),
                              hovertemplate="%{x|%H:%M}  %{y:.2f}<extra>$(region_label(rg))</extra>"),
                   row=2, col=1)
    end
    set_axis!(p, "yaxis", 2; title=axtitle("Loss component ($U_PRICE)"))
    set_axis!(p, "xaxis", 2; tickformat="%H:%M", dtick=3*3600*1000)

    # (c) loss distribution
    for f in FORMS
        v = nz(lw[(lw.formulation .== f) .& lw.ok, :losses])
        isempty(v) && continue
        add_trace!(p, box(y=v, name=FORM_LABEL[f], showlegend=false,
                          boxpoints="outliers", marker=attr(size=2.2, color=FORM_COLOR[f]),
                          line=attr(color=FORM_COLOR[f], width=1.0),
                          fillcolor="rgba(0,0,0,0)"),
                   row=3, col=1)
    end
    set_axis!(p, "yaxis", 3; title=axtitle("Losses ($U_MW)"))

    at = sort(unique(P.time))[1]
    for f in FORMS
        legend_proxy!(p; kind=:line, name=FORM_LABEL[f], color=FORM_COLOR[f],
                      row=1, col=1, at=at, width=2.2, dash=FORM_DASH[f])
    end
    for rg in REGIONS
        legend_proxy!(p; kind=:line, name=region_label(rg), color=REGION_COLOR[rg],
                      row=2, col=1, at=at, width=2.2, group="reg")
    end
    style_panel_titles!(p); style_all_axes!(p)

    CAPTIONS["N3"] = "Network losses and the price they create. (a) Total network losses " *
        "over the trading day under each formulation; the DC model carries losses only " *
        "through its loss approximation, while the AC model and its relaxations solve them, " *
        "and the three relaxations bracket the AC result from above. Values above " *
        "$(round(Int,hi))~MW leave the window as caret glyphs and non-converged intervals " *
        "are breaks. (b) The loss component of the reference-node price under the DC " *
        "formulation, by region -- the settlement signature of the same physics, largest and " *
        "most negative in the electrically remote regions (SA, TAS). (c) Distribution of " *
        "total losses per formulation, showing that the disagreement is systematic rather " *
        "than confined to a few intervals."
    return p, w, h
end

# =============================================================================
# N4 - Marginal loss factors
# =============================================================================
"""
The regional price factor implied by the nodal solution, and what AEMO's static
marginal loss factors are worth against it.

With the nodal price decomposed as `lmp = energy + congestion + loss` and the
energy component common to the system, the ratio `lmp/energy` is the marginal
loss factor of that reference node ONLY IF the congestion component genuinely
vanishes there. In this run it does not vanish physically - it vanishes *by
construction*, because the decomposition attributes congestion along the
inter-regional path and no such path limit binds, while the network is heavily
congested internally (see `figure_N5`). The loss term is therefore a RESIDUAL
carrying both losses and intra-regional congestion, and the ratio is a combined
loss-and-congestion factor, not a pure MLF: it reaches 0.13 in Tasmania, far
below any physical loss factor, and goes negative when regions price apart.

The figure is labelled accordingly, and the genuine MLF result is panel (c) -
the price difference between the DC model and the same model carrying AEMO's
static marginal loss factors, which is what the loss factors are actually worth
in settlement.

The ratio is undefined as the energy component approaches zero, so it is
computed only where |energy| exceeds MLF_FLOOR and left as a gap elsewhere
rather than plotted as a spike.
"""
const MLF_FLOOR = 5.0   # $/MWh

function implied_mlf(D::DataFrame, form::String)
    d = D[D.formulation .== form, :]
    out = DataFrame(time=DateTime[], region=String[], mlf=Union{Missing,Float64}[])
    for r in eachrow(d)
        ok = r.ok === true
        v = (!ok || ismissing(r.energy) || abs(r.energy) < MLF_FLOOR) ? missing :
            (r.lmp / r.energy)
        push!(out, (r.time, r.region, v))
    end
    return out
end

function figure_N4(P, D, R, B)
    w, h = COL2, 380
    sp = PlotlyJS.Subplots(rows=1, cols=3, horizontal_spacing=0.075,
                           column_widths=[0.44, 0.28, 0.28],
                           subplot_titles=reshape(["(a) Implied price factor λ/λᴱ over the day (DC)",
                                                   "(b) By region (DC)",
                                                   "(c) By formulation"], 1, :))
    p = PlotlyJS.Plot(ieee_layout(sp; width=w, height=h,
        title=figtitle("Loss and congestion in the nodal price", height=h),
        legend=boxed_leg(1.10), showlegend=true,
        margin=attr(l=60, r=16, t=104, b=52)))

    m = implied_mlf(D, "DCP")
    lo, hi = 0.0, 1.6

    for rg in REGIONS
        s = m[m.region .== rg, :]; sort!(s, :time)
        add_clipped_series!(p, s.time, s.mlf; lo=lo, hi=hi,
                            color=REGION_COLOR[rg], dash="solid",
                            row=1, col=1, width=1.0, name=region_label(rg))
    end
    add_trace!(p, scatter(x=[minimum(m.time), maximum(m.time)], y=[1.0, 1.0],
                          mode="lines", showlegend=false, hoverinfo="skip",
                          line=attr(color=MUTED, width=0.8, dash="dot")),
               row=1, col=1)
    set_axis!(p, "yaxis", 1; range=[lo, hi], title=axtitle("λ / λᴱ  (-)"))
    set_axis!(p, "xaxis", 1; title=axtitle("Time of day (AEST)"),
              tickformat="%H:%M", dtick=6*3600*1000)

    for rg in REGIONS
        v = nz(m[m.region .== rg, :mlf])
        isempty(v) && continue
        add_trace!(p, box(y=v, name=region_label(rg), showlegend=false,
                          boxpoints=false, line=attr(color=REGION_COLOR[rg], width=1.0),
                          fillcolor="rgba(0,0,0,0)"),
                   row=1, col=2)
    end
    # Clipped for legibility: South Australian whiskers reach roughly 15.
    set_axis!(p, "yaxis", 2; range=[-2.0, 3.0], title=axtitle("λ / λᴱ  (-)"))

    for f in FORMS
        v = nz(implied_mlf(D, f).mlf)
        isempty(v) && continue
        add_trace!(p, box(y=v, name=FORM_LABEL[f], showlegend=false,
                          boxpoints=false, line=attr(color=FORM_COLOR[f], width=1.0),
                          fillcolor="rgba(0,0,0,0)"),
                   row=1, col=3)
    end
    set_axis!(p, "yaxis", 3; range=[lo, hi], title=axtitle("λ / λᴱ  (-)"))

    at = minimum(m.time)
    for rg in REGIONS
        legend_proxy!(p; kind=:line, name=region_label(rg), color=REGION_COLOR[rg],
                      row=1, col=1, at=at, width=2.2, group="reg")
    end
    style_panel_titles!(p); style_all_axes!(p)

    CAPTIONS["N4"] = "The price factor implied by the nodal decomposition. With " *
        "\$\\lambda = \\lambda^{E} + \\lambda^{C} + \\lambda^{L}\$ and the energy component " *
        "common to the system, \$\\lambda/\\lambda^{E}\$ would be the reference node's " *
        "marginal loss factor if the congestion component vanished there. It does " *
        "vanish -- but by construction, not physically: the decomposition attributes " *
        "congestion along the inter-regional path, no such path limit binds in this " *
        "window, and the network is nevertheless congested internally " *
        "(Fig.~\\ref{fig:n6}). The plotted ratio is therefore a combined " *
        "loss-and-congestion factor and an upper bound in magnitude on the pure loss " *
        "factor, which is why it reaches 0.13 in Tasmania -- far below any physical " *
        "loss factor -- and turns negative when regions price apart. " *
        "(a) The ratio through the day by region against unity (dotted), left as a gap " *
        "where \$|\\lambda^{E}| < \\\$$(Int(MLF_FLOOR))\$/MWh since it is undefined as " *
        "\$\\lambda^{E}\\to 0\$; (b) its distribution by region, with New South Wales at " *
        "unity by construction as the reference node (clipped to [-2,3]; the South " *
        "Australian whiskers reach roughly 15); (c) by formulation."
    return p, w, h
end

# =============================================================================
# N5 - Congestion, from the binding shadow-price ledger
# =============================================================================
"""
Congestion has to be read from the ACTIVE-CONSTRAINT LEDGER, not from the
`congestion` column of the price decomposition.

That column is identically zero at every regional reference node under DCP and
DCP_MLF, and is numerical noise (|.| < 1e-3 \$/MWh) under the AC formulations,
because the decomposition attributes congestion along the interconnector path
between reference nodes, and those paths carry no binding limit in this window.
The network is nonetheless congested: the security ledger records thousands of
binding `network_security` constraints per interval, with shadow prices
averaging several hundred \$/MWh. Plotting the decomposition column would
therefore have shown a flat zero and licensed the false conclusion that the day
was uncongested. This figure uses the ledger instead, and the discrepancy is
itself reported as a result.
"""
function figure_N5(P, D, R, B)
    w, h = COL2, 700
    if isempty(B)
        @warn "Binding ledger not available; skipping N5."
        return nothing, 0, 0
    end
    sp = PlotlyJS.Subplots(rows=2, cols=2, vertical_spacing=0.145,
                           horizontal_spacing=0.09,
                           column_widths=[0.52, 0.48],
                           subplot_titles=reshape(["(a) Binding network-security constraints",
                                                    "(b) Congestion shadow price (sum of |duals|)",
                                                    "(c) Most frequently binding constraints (DC)",
                                                    "(d) Shadow price by constraint family (DC)"], 1, :))
    p = PlotlyJS.Plot(ieee_layout(sp; width=w, height=h,
        title=figtitle("Network congestion from the active-constraint ledger", height=h),
        legend=boxed_leg(1.05), showlegend=true,
        margin=attr(l=66, r=16, t=112, b=52)))

    ns = B[B.family .== "network_security", :]

    # (a) count of binding security constraints per interval
    for f in FORMS
        s = ns[ns.formulation .== f, :]
        isempty(s) && continue
        g = combine(groupby(s, :time), nrow => :n); sort!(g, :time)
        add_trace!(p, scatter(x=g.time, y=g.n, mode="lines", showlegend=false,
                              connectgaps=false,
                              line=attr(color=FORM_COLOR[f], width=1.0, dash=FORM_DASH[f]),
                              hovertemplate="%{x|%H:%M}  %{y:.0f}<extra>$(FORM_LABEL[f])</extra>"),
                   row=1, col=1)
    end
    set_axis!(p, "yaxis", 1; title=axtitle("Binding constraints (count)"))
    set_axis!(p, "xaxis", 1; tickformat="%H:%M", dtick=6*3600*1000)

    # (b) total congestion shadow price per interval
    for f in FORMS
        s = ns[ns.formulation .== f, :]
        isempty(s) && continue
        g = combine(groupby(s, :time), :dual => (x -> sum(abs, skipmissing(x))) => :d)
        sort!(g, :time)
        add_trace!(p, scatter(x=g.time, y=g.d, mode="lines", showlegend=false,
                              connectgaps=false,
                              line=attr(color=FORM_COLOR[f], width=1.0, dash=FORM_DASH[f]),
                              hovertemplate="%{x|%H:%M}  %{y:.3g}<extra>$(FORM_LABEL[f])</extra>"),
                   row=1, col=2)
    end
    set_axis!(p, "yaxis", 2; type="log", title=axtitle("Σ|shadow price| ($U_PRICE)"))
    set_axis!(p, "xaxis", 2; tickformat="%H:%M", dtick=6*3600*1000)

    # (c) most frequently binding constraints under the DC model
    dcp = ns[ns.formulation .== "DCP", :]
    if !isempty(dcp)
        g = combine(groupby(dcp, :constraint),
                    nrow => :n, :dual => (x -> mean(abs, skipmissing(x))) => :mdual)
        sort!(g, :n, rev=true)
        top = first(g, 12)
        reverse!(top)                       # highest bar at the top
        add_trace!(p, bar(x=top.n, y=top.constraint, orientation="h",
                          showlegend=false,
                          marker=attr(color=FORM_COLOR["DCP"], line=attr(width=0)),
                          hovertemplate="%{y}  %{x:.0f} intervals<extra></extra>"),
                   row=2, col=1)
        set_axis!(p, "xaxis", 3; title=axtitle("Intervals binding (of 288)"))
        set_axis!(p, "yaxis", 3; tickfont=attr(family=FONT, size=pt(6.2), color=INK_2))
    end

    # (d) shadow price by family
    fam = B[B.formulation .== "DCP", :]
    for (i, fm) in enumerate(sort(unique(fam.family)))
        v = abs.(nz(fam[fam.family .== fm, :dual]))
        v = filter(>(0), v)
        isempty(v) && continue
        add_trace!(p, box(y=v, name=fm, showlegend=false, boxpoints=false,
                          line=attr(color=FORM_COLOR[FORMS[min(i, length(FORMS))]], width=1.0),
                          fillcolor="rgba(0,0,0,0)"),
                   row=2, col=2)
    end
    set_axis!(p, "yaxis", 4; type="log", title=axtitle("|shadow price| ($U_PRICE)"))
    set_axis!(p, "xaxis", 4; title=axtitle("Constraint family"))

    at = minimum(ns.time)
    for f in FORMS
        legend_proxy!(p; kind=:line, name=FORM_LABEL[f], color=FORM_COLOR[f],
                      row=1, col=1, at=at, width=2.2, dash=FORM_DASH[f])
    end
    style_panel_titles!(p); style_all_axes!(p)

    CAPTIONS["N5"] = "Network congestion, taken from the active-constraint ledger rather " *
        "than from the congestion term of the price decomposition. " *
        "(a) Number of binding network-security constraints per dispatch interval under each " *
        "formulation, and (b) the corresponding sum of absolute shadow prices on a " *
        "logarithmic axis. (c) The twelve constraints that bind most often under the DC " *
        "model, and (d) the distribution of shadow prices by constraint family. " *
        "The congestion component of the reference-node price decomposition is identically " *
        "zero throughout this day, because it is attributed along the interconnector path " *
        "between reference nodes and no such path limit binds; the network is nevertheless " *
        "congested inside the regions, as panels (a)--(d) show. Reading congestion from the " *
        "decomposition alone would have licensed the opposite conclusion."
    return p, w, h
end

# =============================================================================
# N6 - Price decomposition in the network dispatch
# =============================================================================
"""
The three quantities a locational price is made of, side by side, for the DC
formulation: the price itself, the congestion signal, and the loss component.

The congestion panel deliberately does NOT plot the decomposition's congestion
term. That term is identically zero at every regional reference node all day,
because it is attributed along the inter-regional path and no such path limit
binds; plotting it would draw a flat line at zero and imply an uncongested
network. The congestion signal shown is the one that actually exists - the sum
of absolute shadow prices on the binding network-security constraints - and the
gap between the two is itself reported (Section on congestion).
"""
function figure_N6(P, D, R, B)
    w, h = COL2, 700
    sp = PlotlyJS.Subplots(rows=2, cols=2, vertical_spacing=0.135,
                           horizontal_spacing=0.085,
                           subplot_titles=reshape(["(a) Regional reference-node price λ (DC)",
                                                   "(b) Congestion shadow price (security ledger)",
                                                   "(c) Loss component λᴸ of the price (DC)",
                                                   "(d) Mean price composition by region (DC)"], 1, :))
    p = PlotlyJS.Plot(ieee_layout(sp; width=w, height=h,
        title=figtitle("Price decomposition in the network dispatch: " *
                       "energy, congestion and loss", height=h),
        legend=boxed_leg(1.05), showlegend=true,
        margin=attr(l=64, r=16, t=112, b=52)))

    dd = D[(D.formulation .== "DCP"), :]

    # (a) the price itself
    for rg in REGIONS
        s = dd[dd.region .== rg, :]; sort!(s, :time)
        y = [ok === true ? v : missing for (ok, v) in zip(s.ok, s.lmp)]
        add_clipped_series!(p, s.time, y; lo=-250.0, hi=700.0,
                            color=REGION_COLOR[rg], dash="solid",
                            row=1, col=1, width=1.0, name=region_label(rg))
    end
    set_axis!(p, "yaxis", 1; range=[-250, 700], title=axtitle("λ ($U_PRICE)"))
    set_axis!(p, "xaxis", 1; tickformat="%H:%M", dtick=6*3600*1000)

    # (b) congestion, from the ledger rather than the (identically zero) term
    if !isempty(B)
        ns = B[(B.family .== "network_security") .& (B.formulation .== "DCP"), :]
        if !isempty(ns)
            g = combine(groupby(ns, :time),
                        :dual => (x -> sum(abs, skipmissing(x))) => :d,
                        nrow => :n)
            sort!(g, :time)
            add_trace!(p, scatter(x=g.time, y=g.d, mode="lines", showlegend=false,
                                  connectgaps=false,
                                  line=attr(color=FORM_COLOR["DCP"], width=1.1),
                                  hovertemplate="%{x|%H:%M}  %{y:.3g}<extra>Σ|μ|</extra>"),
                       row=1, col=2)
        end
    end
    set_axis!(p, "yaxis", 2; type="log", title=axtitle("Σ|μ| ($U_PRICE)"))
    set_axis!(p, "xaxis", 2; tickformat="%H:%M", dtick=6*3600*1000)

    # (c) loss component
    for rg in REGIONS
        s = dd[dd.region .== rg, :]; sort!(s, :time)
        y = [ok === true ? v : missing for (ok, v) in zip(s.ok, s.loss)]
        add_clipped_series!(p, s.time, y; lo=-500.0, hi=120.0,
                            color=REGION_COLOR[rg], dash="solid",
                            row=2, col=1, width=1.0, name=region_label(rg))
    end
    set_axis!(p, "yaxis", 3; range=[-500, 120], title=axtitle("λᴸ ($U_PRICE)"))
    set_axis!(p, "xaxis", 3; title=axtitle("Time of day (AEST)"),
              tickformat="%H:%M", dtick=6*3600*1000)

    # (d) mean composition per region: energy vs loss (congestion is ~0 and is
    #     shown as a labelled zero rather than omitted, so its absence is explicit)
    en = Float64[]; lo = Float64[]; cg = Float64[]
    for rg in REGIONS
        s = dd[(dd.region .== rg) .& (dd.ok .=== true), :]
        push!(en, safemean(s.energy)); push!(lo, safemean(s.loss))
        push!(cg, safemean(abs.(skipmissing(s.congestion))))
    end
    xs = [region_label(r) for r in REGIONS]
    add_trace!(p, bar(x=xs, y=en, name="energy λᴱ", showlegend=false,
                      marker=attr(color="#2a78d6", line=attr(width=0))), row=2, col=2)
    add_trace!(p, bar(x=xs, y=lo, name="loss λᴸ", showlegend=false,
                      marker=attr(color="#eda100", line=attr(width=0))), row=2, col=2)
    add_trace!(p, bar(x=xs, y=cg, name="congestion λᶜ", showlegend=false,
                      marker=attr(color=C_CRIT, line=attr(width=0))), row=2, col=2)
    p.layout[:barmode] = "relative"
    set_axis!(p, "yaxis", 4; title=axtitle("Mean component ($U_PRICE)"))
    set_axis!(p, "xaxis", 4; title=axtitle("Region"))

    at = minimum(dd.time)
    for rg in REGIONS
        legend_proxy!(p; kind=:line, name=region_label(rg), color=REGION_COLOR[rg],
                      row=1, col=1, at=at, width=2.2, group="reg")
    end
    for (nm, c) in (("energy λᴱ", "#2a78d6"), ("loss λᴸ", "#eda100"),
                    ("congestion λᶜ (≈0)", C_CRIT))
        legend_proxy!(p; kind=:marker, name=nm, color=c, row=2, col=2,
                      at=xs[1], size=9, symbol="square", group=nm)
    end
    style_panel_titles!(p); style_all_axes!(p)

    CAPTIONS["N6"] = "Price decomposition in the network-constrained dispatch under the " *
        "DC formulation, \$\\lambda = \\lambda^{E} + \\lambda^{C} + \\lambda^{L}\$. " *
        "(a) The regional reference-node price itself; (c) its loss component, which is " *
        "the entire inter-regional spread and reaches \$-\\\$467\$/MWh in Tasmania; " *
        "(d) the mean composition by region, with the congestion component drawn " *
        "explicitly at its measured value of zero rather than omitted. " *
        "(b) is the congestion signal that actually exists: the summed absolute shadow " *
        "price of the binding network-security constraints, on a logarithmic axis. " *
        "The decomposition's own congestion term is identically zero at every reference " *
        "node for all 288 intervals, because it is attributed along the inter-regional " *
        "path and no path limit binds -- while the security ledger shows a median of " *
        "three constraints binding per interval at a median \\\$454/MWh. A " *
        "decomposition read without the ledger would report this day as uncongested."
    return p, w, h
end

# =============================================================================
# N7 - The congestion component, for every formulation
# =============================================================================
"""
The congestion term of the decomposition, isolated and shown for all
formulations, because it is the component that behaves least like the other two.

Panel (a) is the summed absolute shadow price of the binding network-security
constraints per interval; panel (b) is the distribution of the INDIVIDUAL
shadow prices behind that sum. The two together answer a question the sum alone
cannot: whether a formulation reports congestion because the network is
congested, or because its solver has left a large near-active set at numerically
zero prices. Those look identical in a count and nearly identical in a sum; they
are three orders of magnitude apart in the distribution.
"""
function figure_N7(P, D, R, B)
    w, h = COL2, 360
    if isempty(B)
        @warn "Binding ledger not available; skipping N7."
        return nothing, 0, 0
    end
    sp = PlotlyJS.Subplots(rows=1, cols=2, horizontal_spacing=0.10,
                           column_widths=[0.60, 0.40],
                           subplot_titles=reshape([
                             "(a) Congestion shadow price per interval, Σ|μ|",
                             "(b) Distribution of individual |μ|"], 1, :))
    p = PlotlyJS.Plot(ieee_layout(sp; width=w, height=h,
        legend=boxed_leg(1.10; ncol=5), showlegend=true,
        margin=attr(l=64, r=16, t=96, b=52)))

    ns = B[B.family .== "network_security", :]
    for f in FORMS
        s = ns[ns.formulation .== f, :]
        isempty(s) && continue
        g = combine(groupby(s, :time), :dual => (x -> sum(abs, skipmissing(x))) => :d)
        sort!(g, :time)
        add_trace!(p, scatter(x=g.time, y=g.d, mode="lines", showlegend=false,
                              connectgaps=false,
                              line=attr(color=FORM_COLOR[f], width=1.0, dash=FORM_DASH[f]),
                              hovertemplate="%{x|%H:%M}  %{y:.4g}<extra>$(FORM_LABEL[f])</extra>"),
                   row=1, col=1)
    end
    set_axis!(p, "yaxis", 1; type="log", title=axtitle("Σ|μ| ($U_PRICE)"))
    set_axis!(p, "xaxis", 1; title=axtitle("Time of day (AEST)"),
              tickformat="%H:%M", dtick=6*3600*1000)

    for f in FORMS
        v = filter(>(0), abs.(nz(ns[ns.formulation .== f, :dual])))
        isempty(v) && continue
        add_trace!(p, box(y=v, name=FORM_LABEL[f], showlegend=false, boxpoints=false,
                          line=attr(color=FORM_COLOR[f], width=1.0),
                          fillcolor="rgba(0,0,0,0)"),
                   row=1, col=2)
    end
    set_axis!(p, "yaxis", 2; type="log", title=axtitle("|μ| ($U_PRICE)"))
    set_axis!(p, "xaxis", 2; title=axtitle("Formulation"))

    at = minimum(ns.time)
    for f in FORMS
        legend_proxy!(p; kind=:line, name=FORM_LABEL[f], color=FORM_COLOR[f],
                      row=1, col=1, at=at, width=2.2, dash=FORM_DASH[f])
    end
    style_panel_titles!(p); style_all_axes!(p)

    CAPTIONS["N7"] = "The congestion component of the price decomposition, " *
        "\\(\\lambda^{C}\\), for every formulation. (a) Summed absolute shadow price of " *
        "the binding network-security constraints per dispatch interval; (b) the " *
        "distribution of the individual shadow prices behind that sum, both " *
        "logarithmic. The DC model binds a median of three constraints per interval " *
        "at a median individual price of 919~\\\$/MWh -- few constraints, each " *
        "economically material. The AC model and its relaxations bind 12--17 per " *
        "interval at median individual prices of order \\(10^{-5}\\)~\\\$/MWh: a " *
        "near-active set carrying no economic weight, which a constraint COUNT cannot " *
        "distinguish from real congestion and a summed shadow price barely can. " *
        "Panel (b) separates the two by three orders of magnitude."
    return p, w, h
end

# =============================================================================
# Tables (booktabs LaTeX)
# =============================================================================
# NEM constraint identifiers use the SPD operator characters `>`, `^` and `#`
# (e.g. `V^^N_NIL_1`, `N>NIL_969`, `Q>CPGG1_CPWU_CPGG2`), every one of which is
# special in LaTeX - `^` silently becomes a superscript and `^^` is an input
# escape that can swallow the following characters. `replace` with several pairs
# makes a SINGLE pass, so escaping the backslash alongside the rest is safe.
tex_esc(s) = replace(String(s),
                     "\\" => raw"\textbackslash{}",
                     "_" => raw"\_", "#" => raw"\#", "&" => raw"\&",
                     "%" => raw"\%", "\$" => raw"\$",
                     "{" => raw"\{", "}" => raw"\}",
                     "^" => raw"\textasciicircum{}",
                     "~" => raw"\textasciitilde{}",
                     "<" => raw"\textless{}", ">" => raw"\textgreater{}")

"Format a number for a table cell; `--` for a missing/NaN entry."
function tnum(v; d=2)
    (v === missing || (v isa Real && isnan(v))) && return "--"
    a = abs(v)
    a >= 1e5 && return @sprintf("%.2e", v)
    return string(round(v, digits=d))
end

function write_tex(name, body)
    path = joinpath(FIG_DIR, name)
    open(path, "w") do io
        println(io, "% Auto-generated by script/plot_network_day_figures.jl")
        println(io, "% Source: network_day_*_$(DAY_TAG).csv + nem_prices_vs_rop_sept2025.csv")
        print(io, body)
    end
    println("  $(name)")
    return path
end

"""
T1 - the single comprehensive results table.

Three blocks, all measured against the SAME baseline: a zonal dispatch of the
same day on the MLF-scaled bid stack (see `run_network_day.jl`).

  * regional reference-node price error -- how well the formulation reproduces
    the baseline at the five pricing nodes;
  * PARTICIPANT-NODE LMP deviation -- what a generator actually faces at its own
    bus. The regional reference node is one bus of about two thousand, so the
    regional columns can look reasonable while the fleet is priced systematically
    high or low. The over/under split is the sharpest form of that: an unbiased
    formulation puts roughly half the fleet either side.
    BOTH SIDES ARE CONNECTION-POINT PRICES. The nodal LMP already is one; the
    zonal price is at the regional reference node and a participant is settled
    on it as RRP x MLF, so the baseline is `zonal x gamma` for that unit.
    Comparing against the bare regional price instead would charge the fleet a
    spurious (1 - gamma) -- about 2% on the median unit and up to 20% at the
    extremes -- and it showed: on that basis the DC model appeared to carry a
    bias of -3.01 \$/MWh, where on the correct basis it is +0.24.
  * network losses, against NEMDE's published figure quoted in the note.

The convergence column is dropped: every formulation now solves the whole day
bar one interval, which the note records rather than spending a column on.
"""
function table_T1(P, D, R, B)
    rows = String[]
    demand_mw = NEM_DEMAND_MW
    pdev = Dict{String,Vector{Float64}}()
    if isfile(PARTIC_CSV)
        pv = CSV.read(PARTIC_CSV, DataFrame)
        for f in FORMS
            pdev[f] = nz(pv[pv.formulation .== f, :dev])
        end
    end
    npart = isempty(pdev) ? 0 : maximum(length(v) for v in values(pdev))
    for f in FORMS
        s = P[P.formulation .== f, :]
        e = nz(s.err); ae = abs.(e)
        lw = combine(groupby(s[s.ok, :], :time), :losses_mw => safefirst => :l)
        lv = nz(lw.l); medloss = isempty(lv) ? NaN : median(lv)
        d  = get(pdev, f, Float64[])
        over  = isempty(d) ? NaN : 100 * count(>(0.01), d) / length(d)
        under = isempty(d) ? NaN : 100 * count(<(-0.01), d) / length(d)
        push!(rows, join([
            tex_esc(FORM_LABEL[f]),
            tnum(isempty(ae) ? NaN : median(ae)),
            tnum(isempty(ae) ? NaN : quantile(ae, 0.95)),
            tnum(isempty(ae) ? NaN : mean(ae)),
            tnum(isempty(d) ? NaN : median(d)),
            tnum(isempty(d) ? NaN : mean(d); d=1),
            tnum(over; d=1), tnum(under; d=1),
            tnum(medloss; d=1),
            tnum(isnan(medloss) ? NaN : 100 * medloss / demand_mw; d=2),
            tnum(safemean(s.solve_s)),
        ], " & ") * " \\\\")
    end
    body = """
\\begin{table*}[!t]
\\caption{Network-constrained nodal dispatch over one NEM trading day (288
consecutive five-minute intervals, 2025-09-02 04:05 to 2025-09-03 04:00). All
quantities are measured against one baseline: a zonal dispatch of the same day
on the MLF-scaled bid stack. The regional block compares the five pricing nodes;
the participant-node block compares every mapped generator at its OWN bus, which
is the price it actually faces.}
\\label{tab:formulation}
\\centering
\\begin{tabular}{lrrrrrrrrrr}
\\toprule
 & \\multicolumn{3}{c}{Regional price error (\\\$/MWh)} & \\multicolumn{4}{c}{Participant-node LMP vs baseline} & \\multicolumn{2}{c}{Losses} & Solve \\\\
\\cmidrule(lr){2-4}\\cmidrule(lr){5-8}\\cmidrule(lr){9-10}
Formulation & med. & p95 & mean & med. (\\\$/MWh) & bias (\\\$/MWh) & over (\\%) & under (\\%) & med. (MW) & (\\% dem.) & (s) \\\\
\\midrule
$(join(rows, "\n"))
\\bottomrule
\\multicolumn{11}{p{0.98\\linewidth}}{\\footnotesize All five formulations solve
all 288 intervals, none falling back to acceptable tolerance, so a convergence
column would carry the same entry five times and is omitted. Participant-node statistics pool
$(npart > 0 ? string(npart) : "---") (interval, unit) observations per
formulation over mapped generators. The baseline for a participant is the zonal
regional price referred to its connection point, \$\\lambda_r \\gamma_u\$, since the
zonal run prices at the reference node while the nodal LMP is already at the
connection point; ``over'' and ``under'' are the shares priced above and below
that baseline by more than one cent. Losses as a share of demand
use the median total NEM demand over the window, $(round(Int, NEM_DEMAND_MW))~MW.
For reference, AEMO's published interconnector losses have a median of
$(tnum(NEMDE_LOSS_MED; d=1))~MW ($(tnum(100*NEMDE_LOSS_MED/NEM_DEMAND_MW; d=2))\\%),
and the market formulation books no intra-regional losses at all, so a DC model
that omits them sits below that figure and an AC model that solves them above it.}
\\end{tabular}
\\end{table*}
"""
    write_tex("tab1_formulation.tex", body)
end

function table_T2(P, D, R, B)
    rows = String[]
    for rg in REGIONS
        m = implied_mlf(D, "DCP")
        mv = nz(m[m.region .== rg, :mlf])
        dd = D[(D.formulation .== "DCP") .& (D.region .== rg), :]
        lo = nz(dd.loss); cg = abs.(nz(dd.congestion))
        e6 = nz(P[(P.formulation .== "DCP") .& (P.region .== rg), :err])
        push!(rows, join([
            region_label(rg),
            tnum(isempty(mv) ? NaN : median(mv); d=3),
            tnum(isempty(mv) ? NaN : quantile(mv, 0.05); d=3),
            tnum(isempty(mv) ? NaN : quantile(mv, 0.95); d=3),
            tnum(isempty(lo) ? NaN : median(lo)),
            tnum(isempty(lo) ? NaN : minimum(lo); d=1),
            tnum(isempty(cg) ? NaN : maximum(cg); d=4),
            tnum(isempty(e6) ? NaN : median(abs.(e6))),
        ], " & ") * " \\\\")
    end
    body = """
\\begin{table}[!t]
\\caption{Loss and congestion signature of the regional reference-node price
under the DC formulation. \$\\lambda/\\lambda^{E}\$ is the price factor implied by
the decomposition (computed only where \$|\\lambda^{E}|>\\\$$(Int(MLF_FLOOR))\$/MWh).
It equals the marginal loss factor only where the congestion component truly
vanishes; here that component is zero \\emph{by construction} -- it is attributed
along the inter-regional path, which never binds -- so the loss term is a residual
carrying intra-regional congestion as well, and the factor is a combined
loss-and-congestion factor. Values of 0.13 (TAS) are price separation, not
physical losses. The congestion column reports the \\emph{largest} absolute
congestion component seen all day, evidencing that it is zero to numerical
precision at every reference node; congestion is therefore read from the
active-constraint ledger (Fig.~\\ref{fig:n5}) instead.}
\\label{tab:regionmlf}
\\centering
\\begin{tabular}{lrrrrrrr}
\\toprule
 & \\multicolumn{3}{c}{\$\\lambda/\\lambda^{E}\$ (--)} & \\multicolumn{2}{c}{Loss comp. (\\\$/MWh)} & Max \$|\$cong.\$|\$ & Med. \$|\$err\$|\$ \\\\
\\cmidrule(lr){2-4}\\cmidrule(lr){5-6}
Region & median & p5 & p95 & median & min & (\\\$/MWh) & (\\\$/MWh) \\\\
\\midrule
$(join(rows, "\n"))
\\bottomrule
\\end{tabular}
\\end{table}
"""
    write_tex("tab2_region_mlf.tex", body)
end

"T3 - congestion ledger: the constraints that actually bind."
function table_T3(P, D, R, B)
    if isempty(B)
        @warn "Binding ledger not available; skipping T3."
        return nothing
    end
    ns = B[(B.formulation .== "DCP") .& (B.family .== "network_security"), :]
    isempty(ns) && return nothing
    g = combine(groupby(ns, :constraint),
                nrow => :n,
                :dual => (x -> mean(abs, skipmissing(x))) => :mdual,
                :dual => (x -> maximum(abs, skipmissing(x))) => :xdual)
    sort!(g, :n, rev=true)
    nint = length(unique(ns.time))
    rows = String[]
    for r in eachrow(first(g, 12))
        push!(rows, join([
            "\\texttt{" * tex_esc(r.constraint) * "}",
            string(r.n),
            @sprintf("%.0f", 100 * r.n / nint),
            tnum(r.mdual; d=1),
            tnum(r.xdual; d=1),
        ], " & ") * " \\\\")
    end
    body = """
\\begin{table}[!t]
\\caption{The twelve network-security constraints that bind most often over the
trading day under the DC formulation, with their shadow prices. These are the
constraints that make the nodal solution differ from a copper plate; none of
them appears in the congestion term of the reference-node price decomposition,
which is identically zero because that term is attributed along the
inter-regional path.}
\\label{tab:congestion}
\\centering
\\begin{tabular}{lrrrr}
\\toprule
 & Intervals & Share & \\multicolumn{2}{c}{\$|\$shadow price\$|\$ (\\\$/MWh)} \\\\
\\cmidrule(lr){4-5}
Constraint & binding & (\\%) & mean & max \\\\
\\midrule
$(join(rows, "\n"))
\\bottomrule
\\end{tabular}
\\end{table}
"""
    write_tex("tab3_congestion.tex", body)
end

# =============================================================================
# Driver
# =============================================================================
const FIG_BUILDERS = Dict("N1"=>figure_N1, "N1B"=>figure_N1B,
                          "N2"=>figure_N2, "N3"=>figure_N3,
                          "N4"=>figure_N4, "N5"=>figure_N5, "N6"=>figure_N6, "N7"=>figure_N7)
const FIG_NAME = Dict("N1"=>"figN1_network_price_tracking",
                      "N1B"=>"figN1b_network_price_tracking_fullrange",
                      "N2"=>"figN2_accuracy_reliability",
                      "N3"=>"figN3_losses",
                      "N4"=>"figN4_marginal_loss_factors",
                      "N5"=>"figN5_congestion",
                      "N6"=>"figN6_price_decomposition",
                      "N7"=>"figN7_congestion_component")
const TAB_BUILDERS = Dict("T1"=>table_T1, "T2"=>table_T2, "T3"=>table_T3)

"Report what was loaded, so a silently truncated CSV cannot pass unnoticed."
function verify(P, D, R, B)
    println("  intervals            : $(length(unique(P.time)))")
    println("  formulations         : $(join(sort(unique(P.formulation)), ", "))")
    println("  regions              : $(join(sort(unique(P.region)), ", "))")
    println("  price rows           : $(nrow(P))  (converged $(count(P.ok)))")
    println("  decomposition rows   : $(nrow(D))")
    println("  ROP reference rows   : $(nrow(R))")
    println("  binding ledger rows  : $(nrow(B))")
    matched = count(!ismissing, P.ROP)
    println("  rows matched to ROP  : $matched / $(nrow(P))")
    matched == 0 && @warn "No ROP matches - check the interval window overlap."
    return nothing
end

function main()
    println("Loading network-day results ($DAY_TAG) ...")
    P, D, R = load_network_day()
    wanted = isempty(ARGS) ? ["N1","N1B","N2","N3","N4","N5","N6","N7","T1","T2","T3"] : uppercase.(ARGS)
    # The shadow-price ledger is tens of MB; only pay for it when a congestion
    # output is actually being built.
    B = any(in(wanted), ("N5", "N6", "N7", "T3")) ? load_binding() : DataFrame()
    verify(P, D, R, B)

    figs = filter(f -> haskey(FIG_BUILDERS, f), wanted)
    if !isempty(figs)
        println("\nRendering figures:")
        for f in figs
            p, w, h = FIG_BUILDERS[f](P, D, R, B)
            p === nothing && continue
            save_figure(p, FIG_NAME[f]; width=w, height=h)
            if haskey(CAPTIONS, f)
                open(joinpath(FIG_DIR, FIG_NAME[f] * "_caption.tex"), "w") do io
                    println(io, "\\caption{", CAPTIONS[f], "}")
                    println(io, "\\label{fig:", lowercase(f), "}")
                end
            end
        end
    end

    tabs = filter(t -> haskey(TAB_BUILDERS, t), wanted)
    if !isempty(tabs)
        println("\nWriting LaTeX tables:")
        for t in tabs
            TAB_BUILDERS[t](P, D, R, B)
        end
    end

    if !isempty(CAPTIONS)
        open(joinpath(FIG_DIR, "captions_network_day.tex"), "w") do io
            println(io, "% Auto-generated by script/plot_network_day_figures.jl")
            println(io, "% \\input{figures/captions_network_day.tex}, or copy a block.")
            for f in sort(collect(keys(CAPTIONS)))
                println(io, "\n% --- $f : $(FIG_NAME[f]) ---")
                println(io, "\\begin{figure*}[!t]\n\\centering")
                println(io, "\\includegraphics[width=\\textwidth]{$(FIG_NAME[f]).pdf}")
                println(io, "\\caption{", CAPTIONS[f], "}")
                println(io, "\\label{fig:", lowercase(f), "}\n\\end{figure*}")
            end
        end
        println("\nCaptions -> $(joinpath(FIG_DIR, "captions_network_day.tex"))")
    end
    println("\nOutputs in $(abspath(FIG_DIR))/")
end

if !isinteractive()
    main()
end
main()