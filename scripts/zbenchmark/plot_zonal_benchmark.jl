# =============================================================================
# plot_zonal_benchmark.jl
#
# Publication figures and tables for a zonal benchmark sweep: modelled prices
# against AEMO's published ROP by region and service, error distributions, and
# the accuracy summary.
#
# The same honesty rules as plot_network_day.jl apply — nothing is dropped to
# make a figure look better, out-of-scale points are marked at the frame edge,
# and missing intervals appear as gaps rather than being interpolated across.
#
# ARGUMENTS
#   Options       Env             Default                Meaning
#   ------------  --------------  ---------------------  ----------------------
#   --data-dir=   NEMX_DATA_DIR   data/nemx_2025_09      where the CSVs are
#   --out-dir=    NEMX_OUT_DIR    figures                where output goes
#
# EXAMPLE
#   julia --project=. scripts/zbenchmark/plot_zonal_benchmark.jl
# =============================================================================

using NEMX
using CSV
using DataFrames
using Dates
using PlotlyJS
using Printf
using Statistics

# Anchor paths to the repo, not to pwd: the script is run from the root, from an
# IDE and from the REPL, and relative paths silently put the figures elsewhere
# in the latter two.
const ROOT = NEMX.PKG_DIR

const DATA_CSV = script_option("prices-csv",
                        joinpath(resolve_input_dir(joinpath(ROOT, "data", "nemx_2025_09")),
                                 "nem_prices_vs_rop_sept2025.csv"))
const FIG_DIR  = resolve_output_dir(joinpath(ROOT, "figures"))

print_banner("Zonal benchmark figures",
             "prices CSV" => DATA_CSV,
             "output dir" => FIG_DIR)
mkpath(FIG_DIR)

# --- IEEE geometry and type ---------------------------------------------------
const PX_PER_IN = 96                      # CSS px per inch
const COL1 = round(Int, 3.50 * PX_PER_IN) # IEEE single column
const COL2 = round(Int, 7.16 * PX_PER_IN) # IEEE double column
pt(x) = x * 96 / 72                       # points -> CSS px
# Top margin for a figure carrying BOTH a title and a horizontal legend. The
# title is anchored to the container top and the legend to the plot area, so
# without a reserved band they overlap (they did, in the first render).
const TOP_TITLE_LEGEND = 92
const TOP_TITLE_ONLY   = 58
const PNG_SCALE = 600 / PX_PER_IN         # 600 dpi raster
const FONT = "Times New Roman, Times, serif"

# --- Ink (chart chrome) -------------------------------------------------------
const INK   = "#0b0b0b"   # primary text
const INK_2 = "#52514e"   # secondary text
const MUTED = "#898781"   # de-emphasised marks
const GRID  = "#e1e0d9"   # hairline grid
const AXIS  = "#c3c2b7"   # baseline / axis line

# --- Validated series colours (see header for the validator results) ----------
const C_MODEL = "#2a78d6"     # blue   — nemjl model
const C_AEMO  = "#eb6834"     # orange — AEMO published ROP
const REGION_COLOR = Dict("NSW1"=>"#2a78d6", "QLD1"=>"#eda100", "SA1"=>"#e87ba4",
                          "TAS1"=>"#008300", "VIC1"=>"#4a3aa7")
const BAND_COLOR = ["#86b6ef", "#5598e7", "#2a78d6", "#1c5cab", "#0d366b"]
const C_CRIT = "#d03b3b"      # status:critical — divergence markers only
# F1 marks intervals whose energy residual is material. At $1/MWh this fires on
# 13-39% of intervals and the marker layer swamps the price lines; $10/MWh
# selects genuinely material divergences against prices that run to $600/MWh.
const DIVERGENCE_TOL = 10.0

# --- Domain vocabulary --------------------------------------------------------
const REGIONS = ["NSW1", "QLD1", "SA1", "TAS1", "VIC1"]
region_label(r) = replace(r, "1" => "")

# Display order: energy first, then raise services, then lower.
const SERVICES = ["energy",
                  "raise_reg", "raise_1s", "raise_6s", "raise_60s", "raise_5min",
                  "lower_reg", "lower_1s", "lower_6s", "lower_60s", "lower_5min"]
const SERVICE_LABEL = Dict(
    "energy"=>"Energy", "raise_reg"=>"Raise Reg", "raise_1s"=>"Raise 1s",
    "raise_6s"=>"Raise 6s", "raise_60s"=>"Raise 60s", "raise_5min"=>"Raise 5min",
    "lower_reg"=>"Lower Reg", "lower_1s"=>"Lower 1s", "lower_6s"=>"Lower 6s",
    "lower_60s"=>"Lower 60s", "lower_5min"=>"Lower 5min")
# AEMO short codes. Used where panel titles must stay compact (F2's 3-column
# grid): the long names wrap at IEEE column width and push the panels down.
const SERVICE_CODE = Dict(
    "energy"=>"Energy",
    "raise_reg"=>"RREG", "raise_1s"=>"R1S", "raise_6s"=>"R6S",
    "raise_60s"=>"R60S", "raise_5min"=>"R5M",
    "lower_reg"=>"LREG", "lower_1s"=>"L1S", "lower_6s"=>"L6S",
    "lower_60s"=>"L60S", "lower_5min"=>"L5M")
# Energy settles in \$/MWh; FCAS are enabled-MW products priced in \$/MW.
unit_of(svc) = svc == "energy" ? "\$/MWh" : "\$/MW"

# Error-magnitude bands (ordinal, matched to BAND_COLOR light->dark).
const BAND_EDGE  = [1e-6, 0.10, 1.0, 10.0, Inf]
# Unicode, not HTML entities: Plotly's text sanitiser does not accept `&le;`
# and Kaleido fails the whole render on it (`&gt;` happens to be allowed).
const BAND_LABEL = ["Exact", "≤ \$0.10", "≤ \$1", "≤ \$10", "> \$10"]

# Error ribbon between the two price traces (F1). Amber reads as "difference"
# without competing with either series hue, and at 22% alpha it never obscures
# the lines it sits between.
const C_RIBBON = "rgba(235,140,52,0.22)"
const C_BOX    = "#5b6b7a"   # neutral slate — the box summarises, not competes
band_of(e) = findfirst(x -> abs(e) <= x, BAND_EDGE)

