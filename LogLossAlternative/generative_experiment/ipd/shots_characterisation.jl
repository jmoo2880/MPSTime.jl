using ITensors
using Plots
using JLD2
using Base.Threads
using StatsBase
using HDF5
include("/Users/joshua/Documents/QuantumInspiredML/LogLossAlternative/sampling.jl");

function loadMPS(path::String; id::String="W")
    """Loads an MPS from a .h5 file. Returns and ITensor MPS."""
    file = path[end-2:end] != ".h5" ? path * ".h5" : path
    f = h5open("$file","r")
    mps = read(f, "$id", MPS)
    close(f)
    return mps
end

function sliceMPS(W::MPS, class_label::Int)
    """General function to slice the MPS and return the state corresponding to a specific class label."""
    ψ = deepcopy(W)
    decision_idx = findindex(ψ[end], "f(x)")
    decision_state = onehot(decision_idx => (class_label + 1))
    ψ[end] *= decision_state
    normalize!(ψ) 
    return ψ
end;

mps_loaded = loadMPS("/Users/joshua/Documents/QuantumInspiredML/LogLossAlternative/generative_experiment/ipd/chi30_mps_og.h5");
state0 = sliceMPS(mps_loaded, 0)
state1 = sliceMPS(mps_loaded, 1)
@load "/Users/joshua/Documents/QuantumInspiredML/LogLossAlternative/generative_experiment/ipd/ipd_test_og.jld2"
c0_test_idxs = findall(x -> x.== 0, y_test);
c1_test_idxs = findall(x -> x.== 1, y_test);
c0_test_samples = X_test_scaled[c0_test_idxs, :];
c1_test_samples = X_test_scaled[c1_test_idxs, :];

function test_shots_repeated()
    num_shots = [100, 500, 1000]
    num_trials = 3
    smape_vals = Matrix{Float64}(undef, length(num_shots), num_trials)

    for (i, ns) in enumerate(num_shots)
        for t in 1:num_trials
            all_shots_forecast = Matrix{Float64}(undef, ns, 96)
            
            for j in 1:ns
                all_shots_forecast[j, :] = forecast_mps_sites(state1, c1_test_samples[1,1:50], 51)
            end
            
            mean_ts = mean(all_shots_forecast, dims=1)[1,:]
            smape = compute_mape(mean_ts[51:end], c1_test_samples[1,51:end])
            
            println("Num shots: $ns - Trial: $t - sMAPE: $smape")
            smape_vals[i, t] = smape
        end
    end
    
    return smape_vals
end

function test_shots_class_subset(subset_size=10)
    num_shots = [100, 250, 500, 750, 1000]
    smape_vals = Matrix{Float64}(undef, subset_size, 5) # each row is a sample, each column is num shots
    # get random subset
    random_idxs = StatsBase.sample(collect(1:size(c0_test_samples, 1)), subset_size; replace=false)
    for (si, ns) in enumerate(num_shots)
        for (idx, s_idx) in enumerate(random_idxs)
            all_shots_forecast = Matrix{Float64}(undef, ns, 96)
            for j in 1:ns
                all_shots_forecast[j, :] = forecast_mps_sites(state0, c0_test_samples[s_idx,1:50], 51)
            end
            mean_ts = mean(all_shots_forecast, dims=1)[1,:]
            smape = compute_mape(mean_ts[51:end], c0_test_samples[s_idx,51:end])
            println("Num shots: $ns - Sample: $s_idx - sMAPE: $smape")
            smape_vals[idx, si] = smape
        end
    end

    return smape_vals

end

function plot_examples_c1(sample_idx, num_shots; num_tpts_forecast=12)
    all_shots_forecast = Matrix{Float64}(undef, num_shots, 24)
    start_site = 24 - num_tpts_forecast
    for i in 1:num_shots
        all_shots_forecast[i, :] = forecast_mps_sites(state1, c1_test_samples[sample_idx,1:start_site], start_site+1)
    end
    mean_ts = mean(all_shots_forecast, dims=1)[1,:]
    std_ts = std(all_shots_forecast, dims=1)[1,:]
    p = plot(collect(1:start_site), c1_test_samples[sample_idx, 1:start_site], lw=2, label="Conditioning data")
    plot!(collect((start_site+1):24), mean_ts[(start_site+1):end], ribbon=std_ts[(start_site+1):end], label="MPS forecast", ls=:dot, lw=2, alpha=0.5)
    plot!(collect((start_site+1):24), c1_test_samples[sample_idx, (start_site+1):end], lw=2, label="Ground truth", alpha=0.5)
    xlabel!("Time")
    ylabel!("x")
    title!("Sample $sample_idx, Class 1, $num_tpts_forecast Site Forecast, $num_shots Shots")
    println("Sample $sample_idx sMAPE: $(compute_mape(mean_ts[(start_site+1):end], c1_test_samples[sample_idx,(start_site+1):end]))")
    display(p)
    #return all_shots_forecast
