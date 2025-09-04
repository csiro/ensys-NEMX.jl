create_chunks(arr, n) = [arr[i:min(i + n - 1, end)] for i in 1:n:length(arr)]

function plot_fcas(data)
    for (service_name, service) in sort!(collect(fcas_services), by=x -> x[2].id)
        gens = get_fcas_participants(data["gen"], service)
        loads = get_fcas_participants(data["load"], service)

        if length(gens) + length(loads) == 0
            continue
        end

        chunks = create_chunks(sort!(collect(gens), by=x -> x[2]["index"]), 10)

        for chunk in chunks

            titles = Array{Union{Missing,String}}(missing, 2, 5)
            for (i, subchunk) in enumerate(create_chunks(chunk, 5))
                values = ["Generator $(first(j)), ($(last(j)["fuel"]))" for k in 1:1, j in subchunk]
                titles[i, 1:length(values)] = values
            end

            fig = make_subplots(rows=length(titles[1, :]), cols=2, subplot_titles=titles)

            col_index = 1
            row_index = 1
            for (i, gen) in chunk
                n = parse(Int, i)

                fcas = gen["fcas"][service.id]

                t1 = scatter(
                    name="Generator $(i)",
                    mode="line",
                    x=[fcas["emin"], fcas["lb"], fcas["ub"], fcas["emax"]],
                    y=[0, fcas["amax"], fcas["amax"], 0],
                    marker=attr(
                        color="Black",
                        size=0,
                        line=attr(
                            color="Black",
                            width=2
                        )
                    ),
                    showlegend=false,
                )

                p_energy = [data["gen"]["$n"]["pg"]]
                p_fcas = [data["gen"]["$n"]["gen_$(fcas_name(service))"]]

                p_min = gen["pmin"]
                p_max = gen["pmax"]

                t2 = scatter(
                    mode="markers",
                    x=p_energy,
                    y=p_fcas,
                    marker=attr(
                        color="Green",
                        size=8,
                        line=attr(
                            color="Green",
                            width=2
                        ),
                        symbol="x"
                    ),
                    showlegend=false,
                )
                
                t3 = scatter(
                    mode="markers",
                    x=[p_min, p_max],
                    y=[0, 0],
                    marker=attr(
                        color="Red",
                        size=0,
                        line=attr(
                            color="Red",
                            width=2
                        ),
                        symbol="line-ns"
                    ),
                    showlegend=false,
                )

                add_trace!(fig, t1, row=row_index, col=col_index)
                add_trace!(fig, t2, row=row_index, col=col_index)
                add_trace!(fig, t3, row=row_index, col=col_index)

                if (row_index % 5 == 0)
                    row_index = 1
                    col_index += 1
                else
                    row_index += 1
                end
            end

            relayout!(fig, 
                title_text=fcas_name(service), template=:plotly_white
            )

            display(fig)
        end

        chunks = create_chunks(sort!(collect(loads), by=x -> x[2]["index"]), 10)

        for chunk in chunks

            titles = Array{Union{Missing,String}}(missing, 2, 5)
            for (i, subchunk) in enumerate(create_chunks(chunk, 5))
                values = ["Load $(first(j))" for k in 1:1, j in subchunk]
                titles[i, 1:length(values)] = values
            end

            fig = make_subplots(rows=length(titles[1, :]), cols=2, subplot_titles=titles)

            col_index = 1
            row_index = 1
            for (i, load) in chunk
                n = parse(Int, i)

                fcas = load["fcas"][service.id]

                t1 = scatter(
                    name="Load $(i)",
                    mode="line",
                    x=[fcas["emin"], fcas["lb"], fcas["ub"], fcas["emax"]],
                    y=[0, fcas["amax"], fcas["amax"], 0],
                    marker=attr(
                        color="Black",
                        size=0,
                        line=attr(
                            color="Black",
                            width=2
                        )
                    ),
                    showlegend=false,
                )

                p_energy = [data["load"]["$n"]["pd"]]
                p_fcas = [data["load"]["$n"]["load_$(fcas_name(service))"]]

                p_min = load["pmin"]
                p_max = load["pmax"]

                t2 = scatter(
                    mode="markers",
                    x=p_energy,
                    y=p_fcas,
                    marker=attr(
                        color="Green",
                        size=8,
                        line=attr(
                            color="Green",
                            width=2
                        ),
                        symbol="x"
                    ),
                    showlegend=false,
                )

                t3 = scatter(
                    mode="markers",
                    x=[p_min, p_max],
                    y=[0, 0],
                    marker=attr(
                        color="Red",
                        size=0,
                        line=attr(
                            color="Red",
                            width=2
                        ),
                        symbol="line-ns"
                    ),
                    showlegend=false,
                )
                                add_trace!(fig, t1, row=row_index, col=col_index)
                add_trace!(fig, t2, row=row_index, col=col_index)
                add_trace!(fig, t3, row=row_index, col=col_index)

                if (row_index % 5 == 0)
                    row_index = 1
                    col_index += 1
                else
                    row_index += 1
                end
            end

            relayout!(fig, 
                title_text=fcas_name(service), template=:plotly_white
            )

            display(fig)
        end
    end