# =============================================================================
# Data
# =============================================================================
"Load the benchmark CSV and attach display columns."
function load_data(path=DATA_CSV)
    isfile(path) || error("Missing $path — run script/run_historical_dispatch_sept2025.jl first.")
    d = CSV.read(path, DataFrame)
    d.region  = String.(d.region)
    d.service = String.(d.service)
    d.abserr  = abs.(d.error)
    d.band    = band_of.(d.error)
    sort!(d, [:time, :region, :service])
    return d
end

"Per-group agreement metrics."
function metrics(d::DataFrame, keys::Vector{Symbol})
    combine(groupby(d, keys),
        :error  => length                        => :n,
        :error  => mean                          => :bias,
        :abserr => mean                          => :MAE,
        :error  => (x -> sqrt(mean(x .^ 2)))     => :RMSE,
        :abserr => maximum                       => :maxabs,
        :abserr => (x -> 100 * mean(x .<= 1e-6)) => :exact_pct,
        :abserr => (x -> 100 * mean(x .<= 0.10)) => :within10c_pct)
end

"Price for a callout: enough precision that a small value never reads as zero."
fmt_price(v) = abs(v) >= 100 ? @sprintf("%.0f", v) :
               abs(v) >= 1   ? @sprintf("%.2f", v) : @sprintf("%.3g", v)

"Order a metrics frame by the display order of SERVICES."
order_by_service(m) = m[sortperm([findfirst(==(s), SERVICES) for s in m.service]), :]

# Signed log10 — prices span -\$1 000 to +\$14 500, so a linear axis buries the
# bulk of the distribution while a log axis cannot show the negatives at all.
slog(x) = sign(x) * log10(1 + abs(x))
const TICK_V = [-1000, -100, -10, 0, 10, 100, 1000, 10000]
const TICK_T = ["-1k", "-100", "-10", "0", "10", "100", "1k", "10k"]

# =============================================================================
# Layout helpers
# =============================================================================
"""
    ieee_layout([subplots]; width, height, kwargs...) -> Layout

IEEE-styled Layout on a white surface. Axis chrome is NOT set here — call
`style_all_axes!` on the built Plot so it reaches every axis of a faceted
figure, not just axis 1.
"""
function ieee_layout(sp=nothing; width, height, kwargs...)
    base = (paper_bgcolor="white", plot_bgcolor="white",
            font=attr(family=FONT, size=pt(8), color=INK),
            margin=attr(l=52, r=12, t=34, b=42),
            legend=attr(font=attr(family=FONT, size=pt(7.5), color=INK),
                        bgcolor="rgba(255,255,255,0.85)", bordercolor=AXIS,
                        borderwidth=0.6),
            hoverlabel=attr(font=attr(family=FONT, size=pt(8))))
    return sp === nothing ? Layout(; width=width, height=height, base..., kwargs...) :
                            Layout(sp; width=width, height=height, base..., kwargs...)
end

# Axis key for subplot index k (Plotly numbers the first axis without a suffix).
axkey(kind, k) = Symbol(kind, k == 1 ? "" : string(k))

# Shared axis chrome. Applied field-by-field to every axis the figure owns
# rather than through a Plotly template: `Layout(template=...)` expects a
# `Template` object, and a template would in any case be merged by Plotly at
# render time, hiding the resulting values from the checks below.
const AXIS_STYLE = (showgrid=true, gridcolor=GRID, gridwidth=0.6,
                    zeroline=false, showline=true, linecolor=AXIS, linewidth=0.8,
                    ticks="outside", ticklen=3, tickwidth=0.6, tickcolor=AXIS,
                    tickfont=attr(family=FONT, size=pt(7.5), color=INK_2),
                    automargin=true)

"Figure title, anchored to the top of the container so the legend can sit under it."
figtitle(text; height) =
    attr(text=text, x=0.5, xanchor="center", y=1 - 18/height, yanchor="top",
         yref="container", font=attr(family=FONT, size=pt(9.5), color=INK))

"Horizontal legend placed just above the plot area, under the figure title."
leg(y=1.012) = attr(orientation="h", x=0.5, xanchor="center", y=y, yanchor="bottom",
             traceorder="normal",
             font=attr(family=FONT, size=pt(7.5), color=INK),
             bgcolor="rgba(0,0,0,0)", borderwidth=0)

"""
    boxed_leg([y]; itemwidth=34)

Horizontal legend inside a hairline box, on an opaque white ground so it stays
legible where it overlaps the plot frame. `itemsizing="constant"` decouples the
legend swatch from the (deliberately tiny) plotted marker size, so the key
reads clearly at IEEE column width even when the series it describes is drawn
at 2.6 px; `itemwidth` adds breathing room between key and label.
"""
boxed_leg(y=1.012; itemwidth=34) =
    attr(orientation="h", x=0.5, xanchor="center", y=y, yanchor="bottom",
         traceorder="normal", itemsizing="constant", itemwidth=itemwidth,
         font=attr(family=FONT, size=pt(7.5), color=INK),
         bgcolor="rgba(255,255,255,0.92)", bordercolor=AXIS, borderwidth=0.7)

"""
    legend_proxy!(p; kind, name, color, row, col, size=9, width=2.6, dash="solid")

Add a data-free trace whose only job is to own a legend entry. The plotted
series then carry `showlegend=false`, which lets the key use a large, clearly
readable swatch (markers at `size`, lines at `width`) while the data itself
stays at the small marks IEEE column width demands. Without this the legend
dot inherits the 2.6 px plotted size and is barely visible in print.
"""
function legend_proxy!(p; kind::Symbol, name, color, row, col, at, size=9, width=2.6,
                       dash="solid", group=name)
    # ONE point at a REAL x (`at`) with a NaN y. Two failure modes are avoided:
    #   * `[nothing]` types the axis as numeric, and with shared_xaxes that
    #     forces every panel numeric — the DateTime series then vanish (observed:
    #     five blank panels on a 1970-epoch axis);
    #   * fully EMPTY vectors keep the axis correct but Plotly then drops the
    #     legend entry altogether (observed: no legend rendered at all).
    # A real x keeps the axis type right; a NaN y draws nothing and does not
    # participate in autorange.
    tr = kind === :marker ?
        scatter(x=[at], y=[NaN], mode="markers", name=name,
                legendgroup=group, showlegend=true, hoverinfo="skip",
                marker=attr(color=color, size=size, line=attr(width=0))) :
        scatter(x=[at], y=[NaN], mode="lines", name=name,
                legendgroup=group, showlegend=true, hoverinfo="skip",
                line=attr(color=color, width=width, dash=dash))
    add_trace!(p, tr, row=row, col=col)
    return p
end