end

function plot_examples_c0(sample_idx, num_shots; num_tpts_forecast=12)
    all_shots_forecast = Matrix{Float64}(undef, num_shots, 24)
    start_site = 24 - num_tpts_forecast
    for i in 1:num_shots
        all_shots_forecast[i, :] = forecast_mps_sites(state0, c0_test_samples[sample_idx,1:start_site], start_site+1)
    end
    mean_ts = mean(all_shots_forecast, dims=1)[1,:]
    std_ts = std(all_shots_forecast, dims=1)[1,:]
    p = plot(collect(1:start_site), c0_test_samples[sample_idx, 1:start_site], lw=2, label="Conditioning data")
    plot!(collect((start_site+1):24), mean_ts[(start_site+1):end], ribbon=std_ts[(start_site+1):end], label="MPS forecast", ls=:dot, lw=2, alpha=0.5)
    plot!(collect((start_site+1):24), c0_test_samples[sample_idx, (start_site+1):end], lw=2, label="Ground truth", alpha=0.5)
    xlabel!("Time")
    ylabel!("x")
    title!("Sample $sample_idx, Class 0, $num_tpts_forecast Site Forecast, $num_shots Shots")
    println("Sample $sample_idx sMAPE: $(compute_mape(mean_ts[(start_site+1):end], c0_test_samples[sample_idx,(start_site+1):end]))")
    display(p)
end

function smape_versus_chi_max()
    num_shots = 500
    subset_size = 25
    seed = 23
    rng = MersenneTwister(seed)
    smape_vals = []
    random_idxs = StatsBase.sample(rng, collect(1:size(c1_test_samples, 1)), subset_size; replace=false)
    for idx in random_idxs
        all_shots_forecast = Matrix{Float64}(undef, num_shots, 100)
        for j in 1:num_shots
            all_shots_forecast[j, :] = forecast_mps_sites(state1, c1_test_samples[idx,1:50], 51)
        end
        mean_ts = mean(all_shots_forecast, dims=1)[1,:]
        smape = compute_mape(mean_ts[51:end], c1_test_samples[idx,51:end])
        println("Sample: $idx - sMAPE: $smape")
        push!(smape_vals, smape)
    end

    return smape_vals

end

function compute_smape_all_c0()
    # compute sMAPE for all test samples in a class using a fixed number of shots
    # and fixed forecasting horizon
    smapes_all = []
    num_shots = 500
    for idx in eachindex(1:size(c0_test_samples,1))
        all_shots_forecast = Matrix{Float64}(undef, num_shots, 24)
        for j in 1:num_shots
            all_shots_forecast[j, :] = forecast_mps_sites(state0, c0_test_samples[idx,1:12], 13)
        end
        mean_ts = mean(all_shots_forecast, dims=1)[1,:]
        smape = compute_mape(mean_ts[13:end], c0_test_samples[idx,13:end]; symmetric=true)
        println("Sample: $idx - sMAPE: $smape")
        push!(smapes_all, smape)
    end
    return smapes_all
end

function compute_smape_all_c1()
    # compute sMAPE for all test samples in a class using a fixed number of shots
    # and fixed forecasting horizon
    smapes_all = []
    num_shots = 500
    for idx in eachindex(1:size(c1_test_samples,1))
        all_shots_forecast = Matrix{Float64}(undef, num_shots, 24)
        for j in 1:num_shots
            all_shots_forecast[j, :] = forecast_mps_sites(state1, c1_test_samples[idx,1:12], 13)
        end
        mean_ts = mean(all_shots_forecast, dims=1)[1,:]
        smape = compute_mape(mean_ts[13:end], c1_test_samples[idx,13:end]; symmetric=true)
        println("Sample: $idx - sMAPE: $smape")
        push!(smapes_all, smape)
    end
    return smapes_all
end

function smape_versus_forecast_horizon(sample_idx::Int)
    smapes_all = []
    num_shots = 500
    horizons = collect(1:1:23)
    for fh in horizons
        all_shots_forecast = Matrix{Float64}(undef, num_shots, 24)
        for j in 1:num_shots
            all_shots_forecast[j, :] = forecast_mps_sites(state1, c1_test_samples[sample_idx,1:fh], (fh+1))
        end
        mean_ts = mean(all_shots_forecast, dims=1)[1,:]
        smape = compute_mape(mean_ts[(fh+1):end], c1_test_samples[sample_idx,(fh+1):end]; symmetric=true)
        println("Horizon: $(24-fh) pts. - sMAPE: $smape")
        push!(smapes_all, smape)
    end

    return smapes_all

end

