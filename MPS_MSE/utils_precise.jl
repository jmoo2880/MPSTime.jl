using StatsBase
using Random
using Plots
using DelimitedFiles



function AngleEncoder(x::Float64) 
    """Function to convert normalised time series to an angle encoding."""
    @assert x <= 1.0 && x >= 0.0 "Data points must be rescaled between 1 and 0 before encoding using the angle encoder."
    s1 = exp(1im * (3π/2) * x) * cospi(0.5 * x)
    s2 = exp(-1im * (3π/2) * x) * sinpi(0.5 * x)
    return [s1, s2]
 
end

function NormalisedDataToProductState(sample::Vector, site_indices::Vector{Index{Int64}})
    """Function to convert a single normalised sample to a product state
    with local dimension 2, as specified by the feature map."""

    n_sites = length(site_indices) # number of mps sites
    product_state = MPS(Complex{BigFloat},site_indices; linkdims=1)
    
    # check that the number of sites matches the length of the time series
    if n_sites !== length(sample)
        error("Number of MPS sites: $n_sites does not match the time series length: $(length(sample))")
    end

    for j=1:n_sites
        T = ITensor(Complex{BigFloat},site_indices[j])
        # map 0 to |0> and 1 to |1> 
        zero_state, one_state = AngleEncoder(sample[j])
        T[1] = zero_state
        T[2] = one_state
        product_state[j] = T
    end

    return product_state

end

function GenerateAllProductStates(X_normalised::Matrix, y::Vector{Int}, type::String, 
    site_indices::Vector{Index{Int64}})
    """"Convert an entire dataset of normalised time series to a corresponding 
    dataset of product states"""
    # check data is in the expected range first
    if all((0 .<= X_normalised) .& (X_normalised .<= 1)) == false
        error("Data must be rescaled between 0 and 1 before generating product states.")
    end

    types = ["train", "test", "valid"]
    if type in types
        println("Initialising $type states.")
    else
        error("Invalid dataset type. Must be train, test, or valid.")
    end

    num_samples = size(X_normalised)[1]
    # pre-allocate
    all_product_states = timeSeriesIterable(undef, num_samples)

    for i=1:num_samples
        sample_pstate = NormalisedDataToProductState(X_normalised[i, :], site_indices)
        sample_label = y[i]
        product_state = PState(sample_pstate, sample_label, type)
        all_product_states[i] = product_state
    end

    return all_product_states

end;

function LoadSplitsFromTextFile(train_set_location::String, val_set_location::String, 
    test_set_location::String)
    """As per typical UCR formatting, assume labels in first column, followed by data"""
    # do checks
    train_data = readdlm(train_set_location)
    val_data = readdlm(val_set_location)
    test_data = readdlm(test_set_location)

    X_train = train_data[:, 2:end]
    y_train = Int.(train_data[:, 1])

    X_val = val_data[:, 2:end]
    y_val = Int.(val_data[:, 1])

    X_test = test_data[:, 2:end]
    y_test = Int.(test_data[:, 1])

    # recombine val and train into train

    return (X_train, y_train), (X_val, y_val), (X_test, y_test)

end

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
    #amplitude = rand(Uniform(0.1, 1.0))
    return amplitude .* sin.(frequency .* t .+ phase) .+ 0.2 .* randn(n)
end

function GenerateRandomNoise(n, scale=1)
    return randn(n) .* scale
end

function GenerateToyDataset(n, dataset_size, train_split=0.7)
    # calculate size of the splits
    train_size = floor(Int, dataset_size * train_split) # round to an integer
    #val_size = floor(Int, dataset_size * val_split) # do the same for the validation set
    test_size = dataset_size - train_size

    # initialise structures for the datasets
    X_train = zeros(BigFloat, train_size, n)
    y_train = zeros(Int, train_size)




    X_test = zeros(BigFloat, test_size, n)
    y_test = zeros(Int, test_size)

    function insert_data!(X, y, idx, data, label)
        X[idx, :] = data
        y[idx] = label
    end

    for i in 1:train_size
        label = rand(0:1)  # Randomly choose between sine wave (0) and noise (1)
        data = label == 0 ? GenerateSine(n, 1.0, 2.0) : GenerateSine(n, 1.0, 5.0)
        insert_data!(X_train, y_train, i, data, label)
    end

    # for i in 1:val_size
    #     label = rand(0:1)
    #     data = label == 0 ? GenerateSine(n) : GenerateRandomNoise(n)
    #     insert_data!(X_val, y_val, i, data, label)
    # end

    for i in 1:test_size
        label = rand(0:1)
        data = label == 0 ? GenerateSine(n, 1.0, 2.0) : GenerateSine(n, 1.0, 5.0)
        insert_data!(X_test, y_test, i, data, label)
    end

    return (X_train, y_train), (X_test, y_test)

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

