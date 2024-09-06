include("../../MLJ_integration.jl")
using MLJParticleSwarmOptimization
import MLJ
using JLD2

dloc =  "Data/italypower/datasets/ItalyPowerDemandOrig.jld2"
f = jldopen(dloc, "r")
    X_train_f = read(f, "X_train")
    y_train_f = read(f, "y_train")
    X_test_f = read(f, "X_test")
    y_test_f = read(f, "y_test")
close(f)

Xs = MLJ.table([X_train_f; X_test_f])
ys = coerce([y_train_f; y_test_f], OrderedFactor)
X_train = MLJ.table(X_train_f)
X_test = MLJ.table(X_test_f)
y_train = coerce(y_train_f, OrderedFactor)
y_test = coerce(y_test_f, OrderedFactor)


Rdtype = Float64

verbosity = 0
test_run = false
track_cost = false
#
encoding = legendre(project=false)
encode_classes_separately = false
train_classes_separately = false
exit_early=false

nsweeps=5
chi_max=29
eta=0.1
d=2

MC_CV = false
evaL_resamp = false


# etas = [0.001, 0.004, 0.007, 0.01, 0.04, 0.07, 0.1, 0.3, 0.5]
# max_sweeps=5
# ds = [2;Int.(ceil.(3:1.5:15))]
# chi_maxs=15:5:50


mps = MPSClassifier(nsweeps=nsweeps, chi_max=chi_max, eta=eta, d=d, encoding=:Legendre_No_Norm, exit_early=exit_early, init_rng=4567)
r1 = MLJ.range(mps, :eta, lower=0.001, upper=10, scale=:log);
r2 = MLJ.range(mps, :d, lower=2, upper=15)
r3 = MLJ.range(mps, :chi_max, lower=15, upper=50)
r4 = MLJ.range(mps, :exit_early, values=[true,false])
r5 = MLJ.range(mps, :sigmoid_transform, values=[true,false])

if !MC_CV
    swarm = AdaptiveParticleSwarm(rng=MersenneTwister(0))
    self_tuning_mps = TunedModel(
        model=mps,
        resampling=StratifiedCV(nfolds=5, rng=MersenneTwister(1)),
        tuning=swarm,
        range=[r1, r2, r3],
        measure=MLJ.misclassification_rate,
        n=50,
        acceleration=CPUThreads() # acceleration=CPUProcesses()
    );

    mach = machine(self_tuning_mps, X_train, y_train)
    fit!(mach)



    @show report(mach).best_model
    best = report(mach).best_model
    mach = machine(best, X_train, y_train)
    fit!(mach)
    yhat = MLJ.predict(mach, X_test)
    @show MLJ.accuracy(yhat, y_test)
    
else
    swarm = AdaptiveParticleSwarm(rng=MersenneTwister(0))
    self_tuning_mps = TunedModel(
        model=mps,
        resampling=StratifiedCV(nfolds=5, rng=MersenneTwister(1)),
        tuning=swarm,
        range=[r1, r2, r3],
        measure=MLJ.misclassification_rate,
        n=50,
        acceleration=CPUThreads() # acceleration=CPUProcesses()
    );
    mach = machine(self_tuning_mps, Xs, ys)
end


if evaL_resamp
    train_rat = length(y_train)/length(ys)
    nresamps = 30
    splits = [partition(1:length(ys), train_rat, rng=MersenneTwister(i), stratify=ys) for i in 1:nresamps]
    evaluate!(mach,
        resampling = splits,
        measure=MLJ.misclassification_rate,
        verbosity=1,
        acceleration=CPUThreads()
    )
end

#println("Evaluating")
#encoding = Basis("Legendre")
# MPSClassifier(
#   nsweeps = 5, 
#   chi_max = 32, 
#   eta = 0.07498942093324559, 
#   d = 5, 
#   encoding = :Legendre_No_Norm, 
#   projected_basis = false, 
#   aux_basis_dim = 2, 
#   cutoff = 1.0e-10, 
#   update_iters = 1, 
#   dtype = Float64, 
#   loss_grad = :KLD, 
#   bbopt = :TSGO, 
#   track_cost = false, 
#   rescale = (false, true), 
#   train_classes_separately = false, 
#   encode_classes_separately = false, 
#   return_encoding_meta_info = false, 
#   minmax = true, 
#   exit_early = false, 
#   sigmoid_transform = true, 
#   init_rng = 4567, 
#   chi_init = 4, 
#   reformat_verbosity = -1)