# --- Figure captions ---------------------------------------------------------
# Kept beside the builders so a caption can never drift from the figure it
# describes, and emitted to figures/captions.tex for direct \input{} into the
# manuscript.
const CAPTIONS = Dict{String,String}()

"Axis title with the IEEE label font (set_axis! replaces the whole title dict)."
axtitle(text; standoff=6) =
    attr(text=text, standoff=standoff, font=attr(family=FONT, size=pt(8.5), color=INK))

"Apply AXIS_STYLE to every axis in the layout. Call once, after Plot creation."
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

"""
    set_axis!(p, kind, k; kw...)

Merge properties into subplot k's axis. This must be a field-level merge:
`relayout!` REPLACES the axis dict, which would discard the `domain`/`anchor`
that `Subplots` wrote and silently collapse the facet grid.
"""
function set_axis!(p, kind::String, k::Int; kw...)
    key = axkey(kind, k)
    haskey(p.layout.fields, key) || (p.layout[key] = Dict{Any,Any}())
    for (kk, vv) in kw
        p.layout[key][kk] = vv
    end
    return p
end

"Ensure the layout has an annotations vector and return it."
function annotations!(p)
    haskey(p.layout.fields, :annotations) || (p.layout[:annotations] = Any[])
    return p.layout[:annotations]
end

"""
    annot!(p, k; domain=false, kw...)

Append an annotation bound to subplot `k`'s axes. `domain=true` positions it in
0-1 panel coordinates rather than data coordinates.
"""
function annot!(p, k::Int; domain::Bool=false, kw...)
    s = k == 1 ? "" : string(k)
    a = Dict{Symbol,Any}(:xref => domain ? "x$s domain" : "x$s",
                         :yref => domain ? "y$s domain" : "y$s",
                         :showarrow => false)
    for (kk, vv) in kw
        a[kk] = vv
    end
    push!(annotations!(p), attr(; a...))
    return p
end

"""
Restyle the panel titles `Subplots` generates (they default to 16 px).
Call this immediately after building the Plot, BEFORE adding any annotations
of our own, so it only touches the generated titles.
"""
function style_panel_titles!(p)
    haskey(p.layout.fields, :annotations) || return p
    for a in p.layout[:annotations]
        a[:font] = attr(family=FONT, size=pt(8.5), color=INK)
    end
    return p
end

"Write PDF (vector master), 600-dpi PNG and interactive HTML."
function save_figure(p, name; width, height)
    base = joinpath(FIG_DIR, name)
    savefig(p, base * ".pdf"; width=width, height=height)
    savefig(p, base * ".png"; width=width, height=height, scale=PNG_SCALE)
    open(base * ".html", "w") do io
        PlotlyBase.to_html(io, p; include_plotlyjs="cdn", full_html=true)
    end
    @printf("  %-30s %4d x %4d px   pdf/png@600dpi/html\n", name, width, height)
    return base
end

