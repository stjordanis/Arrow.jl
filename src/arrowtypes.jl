# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""
The ArrowTypes module provides the [`ArrowTypes.Arrowtype`](@ref) interface trait that objects can define
in order to signal how they should be serialized in the arrow format.
"""
module ArrowTypes

using UUIDs

export ArrowType, NullType, PrimitiveType, BoolType, ListType, FixedSizeListType, MapType, StructType, UnionType, DictEncodedType

abstract type ArrowType end

ArrowType(x::T) where {T} = ArrowType(T)
ArrowType(::Type{T}) where {T} = isprimitivetype(T) ? PrimitiveType() : StructType()

function arrowconvert end

arrowconvert(T, x) = convert(T, x)
arrowconvert(::Type{Union{T, Missing}}, x) where {T} = arrowconvert(T, x)
arrowconvert(::Type{Union{T, Missing}}, ::Missing) where {T} = missing

struct NullType <: ArrowType end

ArrowType(::Type{Missing}) = NullType()

struct PrimitiveType <: ArrowType end

ArrowType(::Type{<:Integer}) = PrimitiveType()
ArrowType(::Type{<:AbstractFloat}) = PrimitiveType()

struct BoolType <: ArrowType end
ArrowType(::Type{Bool}) = BoolType()

struct ListType <: ArrowType end

# isstringtype MUST BE UTF8 (other codeunit sizes not supported; arrow encoding for strings is specifically UTF8)
isstringtype(T) = false
isstringtype(::Type{Union{T, Missing}}) where {T} = isstringtype(T)

ArrowType(::Type{<:AbstractString}) = ListType()
isstringtype(::Type{<:AbstractString}) = true

ArrowType(::Type{Symbol}) = ListType()
isstringtype(::Type{Symbol}) = true
arrowconvert(::Type{Symbol}, x::String) = Symbol(x)
arrowconvert(::Type{String}, x::Symbol) = String(x)

ArrowType(::Type{<:AbstractArray}) = ListType()

struct FixedSizeListType <: ArrowType end

ArrowType(::Type{NTuple{N, T}}) where {N, T} = FixedSizeListType()
gettype(::Type{NTuple{N, T}}) where {N, T} = T
getsize(::Type{NTuple{N, T}}) where {N, T} = N

ArrowType(::Type{UUID}) = FixedSizeListType()
gettype(::Type{UUID}) = UInt8
getsize(::Type{UUID}) = 16

function _cast(::Type{Y}, x)::Y where {Y}
    y = Ref{Y}()
    _unsafe_cast!(y, Ref(x), 1)
    return y[]
end

function _unsafe_cast!(y::Ref{Y}, x::Ref, n::Integer) where {Y}
    X = eltype(x)
    GC.@preserve x y begin
        ptr_x = Base.unsafe_convert(Ptr{X}, x)
        ptr_y = Base.unsafe_convert(Ptr{Y}, y)
        unsafe_copyto!(Ptr{X}(ptr_y), ptr_x, n)
    end
    return y
end

arrowconvert(::Type{NTuple{16,UInt8}}, u::UUID) = _cast(NTuple{16,UInt8}, u.value)
arrowconvert(::Type{UUID}, u::NTuple{16,UInt8}) = UUID(_cast(UInt128, u))

# These methods are included as deprecation paths to allow reading Arrow files that may have
# been written before Arrow.jl's current UUID <-> NTuple{16,UInt8} mapping existed (in which case
# a struct-based fallback `JuliaLang.UUID` extension type may have been utilized)
arrowconvert(::Type{UUID}, u::NamedTuple{(:value,),Tuple{UInt128}}) = UUID(u.value)
arrowconvert(::Type{UUID}, u::UInt128) = UUID(u)

struct StructType <: ArrowType end

ArrowType(::Type{<:NamedTuple}) = StructType()

@enum STRUCT_TYPES NAMEDTUPLE STRUCT # KEYWORDARGS

structtype(::Type{NamedTuple{N, T}}) where {N, T} = NAMEDTUPLE
structtype(::Type{T}) where {T} = STRUCT

# must implement keytype, valtype
struct MapType <: ArrowType end

ArrowType(::Type{<:AbstractDict}) = MapType()

struct UnionType <: ArrowType end

ArrowType(::Union) = UnionType()

struct DictEncodedType <: ArrowType end

"""
There are a couple places when writing arrow buffers where
we need to write a "dummy" value; it doesn't really matter
what we write, but we need to write something of a specific
type. So each supported writing type needs to define `default`.
"""
function default end

default(T) = zero(T)
default(::Type{Symbol}) = Symbol()
default(::Type{Char}) = '\0'
default(::Type{<:AbstractString}) = ""
default(::Type{Union{T, Missing}}) where {T} = default(T)

function default(::Type{A}) where {A <: AbstractVector{T}} where {T}
    a = similar(A, 1)
    a[1] = default(T)
    return a
end

default(::Type{NTuple{N, T}}) where {N, T} = ntuple(i -> default(T), N)
default(::Type{T}) where {T <: Tuple} = Tuple(default(fieldtype(T, i)) for i = 1:fieldcount(T))
default(::Type{Dict{K, V}}) where {K, V} = Dict{K, V}()
default(::Type{NamedTuple{names, types}}) where {names, types} = NamedTuple{names}(Tuple(default(fieldtype(types, i)) for i = 1:length(names)))

const JULIA_TO_ARROW_TYPE_MAPPING = Dict{Type, Tuple{String, Type}}(
    Char => ("JuliaLang.Char", UInt32),
    Symbol => ("JuliaLang.Symbol", String),
    UUID => ("JuliaLang.UUID", NTuple{16,UInt8}),
)

istyperegistered(::Type{T}) where {T} = haskey(JULIA_TO_ARROW_TYPE_MAPPING, T)

function getarrowtype!(meta, ::Type{T}) where {T}
    arrowname, arrowtype = JULIA_TO_ARROW_TYPE_MAPPING[T]
    meta["ARROW:extension:name"] = arrowname
    meta["ARROW:extension:metadata"] = ""
    return arrowtype
end

const ARROW_TO_JULIA_TYPE_MAPPING = Dict{String, Tuple{Type, Type}}(
    "JuliaLang.Char" => (Char, UInt32),
    "JuliaLang.Symbol" => (Symbol, String),
    "JuliaLang.UUID" => (UUID, NTuple{16,UInt8}),
)

function extensiontype(f, meta)
    if haskey(meta, "ARROW:extension:name")
        typename = meta["ARROW:extension:name"]
        if haskey(ARROW_TO_JULIA_TYPE_MAPPING, typename)
            T = ARROW_TO_JULIA_TYPE_MAPPING[typename][1]
            return f.nullable ? Union{T, Missing} : T
        else
            @warn "unsupported ARROW:extension:name type: \"$typename\""
        end
    end
    return nothing
end

function registertype!(juliatype::Type, arrowtype::Type, arrowname::String=string("JuliaLang.", string(juliatype)))
    # TODO: validate that juliatype isn't already default arrow type
    JULIA_TO_ARROW_TYPE_MAPPING[juliatype] = (arrowname, arrowtype)
    ARROW_TO_JULIA_TYPE_MAPPING[arrowname] = (juliatype, arrowtype)
    return
end

end # module ArrowTypes