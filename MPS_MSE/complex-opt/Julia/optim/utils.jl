using StatsBase
using Random
using Plots
using ITensors

function generate_training_data(samples_per_class::Int, data_pts::Int=5)

    class_A_samples = zeros(samples_per_class, data_pts)
    class_B_samples = ones(samples_per_class, data_pts)
    all_samples = vcat(class_A_samples, class_B_samples)
    all_labels = Int.(vcat(zeros(size(class_A_samples)[1]), ones(size(class_B_samples)[1])))

    shuffle_idxs = shuffle(1:samples_per_class*2)


    return all_samples[shuffle_idxs, :], all_labels[shuffle_idxs]

end

function GenerateSine(n, amplitude=1.0, frequency=1.0)
    t = range(0, 2π, n)
    phase = rand(Uniform(0, 2π)) # randomise the phase
    amplitude = rand(Uniform(0.1, 1.0))
    return amplitude .* sin.(frequency .* t .+ phase) .+ 0.2 .* randn(n)
end

function GenerateRandomNoise(n, scale=1)
    return randn(n) .* scale
end

function GenerateToyDataset(n, dataset_size, train_split=0.7, val_split=0.15)
    # calculate size of the splits
    train_size = floor(Int, dataset_size * train_split) # round to an integer
    val_size = floor(Int, dataset_size * val_split) # do the same for the validation set
    test_size = dataset_size - train_size - val_size # whatever remains

    # initialise structures for the datasets
    X_train = zeros(Float64, train_size, n)
    y_train = zeros(Int, train_size)

    X_val = zeros(Float64, val_size, n)
    y_val = zeros(Int, val_size)

    X_test = zeros(Float64, test_size, n)
    y_test = zeros(Int, test_size)

    function insert_data!(X, y, idx, data, label)
        X[idx, :] = data
        y[idx] = label
    end

    for i in 1:train_size
        label = rand(0:1)  # Randomly choose between sine wave (0) and noise (1)
        data = label == 0 ? GenerateSine(n) : GenerateRandomNoise(n)
        insert_data!(X_train, y_train, i, data, label)
    end

    for i in 1:val_size
        label = rand(0:1)
        data = label == 0 ? GenerateSine(n) : GenerateRandomNoise(n)
        insert_data!(X_val, y_val, i, data, label)
    end

    for i in 1:test_size
        label = rand(0:1)
        data = label == 0 ? GenerateSine(n) : GenerateRandomNoise(n)
        insert_data!(X_test, y_test, i, data, label)
    end

    return (X_train, y_train), (X_val, y_val), (X_test, y_test)

end

using Plots.PlotMeasures
function PlotTrainingSummary(info::Dict)
    """Takes in the dictionary of training information 
    and summary information"""
    # extract the keys
    training_loss = info["train_loss"]
    num_sweeps = length(training_loss) - 1
    time_per_sweep = info["time_taken"]

    train_accuracy = info["train_acc"]
    test_accuracy = info["test_acc"]
    validation_accuracy = info["val_acc"]

    train_loss = info["train_loss"]
    test_loss = info["test_loss"]
    validation_loss = info["val_loss"]

    # compute the mean time per sweep
    mean_sweep_time = mean(time_per_sweep)
    println("Mean sweep time: $mean_sweep_time (s)")

    # compute the maximum accuracy acheived across any sweep
    max_acc_sweep = argmax(test_accuracy)
    # subtract one because initial test accuracy before training included at index 1
    println("Maximum test accuracy: $(test_accuracy[max_acc_sweep]) achieved on sweep $(max_acc_sweep-1)")

    # create curves
    sweep_range = collect(0:num_sweeps)
    p1 = plot(sweep_range, train_loss, label="train loss", alpha=0.4, c=palette(:default)[1])
    scatter!(sweep_range, train_loss, alpha=0.4, label="", c=palette(:default)[1])
    plot!(sweep_range, validation_loss, label="valid loss", alpha=0.4, c=palette(:default)[2])
    scatter!(sweep_range, validation_loss, alpha=0.4, label="", c=palette(:default)[2])
    plot!(sweep_range, test_loss, label="test loss", alpha=0.4, c=palette(:default)[3])
    scatter!(sweep_range, test_loss, alpha=0.4, label="", c=palette(:default)[3])
    xlabel!("Sweep")
    ylabel!("Loss")

    p2 = plot(sweep_range, train_accuracy, label="train acc", c=palette(:default)[1], alpha=0.4)
    scatter!(sweep_range, train_accuracy, label="", c=palette(:default)[1], alpha=0.4)
    plot!(sweep_range, validation_accuracy, label="valid acc", c=palette(:default)[2], alpha=0.4)
    scatter!(sweep_range, validation_accuracy, label="", c=palette(:default)[2], alpha=0.4)
    plot!(sweep_range, test_accuracy, label="test acc", c=palette(:default)[3], alpha=0.4)
    scatter!(sweep_range, test_accuracy, label="", c=palette(:default)[3], alpha=0.4)
    xlabel!("Sweep")
    ylabel!("Accuracy")

    p3 = bar(collect(1:length(time_per_sweep)), time_per_sweep, label="", color=:skyblue,
        xlabel="Sweep", ylabel="Time taken (s)", title="Training time per sweep")
    
    ps = [p1, p2, p3]

    p = plot(ps..., size=(1000, 500), left_margin=5mm, bottom_margin=5mm)
    display(p)

