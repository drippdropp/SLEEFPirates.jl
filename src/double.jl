import Base: -, <, copysign, flipsign, convert

const vIEEEFloat = Union{IEEEFloat,Vec{<:Any,<:IEEEFloat},VectorizationBase.VecUnroll{<:Any,<:Any,<:IEEEFloat}}

struct Double{T<:vIEEEFloat} <: Number
    hi::T
    lo::T
end
@inline Double(x::T) where {T<:vIEEEFloat} = Double(x, zero(T))
@inline function Double(x::Vec, y::Vec)
    Double(Vec(data(x)), Vec(data(y)))
end
@inline promote_vtype(::Type{Mask{W,U}}, ::Type{Double{V}}) where {W, U, T, V <: AbstractSIMD{W,T}} = Double{V}
@inline promote_vtype(::Type{Double{V}}, ::Type{Mask{W,U}}) where {W, U, T, V <: AbstractSIMD{W,T}} = Double{V}
@inline promote_vtype(::Type{Mask{W,U}}, ::Type{Double{T}}) where {W, U, T <: Number} = Double{Vec{W,T}}
@inline promote_vtype(::Type{Double{T}}, ::Type{Mask{W,U}}) where {W, U, T <: Number} = Double{Vec{W,T}}
@inline Base.convert(::Type{Double{V}}, v::Vec) where {W,T,V <: AbstractSIMD{W,T}} = Double(convert(V, v), vzero(V))
@inline Base.convert(::Type{Double{V}}, v::V) where {V <: AbstractSIMD} = Double(v, vzero(V))
@inline Base.convert(::Type{Double{V}}, m::Mask) where {V} = m
@inline Base.convert(::Type{Double{V}}, m::V) where {V<:Mask} = m
@inline Base.convert(::Type{Double{V}}, d::Double{T}) where {W,T,V<:AbstractSIMD{W,T}} = Double(vbroadcast(Val{W}(), d.hi), vbroadcast(Val{W}(), d.lo))
@inline Base.eltype(d::Double) = eltype(d.hi)

(::Type{T})(x::Double{T}) where {T<:vIEEEFloat} = x.hi + x.lo

@inline Base.eltype(d::Double{T}) where {T <: IEEEFloat} = T
@inline function Base.eltype(d::Double{S}) where {N,T,S <: Union{Vec{N,T}, Vec{N,T}}}
    T
end
@inline ifelse(u::Mask, v1::Double, v2::Double) = Double(ifelse(u, v1.hi, v2.hi), ifelse(u, v1.lo, v2.lo))
@generated function ifelse(m::VecUnroll{N,W,T}, v1::Double{V1}, v2::Double{V2}) where {N,W,T,V1,V2}
    q = Expr(:block, Expr(:meta, :inline), :(md = m.data), :(v1h = v1.hi), :(v2h = v2.hi), :(v1l = v1.lo), :(v2l = v2.lo))
    if V1 <: VecUnroll
        push!(q.args, :(v1hd = v1h.data))
        push!(q.args, :(v1ld = v1l.data))
    end
    if V2 <: VecUnroll
        push!(q.args, :(v2hd = v2h.data))
        push!(q.args, :(v2ld = v2l.data))
    end
    th = Expr(:tuple); tl = Expr(:tuple)
    for n ∈ 1:N+1
        ifelseₕ = Expr(:call, :ifelse, Expr(:ref, :md, n))
        ifelseₗ = Expr(:call, :ifelse, Expr(:ref, :md, n))
        if V1 <: VecUnroll
            push!(ifelseₕ.args, Expr(:ref, :v1hd, n))
            push!(ifelseₗ.args, Expr(:ref, :v1ld, n))
        else
            push!(ifelseₕ.args, :v1h)
            push!(ifelseₗ.args, :v1l)
        end
        if V2 <: VecUnroll
            push!(ifelseₕ.args, Expr(:ref, :v2hd, n))
            push!(ifelseₗ.args, Expr(:ref, :v2ld, n))
        else
            push!(ifelseₕ.args, :v2h)
            push!(ifelseₕ.args, :v2l)
        end
        push!(th.args, ifelseₕ)
        push!(tl.args, ifelseₗ)
    end
    push!(q.args, :(Double(VecUnroll($th),VecUnroll($tl)))); q