# =============================================================================
# F1 — Energy price tracking, five regions
# =============================================================================
"""
Energy price tracking with an explicit residual layer, one row per region.

Each row pairs two views of the same data, so the reader gets both the time
course and its distribution without leaving the panel:

  * LEFT (a)-(e) — the tracking layers. AEMO ROP is the thick orange reference;
    the model is drawn thin in blue on top, so agreement reads as the orange
    disappearing under the blue. Between the two a shaded amber RIBBON makes the
    residual itself a visible area rather than something the eye must infer from
    two nearly-coincident lines; where the model is exact the ribbon has zero
    width and vanishes. Red markers flag the material misses
    (|E| > DIVERGENCE_TOL \$/MWh).
  * RIGHT — the residual DISTRIBUTION for that region as a box plot on the same
    row, drawn on a signed-log axis so the near-zero bulk and the rare large
    excursions are both visible. Median, IQR and whiskers summarise the 1 000
    intervals; individual outliers are retained as points.

A boxed legend sits under the figure title with enlarged swatches, and each row
carries a compact Exact / MAE / max-|E| readout.
"""
function figure_1(d)
    e = d[d.service .== "energy", :]
    nR = length(REGIONS)
    h = 132 * nR + 110         # reserved band: figure title + boxed legend
    # Row titles label the panel AND name its region; the box column is titled once.
    titles = String[]
    for (i, r) in enumerate(REGIONS)
        push!(titles, "($(Char(96+i)))  $(region_label(r))")
        push!(titles, i == 1 ? "Residual E (\$/MWh)" : "")
    end
    p = Plot(ieee_layout(
        Subplots(rows=nR, cols=2, shared_xaxes=true,
                 column_widths=[0.855, 0.145],
                 vertical_spacing=0.032, horizontal_spacing=0.042,
                 subplot_titles=reshape(titles, 1, :));
        width=COL2, height=h,
        title=figtitle("Energy price tracking and residual distribution: nemjl model vs AEMO published ROP, "*
                       "1 000 consecutive dispatch intervals"; height=h),
        # The legend must clear the FIRST panel's generated subplot title, which
        # Subplots anchors just above that panel's domain (~y=1.01). Sitting the
        # legend at 1.02 put the two on top of each other.
        margin=attr(l=58, r=14, t=TOP_TITLE_LEGEND + 52, b=50),
        legend=boxed_leg(1.062)))
    style_panel_titles!(p); style_all_axes!(p)

    # Subplot index for (row i, col c) in a 2-column grid.
    kx(i, c) = 2 * (i - 1) + c

    # Legend proxies: large, clearly readable swatches independent of the small
    # marks used in the data layers. Anchored at a real timestamp (NaN y) so the
    # shared DateTime axis keeps its type.
    t0 = minimum(e.time)
    legend_proxy!(p; kind=:line,   name="AEMO published ROP", color=C_AEMO,
                  row=1, col=1, at=t0, width=3.0, group="aemo")
    legend_proxy!(p; kind=:line,   name="nemjl model",        color=C_MODEL,
                  row=1, col=1, at=t0, width=2.2, group="model")
    legend_proxy!(p; kind=:marker, name="Residual band |E|",  color="#eb8c34",
                  row=1, col=1, at=t0, size=10, group="ribbon")
    legend_proxy!(p; kind=:marker, name="|E| > \$$(Int(DIVERGENCE_TOL))/MWh",
                  color=C_CRIT, row=1, col=1, at=t0, size=9, group="div")
    legend_proxy!(p; kind=:marker, name="Residual distribution", color=C_BOX,
                  row=1, col=1, at=t0, size=9, group="box")

    for (i, r) in enumerate(REGIONS)
        s = sort(e[e.region .== r, :], :time)

        # --- tracking + residual ribbon (col 1) -------------------------------
        # AEMO first with no fill, then the model filling BACK to it: the filled
        # area between the two curves is exactly the residual.
        add_trace!(p, scatter(x=s.time, y=s.ROP, mode="lines", showlegend=false,
            legendgroup="aemo", line=attr(color=C_AEMO, width=2.6), opacity=0.88,
            hovertemplate="AEMO %{y:.2f}<extra></extra>"), row=i, col=1)
        add_trace!(p, scatter(x=s.time, y=s.price, mode="lines", showlegend=false,
            legendgroup="model", fill="tonexty", fillcolor=C_RIBBON,
            line=attr(color=C_MODEL, width=1.15),
            hovertemplate="model %{y:.2f}<extra></extra>"), row=i, col=1)

        dv = s[s.abserr .> DIVERGENCE_TOL, :]
        add_trace!(p, scatter(x=dv.time, y=dv.price, mode="markers", showlegend=false,
            legendgroup="div", marker=attr(color=C_CRIT, size=3.6, line=attr(width=0)),
            customdata=dv.error,
            hovertemplate="%{x|%d %b %H:%M}<br>E %{customdata:.2f}<extra></extra>"),
            row=i, col=1)

        annot!(p, kx(i, 1); domain=true, x=0.995, y=0.94, xanchor="right", yanchor="top",
            text=@sprintf("Exact %.0f%% · MAE %.2f · max |E| %.1f",
                          100*mean(s.abserr .<= 1e-6), mean(s.abserr), maximum(s.abserr)),
            font=attr(family=FONT, size=pt(6.8), color=INK_2),
            bgcolor="rgba(255,255,255,0.82)", bordercolor=AXIS, borderwidth=0.5)
        set_axis!(p, "yaxis", kx(i, 1); title=axtitle("Price (\$/MWh)", standoff=6))

        # --- residual distribution (col 2) ------------------------------------
        # Signed log keeps the near-zero bulk readable next to the rare
        # hundreds-of-dollars excursions; slog is monotone, so the quartiles
        # shown are the transforms of the true quartiles.
        add_trace!(p, box(y=slog.(s.error), showlegend=false, legendgroup="box",
            name="", boxpoints="outliers", jitter=0.35, pointpos=0,
            width=0.55, whiskerwidth=0.55,
            marker=attr(color=C_CRIT, size=2.0, opacity=0.55, line=attr(width=0)),
            line=attr(color=C_BOX, width=0.9), fillcolor="rgba(91,107,122,0.16)",
            customdata=s.error,
            hovertemplate="E %{customdata:.2f} \$/MWh<extra></extra>"), row=i, col=2)
        # Zero-error reference: the line the model is trying to sit on.
        add_trace!(p, scatter(x=[-0.5, 0.5], y=[0.0, 0.0], mode="lines",
            showlegend=false, hoverinfo="skip",
            line=attr(color=MUTED, width=0.8, dash="dot")), row=i, col=2)
        set_axis!(p, "yaxis", kx(i, 2); tickmode="array",
                  tickvals=slog.([-100, -10, 0, 10, 100]),
                  ticktext=["-100", "-10", "0", "10", "100"],
                  tickfont=attr(family=FONT, size=pt(6.5), color=INK_2))
        set_axis!(p, "xaxis", kx(i, 2); showticklabels=false, showgrid=false,
                  ticks="", range=[-0.75, 0.75])
    end

    set_axis!(p, "xaxis", kx(nR, 1);
        title=axtitle("Dispatch interval (2025-09-01 00:05 → 2025-09-04 11:20, 5-min resolution)", standoff=8))

    CAPTIONS["F1"] = "Energy price tracking and residual distribution over 1\\,000 consecutive " *
        "five-minute dispatch intervals (2025-09-01 00:05 to 2025-09-04 11:20), by NEM region: " *
        "(a) NSW, (b) QLD, (c) SA, (d) TAS, (e) VIC. " *
        "In each left-hand panel the thick orange curve is AEMO's published pre-scaling regional " *
        "reference price (ROP) and the thin blue curve is the reconstructed model price; the shaded " *
        "amber ribbon between them is the residual \$E\$, so exact agreement appears as a ribbon of " *
        "zero width. Red markers flag intervals with \$|E| > \\\$$(Int(DIVERGENCE_TOL))\$/MWh. " *
        "The right-hand box plot on each row summarises the distribution of \$E\$ for that region " *
        "(median, interquartile range, whiskers, outliers retained) on a signed-logarithmic axis, " *
        "which keeps the near-zero bulk legible alongside the rare large excursions. " *
        "Each panel is annotated with its exact-match rate, mean absolute error and worst case."
    return p, COL2, h
end