end

function plot_cost(data)
    gens = get_dispatchable_participants(data["gen"])

    chunks = create_chunks(sort!(collect(gens), by=x -> x[2]["index"]), 10)

    for chunk in chunks

        titles = Array{Union{Missing,String}}(missing, 2, 5)
        for (i, subchunk) in enumerate(create_chunks(chunk, 5))
            values = ["Generator $(first(j)), ($(last(j)["fuel"]))" for k in 1:1, j in subchunk]
            titles[i, 1:length(values)] = values
        end

        fig = make_subplots(rows=length(titles[1, :]), cols=2, subplot_titles=titles)

        col_index = 1
        row_index = 1

        for (i, gen) in chunk
            n = parse(Int, i)

            costs = gen["cost"]

            points = _PM.calc_pwl_points(gen["ncost"], costs, gen["pmin"], gen["pmax"])

            x = [mw for (mw, cost) in points]
            y = [cost for (mw, cost) in points]

            y_min = y[argmin(y)]
            y_max = y[argmax(y)]

            p_min = gen["pmin"]
            p_max = gen["pmax"]

            if x[end] < p_max
                dx = p_max - x[end]
                m = (y[end] - y[end-1]) / (x[end] - x[end-1])
                push!(x, p_max)
                push!(y, y[end] + m * dx)
            end

            t1 = scatter(
                name="Generator $(i)",
                x=x,
                y=y,
                mode="lines",
                showlegend=false
            )

            t2 = scatter(
                mode="markers",
                x=[data["gen"]["$n"]["pg"]],
                y=[data["gen"]["$n"]["pg_cost"]],
                marker=attr(
                    color="Green",
                    size=8,
                    line=attr(
                        color="Green",
                        width=2
                    ),
                    symbol="x"
                ),
                showlegend=false,
            )
            
            t3 = scatter(
                mode="markers",
                x=[p_min, p_max],
                y=[0, 0],
                marker=attr(
                    color="Red",
                    size=0,
                    line=attr(
                        color="Red",
                        width=2
                    ),
                    symbol="line-ns"
                ),
                showlegend=false,
            )

            add_trace!(fig, t1, row=row_index, col=col_index)
            add_trace!(fig, t2, row=row_index, col=col_index)
            add_trace!(fig, t3, row=row_index, col=col_index)

            if (row_index % 5 == 0)
                row_index = 1
                col_index += 1
            else
                row_index += 1
            end
        end

        display(fig)
    end

    loads = get_dispatchable_participants(data["load"])

    chunks = create_chunks(sort!(collect(loads), by=x -> x[2]["index"]), 10)

    for chunk in chunks

        titles = Array{Union{Missing,String}}(missing, 2, 5)
        for (i, subchunk) in enumerate(create_chunks(chunk, 5))
            values = ["Load $(first(j))" for k in 1:1, j in subchunk]
            titles[i, 1:length(values)] = values
        end

        fig = make_subplots(rows=length(titles[1, :]), cols=2, subplot_titles=titles)

        col_index = 1
        row_index = 1

        for (i, load) in chunk
            n = parse(Int, i)

            costs = load["cost"]

            points = _PM.calc_pwl_points(load["ncost"], costs, load["pmin"], load["pmax"])

            x = [mw for (mw, cost) in points]
            y = [cost for (mw, cost) in points]

            y_min = y[argmin(y)]
            y_max = y[argmax(y)]

            p_min = load["pmin"]
            p_max = load["pmax"]

            if x[end] < p_max
                dx = p_max - x[end]
                m = (y[end] - y[end-1]) / (x[end] - x[end-1])
                push!(x, p_max)
                push!(y, y[end] + m * dx)
            end

            t1 = scatter(
                name="Load $(i)",
                x=x,
                y=y,
                mode="lines",
                showlegend=false
            )

            t2 = scatter(
                mode="markers",
                x=[data["load"]["$n"]["pd"]],
                y=[data["load"]["$n"]["pd_cost"]],
                marker=attr(
                    color="Green",
                    size=8,
                    line=attr(
                        color="Green",
                        width=2
                    ),
                    symbol="x"
                ),
                showlegend=false,
            )

            t3 = scatter(
                mode="markers",
                x=[p_min, p_max],
                y=[0, 0],
                marker=attr(
                    color="Red",
                    size=0,
                    line=attr(
                        color="Red",
                        width=2
                    ),
                    symbol="line-ns"
                ),
                showlegend=false,
            )

            add_trace!(fig, t1, row=row_index, col=col_index)
            add_trace!(fig, t2, row=row_index, col=col_index)
            add_trace!(fig, t3, row=row_index, col=col_index)

            if (row_index % 5 == 0)
                row_index = 1
                col_index += 1
            else
                row_index += 1
            end
        end

        display(fig)
    end
