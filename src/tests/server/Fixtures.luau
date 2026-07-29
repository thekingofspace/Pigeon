local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pigeon = require(ReplicatedStorage:WaitForChild("Pigeon"))
local Network = require(ReplicatedStorage.Pigeon.Network)

local Tests = ReplicatedStorage:WaitForChild("PigeonTests")
local Protocol = require(Tests.Protocol)
local Recorder = require(Tests.Recorder)

local Fixtures = {}

Fixtures.carriers = {} :: { [string]: any }
Fixtures.tables = {} :: { [string]: any }
Fixtures.inbox = Recorder.new()
Fixtures.transformers = {} :: { [string]: any }

local Actions: { [string]: (Player, any) -> any } = {}
Fixtures.Actions = Actions

local function carrier(name: string): any
	local found = Fixtures.carriers[name]
	if not found then
		error("no fixture carrier named " .. tostring(name), 0)
	end
	return found
end

local function argsOf(payload: any): ...any
	local list = payload.args
	if type(list) ~= "table" then
		return
	end
	local count = payload.arity or #list
	local out = table.create(count)
	for index = 1, count do
		local value = list[index]
		out[index] = if value == Protocol.NIL then nil else value
	end
	return table.unpack(out, 1, count)
end

local function writePath(staged: any, path: { any }, value: any)
	local node = staged:GetTable()
	for index = 1, #path - 1 do
		node = node[path[index]]
	end
	node[path[#path]] = value
end

function Fixtures.build()
	local inbox = Fixtures.inbox

	local echo = Pigeon.new(Protocol.Echo)
	Fixtures.carriers[Protocol.Echo] = echo

	inbox:hookServer(echo, "Emit", "Echo.Emit")

	inbox:hookServer(echo, "Shared", "Echo.SharedOn")
	echo:When("Shared", function()
		return "from the responder"
	end)

	inbox:hookServer(echo, "OnlyOn", "Echo.OnlyOn")

	echo:When("Echo", function(_player: Player, ...: any)
		return ...
	end)

	echo:When("Sum", function(_player: Player, left: number, right: number)
		return left + right
	end)

	echo:When("Multi", function()
		return 1, "two", true
	end)

	echo:When("Trailing", function()
		return "first", nil, "third"
	end)

	echo:When("Nothing", function() end)

	echo:When("Fails", function()
		error("a listener that throws must not answer the Call")
	end)

	echo:When("WhoAmI", function(player: Player)
		return player.Name, player.UserId
	end)

	echo:When("Slow", function()
		task.wait(1.2)
		return "eventually"
	end)

	local guarded = Pigeon.new(Protocol.Guarded)
	Fixtures.carriers[Protocol.Guarded] = guarded
	inbox:hookServer(guarded, "Emit", "Guarded.Emit")
	guarded:When("Ask", function()
		return "answered"
	end)

	Fixtures.carriers[Protocol.Rooms] = Pigeon.new(Protocol.Rooms)

	local tables = Pigeon.new(Protocol.Tables)
	Fixtures.carriers[Protocol.Tables] = tables

	local main = Pigeon.StagedTable({
		counter = 0,
		label = "initial",
		stats = { hp = 100, mp = 50 },
		list = { 1, 2, 3 },
	})
	Fixtures.tables[Protocol.TableMain] = main
	tables:CaptureTable(Protocol.TableMain, main)

	local guardedTable = Pigeon.StagedTable({ secret = "hidden" })
	Fixtures.tables[Protocol.TableGuarded] = guardedTable
	guardedTable:UseCapture(function()
		return Fixtures.captureMode ~= "deny"
	end)
	guardedTable:UseRelease(function()
		return Fixtures.releaseMode ~= "deny"
	end)
	tables:CaptureTable(Protocol.TableGuarded, guardedTable)

	local forced = Pigeon.StagedTable({ pushed = true, at = "start" })
	Fixtures.tables[Protocol.TableForced] = forced

	local mixed = Pigeon.StagedTable()
	mixed:GetTable().keys = { [1] = "one", ["named"] = "two", [true] = "three", [4.5] = "four" }
	Fixtures.tables[Protocol.TableMixed] = mixed
	tables:CaptureTable(Protocol.TableMixed, mixed)

	local sticky = Pigeon.StagedTable({ ticks = 0 })
	Fixtures.tables[Protocol.TableSticky] = sticky
	tables:CaptureTable(Protocol.TableSticky, sticky)

	Fixtures.captureMode = "allow"
	Fixtures.releaseMode = "allow"

	local middleware = Pigeon.new(Protocol.Middleware)
	Fixtures.carriers[Protocol.Middleware] = middleware

	middleware:UseIncoming(function(direction: string, event: string, args: { any }, player: Player?)
		inbox:recordFrom("Mw.Incoming", player, direction, event, #args)

		if event == "Renamed" or event == "Unbound" then
			return "Target", args
		end
		return nil
	end)

	middleware:UseIncoming(function(_direction, event: string, args: { any })
		if event == "Appended" then
			local copy = table.clone(args)
			table.insert(copy, "added-by-server-incoming")
			return nil, copy
		end
		return nil
	end)

	middleware:UseIncoming(function()
		error("deliberate incoming middleware failure")
	end)

	middleware:UseOutgoing(function(direction: string, event: string, args: { any })
		inbox:record("Mw.Outgoing", direction, event, #args)
		if event == "Rewritten" then
			local copy = table.clone(args)
			table.insert(copy, "added-by-server-outgoing")
			return "Delivered", copy
		end
		return nil
	end)

	inbox:hookServer(middleware, "Target", "Mw.Target")
	inbox:hookServer(middleware, "Plain", "Mw.Plain")
	inbox:hookServer(middleware, "Appended", "Mw.Appended")
	inbox:hookServer(middleware, "Grow", "Mw.Grow")

	middleware:On("Renamed", function()
		inbox:record("Mw.RenamedRanDirectly")
	end)

	local unreliable = Pigeon.new(Protocol.Unreliable, { Unreliable = true })
	Fixtures.carriers[Protocol.Unreliable] = unreliable
	inbox:hookServer(unreliable, "Emit", "Unreliable.Emit")

	Fixtures.carriers[Protocol.UnreliableBuffer] = Pigeon.new(Protocol.UnreliableBuffer, { Unreliable = true })

	for _, channel in { Protocol.Buffered, Protocol.BufferedB, Protocol.BufferedC, Protocol.BufferedD } do
		Fixtures.carriers[channel] = Pigeon.new(channel)
	end
	Fixtures.carriers[Protocol.Late] = Pigeon.new(Protocol.Late)

	local shared = Pigeon.Transformer(Protocol.SharedTransformer)
	Fixtures.transformers.shared = shared

	local sharedA = Pigeon.new(Protocol.SharedA, { Transformer = shared })
	local sharedB = Pigeon.new(Protocol.SharedB, { Transformer = shared })
	Fixtures.carriers[Protocol.SharedA] = sharedA
	Fixtures.carriers[Protocol.SharedB] = sharedB

	inbox:hookServer(sharedA, "Ping", "SharedA.Ping")
	inbox:hookServer(sharedB, "Ping", "SharedB.Ping")

	local mismatch = Pigeon.new(Protocol.Mismatch)
	Fixtures.carriers[Protocol.Mismatch] = mismatch
	inbox:hookServer(mismatch, "Emit", "Mismatch.Emit")

	local cluster = Pigeon.Transformer(Protocol.ClusterTransformer)
	Fixtures.transformers.cluster = cluster
	Fixtures.carriers[Protocol.ClusterA] = Pigeon.new(Protocol.ClusterA, { Transformer = cluster })
	Fixtures.carriers[Protocol.ClusterB] = Pigeon.new(Protocol.ClusterB, { Transformer = cluster })

	local doomed = Pigeon.new(Protocol.Doomed)
	Fixtures.carriers[Protocol.Doomed] = doomed
	inbox:hookServer(doomed, "Emit", "Doomed.Emit")

	Fixtures.carriers[Protocol.Live] = Pigeon.new(Protocol.Live)

	local liveGuarded = Pigeon.new(Protocol.LiveGuarded)
	liveGuarded:UseHandshake(function()
		return false
	end)
	Fixtures.carriers[Protocol.LiveGuarded] = liveGuarded

	local revocable = Pigeon.new(Protocol.Revoke)
	revocable:UseHandshake(function(_player: Player, token: any)
		return token == Protocol.GoodToken
	end)
	Fixtures.carriers[Protocol.Revoke] = revocable
	inbox:hookServer(revocable, "Emit", "Revoke.Emit")

	local revocableTable = Pigeon.StagedTable({ ticks = 0, secret = "members only" })
	Fixtures.tables[Protocol.TableRevoke] = revocableTable
	revocable:CaptureTable(Protocol.TableRevoke, revocableTable)

	local control = Pigeon.new(Protocol.Control)
	Fixtures.carriers[Protocol.Control] = control

	control:When("Do", function(player: Player, action: string, payload: any)
		local handler = Actions[action]
		if not handler then
			return false, "unknown control action: " .. tostring(action)
		end

		local ok, result = pcall(handler, player, payload or {})
		if not ok then
			return false, tostring(result)
		end
		return true, result
	end)
end

Actions.ping = function()
	return "pong"
end

Actions.observed = function(_player, payload)
	return {
		count = Fixtures.inbox:count(payload.key),
		entries = Fixtures.inbox:all(payload.key),
	}
end

Actions.reset = function(_player, payload)
	Fixtures.inbox:reset(payload.key)
	return true
end

Actions.diagnostics = function()
	return Network.Diagnostics()
end

Actions.refCount = function()
	return Network.GetRefCount()
end

Actions.broadcast = function(_player, payload)
	carrier(payload.carrier):Broadcast(payload.event, argsOf(payload))
	return true
end

Actions.broadcastTo = function(player, payload)
	carrier(payload.carrier):BroadcastTo({ player }, payload.event, argsOf(payload))
	return true
end

Actions.broadcastExcept = function(player, payload)
	carrier(payload.carrier):BroadcastExcept({ player }, payload.event, argsOf(payload))
	return true
end

Actions.broadcastSeries = function(player, payload)
	local target = carrier(payload.carrier)
	for index = 1, payload.count do
		target:BroadcastTo({ player }, payload.event, index)
	end
	return true
end

Actions.callTo = function(player, payload)
	local target = carrier(payload.carrier)
	return Protocol.pack(target:CallTo(player, payload.event, argsOf(payload)))
end

Actions.approved = function(_player, payload)
	local names = {}
	for _, player in carrier(payload.carrier):Approved() do
		table.insert(names, player.Name)
	end
	return names
end

Actions.setGuard = function(_player, payload)
	local target = carrier(payload.carrier) :: any

	if payload.mode == "none" then
		target._handshake = nil
		table.clear(target._authed)
		return true
	end

	if payload.mode == "deny" then
		target:UseHandshake(function()
			return false
		end)
	elseif payload.mode == "allow" then
		target:UseHandshake(function()
			return true
		end)
	elseif payload.mode == "error" then
		target:UseHandshake(function()
			error("a guard that throws must refuse")
		end)
	else
		target:UseHandshake(function(_player: Player, token: any)
			return token == Protocol.GoodToken
		end)
	end

	return true
end

Actions.revoke = function(player, payload)
	return carrier(payload.carrier):Revoke(player)
end

Actions.addLateResponder = function()
	carrier(Protocol.Echo):When("LateResponder", function()
		return "answered late"
	end)
	return true
end

Actions.isAuthed = function(player, payload)
	return (carrier(payload.carrier) :: any)._authed[player] == true
end

Actions.roomCreate = function(player, payload)
	local members = if payload.includeCaller then { player } else {}
	carrier(payload.carrier):CreateRoom(payload.room, members)
	return true
end

Actions.roomJoin = function(player, payload)
	carrier(payload.carrier):JoinRoom(payload.room, player)
	return true
end

Actions.roomLeave = function(player, payload)
	carrier(payload.carrier):LeaveRoom(payload.room, player)
	return true
end

Actions.roomDestroy = function(_player, payload)
	carrier(payload.carrier):DestroyRoom(payload.room)
	return true
end

Actions.roomSend = function(_player, payload)
	carrier(payload.carrier):SendToRoom(payload.room, payload.event, argsOf(payload))
	return true
end

Actions.roomMembers = function(_player, payload)
	local room = (carrier(payload.carrier) :: any)._rooms[payload.room]
	if not room then
		return nil
	end
	local names = {}
	for _, member in room do
		table.insert(names, member.Name)
	end
	return names
end

Actions.tableSet = function(_player, payload)
	local staged = Fixtures.tables[payload.id]
	writePath(staged, payload.path, if payload.value == Protocol.NIL then nil else payload.value)
	return true
end

Actions.tableBurst = function(_player, payload)
	local staged = Fixtures.tables[payload.id]
	local view = staged:GetTable()
	for index = 1, payload.count do
		view["burst" .. index] = index
	end
	return true
end

Actions.tableForce = function(player, payload)
	local target = carrier(Protocol.Tables)
	local staged = Fixtures.tables[payload.id]
	target:ForceTable(payload.id, staged, if payload.toCaller then { player } else nil)
	return true
end

Actions.tableCapture = function(_player, payload)
	carrier(Protocol.Tables):CaptureTable(payload.id, Fixtures.tables[payload.id])
	return true
end

Actions.tableReleasePointer = function(_player, payload)
	carrier(Protocol.Tables):ReleaseTable(payload.id)
	return true
end

Actions.tableSubscribers = function(_player, payload)
	local staged = Fixtures.tables[payload.id] :: any
	local count = 0
	for _ in staged._subscribers or {} do
		count += 1
	end
	return count
end

Actions.tableGuardMode = function(_player, payload)
	if payload.capture then
		Fixtures.captureMode = payload.capture
	end
	if payload.release then
		Fixtures.releaseMode = payload.release
	end
	return true
end

Actions.tableSnapshotValue = function(_player, payload)
	local staged = Fixtures.tables[payload.id]
	local node = staged:GetTable()
	for index = 1, #payload.path - 1 do
		node = node[payload.path[index]]
	end
	return node[payload.path[#payload.path]]
end

Actions.destroyCarrier = function(_player, payload)
	carrier(payload.carrier):Destroy()
	return true
end

Actions.destroyCluster = function()
	Fixtures.transformers.cluster:Destroy()
	return true
end

Actions.playerCount = function()
	return #Players:GetPlayers()
end

return Fixtures