# =============================================================================
# F2 — Parity scatter, one facet per market
# =============================================================================
"""
Model price against AEMO ROP for every market, as an agreement (parity) plot.

Perfect agreement is the dashed 1:1 diagonal, so the figure answers "does it
reproduce AEMO?" directly and any disagreement shows as displacement off that
line. Three additions make the accuracy legible rather than merely asserted:

  * a shaded ±\$1 TOLERANCE ENVELOPE around the diagonal, so a reader can see at
    a glance which points are inside commercial tolerance instead of estimating
    distance from a line;
  * points coloured by region (validated 5-hue set) with a boxed legend whose
    swatches are enlarged, because the plotted marks are deliberately 2.6 px;
  * a per-panel readout of Exact / MAE / max |E|, and a count of the points that
    fall OUTSIDE the envelope — the number the diagonal alone cannot convey.

Axes are signed-log: the sample spans -\$1 000 to +\$14 500 and includes negative
prices, which no plain log axis can show. Panels are lettered (a)-(k) and named
by market.
"""
function figure_2(d)
    rows, cols = 4, 3
    h = 192 * rows + 96
    titles = ["($(Char(96+k)))  $(SERVICE_CODE[s])  ($(unit_of(s)))"
              for (k, s) in enumerate(SERVICES)]
    append!(titles, fill("", rows*cols - length(SERVICES)))
    p = Plot(ieee_layout(
        Subplots(rows=rows, cols=cols, vertical_spacing=0.078, horizontal_spacing=0.068,
                 subplot_titles=reshape(titles, 1, :));
        width=COL2, height=h,
        title=figtitle("Model–AEMO price parity by market (1 000 intervals × 5 regions per panel)"; height=h),
        # As in F1: clear the generated subplot title of panel (a).
        margin=attr(l=54, r=14, t=TOP_TITLE_LEGEND + 26, b=54),
        legend=boxed_leg(1.038; itemwidth=30)))
    style_panel_titles!(p); style_all_axes!(p)

    # Legend proxies (enlarged swatches, drawn before the data traces so the key
    # order matches the reading order).
    for reg in REGIONS
        legend_proxy!(p; kind=:marker, name=region_label(reg),
                      color=REGION_COLOR[reg], row=1, col=1, at=0.0, size=9, group=reg)
    end
    legend_proxy!(p; kind=:line, name="1:1 (exact agreement)", color=MUTED,
                  row=1, col=1, at=0.0, width=1.6, dash="dash", group="diag")
    legend_proxy!(p; kind=:marker, name="±\$1 tolerance", color="rgba(120,120,120,0.30)",
                  row=1, col=1, at=0.0, size=10, group="tol")

    for (k, svc) in enumerate(SERVICES)
        r = div(k - 1, cols) + 1; c = mod(k - 1, cols) + 1
        sd = d[d.service .== svc, :]
        lo = min(minimum(sd.price), minimum(sd.ROP))
        hi = max(maximum(sd.price), maximum(sd.ROP))
        pad = 0.05 * (slog(hi) - slog(lo)) + 0.02
        ax  = [slog(lo) - pad, slog(hi) + pad]

        # ±$1 envelope, drawn in DATA space then transformed, so its width is a
        # true $1 either side at every price rather than a constant screen offset.
        gridv = range(lo, hi; length=220)
        add_trace!(p, scatter(x=slog.(gridv), y=slog.(gridv .+ 1.0), mode="lines",
            showlegend=false, hoverinfo="skip",
            line=attr(color="rgba(0,0,0,0)", width=0)), row=r, col=c)
        add_trace!(p, scatter(x=slog.(gridv), y=slog.(gridv .- 1.0), mode="lines",
            showlegend=false, hoverinfo="skip", fill="tonexty",
            fillcolor="rgba(120,120,120,0.16)",
            line=attr(color="rgba(0,0,0,0)", width=0)), row=r, col=c)
        # 1:1 reference above the envelope, below the points.
        add_trace!(p, scatter(x=ax, y=ax, mode="lines", showlegend=false,
            line=attr(color=MUTED, width=0.9, dash="dash"), hoverinfo="skip"),
            row=r, col=c)

        for reg in REGIONS
            g = sd[sd.region .== reg, :]
            add_trace!(p, scatter(x=slog.(g.ROP), y=slog.(g.price), mode="markers",
                showlegend=false, legendgroup=reg,
                marker=attr(color=REGION_COLOR[reg], size=2.6, opacity=0.55,
                            line=attr(width=0)),
                customdata=hcat(g.ROP, g.price, g.error),
                hovertemplate="$(region_label(reg))<br>AEMO %{customdata[0]:.2f}<br>"*
                              "model %{customdata[1]:.2f}<br>E %{customdata[2]:.3f}<extra></extra>"),
                row=r, col=c)
        end

        n_out = count(>(1.0), sd.abserr)
        annot!(p, k; domain=true, x=0.04, y=0.96, xanchor="left", yanchor="top",
            text=@sprintf("Exact %.1f%%<br>MAE %.3f<br>max |E| %.1f<br>outside ±\$1: %d",
                          100*mean(sd.abserr .<= 1e-6), mean(sd.abserr),
                          maximum(sd.abserr), n_out),
            font=attr(family=FONT, size=pt(6.5), color=INK_2),
            bgcolor="rgba(255,255,255,0.86)", bordercolor=AXIS, borderwidth=0.5,
            align="left")
        for (kind, lbl) in (("xaxis", "AEMO ROP"), ("yaxis", "Model"))
            set_axis!(p, kind, k; tickmode="array", tickvals=slog.(TICK_V),
                      ticktext=TICK_T, range=ax,
                      title=axtitle("$lbl ($(unit_of(svc)))", standoff=4))
        end
    end
    set_axis!(p, "xaxis", rows*cols; visible=false)
    set_axis!(p, "yaxis", rows*cols; visible=false)

    CAPTIONS["F2"] = "Model--AEMO price parity for all eleven NEM markets: " *
        "(a) energy, (b)--(f) the raise services RREG, R1S, R6S, R60S and R5M, and " *
        "(g)--(k) the lower services LREG, L1S, L6S, L60S and L5M " *
        "(regulation, and the 1\\,s, 6\\,s, 60\\,s and 5\\,min contingency services). " *
        "Each panel plots the reconstructed model price against " *
        "AEMO's published ROP for 1\\,000 consecutive dispatch intervals in all five regions " *
        "(5\\,000 comparisons per panel), coloured by region. Exact agreement lies on the dashed " *
        "1:1 diagonal; the grey band is a \$\\pm\\\$1\$ tolerance envelope about it. Both axes are " *
        "signed-logarithmic, \$\\mathrm{sgn}(x)\\log_{10}(1+|x|)\$, because the sample spans " *
        "\$-\\\$1\\,000\$ to \$+\\\$14\\,500\$ and includes negative prices. Each panel reports its " *
        "exact-match rate, mean absolute error, worst case, and the number of comparisons falling " *
        "outside the tolerance envelope."
    return p, COL2, h
end