end


function calculate_dc_losses(branches::Dict{String,Any})
    losses = Dict{String,Float64}()
    for (i, branch) in branches
        losses[i] = branch["pf"]^2 * branch["br_r"]
    end

    return losses
end

function calculate_ac_losses(branches::Dict{String,Any})
    losses = Dict{String,Float64}()
    for (i, branch) in branches
        losses[i] = sqrt((branch["pf"] + branch["pt"])^2 + (branch["qf"] + branch["qt"])^2)
    end

    return losses
end

function calculate_region_prices(data, rrn)
    prices = Dict()
    for (region, bus) in rrn
        prices[region] = data["bus"]["$(bus)"]["lam_kcl_r"]
    end
    return prices
end

function plot_losses(dc_data, ac_data)
    dc_losses = calculate_dc_losses(dc_data["branch"])
    ac_losses = calculate_ac_losses(ac_data["branch"])

    trace = [
        histogram(name="DC Model", x=collect(values(dc_losses))),
        histogram(name="AC Model", x=collect(values(ac_losses)), opacity=0.6)
    ]

    layout = Layout(
        barmode="overlay",
        title_text="Branch Losses",
        xaxis_title="MW (p.u)",
        yaxis_title="Count",
        plot_bgcolor="white",
        xaxis=attr(showline=true, linecolor="black"),
        yaxis=attr(showline=true,
            linecolor="black",
            showgrid=true,
            gridwidth=0.5,
            gridcolor="lightgray")
    )

    fig = plot(trace, layout)
    relayout!(fig, template=:plotly_white)
    display(fig)
end

