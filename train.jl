using Knet
using ArgParse
using JLD
using HDF5
using MAT
using JSON
using AutoGrad

include("lib/vocab.jl")
include("lib/base.jl")
include("lib/init.jl")
include("lib/model.jl")
include("lib/batch.jl")
include("lib/convnet.jl")
include("lib/train.jl")
include("lib/eval.jl")
include("lib/util.jl")
include("lib/data.jl")

function main(args)
    s = ArgParseSettings()
    s.description = string(
        "Show and Tell: A Neural Image Caption Generator",
        " Knet implementation by Ilker Kesen [ikesen16_at_ku.edu.tr], 2016.")

    @add_arg_table s begin
        # load/save files
        ("--images"; help="images JLD file")
        ("--captions"; help="captions zip file (shared by Karpathy)")
        ("--vocabfile"; help="vocabulary JLD file")
        ("--loadfile"; default=nothing; help="pretrained model file if any")
        ("--savefile"; default=nothing; help="model save file after train")
        ("--cnnfile"; help="pre-trained CNN MAT file")
        ("--extradata"; action=:store_true;
         help="use restval split for training")

        # model options
        ("--winit"; arg_type=Float32; default=Float32(0.08))
        ("--hidden"; arg_type=Int; default=512)
        ("--embed"; arg_type=Int; default=512)
        ("--convnet"; default="vgg16")
        ("--lastlayer"; default="relu7")
        ("--visual"; arg_type=Int; nargs='+'; default=[4096])
        ("--cnnmode"; arg_type=Int; default=1)

        # training options
        ("--nogpu"; action=:store_true)
        ("--epochs"; arg_type=Int; default=1)
        ("--batchsize"; arg_type=Int; default=200)
        ("--lr"; arg_type=Float32; default=Float32(0.001))
        ("--gclip"; arg_type=Float32; default=Float32(5.0))
        ("--seed"; arg_type=Int; default=-1; help="random seed")
        ("--gcheck"; arg_type=Int; default=0; help="gradient checking")
        ("--finetune"; action=:store_true; help="fine tune convnet")
        ("--optim"; default="Adam"; help="optimizer (Sgd|Adam|Adagrad)")
        ("--eps"; default=1e-6; help="epsilon for Adagrad optimizer")
        ("--adam"; action=:store_true; help="use adam optimizer")
        ("--decay"; arg_type=Float32; default=Float32(1.0); help="lr decay")
        ("--decayperiod"; arg_type=Int64; default=0)
        ("--fast"; action=:store_true; help="do not compute train loss")
        ("--saveperiod"; arg_type=Int; default=0)
        ("--newoptimizer"; action=:store_true)
        ("--evalmetric"; default="bleu")
        ("--beamsize"; arg_type=Int; default=1)
        ("--checkpoints"; arg_type=Int; default=1)
        ("--sortbylen"; action=:store_true)

        # dropout values
        ("--fc6drop"; arg_type=Float32; default=Float32(0.5))
        ("--fc7drop"; arg_type=Float32; default=Float32(0.5))
        ("--softdrop"; arg_type=Float32; default=Float32(0.5))
        ("--wembdrop"; arg_type=Float32; default=Float32(0.5))
        ("--vembdrop"; arg_type=Float32; default=Float32(0.5))
        ("--membdrop"; arg_type=Float32; default=Float32(0.5))
        ("--attdrop"; arg_type=Float32; default=Float32(0.5))
    end

    # parse args
    @printf("\nScript started. [%s]\n", now()); flush(STDOUT)
    isa(args, AbstractString) && (args=split(args))
    o = parse_args(args, s; as_symbols=true); display(o); flush(STDOUT)

    # random seed
    s = o[:seed] > 0 ? srand(o[:seed]) : srand()
    @printf("\nrandom seed:\n")
    display(s.seed); println(); flush(STDOUT)

    # load vocabulary
    vocab = load(o[:vocabfile], "vocab")
    o[:vocabsize] = vocab.size
    println("Vocabulary loaded."); flush(STDOUT)

    # initialize state and weights
    o[:atype] = !o[:nogpu] ? KnetArray{Float32} : Array{Float32}
    prevscore = bestscore =
        o[:loadfile] == nothing ? Inf : load(o[:loadfile], "score")
    prevloss = bestloss =
        o[:loadfile] == nothing ? Inf : load(o[:loadfile], "lossval")
    w, srnn = get_weights(o)
    wcnn =  get_wcnn(o)
    if wcnn != nothing && o[:finetune]
        w["wcnn"] = wcnn
    end
    opts = get_opts(o, w)
    println("Model loaded."); flush(STDOUT)

    # get samples used during training process
    train, restval, val = get_entries(o[:captions], ["train", "restval", "val"])
    if o[:extradata]
        train = [train; restval]
    else
        val = [val; restval]
    end
    restval = 0

    # split samples into image/sentence pairs
    train = get_pairs(train)
    valid = get_pairs(val) # keep val for validation
    gc()
    const nsamples = length(train)
    const nbatches = div(nsamples, o[:batchsize])
    println("Data loaded."); flush(STDOUT)


    # gradient check
    # if o[:gcheck] > 0
    #     ids = shuffle([1:nsamples...])[1:o[:batchsize]]
    #     images, captions, masks = make_batch(o, train[ids], vocab)
    #     gradcheck(loss, w, copy(s), images, captions, masks;
    #               gcheck=o[:gcheck], verbose=true, atol=0.01)
    #     images
    #     gc()
    # end

    # checkpoints
    checkpoints = []

    # sort sequences
    if o[:sortbylen]
        sort!(train, by=i->length(i[2]), rev=true)
    end
    sort!(valid, by=i->length(i[2]), rev=true)
    offsets = collect(1:o[:batchsize]:nsamples+1)

    # training
    const saveperiod = o[:saveperiod] > 0 ? o[:saveperiod] : length(offsets)-1
    @printf("Training started (nsamples=%d, nbatches=%d, loss=%g, score=%g). [%s]\n",
            nsamples, nbatches, prevloss, prevscore, now()); flush(STDOUT)
    for epoch = 1:o[:epochs]
        t0 = now()

        # data split training
        losstrn = 0
        nwords  = 0
        if !o[:sortbylen]
            shuffle!(train)
            orders = [1:(length(offsets)-1)...]
        else
            orders = randperm(length(offsets)-1)
        end
        for (i,k) in enumerate(orders)
            iter = (epoch-1)*nbatches+i
            lower, upper = offsets[k:k+1]
            samples = train[lower:upper-1]
            images, x, y, batchsizes = make_batch(o, samples, vocab)
            this_loss, this_words = train!(
                w, srnn, images, x, y, batchsizes, opts, o)
            flush(STDOUT)
            images = 0; captions = 0; ans = 0; gc()
            losstrn += this_loss
            nwords  += this_words

            if iter % saveperiod == 0
                lossval = bulkloss(w,srnn,o,valid,vocab)
                @printf("\n(epoch/iter): %d/%d, loss: %g/%g [%s] ",
                        epoch, iter, losstrn/nwords, lossval, now())
                flush(STDOUT)
                # scores, bp, hlen, rlen =
                #     validate(w, val, vocab, o)
                # @printf("\nBLEU = %.1f/%.1f/%.1f/%.1f ",
                #         map(i->i*100,scores)...)
                # @printf("(BP=%g, ratio=%g, hyp_len=%d, ref_len=%d) [%s]\n",
                #         bp, hlen/rlen, hlen, rlen, now())
                # flush(STDOUT)
                # score = scores[end]
                score = lossval

                # learning rate decay
                decay!(o, opts, lossval, prevloss)
                prevscore = score
                prevloss  = lossval
                gc()

                # check and save best model
                score <= bestscore || continue

                path, ext = splitext(abspath(o[:savefile]))
                filename  = abspath(string(path, "-iter-", iter, ext))
                savemodel(o, w, opts, filename, score, lossval)
                @printf("Model saved to %s.\n", filename); flush(STDOUT)

                # keep track of checkpoints
                push!(checkpoints, (score, -lossval, filename))
                sort!(checkpoints, rev=true)
                if length(checkpoints) > o[:checkpoints]
                    _, _, worst = pop!(checkpoints)
                    rm(worst)
                end
                bestscore = checkpoints[end][1]
            end
        end # batches end

        t1 = now()
        elapsed = Int64(round(Float64(t1-t0)*0.001))
        @printf("\nepoch #%d finished. (time elapsed: %s)\n",
                epoch, pretty_time(elapsed))
        flush(STDOUT)
        gc()
    end # epoch end