end

struct RobustSigmoidTransform{T<:Real} <: AbstractDataTransform
    median::T
    iqr::T
    k::T
    positive::Bool

    function RobustSigmoidTransform(median::T, iqr::T, k::T, positive=true) where T<:Real
        new{T}(median, iqr, k, positive)
    end
end

function robust_sigmoid(x::Real, median::Real, iqr::Real, k::Real, positive::Bool)
    xhat = 1.0 / (1.0 + exp(-(x - median) / (iqr / k)))
    if !positive
        xhat = 2*xhat - 1
    end
    return xhat
end

function fitScaler(::Type{RobustSigmoidTransform}, X::Matrix; k::Real=1.35, positive::Bool=true)
    medianX = median(X)
    iqrX = iqr(X)
    return RobustSigmoidTransform(medianX, iqrX, k, positive)
end

function transformData(t::RobustSigmoidTransform, X::Matrix)
    return map(x -> robust_sigmoid(x, t.median, t.iqr, t.k, t.positive), X)
end

# New SigmoidTransform
struct SigmoidTransform <: AbstractDataTransform
    positive::Bool
end

function sigmoid(x::Real, positive::Bool)
    xhat = 1.0 / (1.0 + exp(-x))
    if !positive
        xhat = 2*xhat - 1
    end
    return xhat
end

function fitScaler(::Type{SigmoidTransform}, X::Matrix; positive::Bool=true)
    return SigmoidTransform(positive)
end

function transformData(t::SigmoidTransform, X::Matrix)
    return map(x -> sigmoid(x, t.positive), X)
end;

### DEBUG
function custom_MPS_norm(mps::MPS)
    prod = mps .* dag.(mps)

    norm = 1
    for p in prod
        norm *= p
    end
    return sqrt(norm)
end

function custom_MPS_norm2(mps::MPS)
    mpsdag = dag(mps)

    norm = mpsdag[1] * mps[1]
    for i in 2:length(mps)
        norm *= mps[i] * mpsdag[i]
    end
    return sqrt(norm)
end

function ITnorm(M1::MPS, M2::MPS)
    N = length(M1)
    M1dag = dag(M1)
    O = M1dag[1] * M2[1]

    for j in eachindex(M1)[2:end]
        O = (O * M1dag[j]) * M2[j]
    end

    return  O[]
end

function ITnorm(M1::MPS, M2::MPS)
    N = length(M1)
    M1dag = dag(M1)
    ITensors.sim!(linkinds, M1dag)
    O = M1dag[1] * M2[1]

    for j in eachindex(M1)[2:end]
        O = (O * M1dag[j]) * M2[j]
    end

    return  O[]
end