function plot_prices(dc_data, ac_data)
    sorted_buses(data) = sort(collect(data["bus"]), by = x -> x[2]["index"])
    prices(data) = [bus["lam_kcl_r"] for (i, bus) in sorted_buses(data)]
    dc_prices = prices(dc_data)
    ac_prices = prices(ac_data)

    trace = [
        scatter(name="DC Model", x=1:length(dc_prices), y=dc_prices, text=keys(sorted_buses(dc_data)), hovertemplate="bus: %{text}\nprice: \$%{y,.2f}", mode="markers"),
        scatter(name="AC Model", x=1:length(ac_prices), y=ac_prices, text=keys(sorted_buses(ac_data)), hovertemplate="bus: %{text}\nprice: \$%{y,.2f}", mode="markers")
    ]

    layout = Layout(
        title_text="Locational Prices",
        xaxis_title="Bus",
        yaxis_title="Price (\$/MWh)",
        yaxis_range=[-1000, 15000],
        plot_bgcolor="white",
        xaxis=attr(showline=true, linecolor="black"),
        yaxis=attr(showline=true,
            linecolor="black",
            showgrid=true,
            gridwidth=0.5,
            gridcolor="lightgray")
    )

    plot(trace, layout)
end

function plot_voltages(data)
    voltages = [bus["vm"] for (i, bus) in data["bus"]]

    bins = 200
    trace = histogram(x=voltages, nbinsx=bins)
    layout = Layout(
        title_text="Bus Voltage",
        xaxis_title="Bus Voltage (p.u.)",
        yaxis_title="Count",
        plot_bgcolor="white",
        xaxis=attr(showline=true, linecolor="black"),
        yaxis=attr(showline=true,
            linecolor="black",
            showgrid=true,
            gridwidth=0.5,
            gridcolor="lightgray")
    )

    plot(trace, layout)
end

function plot_line_capacities(dc_data, ac_data)
    sij(data) = [100 * ((sqrt((branch["pf"])^2 + (!isnan(branch["qf"]) ? branch["qf"] : 0)^2)) / branch["rate_a"]) for (i, branch) in data["branch"]]

    trace = [
        histogram(name="DC Model", x=sij(dc_data), opacity=0.6),
        histogram(name="AC Model", x=sij(ac_data), opacity=0.6)
    ]

    layout = Layout(
        barmode="overlay",
        title_text="Line Loading",
        xaxis_title="% line loading",
        yaxis_title="Count",
        plot_bgcolor="white",
        xaxis=attr(showline=true, linecolor="black"),
        yaxis=attr(showline=true,
            linecolor="black",
            showgrid=true,
            gridwidth=0.5,
            gridcolor="lightgray")
    )

    plot(trace, layout)
end

function plot_regional_prices(dc_data, ac_data, rrns)
    dc_prices = calculate_region_prices(dc_data, rrns)
    ac_prices = calculate_region_prices(ac_data, rrns)

    y_values(prices) = collect(values(prices))

    trace = [
        bar(name="DC Model", x=keys(dc_prices), y=y_values(dc_prices), text=y_values(dc_prices), texttemplate="\$%{text:,.2f}", textposition="outside"),
        bar(name="AC Model", x=keys(ac_prices), y=y_values(ac_prices), text=y_values(ac_prices), texttemplate="\$%{text:,.2f}", textposition="outside")
    ]

    layout = Layout(
        barmode="group",
        title_text="Regional Prices",
        xaxis_title="Region",
        yaxis_title="\$/MWh",
        plot_bgcolor="white",
        xaxis=attr(showline=true, linecolor="black"),
        yaxis=attr(showline=true,
            linecolor="black",
            showgrid=true,
            gridwidth=0.5,
            gridcolor="lightgray")
    )

    plot(trace, layout)
end