function plot_interp_examples_c0(sample_idx::Int, num_shots::Int, interp_idxs::Vector{Int})
    all_shots_interp = Matrix{Float64}(undef, num_shots, 24)
    for i in 1:num_shots
        all_shots_interp[i, :] = interpolate_time_ordered(state0, c0_test_samples[sample_idx,:], interp_idxs)
    end
    mean_ts = mean(all_shots_interp, dims=1)[1,:]
    std_ts = std(all_shots_interp, dims=1)[1,:]
    p = plot(mean_ts, ribbon=std_ts, label="MPS Interpolated", lw=2, ls=:dot)
    plot!(c0_test_samples[sample_idx,:], label="Ground truth", lw=2)
    xlabel!("time")
    ylabel!("x")
    title!("Class 0, Sample $sample_idx, $num_shots Shots MPS Interpolation")
    display(p)
end

function plot_interp_examples_c1(sample_idx::Int, num_shots::Int, interp_idxs::Vector{Int})
    all_shots_interp = Matrix{Float64}(undef, num_shots, 24)
    for i in 1:num_shots
        all_shots_interp[i, :] = interpolate_time_ordered(state1, c1_test_samples[sample_idx,:], interp_idxs)
    end
    mean_ts = mean(all_shots_interp, dims=1)[1,:]
    std_ts = std(all_shots_interp, dims=1)[1,:]
    p = plot(mean_ts, ribbon=std_ts, label="MPS Interpolated", lw=2, ls=:dot)
    plot!(c1_test_samples[sample_idx,:], label="Ground truth", lw=2)
    xlabel!("time")
    ylabel!("x")
    title!("Class 1, Sample $sample_idx, $num_shots Shots MPS Interpolation")
    display(p)
end

function plot_interp_ns_examples_c1(sample_idx::Int, num_shots::Int, interp_idxs::Vector{Int})
    all_shots_interp = Matrix{Float64}(undef, num_shots, 24)
    for i in 1:num_shots
        all_shots_interp[i, :] = interpolate_non_sequential(state1, c1_test_samples[sample_idx,:], interp_idxs);
    end
    mean_ts = mean(all_shots_interp, dims=1)[1,:]
    std_ts = std(all_shots_interp, dims=1)[1,:]
    p = plot(mean_ts, ribbon=std_ts, label="MPS Interpolated", lw=2, ls=:dot)
    plot!(c1_test_samples[sample_idx,:], label="Ground truth", lw=2)
    xlabel!("time")
    ylabel!("x")
    title!("Class 1, Sample $sample_idx, $num_shots Shots MPS Interpolation")
    display(p)
end

function plot_interp_ns_examples_c0(sample_idx::Int, num_shots::Int, interp_idxs::Vector{Int})
    all_shots_interp = Matrix{Float64}(undef, num_shots, 24)
    for i in 1:num_shots
        all_shots_interp[i, :] = interpolate_non_sequential(state0, c0_test_samples[sample_idx,:], interp_idxs);
    end
    mean_ts = mean(all_shots_interp, dims=1)[1,:]
    std_ts = std(all_shots_interp, dims=1)[1,:]
    p = plot(mean_ts, ribbon=std_ts, label="MPS Interpolated", lw=2, ls=:dot)
    plot!(c0_test_samples[sample_idx,:], label="Ground truth", lw=2)
    xlabel!("time")
    ylabel!("x")
    title!("Class 0, Sample $sample_idx, $num_shots Shots MPS Interpolation")
    display(p)
end

function plot_interp_acausal_c0(sample_idx::Int, num_shots::Int, interp_idxs::Vector{Int})
    all_shots_interp = Matrix{Float64}(undef, num_shots, 24)
    for i in 1:num_shots
        all_shots_interp[i, :] = interpolate_acausal(state0, c0_test_samples[sample_idx,:], interp_idxs);
    end
    mean_ts = mean(all_shots_interp, dims=1)[1,:]
    std_ts = std(all_shots_interp, dims=1)[1,:]
    p = plot(mean_ts, ribbon=std_ts, label="MPS Interpolated", lw=2, ls=:dot)
    plot!(c0_test_samples[sample_idx,:], label="Ground truth", lw=2)
    xlabel!("time")
    ylabel!("x")
    title!("Class 0, Sample $sample_idx, $num_shots Shots MPS Interpolation")
    display(p)
end

function plot_interp_acausal_c1(sample_idx::Int, num_shots::Int, interp_idxs::Vector{Int})
    all_shots_interp = Matrix{Float64}(undef, num_shots, 24)
    for i in 1:num_shots
        all_shots_interp[i, :] = interpolate_acausal(state1, c1_test_samples[sample_idx,:], interp_idxs);
    end
    mean_ts = mean(all_shots_interp, dims=1)[1,:]
    std_ts = std(all_shots_interp, dims=1)[1,:]
    p = plot(mean_ts, ribbon=std_ts, label="MPS Interpolated", lw=2, ls=:dot)
    plot!(c1_test_samples[sample_idx,:], label="Ground truth", lw=2)
    xlabel!("time")
    ylabel!("x")
    title!("Class 1, Sample $sample_idx, $num_shots Shots MPS Interpolation")
    display(p)
end