# =============================================================================
# F3 — Error-magnitude composition per market
# =============================================================================
"""
How the 5 000 comparisons per market distribute across error-magnitude bands.
A box plot would be degenerate here (median and both quartiles are 0 for every
market), so the composition itself is the story: stacked shares on an ordinal
light->dark ramp, exact matches at the light end. Bars carry a direct label
with the exact-match rate, and panel (b) shows the worst case per market on a
log axis — the tail the shares alone would hide.
"""
function figure_3(d)
    m = order_by_service(metrics(d, [:service]))
    ylab = [SERVICE_LABEL[s] for s in m.service]
    h = 34 * length(SERVICES) + 130
    p = Plot(ieee_layout(
        Subplots(rows=1, cols=2, column_widths=[0.68, 0.32], horizontal_spacing=0.10,
                 subplot_titles=["(a) share of comparisons by error band" "(b) worst case"]);
        width=COL2, height=h,
        title=figtitle("Distribution of |model − AEMO| by market (n = 5 000 comparisons per market)"; height=h),
        margin=attr(l=78, r=16, t=TOP_TITLE_LEGEND, b=50), barmode="stack", bargap=0.28,
        legend=leg()))
    style_panel_titles!(p); style_all_axes!(p)

    for b in eachindex(BAND_LABEL)
        share = [100 * mean(d[d.service .== s, :band] .== b) for s in m.service]
        add_trace!(p, bar(y=ylab, x=share, orientation="h", name=BAND_LABEL[b],
            marker=attr(color=BAND_COLOR[b], line=attr(color="white", width=1.0)),
            hovertemplate="%{y}<br>%{x:.2f}% of comparisons<extra></extra>"),
            row=1, col=1)
    end
    for (i, lbl) in enumerate(ylab)
        annot!(p, 1; x=101.5, y=lbl, xanchor="left", yanchor="middle",
            text=@sprintf("%.1f%% exact", m.exact_pct[i]),
            font=attr(family=FONT, size=pt(6.6), color=INK_2))
    end
    add_trace!(p, bar(y=ylab, x=m.maxabs, orientation="h", showlegend=false,
        marker=attr(color=C_CRIT, line=attr(width=0)),
        text=[@sprintf("%.4g", v) for v in m.maxabs], textposition="outside",
        textfont=attr(family=FONT, size=pt(6.6), color=INK_2), cliponaxis=false,
        hovertemplate="%{y}<br>max |error| %{x:.4g}<extra></extra>"), row=1, col=2)

    set_axis!(p, "xaxis", 1; title=axtitle("Share of comparisons (%)", standoff=6),
              range=[0, 122], tickvals=[0, 25, 50, 75, 100])
    set_axis!(p, "yaxis", 1; autorange="reversed", showgrid=false)
    set_axis!(p, "xaxis", 2; title=axtitle("max |error| (\$/MWh or \$/MW)", standoff=6),
              type="log", range=[log10(0.02), log10(120_000)])
    set_axis!(p, "yaxis", 2; autorange="reversed", showgrid=false, showticklabels=false)
    return p, COL2, h
end

# =============================================================================
# F4 — Region x market agreement heatmaps
# =============================================================================
"""
Where the residual disagreement lives, across the full 5 x 11 grid. Two
sequential single-hue panels (never a rainbow): exact-match rate, and MAE on a
log colour scale because it spans four orders of magnitude. Every cell is
annotated with its value, so the panels stay readable without the colour bar —
which is also what keeps them accessible.
"""
function figure_4(d)
    m = metrics(d, [:service, :region])
    val(s, r, col) = only(m[(m.service .== s) .& (m.region .== r), col])
    Z1 = [val(s, r, :exact_pct) for s in SERVICES, r in REGIONS]
    Z2 = [val(s, r, :MAE)       for s in SERVICES, r in REGIONS]
    xs = region_label.(REGIONS)
    ys = [SERVICE_LABEL[s] for s in SERVICES]
    h  = 30 * length(SERVICES) + 155
    p = Plot(ieee_layout(
        Subplots(rows=1, cols=2, horizontal_spacing=0.16,
                 subplot_titles=["(a) exact-match rate (%)" "(b) mean absolute error"]);
        width=COL2, height=h,
        title=figtitle("Agreement by region and market"; height=h),
        margin=attr(l=78, r=16, t=TOP_TITLE_ONLY, b=56)))
    style_panel_titles!(p); style_all_axes!(p)

    blues = [[0.0, "#eef4fd"], [0.25, "#9ec5f4"], [0.5, "#3987e5"],
             [0.75, "#1c5cab"], [1.0, "#0d366b"]]
    add_trace!(p, heatmap(z=Z1, x=xs, y=ys, colorscale=blues, zmin=0, zmax=100,
        xgap=1.4, ygap=1.4,
        colorbar=attr(title=attr(text="%", side="right",
                                 font=attr(family=FONT, size=pt(7.5), color=INK)),
                      len=0.84, thickness=9, x=0.425,
                      tickfont=attr(family=FONT, size=pt(7), color=INK_2)),
        hovertemplate="%{y} · %{x}<br>exact %{z:.1f}%<extra></extra>"), row=1, col=1)

    L2 = log10.(max.(Z2, 1e-4))
    add_trace!(p, heatmap(z=L2, x=xs, y=ys, colorscale=blues, xgap=1.4, ygap=1.4,
        customdata=Z2,
        colorbar=attr(title=attr(text="log₁₀ MAE", side="right",
                                 font=attr(family=FONT, size=pt(7.5), color=INK)),
                      len=0.84, thickness=9, x=1.005,
                      tickfont=attr(family=FONT, size=pt(7), color=INK_2)),
        hovertemplate="%{y} · %{x}<br>MAE %{customdata:.4g}<extra></extra>"), row=1, col=2)

    # Cell labels — ink flips to white over the dark end of each ramp.
    hi2 = maximum(L2)
    for (i, s) in enumerate(SERVICES), (j, r) in enumerate(REGIONS)
        annot!(p, 1; x=xs[j], y=ys[i], text=@sprintf("%.0f", Z1[i, j]),
            font=attr(family=FONT, size=pt(6.4),
                      color=Z1[i, j] > 62 ? "white" : INK))
        annot!(p, 2; x=xs[j], y=ys[i],
            text=(Z2[i, j] < 1e-3 ? "0" : @sprintf("%.3g", Z2[i, j])),
            font=attr(family=FONT, size=pt(6.4),
                      color=L2[i, j] > hi2 - 1.1 ? "white" : INK))
    end
    for k in 1:2
        set_axis!(p, "xaxis", k; title=axtitle("Region", standoff=6), showgrid=false)
        set_axis!(p, "yaxis", k; autorange="reversed", showgrid=false,
                  showticklabels=(k == 1))
    end
    return p, COL2, h
end

