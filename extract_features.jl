using Knet, ArgParse, JLD, MAT
include("lib/convnet.jl")
SPLITS = ["train", "restval", "val", "test"]

function main(args)
    s = ArgParseSettings()
    s.description = "Extract CNN features of images (now only just for VGG-19)"

    @add_arg_table s begin
        ("--images"; help="image data file in JLD format")
        ("--cnnfile"; help="CNN model file")
        ("--savefile"; help="extracted features output file")
        ("--lastlayer"; default="relu7"; help="layer for feature extraction")
        ("--batchsize"; arg_type=Int; default=10; help="batchsize")
        ("--seed"; arg_type=Int; default=1; help="random seed")
        ("--fc6drop"; arg_type=Float32; default=Float32(0.0))
        ("--fc7drop"; arg_type=Float32; default=Float32(0.0))
        ("--feedback"; arg_type=Int; default=0; help="feedback in every N image")
        ("--extradata"; action=:store_true)
    end

    # parse args
    isa(args, AbstractString) && (args=split(args))
    o = parse_args(args, s; as_symbols=true); println(o); flush(STDOUT)
    o[:seed] > 0 && srand(o[:seed])


    # load data
    @printf("Data and model loading... "); flush(STDOUT)
    images = load(o[:images])
    batchsize = o[:batchsize]
    lastlayer = o[:lastlayer]
    CNN = matread(o[:cnnfile])
    weights = get_vgg_weights(CNN; last_layer=lastlayer)
    features = Dict()
    @printf("Done.\n"); flush(STDOUT)

    # feature extraction
    for splitname in keys(images)
        @printf("Feature extraction for %s split...\n", splitname); flush(STDOUT)
        splitdata = Any[]
        counter = 0
        dropouts = Dict()
        if splitname == "train" || (splitname == "restval" && o[:extradata])
            dropouts = Dict("fc6drop" => o[:fc6drop], "fc7drop" => o[:fc7drop])
        end
        for entry in images[splitname]
            filename, image = entry
            feats = vgg19(weights, KnetArray(image); dropouts=dropouts)
            feats = convert(Array{Float32}, feats)
            feats = reshape(feats, 1, length(feats))
            push!(splitdata, (filename, feats))
            counter += 1
            if o[:feedback] > 0 && counter % o[:feedback] == 0
                @printf("%d images processed so far.\n", counter)
                flush(STDOUT)
            end
        end
        features[splitname] = splitdata
        @printf("Done.\n"); flush(STDOUT)
    end

    # save features
    @printf("Save extracted features to output file... "); flush(STDOUT)
    save(o[:savefile],
         "train", features["train"],
         "restval", features["restval"],
         "val", features["val"],
         "test", features["test"])
    @printf("Totally done.\n"); flush(STDOUT)
end


function split_feature_extraction(data, bs, model)
    ns = length(data) # number of samples
    nb = Int(ceil(ns/bs)) # number of batches
    rvecs2array(A) = map(i -> A[i,:], 1:size(A,1))
    nth_batch(n) = data[(n-1)*bs+1:min(n*bs,ns)]
    make_batch(A) = reduce((x...) -> cat(4, x...), A[1], A[2:end])
    make_nth_batch(n) = make_batch(nth_batch(n))
    extract_features = get_feature_extractor(model...)
    extract_nth_batch_features(n) = extract_features(make_batch(nth_batch(n)))
    return mapreduce(extract_nth_batch_features, hcat, 1:nb)
end


!isinteractive() && !isdefined(Core.Main, :load_only) && main(ARGS)