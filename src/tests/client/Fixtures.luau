local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pigeon = require(ReplicatedStorage:WaitForChild("Pigeon"))

local Tests = ReplicatedStorage:WaitForChild("PigeonTests")
local Protocol = require(Tests.Protocol)
local Recorder = require(Tests.Recorder)

local Fixtures = {}

Fixtures.carriers = {} :: { [string]: any }
Fixtures.transformers = {} :: { [string]: any }
Fixtures.inbox = Recorder.new()

Fixtures.patchPackets = 0
Fixtures.snapshotPackets = 0

Fixtures.control = nil :: any
Fixtures.patientControl = nil :: any

function Fixtures.ask(action: string, payload: any?): any
	local ok, result = Fixtures.control:Call("Do", action, payload or {})
	if ok ~= true then
		error(string.format("control action %q failed: %s", action, tostring(result)), 0)
	end
	return result
end

function Fixtures.args(...: any): any
	local count = select("#", ...)
	local values = table.create(count)
	for index = 1, count do
		local value = select(index, ...)
		values[index] = if value == nil then Protocol.NIL else value
	end
	return { args = values, arity = count }
end

function Fixtures.withArgs(payload: any, ...: any): any
	local out = table.clone(payload)
	local packed = Fixtures.args(...)
	out.args = packed.args
	out.arity = packed.arity
	return out
end

function Fixtures.serverCount(key: string): number
	local result = Fixtures.ask("observed", { key = key })
	return result.count
end

function Fixtures.serverEntries(key: string): { any }
	return Fixtures.ask("observed", { key = key }).entries
end

function Fixtures.serverForget(key: string?)
	Fixtures.ask("reset", { key = key })
end

