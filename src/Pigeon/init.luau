--!strict

local Types = require(script.Types)
local Network = require(script.Network)
local NewTransformer = require(script.Transformer)
local NewStagedTable = require(script.StagedTable)
local NewCarrier = require(script.Carrier)

export type Transformer = Types.Transformer
export type StageTable<i> = Types.StageTable<i>
export type PigeonCarrier = Types.PigeonCarrier
export type MiddlewareFunction = Types.MiddlewareFunction
export type StageGuard = Types.StageGuard

local pigeon = {}

pigeon.Network = Network
pigeon.Types = Types

local carriers: { [string]: Types.InternalCarrier } = {}

function pigeon.new(name: string, options: Types.CarrierOptions?): Types.PigeonCarrier
	if options ~= nil then
		return NewCarrier(name, options)
	end

	local existing = carriers[name]
	if existing and not existing._dropped and not existing._transformer.destroyed then
		return existing
	end

	local carrier = (NewCarrier(name) :: any) :: Types.InternalCarrier

	if carrier._dropped then
		return carrier
	end

	carriers[name] = carrier
	carrier._onDropped = function()
		if carriers[name] == carrier then
			carriers[name] = nil
		end
	end

	return carrier
end

function pigeon.StagedTable<i>(initial): Types.StageTable<i>
	return NewStagedTable(initial)
end

function pigeon.Transformer(uuid: string?): Types.Transformer
	return NewTransformer(uuid)
end

function pigeon.GetRef(transformer: Types.Transformer): RemoteEvent
	return Network.GetRef(transformer)
end
return pigeon