# =============================================================================
# F5 — Event study of the largest FCAS divergence
# =============================================================================
"""
The aggregate figures are dominated by exact matches; this one zooms into the
single worst FCAS divergence in the window to show what a residual actually
looks like. Three stacked panels over the same ±1 h window:
  (a) the affected FCAS market, model (solid) vs AEMO (dotted), all five regions
  (b) the co-optimised energy price over the same window
  (c) the signed error for the affected market
That is the co-optimisation story: an FCAS price excursion beside the energy
prices it is solved jointly with.
"""
function figure_5(d)
    fcas = d[d.service .!= "energy", :]
    k = argmax(fcas.abserr)
    svc, t0, reg0 = fcas.service[k], fcas.time[k], fcas.region[k]
    w0, w1 = t0 - Hour(1), t0 + Hour(1)
    sd = d[(d.service .== svc)      .& (d.time .>= w0) .& (d.time .<= w1), :]
    ed = d[(d.service .== "energy") .& (d.time .>= w0) .& (d.time .<= w1), :]
    h = 520
    titles = ["(a) $(SERVICE_LABEL[svc]) price — model (solid) vs AEMO ROP (dotted)",
              "(b) Energy price over the same window — model",
              "(c) $(SERVICE_LABEL[svc]) signed error (model − AEMO)"]
    p = Plot(ieee_layout(
        Subplots(rows=3, cols=1, shared_xaxes=true, vertical_spacing=0.085,
                 subplot_titles=reshape(titles, 1, :));
        width=COL2, height=h,
        title=figtitle(@sprintf("Largest FCAS divergence in the sample: %s, %s, %s",
                                 SERVICE_LABEL[svc], region_label(reg0),
                                 Dates.format(t0, "yyyy-mm-dd HH:MM")); height=h),
        margin=attr(l=62, r=16, t=TOP_TITLE_LEGEND + 16, b=48),
        legend=leg(1.055)))
    style_panel_titles!(p); style_all_axes!(p)

    for reg in REGIONS
        g  = sort(sd[sd.region .== reg, :], :time)
        ge = sort(ed[ed.region .== reg, :], :time)
        lab = region_label(reg)
        add_trace!(p, scatter(x=g.time, y=g.price, mode="lines", name=lab,
            legendgroup=reg, showlegend=true, line=attr(color=REGION_COLOR[reg], width=1.4),
            hovertemplate="$lab model %{y:.2f}<extra></extra>"), row=1, col=1)
        add_trace!(p, scatter(x=g.time, y=g.ROP, mode="lines", name=lab,
            legendgroup=reg, showlegend=false,
            line=attr(color=REGION_COLOR[reg], width=1.0, dash="dot"), opacity=0.85,
            hovertemplate="$lab AEMO %{y:.2f}<extra></extra>"), row=1, col=1)
        add_trace!(p, scatter(x=ge.time, y=ge.price, mode="lines", name=lab,
            legendgroup=reg, showlegend=false, line=attr(color=REGION_COLOR[reg], width=1.2),
            hovertemplate="$lab energy %{y:.2f}<extra></extra>"), row=2, col=1)
        add_trace!(p, scatter(x=g.time, y=g.error, mode="lines", name=lab,
            legendgroup=reg, showlegend=false, line=attr(color=REGION_COLOR[reg], width=1.2),
            hovertemplate="$lab error %{y:.3f}<extra></extra>"), row=3, col=1)
    end
    annot!(p, 1; x=t0, y=log10(max(fcas.price[k], 1e-3)), showarrow=true,
        ax=54, ay=30, arrowhead=2, arrowsize=0.7, arrowwidth=0.8, arrowcolor=INK_2,
        text=@sprintf("%s: model %s vs AEMO %s", region_label(reg0),
                      fmt_price(fcas.price[k]), fmt_price(fcas.ROP[k])),
        font=attr(family=FONT, size=pt(6.8), color=INK),
        bgcolor="rgba(255,255,255,0.85)")

    # Explicit log range: left to autorange, the callout annotation pushed the
    # axis to 1e6 and squashed every trace into the bottom eighth of the panel.
    ylo = minimum(filter(>(0), vcat(sd.price, sd.ROP)); init=0.01)
    yhi = maximum(vcat(sd.price, sd.ROP))
    set_axis!(p, "yaxis", 1; title=axtitle("$(SERVICE_LABEL[svc]) (\$/MW)", standoff=6),
              type="log", range=[log10(ylo) - 0.35, log10(yhi) + 0.85])
    set_axis!(p, "yaxis", 2; title=axtitle("Energy (\$/MWh)", standoff=6))
    set_axis!(p, "yaxis", 3; title=axtitle("Error (\$/MW)", standoff=6),
              zeroline=true, zerolinecolor=AXIS, zerolinewidth=0.8)
    set_axis!(p, "xaxis", 3; title=axtitle("Dispatch interval (5-min)", standoff=8))
    return p, COL2, h
end

# =============================================================================
# F6 — Summary table
# =============================================================================
"""
The numeric backing for F1-F5, and the accessible table view the colour rules
require (two of the five region hues sit below 3:1 contrast on white).
"""
function figure_6(d)
    m = order_by_service(metrics(d, [:service]))
    h = 25 * nrow(m) + 78
    fmt(v, digits) = [@sprintf("%.*f", digits, x) for x in v]
    p = Plot(table(
        columnwidth=[1.5, 0.75, 0.95, 1.05, 1.0, 1.0, 1.0, 1.15],
        header=attr(
            values=["<b>Market</b>", "<b>Unit</b>", "<b>Exact (%)</b>",
                    "<b>≤ \$0.10 (%)</b>", "<b>Bias</b>", "<b>MAE</b>",
                    "<b>RMSE</b>", "<b>max |error|</b>"],
            fill_color="#eef4fd", line=attr(color=GRID, width=0.8), align="center",
            font=attr(family=FONT, size=pt(7.6), color=INK), height=26),
        cells=attr(
            values=[[SERVICE_LABEL[s] for s in m.service],
                    [unit_of(s) for s in m.service],
                    fmt(m.exact_pct, 2), fmt(m.within10c_pct, 2), fmt(m.bias, 4),
                    fmt(m.MAE, 4), fmt(m.RMSE, 3), fmt(m.maxabs, 2)],
            fill_color=["white"], line=attr(color=GRID, width=0.6),
            align=["left", "center", "right", "right", "right", "right", "right", "right"],
            font=attr(family=FONT, size=pt(7.2), color=INK), height=23)),
        ieee_layout(width=COL2, height=h,
            title=figtitle("Benchmark summary — nemjl vs AEMO ROP, 1 000 intervals × 5 regions per market"; height=h),
            margin=attr(l=14, r=14, t=48, b=14)))
    return p, COL2, h
end