function Fixtures.build()
	local inbox = Fixtures.inbox

	Fixtures.control = Pigeon.new(Protocol.Control, { Timeout = 10 }):Init()
	Fixtures.patientControl = Pigeon.new(Protocol.Control, { Timeout = 300 }):Init()

	local live = Pigeon.new(Protocol.Live):Init()
	Fixtures.carriers[Protocol.Live] = live

	live:When("Echo", function(...: any)
		return ...
	end)

	live:When("Triple", function()
		return 1, "two", true
	end)

	live:When("Arity", function(...: any)
		return select("#", ...)
	end)

	live:When("Slow", function()
		task.wait(1.2)
		return "eventually"
	end)

	live:When("Boom", function()
		error("a client listener that throws must not answer the call")
	end)

	live:When("Silent", function() end)

	live:UseIncoming(function(_direction: string, event: string)
		if event == "Denied" then
			return "DENIED"
		end
		return nil
	end)

	live:On("Recv", function(key: string, ...: any)
		inbox:record(key, ...)
	end)

	live:On("Ordered", function(key: string, index: number)
		inbox:record(key, index)
	end)

	live:When("Observed", function(key: string)
		return { count = inbox:count(key), entries = inbox:all(key) }
	end)

	live:When("Reset", function(key: string?)
		inbox:reset(key)
		return true
	end)

	live:When("PatchCount", function()
		return Fixtures.patchPackets
	end)

	live:When("ResetPatches", function()
		Fixtures.patchPackets = 0
		Fixtures.snapshotPackets = 0
		return true
	end)

	live:When("TableValue", function(id: string, path: { any })
		local carrier = Fixtures.carriers[Protocol.Tables]
		local staged = (carrier :: any)._tables[id]
		if not staged then
			return nil
		end

		local node = staged:GetTable()
		for index = 1, #path - 1 do
			node = node[path[index]]
			if node == nil then
				return nil
			end
		end
		return node[path[#path]]
	end)

	live:When("HasTable", function(id: string)
		return (Fixtures.carriers[Protocol.Tables] :: any)._tables[id] ~= nil
	end)

	local echo = Pigeon.new(Protocol.Echo):Init()
	Fixtures.carriers[Protocol.Echo] = echo
	inbox:hook(echo, "Recv", "Echo.Recv")
	inbox:hook(echo, "Ordered", "Echo.Ordered")

	local guarded = Pigeon.new(Protocol.Guarded):Init()
	Fixtures.carriers[Protocol.Guarded] = guarded
	inbox:hook(guarded, "Recv", "Guarded.Recv")

	local revocable = Pigeon.new(Protocol.Revoke):Init()
	Fixtures.carriers[Protocol.Revoke] = revocable
	inbox:hook(revocable, "Recv", "Revoke.Recv")

	local rooms = Pigeon.new(Protocol.Rooms):Init()
	Fixtures.carriers[Protocol.Rooms] = rooms
	inbox:hook(rooms, "Recv", "Rooms.Recv")

	local tables = Pigeon.new(Protocol.Tables):Init()
	Fixtures.carriers[Protocol.Tables] = tables

	tables:UseIncoming(function(_direction: string, event: string)
		if event == "__pigeon_table_patch" then
			Fixtures.patchPackets += 1
		elseif event == "__pigeon_table_snapshot" then
			Fixtures.snapshotPackets += 1
		end
		return nil
	end)

	local middleware = Pigeon.new(Protocol.Middleware):Init()
	Fixtures.carriers[Protocol.Middleware] = middleware

	middleware:UseOutgoing(function(direction: string, event: string, args: { any })
		inbox:record("Mw.ClientOutgoing", direction, event, #args)

		if event == "Alias" then
			return "Plain", args
		end
		if event == "Grow" then
			local copy = table.clone(args)
			table.insert(copy, "added-by-client-outgoing")
			return nil, copy
		end
		return nil
	end)

	middleware:UseOutgoing(function()
		error("deliberate outgoing middleware failure")
	end)

	middleware:UseIncoming(function(_direction: string, event: string, args: { any })
		if event == "ServerSaid" then
			local copy = table.clone(args)
			table.insert(copy, "seen-by-client-incoming")
			return "ClientHeard", copy
		end

		if event == "Denied" then
			return "DENIED"
		end
		return nil
	end)

	inbox:hook(middleware, "Denied", "Mw.Denied")
	inbox:hook(middleware, "ClientHeard", "Mw.ClientHeard")
	inbox:hook(middleware, "ServerSaid", "Mw.ServerSaid")
	inbox:hook(middleware, "Delivered", "Mw.Delivered")
	inbox:hook(middleware, "Rewritten", "Mw.Rewritten")

	local unreliable = Pigeon.new(Protocol.Unreliable, { Unreliable = true }):Init()
	Fixtures.carriers[Protocol.Unreliable] = unreliable
	inbox:hook(unreliable, "Recv", "Unreliable.Recv")

	Fixtures.carriers[Protocol.Late] = Pigeon.new(Protocol.Late):Init()

	local shared = Pigeon.Transformer(Protocol.SharedTransformer)
	Fixtures.transformers.shared = shared

	local sharedA = Pigeon.new(Protocol.SharedA, { Transformer = shared }):Init()
	local sharedB = Pigeon.new(Protocol.SharedB, { Transformer = shared }):Init()
	Fixtures.carriers[Protocol.SharedA] = sharedA
	Fixtures.carriers[Protocol.SharedB] = sharedB

	inbox:hook(sharedA, "Recv", "SharedA.Recv")
	inbox:hook(sharedB, "Recv", "SharedB.Recv")

	local odd = Pigeon.Transformer(Protocol.MismatchTransformer)
	Fixtures.transformers.mismatch = odd

	local mismatch = Pigeon.new(Protocol.Mismatch, { Transformer = odd }):Init()
	Fixtures.carriers[Protocol.Mismatch] = mismatch
	inbox:hook(mismatch, "Recv", "Mismatch.Recv")

	local cluster = Pigeon.Transformer(Protocol.ClusterTransformer)
	Fixtures.transformers.cluster = cluster

	local clusterA = Pigeon.new(Protocol.ClusterA, { Transformer = cluster }):Init()
	local clusterB = Pigeon.new(Protocol.ClusterB, { Transformer = cluster }):Init()
	Fixtures.carriers[Protocol.ClusterA] = clusterA
	Fixtures.carriers[Protocol.ClusterB] = clusterB

	inbox:hook(clusterA, "Recv", "ClusterA.Recv")
	inbox:hook(clusterB, "Recv", "ClusterB.Recv")

	local doomed = Pigeon.new(Protocol.Doomed):Init()
	Fixtures.carriers[Protocol.Doomed] = doomed
	inbox:hook(doomed, "Recv", "Doomed.Recv")
end

return Fixtures