end

function decay!(o, opts, lossval, prevloss)
    if o[:decay] < 1.0 && lossval > prevloss
        o[:lr] *= o[:decay]
        @printf("\nlr decay. new lr=%g\n", o[:lr]); flush(STDOUT)
        decay!(o[:lr], opts)
    end
end

function decay!(lr, opts::Dict)
    for k in keys(opts)
        decay!(lr, opts[k])
    end
end

function decay!(lr, opts::Array)
    for k in 1:length(opts)
        decay!(lr, opts[k])
    end
end

function decay!(lr, opt::Union{Knet.Adam,Knet.Sgd,Knet.Adagrad})
    opt.lr = lr
end

function savemodel(o, w, opts, filename, score, lossval)
    if o[:savefile] != nothing
        save(filename,
             "w", copy_weights(w),
             "opts", copy_opts(opts, w, true),
             "score", score,
             "lossval", lossval)
    end
end

function validate(w, data, vocab, o; metric=bleu, split="val")
    wcnn = o[:finetune] ? w[:wcnn] : nothing
    wdec = w
    hyp, ref = [], []
    s = initstate(o[:atype], o[:hidden], 1)

    hyp, ref = h5open(o[:images], "r") do f
        hyp, ref = [], []
        for entry in data
            image = read(f, entry["filename"])
            caption = generate(
                wdec, copy(s), image, vocab; beamsize=o[:beamsize])
            push!(hyp, caption)
            push!(ref, map(s->s["raw"], entry["sentences"]))
        end
        hyp, ref
    end

    return metric(hyp, ref)
end

!isinteractive() && !isdefined(Core.Main, :load_only) && main(ARGS)
