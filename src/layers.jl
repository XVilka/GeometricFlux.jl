const aggr_func = Dict{Symbol,Function}(:+ => sum, :max => maximum, :mean => mean)

abstract type MessagePassing end
message(m::T, xi, xj, eij) where {T<:MessagePassing} = error("not implement")
update(m::T, xi, mi) where {T<:MessagePassing} = error("not implement")

function propagate(mp::T, neighbors::AbstractVector, X, E;
                   aggr::Symbol=:+) where {T<:MessagePassing}
    aggr in keys(aggr_func) || throw(DomainError(aggr, "not supported aggregation function."))
    N = length(neighbors)
    Y = Vector{AbstractArray}()
    for i = 1:N
        xi = view(X', :, i)
        ne = view(neighbors, i)
        xjs = map(j -> view(X', :, j), ne)
        eijs = map(j -> view(E, :, i, j), ne)
        m = map((xj, eij) -> message(mp, xi, xj, eij), xjs, eijs)[]
        mi = aggr_func[aggr](m, dims=2)
        push!(Y, update(mp, xi, mi))
    end
    return hcat(Y...)'
end



struct GCNConv{T,F}
    weight::AbstractMatrix{T}
    bias::AbstractMatrix{T}
    norm::AbstractMatrix{T}
    σ::F
end

function GCNConv(adj::AbstractMatrix, ch::Pair{<:Integer,<:Integer}, σ = identity;
                 init = glorot_uniform, T::DataType=Float32, bias::Bool=true)
    N = size(adj, 1)
    b = bias ? param(init(N, ch[2])) : zeros(T, N, ch[2])
    GCNConv(param(init(ch[1], ch[2])), b, normalized_laplacian(adj+I, T), σ)
end

(c::GCNConv)(X::AbstractMatrix) = c.σ(c.norm * X * c.weight + c.bias)



struct ChebConv{T}
    weight::AbstractArray{T,3}
    bias::AbstractMatrix{T}
    L̃::AbstractMatrix{T}
    k::Integer
    in_channel::Integer
    out_channel::Integer
end

function ChebConv(adj::AbstractMatrix, ch::Pair{<:Integer,<:Integer}, k::Integer;
                  init = glorot_uniform, T::DataType=Float32, bias::Bool=true)
    N = size(adj, 1)
    b = bias ? param(init(N, ch[2])) : zeros(T, N, ch[2])
    L̃ = T(2. / eigmax(adj)) * normalized_laplacian(adj, T) - I
    ChebConv(param(init(k, ch[1], ch[2])), b, L̃, k, ch[1], ch[2])
end

function (c::ChebConv)(X::AbstractMatrix)
    fin = c.in_channel
    @assert size(X, 2) == fin "Input feature size must match input channel size."
    N = size(c.L̃, 1)
    @assert size(X, 1) == N "Input vertex number must match Laplacian matrix size."
    fout = c.out_channel

    T = eltype(X)
    Y = Array{TrackedReal}(undef, N, fout)
    Z = Array{T}(undef, N, c.k, fin)
    for j = 1:fout
        Z[:,1,:] = X
        Z[:,2,:] = c.L̃ * X
        for k = 3:c.k
            Z[:,k,:] = 2*c.L̃* view(Z, :, k-1, :) - view(Z, :, k-2, :)
        end

        y = view(Z, :, :, 1) * view(c.weight, :, 1, j)
        for i = 2:fin
            y += view(Z, :, :, i) * view(c.weight, :, i, j)
        end
        Y[:,j] = y
    end
    Y += c.bias
    return Y
end



struct GraphConv{V,T,F}
    edgelist::V
    weight::AbstractMatrix{T}
    bias::AbstractMatrix{T}
    aggr::F
end

function GraphConv(el::AbstractVector{<:AbstractVector{<:Integer}},
                   ch::Pair{<:Integer,<:Integer}, aggr=+;
                   init = glorot_uniform, bias::Bool=true)
    N = size(el, 1)
    b = bias ? param(init(N, ch[2])) : zeros(T, N, ch[2])
    GraphConv(el, param(init(ch[1], ch[2])), b, aggr)
end

function GraphConv(adj::AbstractMatrix, ch::Pair{<:Integer,<:Integer}, aggr=+;
                   init = glorot_uniform, bias::Bool=true)
    N = size(adj, 1)
    b = bias ? param(init(N, ch[2])) : zeros(T, N, ch[2])
    GraphConv(neighbors(adj), param(init(ch[1], ch[2])), b, aggr)
end

function (g::GraphConv)(X::AbstractMatrix)
    N = size(X, 1)
    X_ = copy(X)'
    for i = 1:N
        ne = g.edgelist[i]
        X_[:,i] += sum(view(X', :, ne), dims=2)
    end
    X_' * g.weight + g.bias
end



struct GATConv{V,T}
    edgelist::V
    weight::AbstractMatrix{T}
    bias::AbstractMatrix{T}
    a::AbstractArray
    negative_slope::Real
end

function GATConv(adj::AbstractMatrix, ch::Pair{<:Integer,<:Integer}; heads=1,
                 concat=true, negative_slope=0.2, init=glorot_uniform, bias::Bool=true)
    N = size(adj, 1)
    b = bias ? param(init(N, ch[2])) : zeros(T, N, ch[2])
    GATConv(neighbors(adj), param(init(ch[1], ch[2])), b, param(init(2 * ch[2])), negative_slope)
end

function (g::GATConv)(X::AbstractMatrix)
    N = size(X, 1)
    fout = size(g.weight, 2)
    X_ = (X * g.weight)'
    Y = Array{TrackedReal}(undef, fout, N)
    for i = 1:N
        ne = g.edgelist[i]
        i_ne = vcat([i], ne)
        α = [leakyrelu(g.a' * vcat(X_[:,i], X_[:,j]), g.negative_slope) for j in i_ne]
        α = asoftmax(α)
        y = sum(α[i] * X_[:,i_ne[i]] for i = 1:length(α))
        Y[:,i] = y
    end
    Y = Y' + g.bias
    return Y
end

function asoftmax(xs)
    xs = [exp.(x) for x in xs]
    s = sum(xs)
    return [x ./ s for x in xs]
end


struct EdgeConv{V,F}
    edgelist::V
    nn
    aggr::F
end

function EdgeConv(adj::AbstractMatrix, nn; aggr::Symbol=:max)
    aggr in keys(aggr_func) || throw(DomainError(aggr, "not supported aggregation function."))
    EdgeConv(neighbors(adj), nn, aggr)
end

function (e::EdgeConv)(X::AbstractMatrix)
    X_ = X'
    N = size(e.edgelist, 1)
    Y = Vector{AbstractArray}()
    for i = 1:N
        ne = e.edgelist[i]
        x_i = X_[:,i]
        y = [e.nn(vcat(x_i, X_[:,j] - x_i)) for j = ne]
        push!(Y, aggr_func[e.aggr](y))
    end
    return hcat(Y...)'
end