end

@inline trunclo(x::Float64) = reinterpret(Float64, reinterpret(UInt64, x) & 0xffff_ffff_f800_0000) # clear lower 27 bits (leave upper 26 bits)
@inline trunclo(x::Float32) = reinterpret(Float32, reinterpret(UInt32, x) & 0xffff_f000) # clear lowest 12 bits (leave upper 12 bits)

# @inline trunclo(x::VecProduct) = trunclo(Vec(data(x)))
@inline function trunclo(x::Vec{N,Float64}) where {N}
    reinterpret(Vec{N,Float64}, reinterpret(Vec{N,UInt64}, x) & vbroadcast(Val{N}(), 0xffff_ffff_f800_0000)) # clear lower 27 bits (leave upper 26 bits)
end
@inline function trunclo(x::Vec{N,Float32}) where {N}
    reinterpret(Vec{N,Float32}, reinterpret(Vec{N,UInt32}, x) & vbroadcast(Val{N}(), 0xffff_f000)) # clear lowest 12 bits (leave upper 12 bits)
end

@inline function splitprec(x::vIEEEFloat)
    hx = trunclo(x)
    hx, x - hx
end

@inline function dnormalize(x::Double{T}) where {T}
    r = x.hi + x.lo
    Double(r, (x.hi - r) + x.lo)
end

@inline flipsign(x::Double{<:vIEEEFloat}, y::vIEEEFloat) = Double(flipsign(x.hi, y), flipsign(x.lo, y))

@inline scale(x::Double{<:vIEEEFloat}, s::vIEEEFloat) = Double(s * x.hi, s * x.lo)


@inline (-)(x::Double{T}) where {T<:vIEEEFloat} = Double(-x.hi, -x.lo)

@inline function (<)(x::Double{<:vIEEEFloat}, y::Double{<:vIEEEFloat})
    x.hi < y.hi
end

@inline function (<)(x::Double{<:vIEEEFloat}, y::Union{Number,Vec})
    x.hi < y
end

@inline function (<)(x::Union{Number,Vec}, y::Double{<:vIEEEFloat})
    x < y.hi
end

# quick-two-sum x+y
@inline function dadd(x::vIEEEFloat, y::vIEEEFloat) #WARNING |x| >= |y|
    s = x + y
    Double(s, vsub(x, s) + y)
end

@inline function dadd(x::vIEEEFloat, y::Double{<:vIEEEFloat}) #WARNING |x| >= |y|
    s = x + y.hi
    Double(s, vsub(x, s) + y.hi + y.lo)
end

@inline function dadd(x::Double{<:vIEEEFloat}, y::vIEEEFloat) #WARNING |x| >= |y|
    s = x.hi + y
    Double(s, vsub(x.hi, s) + y + x.lo)
end

@inline function dadd(x::Double{<:vIEEEFloat}, y::Double{<:vIEEEFloat}) #WARNING |x| >= |y|
    s = x.hi + y.hi
    Double(s, vsub(x.hi, s) + y.hi + y.lo + x.lo)
end

@inline function dsub(x::Double{<:vIEEEFloat}, y::Double{<:vIEEEFloat}) #WARNING |x| >= |y|
    s = x.hi - y.hi
    Double(s, vsub(x.hi, s) - y.hi - y.lo + x.lo)
end

@inline function dsub(x::Double{<:vIEEEFloat}, y::vIEEEFloat) #WARNING |x| >= |y|
    s = x.hi - y
    Double(s, vsub(x.hi, s) - y + x.lo)
end

@inline function dsub(x::vIEEEFloat, y::Double{<:vIEEEFloat}) #WARNING |x| >= |y|
    s = x - y.hi
    Double(s, vsub(x, s) - y.hi - y.lo)