function plot_costs(dc_data, ac_data)
    data= dc_data
    price_cap = data["price_cap"]
    gens = get_dispatchable_participants(data["gen"])

    chunks = create_chunks(sort!(collect(gens), by=x -> x[2]["index"]), 10)

    for chunk in chunks

        titles = Array{Union{Missing,String}}(missing, 2, 5)
        for (i, subchunk) in enumerate(create_chunks(chunk, 5))
            values = ["Generator $(first(j)), ($(last(j)["fuel"]))" for k in 1:1, j in subchunk]
            titles[i, 1:length(values)] = values
        end

        fig = make_subplots(rows=length(titles[1, :]), cols=2, subplot_titles=titles)

        col_index = 1
        row_index = 1

        for (i, gen) in chunk
            n = parse(Int, i)

            costs = gen["cost"]

            points = calc_pwl_points(gen["ncost"], costs, gen["pmin"], gen["pmax"], price_cap)

            x = [mw for (mw, cost) in points]
            y = [cost for (mw, cost) in points]

            y_min = y[argmin(y)]
            y_max = y[argmax(y)]

            p_min = gen["pmin"]
            p_max = gen["pmax"]

            if x[end] < p_max
                dx = p_max - x[end]
                m = (y[end] - y[end-1]) / (x[end] - x[end-1])
                push!(x, p_max)
                push!(y, y[end] + m * dx)
            end

            t1 = scatter(name="Generator $(i)", x=x, y=y, mode="lines", showlegend=false)
            t2 = scatter(mode="markers", x=[data["gen"]["$n"]["pg"]], y=[data["gen"]["$n"]["pg_cost"]], marker=attr(color="Green", size=8, line=attr(color="Green", width=2), symbol="x"), showlegend=false)
            t3 = scatter(mode="markers", x=[ac_data["gen"]["$n"]["pg"]], y=[ac_data["gen"]["$n"]["pg_cost"]], marker=attr(color="Red", size=8, line=attr(color="Red", width=2), symbol="x"), showlegend=false)
            t4 = scatter(mode="markers", x=[p_min, p_max], y=[0, 0], marker=attr(color="Red", size=0, line=attr(color="Red", width=2), symbol="line-ns"), showlegend=false)

            add_trace!(fig, t1, row=row_index, col=col_index)
            add_trace!(fig, t2, row=row_index, col=col_index)
            add_trace!(fig, t3, row=row_index, col=col_index)
            add_trace!(fig, t4, row=row_index, col=col_index)

            if (row_index % 5 == 0)
                row_index = 1
                col_index += 1
            else
                row_index += 1
            end
        end

        display(fig)
    end

    loads = get_dispatchable_participants(data["load"])

    chunks = create_chunks(sort!(collect(loads), by=x -> x[2]["index"]), 10)

    for chunk in chunks

        titles = Array{Union{Missing,String}}(missing, 2, 5)
        for (i, subchunk) in enumerate(create_chunks(chunk, 5))
            values = ["Load $(first(j))" for k in 1:1, j in subchunk]
            titles[i, 1:length(values)] = values
        end

        fig = make_subplots(rows=length(titles[1, :]), cols=2, subplot_titles=titles)

        col_index = 1
        row_index = 1

        for (i, load) in chunk
            n = parse(Int, i)

            costs = load["cost"]

            points = calc_pwl_points(load["ncost"], costs, load["pmin"], load["pmax"], price_cap)

            x = [mw for (mw, cost) in points]
            y = [cost for (mw, cost) in points]

            y_min = y[argmin(y)]
            y_max = y[argmax(y)]

            p_min = load["pmin"]
            p_max = load["pmax"]

            if x[end] < p_max
                dx = p_max - x[end]
                m = (y[end] - y[end-1]) / (x[end] - x[end-1])
                push!(x, p_max)
                push!(y, y[end] + m * dx)
            end

            t1 = scatter(name="Load $(i)", x=x, y=y, mode="lines", showlegend=false)
            t2 = scatter(mode="markers", x=[data["load"]["$n"]["pd"]], y=[data["load"]["$n"]["pd_cost"]], marker=attr(color="Green", size=8, line=attr(color="Green", width=2), symbol="x"), showlegend=false)
            t3 = scatter(mode="markers", x=[p_min, p_max], y=[0, 0], marker=attr(color="Red", size=0, line=attr(color="Red", width=2), symbol="line-ns"), showlegend=false)

            add_trace!(fig, t1, row=row_index, col=col_index)
            add_trace!(fig, t2, row=row_index, col=col_index)
            add_trace!(fig, t3, row=row_index, col=col_index)

            if (row_index % 5 == 0)
                row_index = 1
                col_index += 1
            else
                row_index += 1
            end
        end

        display(fig)
    end
end