# =============================================================================
# Verification — recompute everything the figures assert
# =============================================================================
"""
Independent recomputation, straight from the CSV, of every number annotated on
a figure, plus structural checks on the frame. Printed so the figures can be
checked against the source rather than trusted.
"""
function verify(d)
    println("\n" * "="^80 * "\nVERIFICATION\n" * "="^80)
    nt, nr, ns = length(unique(d.time)), length(unique(d.region)), length(unique(d.service))
    @printf("rows %d = intervals %d × regions %d × markets %d ?  %s\n",
            nrow(d), nt, nr, ns, nrow(d) == nt*nr*ns ? "YES" : "NO — INCOMPLETE")
    @printf("window %s → %s\n", minimum(d.time), maximum(d.time))
    gaps = unique(diff(sort(unique(d.time))))
    @printf("interval spacing %s → %s\n", gaps,
            length(gaps) == 1 ? "CONSECUTIVE, no gaps" : "GAPS PRESENT")
    @printf("non-finite: price %d, ROP %d | cells per (market,region) %s\n",
            count(!isfinite, d.price), count(!isfinite, d.ROP),
            unique(combine(groupby(d, [:service, :region]), nrow).nrow))
    @printf("error column == price − ROP ?  max discrepancy %.3g\n",
            maximum(abs.(d.error .- (d.price .- d.ROP))))
    @printf("every row lands in a band ?  %s\n",
            all(1 .<= d.band .<= length(BAND_EDGE)) ? "YES" : "NO")
    @printf("band shares sum to 100%% per market ?  %s\n",
        all(abs(sum(100*mean(d[d.service .== s, :band] .== b)
                    for b in eachindex(BAND_EDGE)) - 100) < 1e-9 for s in SERVICES) ?
        "YES" : "NO")

    println("\n── F3 / F6 per-market table (recomputed) " * "─"^38)
    m = order_by_service(metrics(d, [:service]))
    @printf("%-11s %6s %8s %9s %11s %10s %10s %12s\n",
            "market", "n", "exact%", "≤\$0.10%", "bias", "MAE", "RMSE", "max|e|")
    for r in eachrow(m)
        @printf("%-11s %6d %8.2f %9.2f %11.4f %10.4f %10.3f %12.2f\n",
                SERVICE_LABEL[r.service], r.n, r.exact_pct, r.within10c_pct,
                r.bias, r.MAE, r.RMSE, r.maxabs)
    end

    println("\n── F1 per-region energy panel annotations " * "─"^37)
    e = d[d.service .== "energy", :]
    for r in REGIONS
        s = e[e.region .== r, :]
        @printf("  %-4s n=%4d  MAE %8.4f  max|e| %9.3f  exact %6.2f%%  |e|>\$%g in %3d intervals\n",
                region_label(r), nrow(s), mean(s.abserr), maximum(s.abserr),
                100*mean(s.abserr .<= 1e-6), DIVERGENCE_TOL, count(s.abserr .> DIVERGENCE_TOL))
    end

    println("\n── F4 weakest cells (lowest exact-match rate) " * "─"^34)
    for r in eachrow(first(sort(metrics(d, [:service, :region]), :exact_pct), 6))
        @printf("  %-11s %-4s exact %6.2f%%  MAE %9.4f  max|e| %9.2f\n",
                SERVICE_LABEL[r.service], region_label(r.region),
                r.exact_pct, r.MAE, r.maxabs)
    end

    println("\n── F5 event selection " * "─"^57)
    fcas = d[d.service .!= "energy", :]; k = argmax(fcas.abserr)
    @printf("  worst FCAS residual  : %-10s %-4s %s  model %10.2f  AEMO %10.2f  error %10.2f\n",
            SERVICE_LABEL[fcas.service[k]], region_label(fcas.region[k]), fcas.time[k],
            fcas.price[k], fcas.ROP[k], fcas.error[k])
    ee = d[d.service .== "energy", :]; ke = argmax(ee.abserr)
    @printf("  worst energy residual: %-10s %-4s %s  model %10.2f  AEMO %10.2f  error %10.2f\n",
            "Energy", region_label(ee.region[ke]), ee.time[ke],
            ee.price[ke], ee.ROP[ke], ee.error[ke])
    println("="^80)
    return m
end

# =============================================================================
# Main
# =============================================================================
const BUILDERS = Dict("F1"=>figure_1, "F2"=>figure_2, "F3"=>figure_3,
                      "F4"=>figure_4, "F5"=>figure_5, "F6"=>figure_6)
const FIG_NAME = Dict("F1"=>"fig1_energy_price_tracking",
                      "F2"=>"fig2_parity_by_market",
                      "F3"=>"fig3_error_composition",
                      "F4"=>"fig4_agreement_heatmap",
                      "F5"=>"fig5_event_study",
                      "F6"=>"fig6_summary_table")

function main()
    d = load_data()
    println("Loaded $(nrow(d)) comparisons from $DATA_CSV")
    verify(d)
    wanted = isempty(ARGS) ? ["F1","F2","F3","F4","F5","F6"] : uppercase.(ARGS)
    println("\nRendering " * join(wanted, ", ") * ":")
    for f in wanted
        if !haskey(BUILDERS, f)
            @warn "Unknown figure $f (expected F1..F6)"
            continue
        end
        p, w, h = BUILDERS[f](d)
        save_figure(p, FIG_NAME[f]; width=w, height=h)
        # Caption beside the figure it describes, and collected for \input{}.
        if haskey(CAPTIONS, f)
            open(joinpath(FIG_DIR, FIG_NAME[f] * "_caption.tex"), "w") do io
                println(io, "\\caption{", CAPTIONS[f], "}")
                println(io, "\\label{fig:", lowercase(f), "}")
            end
        end
    end
    if !isempty(CAPTIONS)
        open(joinpath(FIG_DIR, "captions.tex"), "w") do io
            println(io, "% Auto-generated by script/plot_benchmark_figures_sept2025.jl")
            println(io, "% \\input{figures/captions.tex} or copy the block you need.")
            for f in sort(collect(keys(CAPTIONS)))
                println(io, "\n% --- $f : $(FIG_NAME[f]) ---")
                println(io, "\\begin{figure*}[!t]\n\\centering")
                println(io, "\\includegraphics[width=\\textwidth]{$(FIG_NAME[f]).pdf}")
                println(io, "\\caption{", CAPTIONS[f], "}")
                println(io, "\\label{fig:", lowercase(f), "}\n\\end{figure*}")
            end
        end
        println("\nCaptions written to $(joinpath(FIG_DIR, "captions.tex"))")
    end
    println("\nFigures in $(abspath(FIG_DIR))/ — .pdf for LaTeX, .png at 600 dpi, .html interactive.")
end

# Run under any non-interactive launcher — `julia script.jl`, the VS Code Julia
# extension's "Execute File", `include` from a driver script. Guarding on
# `PROGRAM_FILE` instead meant the IDE loaded the file, created `figures/` and
# returned without rendering anything, silently. Still skipped when included
# from an interactive REPL, so the builders can be driven one at a time there
# (call `main()` explicitly).
if !isinteractive()
    main()
end
main()