end

@inline function dsub(x::vIEEEFloat, y::vIEEEFloat) #WARNING |x| >= |y|
    s = x - y
    Double(s, vsub(x, s) - y)
end


# two-sum x+y  NO BRANCH
@inline function dadd2(x::vIEEEFloat, y::vIEEEFloat)
    s = x + y
    v = vsub(s, x)
    Double(s, vsub(x, vsub(s, v)) + vsub(y, v))
end

@inline function dadd2(x::vIEEEFloat, y::Double{<:vIEEEFloat})
    s = x + y.hi
    v = s - x
    Double(s, vsub(x, vsub(s, v)) + vsub(y.hi, v) + y.lo)
end

@inline dadd2(x::Double{<:vIEEEFloat}, y::vIEEEFloat) = dadd2(y, x)

@inline function dadd2(x::Double{<:vIEEEFloat}, y::Double{<:vIEEEFloat})
    s = x.hi + y.hi
    v = vsub(s, x.hi)
    smv = vsub(s, v)
    yhimv = vsub(y.hi, v)
    Double(s, vsub(x.hi, smv) + (yhimv) + x.lo + y.lo)
end

@inline function dsub2(x::vIEEEFloat, y::vIEEEFloat)
    s = x - y
    v = s - x
    Double(s, vsub(x, vsub(s, v)) + vsub(-y, v))
end

@inline function dsub2(x::vIEEEFloat, y::Double{<:vIEEEFloat})
    s = x - y.hi
    v = s - x
    Double(s, vsub(x, vsub(s, v)) + vsub(-y.hi, v) - y.lo)
end

@inline function dsub2(x::Double{<:vIEEEFloat}, y::vIEEEFloat)
    s = x.hi - y
    v = s - x.hi
    Double(s, vsub(x.hi, vsub(s, v)) + vsub(-y, v) + x.lo)
end

@inline function dsub2(x::Double{<:vIEEEFloat}, y::Double{<:vIEEEFloat})
    s = x.hi - y.hi
    v = s - x.hi
    Double(s, vsub(x.hi, vsub(s, v)) + vsub(-y.hi, v) + x.lo - y.lo)
end

@inline function ifelse(b::Mask{N}, x::Double{T1}, y::Double{T2}) where {N,T<:Union{Float32,Float64},T1<:Union{T,Vec{N,T}},T2<:Union{T,Vec{N,T}}}
    V = Vec{N,T}
    Double(ifelse(b, V(x.hi), V(y.hi)), ifelse(b, V(x.lo), V(y.lo)))
end

if FMA_FAST

    # two-prod-fma
    @inline function dmul(x::vIEEEFloat, y::vIEEEFloat)
        z = x * y
        Double(z, fma(x, y, -z))
    end

    @inline function dmul(x::Double{<:vIEEEFloat}, y::vIEEEFloat)
        z = x.hi * y
        Double(z, fma(x.hi, y, -z) + x.lo * y)
    end

    @inline dmul(x::vIEEEFloat, y::Double{<:vIEEEFloat}) = dmul(y, x)

    @inline function dmul(x::Double{<:vIEEEFloat}, y::Double{<:vIEEEFloat})
        z = x.hi * y.hi
        Double(z, fma(x.hi, y.hi, -z) + x.hi * y.lo + x.lo * y.hi)
    end

    # x^2
    @inline function dsqu(x::T) where {T<:vIEEEFloat}
        z = x * x
        Double(z, fma(x, x, -z))
    end

    @inline function dsqu(x::Double{T}) where {T<:vIEEEFloat}
        z = x.hi * x.hi
        Double(z, fma(x.hi, x.hi, -z) + x.hi * (x.lo + x.lo))
    end

    # sqrt(x)
    @inline function dsqrt(x::Double{T}) where {T<:vIEEEFloat}
        zhi = _sqrt(x.hi)
        Double(zhi, (x.lo + fma(-zhi, zhi, x.hi)) / (zhi + zhi))
    end

    # x/y
    @inline function ddiv(x::Double{<:vIEEEFloat}, y::Double{<:vIEEEFloat})
        invy = 1 / y.hi
        zhi = x.hi * invy
        Double(zhi, vmul((fma(-zhi, y.hi, x.hi) + fma(-zhi, y.lo, x.lo)), invy))
    end

    @inline function ddiv(x::vIEEEFloat, y::vIEEEFloat)
        ry = 1 / y
        r = x * ry
        Double(r, vmul(vfnmadd(r, y, x), ry))
        # Double(r, vmul(fma(-r, y, x), ry))
    end

    # 1/x
    @inline function drec(x::vIEEEFloat)
        zhi = 1 / x
        Double(zhi, fma(-zhi, x, one(eltype(x))) * zhi)
    end

    @inline function drec(x::Double{<:vIEEEFloat})
        zhi = 1 / x.hi
        Double(zhi, (fma(-zhi, x.hi, one(eltype(x))) + -zhi * x.lo) * zhi)
    end

