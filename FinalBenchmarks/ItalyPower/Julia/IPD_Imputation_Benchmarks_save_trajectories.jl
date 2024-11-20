include("../../../LogLoss/RealRealHighDimension.jl")
include("../../../Imputation/imputation.jl");
using JLD2
using DelimitedFiles
using Plots

GenericLinearAlgebra.LinearAlgebra.BLAS.set_num_threads(1)


# load the original ECG200 split
dloc = "Data/italypower/datasets/ItalyPowerDemandOrig.jld2"
f = jldopen(dloc, "r")
    X_train = read(f, "X_train")
    y_train = read(f, "y_train")
    X_test = read(f, "X_test")
    y_test = read(f, "y_test")
close(f)

# recombine the original train/test splits
Xs = vcat(X_train, X_test)
ys = vcat(y_train, y_test)

# load the resample indices
rs_f = jldopen("FinalBenchmarks/ItalyPower/Julia/ipd_resample_folds_julia_idx.jld2", "r");
rs_fold_idxs = read(rs_f, "rs_folds_julia");
close(rs_f)

# load the window indices
windows_f = jldopen("FinalBenchmarks/ItalyPower/Julia/ipd_windows_julia_idx.jld2", "r");
window_idxs = read(windows_f, "windows_julia")
close(windows_f)

# define structs for the results
struct WindowScores
    mps_scores::Vector{Float64}
    nn_scores::Vector{Float64}
end

struct InstanceScores
    pm_scores::Vector{WindowScores}
end

struct FoldResults 
    fold_scores::Vector{InstanceScores}
end

function run_folds(Xs::Matrix{Float64}, window_idxs::Dict, fold_idxs::Dict, which_folds::UnitRange=0:29)
    
    # training related parameters
    Rdtype = Float64
    verbosity = -10
    test_run = false
    track_cost = false
    encoding = :sahand_legendre
    encode_classes_separately = false
    train_classes_separately = false

    d = 10
    chi_max = 20 # 
    eta = 0.5 # 0.1
    nsweeps = 5 # 3
    opts=MPSOptions(; nsweeps=nsweeps, chi_max=chi_max, update_iters=1, verbosity=verbosity, loss_grad=:KLD,
            bbopt=:TSGO, track_cost=track_cost, eta=eta, rescale = (false, true), d=d, aux_basis_dim=2, encoding=encoding, 
            encode_classes_separately=encode_classes_separately, train_classes_separately=train_classes_separately, 
            exit_early=false, sigmoid_transform=false, init_rng=4567, chi_init=4, log_level=0)
    opts_safe, _... = safe_options(opts, nothing, nothing)

    dx = 5e-3
    pms = 5:10:95


    num_folds = length(which_folds) # specified by the user
    if num_folds > length(fold_idxs)
        error("Fold range specified must be samller than the max number of folds ($length(fold_idxs)).")
    end
    stime = time()
    # main loop
    fold_scores = Vector{FoldResults}(undef, num_folds)
    for (i, fold_idx) in enumerate(which_folds)
        # imputation related parameters

        pms = 5:10:95 
        fold_time = @elapsed begin
            fold_train_idxs = fold_idxs[fold_idx]["train"]
            fold_test_idxs = fold_idxs[fold_idx]["test"]
            X_train_fold = Xs[fold_train_idxs, :]
            X_test_fold = Xs[fold_test_idxs, :]
            # all of the instances go into the same class
            y_train_fold = zeros(Int64, size(X_train_fold, 1))
            y_test_fold = zeros(Int64, size(X_test_fold, 1))
            println("Train fold size: ",size(X_train_fold))
            println("#Train classes: ", size(y_train_fold))
            println("Test fold size: ",size(X_test_fold))
            println("#Test classes: ", size(y_test_fold))
            println("Training")
            train_start = time()

            W, _, _, _ = fitMPS(X_train_fold, y_train_fold, X_test_fold, y_test_fold, chi_init=4, opts=opts, test_run=false)
            println("training took $(round(time() - train_start; digits=3))s")
            # begin imputation
            imp = init_imputation_problem(W, X_train_fold, y_train_fold, X_test_fold, y_test_fold, opts_safe; verbosity=0, dx=dx)

            println("Finished training, beginning evaluation of imputed values...")
            num_instances = size(X_test_fold, 1)
            mps_scores = zeros(Float64, num_instances)
            nn_scores = zeros(Float64, num_instances)
            instance_scores = Vector{InstanceScores}(undef, num_instances)

            times = Vector{Float64}(undef, num_instances)
            for instance in 1:num_instances
                inst_time = time()
                print("t: $(round(time() - stime; digits=3))s F$(fold_idx): Evaluating instance $(instance)/$(num_instances) ")
                # loop over windows
                pm_scores = Vector{WindowScores}(undef, length(pms))
                for (ipm, pm) in enumerate(pms)
                    # loop over window iterations
                    num_wins = length(window_idxs[pm])
                    mps_scores = Vector{Float64}(undef, num_wins)
                    nn_scores = Vector{Float64}(undef, num_wins)
                    @threads for it in 1:num_wins
                        impute_sites = window_idxs[pm][it]
                        ts, pred_err, stats, _ = MPS_impute(imp, 0, instance, impute_sites, :directMedian; invert_transform=true, NN_baseline=true, n_baselines=1, plot_fits=false)
                        mps_scores[it] = stats[1][:MAE]
                        nn_scores[it] = stats[1][:NN_MAE]
                    end
                    pm_scores[ipm] = WindowScores(mps_scores, nn_scores)
                end
                instance_scores[instance] = InstanceScores(pm_scores)
                times[instance] = time() - inst_time
                println("($(round(mean(times[1:instance]);digits=3))s per inst)")
            end
            fold_scores[i] = FoldResults(instance_scores)
        end
        println("Fold $fold_idx took $fold_time seconds.")
        fold_scores_tmp = fold_scores[1:i]
        JLD2.@save "IPD_ImputationFinalResults_30Fold_data_driven_temp_2.jld2" fold_scores_tmp
    end
    return fold_scores, opts_safe
end


results, opts_safe = run_folds(Xs, window_idxs, rs_fold_idxs, 0:29)

mps_results = Dict()
nn_results = Dict()

for pm in 1:length(results[1].fold_scores[1].pm_scores)
    per_pm_res_mps = Dict()
    per_pm_res_nn = Dict()
    for f in 1:length(results)
        total_instances = length(results[f].fold_scores)
        per_pm_res_mps[f] = [results[f].fold_scores[inst].pm_scores[pm].mps_scores for inst in 1:total_instances]
        per_pm_res_nn[f] = [results[f].fold_scores[inst].pm_scores[pm].nn_scores for inst in 1:total_instances]
    end
    mps_results[pm] = per_pm_res_mps
    nn_results[pm] = per_pm_res_nn
end

nfolds = length(results)

JLD2.@save "IPD_ImputationFinalResults_$(nfolds)Fold_data_driven_2.jld2" mps_results nn_results opts_safe