else

    #two-prod x*y
    @inline function dmul(x::vIEEEFloat, y::vIEEEFloat)
        hx, lx = splitprec(x)
        hy, ly = splitprec(y)
        z = x * y
        Double(z, ((hx * hy - z) + lx * hy + hx * ly) + lx * ly)
    end

    @inline function dmul(x::Double{<:vIEEEFloat}, y::vIEEEFloat)
        hx, lx = splitprec(x.hi)
        hy, ly = splitprec(y)
        z = x.hi * y
        Double(z, (hx * hy - z) + lx * hy + hx * ly + lx * ly + x.lo * y)
    end

    @inline dmul(x::vIEEEFloat, y::Double{<:vIEEEFloat}) = dmul(y, x)

    @inline function dmul(x::Double{<:vIEEEFloat}, y::Double{<:vIEEEFloat})
        hx, lx = splitprec(x.hi)
        hy, ly = splitprec(y.hi)
        z = x.hi * y.hi
        Double(z, (((hx * hy - z) + lx * hy + hx * ly) + lx * ly) + x.hi * y.lo + x.lo * y.hi)
    end

    # x^2
    @inline function dsqu(x::T) where {T<:vIEEEFloat}
        hx, lx = splitprec(x)
        z = x * x
        Double(z, (hx * hx - z) + lx * (hx + hx) + lx * lx)
    end

    @inline function dsqu(x::Double{T}) where {T<:vIEEEFloat}
        hx, lx = splitprec(x.hi)
        z = x.hi * x.hi
        Double(z, (hx * hx - z) + lx * (hx + hx) + lx * lx + x.hi * (x.lo + x.lo))
    end

    # sqrt(x)
    @inline function dsqrt(x::Double{T}) where {T<:vIEEEFloat}
        c = _sqrt(x.hi)
        u = dsqu(c)
        Double(c, (x.hi - u.hi - u.lo + x.lo) / (c + c))
    end

    # x/y
    @inline function ddiv(x::Double{<:vIEEEFloat}, y::Double{<:vIEEEFloat})
        invy = 1 / y.hi
        c = x.hi * invy
        u = dmul(c, y.hi)
        Double(c, ((((x.hi - u.hi) - u.lo) + x.lo) - c * y.lo) * invy)
    end

    @inline function ddiv(x::vIEEEFloat, y::vIEEEFloat)
        ry = 1 / y
        r = x * ry
        hx, lx = splitprec(r)
        hy, ly = splitprec(y)
        Double(r, (((-hx * hy + r * y) - lx * hy - hx * ly) - lx * ly) * ry)
    end


    # 1/x
    @inline function drec(x::T) where {T<:vIEEEFloat}
        c = 1 / x
        u = dmul(c, x)
        Double(c, (one(T) - u.hi - u.lo) * c)
    end

    @inline function drec(x::Double{T}) where {T<:vIEEEFloat}
        c = 1 / x.hi
        u = dmul(c, x.hi)
        Double(c, (one(T) - u.hi - u.lo - c * x.lo) * c)
    end

end
