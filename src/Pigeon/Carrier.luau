--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local types = require("./Types")
local Network = require("./Network")
local NewTransformer = require("./Transformer")
local NewStagedTable = require("./StagedTable")

local IS_SERVER = RunService:IsServer()

local ERRORS = {
	NOT_SERVER = "ERR_NOT_SERVER | This function is only available on the server.",
	NOT_CLIENT = "ERR_NOT_CLIENT | This function is only available on the client.",
	NO_ROOM = "ERR_NO_ROOM | Room '%s' does not exist.",
	NO_TABLE = "ERR_NO_TABLE | No staged table captured under id '%s'.",
	NO_NAME = "ERR_NO_NAME | A carrier must be given a name.",
	NO_TRANSFORMER = "ERR_NO_TRANSFORMER | options.Transformer must be a transformer.",
	CAPTURE_DENIED = "ERR_CAPTURE_DENIED | Capture of table '%s' was denied.",
	CALLBACK_ERROR = "ERR_CALLBACK_ERROR | Error in %s callback for event '%s': %s",
	NOT_APPROVED = "ERR_NOT_APPROVED | %s has not passed the handshake, so cannot be put in room '%s'.",
}

local HELD_TTL = 10
local HELD_MAX = 64

type Packet = types.CarrierPacket

local EV_PING = "__pigeon_ping"
local EV_HANDSHAKE = "__pigeon_handshake"
local EV_TABLE_REQUEST = "__pigeon_table_request"
local EV_TABLE_SNAPSHOT = "__pigeon_table_snapshot"
local EV_TABLE_PATCH = "__pigeon_table_patch"
local EV_TABLE_RELEASE = "__pigeon_table_release"
local EV_TABLE_REVOKE = "__pigeon_table_revoke"

local Carrier = {}
Carrier.__index = Carrier

local function wire(self: types.InternalCarrier, event: string): string
	return self._name .. "\0" .. event
end

local function unwire(self: types.InternalCarrier, event: string): string
	local prefix = self._name .. "\0"
	if string.sub(event, 1, #prefix) == prefix then
		return string.sub(event, #prefix + 1)
	end
	return event
end

local function applyMiddleware(
	chain: { types.MiddlewareFunction },
	direction: string,
	event: string,
	args: { any },
	player: Player?
): (string, { any })
	for _, middleware in chain do
		local ok, newEvent, newArgs = pcall(middleware, direction, event, args, player)
		if not ok then
			warn(string.format(ERRORS.CALLBACK_ERROR, direction .. " middleware", event, tostring(newEvent)))
		else
			if type(newEvent) == "string" then
				event = newEvent
			end
			if type(newArgs) == "table" then
				args = newArgs
			end
		end
	end
	return event, args
end

local function toList(value: { Player } | Player): { Player }
	if typeof(value) == "Instance" then
		return { value :: Player }
	end
	return value :: { Player }
end

local function alive(self: types.InternalCarrier): boolean
	return not self._dropped and not self._transformer.destroyed
end

local function notify(callback: (...any) -> (), packet: Packet)
	if packet.player then
		task.spawn(callback, packet.player, table.unpack(packet.args, 1, packet.count))
	else
		task.spawn(callback, table.unpack(packet.args, 1, packet.count))
	end
end

local function answer(self: types.InternalCarrier, responder: (...any) -> ...any, packet: Packet)
	local player = packet.player

	local results = table.pack(pcall(function()
		if player then
			return responder(player, table.unpack(packet.args, 1, packet.count))
		end
		return responder(table.unpack(packet.args, 1, packet.count))
	end))

	if not results[1] then
		warn(string.format(ERRORS.CALLBACK_ERROR, "responder", packet.event, tostring(results[2])))
		return
	end

	if packet.promiseId then
		local returned = table.move(results, 2, results.n, 1, {})
		Network.Respond(packet.bucket, packet.promiseId, { args = returned, n = results.n - 1 }, player)
	end
end

local function serve(self: types.InternalCarrier, packet: Packet)
	if packet.promiseId then
		local responder = self._responder[packet.event]
		if responder then
			answer(self, responder, packet)
		end
		return
	end

	local listeners = self._listeners[packet.event]
	if not listeners then
		return
	end
	for _, callback in table.clone(listeners) do
		notify(callback, packet)
	end
end

local function handled(self: types.InternalCarrier, event: string, isRequest: boolean): boolean
	if isRequest then
		return self._responder[event] ~= nil
	end
	local listeners = self._listeners[event]
	return listeners ~= nil and #listeners > 0
end

local function unbindIfIdle(self: types.InternalCarrier, event: string)
	if handled(self, event, true) or handled(self, event, false) then
		return
	end
	local disconnect = self._bound[event]
	if disconnect then
		disconnect()
		self._bound[event] = nil
	end
end

local function replay(self: types.InternalCarrier, event: string, isRequest: boolean, handler: (...any) -> ...any)
	local queue = self._held[event]
	if not queue then
		return
	end

	local now = os.clock()
	local kept = {}

	for _, packet in queue do
		if now - packet.at >= HELD_TTL then
			continue
		end
		if (packet.promiseId ~= nil) ~= isRequest then
			table.insert(kept, packet)
			continue
		end
		if isRequest then
			task.spawn(answer, self, handler, packet)
		else
			notify(handler, packet)
		end
	end

	if #kept > 0 then
		self._held[event] = kept
	else
		self._held[event] = nil
	end
end

local function keep(self: types.InternalCarrier, packet: Packet)
	local queue = self._held[packet.event]
	if not queue then
		queue = {}
		self._held[packet.event] = queue
	end

	local now = os.clock()
	for index = #queue, 1, -1 do
		if now - queue[index].at >= HELD_TTL then
			table.remove(queue, index)
		end
	end

	if #queue >= HELD_MAX then
		table.remove(queue, 1)
	end
	table.insert(queue, packet)
end

local function route(self: types.InternalCarrier, event: string, ...: any)
	if self._dropped then
		return
	end

	local bucket, payload, promiseId
	local player: Player? = nil

	if IS_SERVER then
		player, bucket, payload, promiseId = ...
	else
		bucket, payload, promiseId = ...
	end

	if IS_SERVER and player and self._handshake and event ~= EV_HANDSHAKE and not self._authed[player] then
		return
	end

	local args: { any } = if type(payload) == "table" then payload.args else {}
	local count: number = if type(payload) == "table" then payload.n or 0 else 0

	local resolved: string
	resolved, args = applyMiddleware(self._incoming, "incoming", event, args, player)
	count = math.max(count, #args)

	local packet: Packet = {
		at = os.clock(),
		event = resolved,
		args = args,
		count = count,
		player = player,
		bucket = bucket,
		promiseId = promiseId,
	}

	if handled(self, resolved, promiseId ~= nil) then
		serve(self, packet)
		return
	end

	if resolved ~= event then
		if promiseId then
			Network.Respond(bucket, promiseId, nil, player)
		end
		return
	end

	keep(self, packet)
end

local function bind(self: types.InternalCarrier, event: string)
	if self._bound[event] or self._transformer.destroyed then
		return
	end

	local disconnect = Network.Receive(wire(self, event), function(...)
		route(self, event, ...)
	end)

	local untrack = self._transformer:Track(disconnect)
	self._bound[event] = function()
		disconnect()
		untrack()
	end
end

local function prepare(self: types.InternalCarrier, event: string, player: Player?, ...: any): (string, { any })
	local args = table.pack(...)
	local plain = table.move(args, 1, args.n, 1, {})

	local resolved: string
	resolved, plain = applyMiddleware(self._outgoing, "outgoing", event, plain, player)

	return resolved, { args = plain, n = math.max(#plain, args.n) }
end

function Carrier.On(self: types.InternalCarrier, event: string, Callback: (...any) -> ())
	if self._dropped then
		return
	end

	if not self._listeners[event] then
		self._listeners[event] = {}
	end
	table.insert(self._listeners[event], Callback)
	bind(self, event)

	replay(self, event, false, Callback)
end

function Carrier.When(self: types.InternalCarrier, event: string, Callback: ((...any) -> ...any)?)
	if self._dropped then
		return
	end

	if Callback == nil then
		self._responder[event] = nil
		unbindIfIdle(self, event)
		return
	end

	self._responder[event] = Callback
	bind(self, event)

	replay(self, event, true, Callback)
end

function Carrier.Off(self: types.InternalCarrier, event: string, Callback: ((...any) -> ...any)?)
	if Callback then
		local callbacks = self._listeners[event]
		if callbacks then
			local index = table.find(callbacks, Callback)
			if index then
				table.remove(callbacks, index)
			end
			if #callbacks == 0 then
				self._listeners[event] = nil
			end
		end
		if self._responder[event] == Callback then
			self._responder[event] = nil
		end
	else
		self._listeners[event] = nil
		self._responder[event] = nil
	end

	unbindIfIdle(self, event)
end

function Carrier.UseHandshake(self: types.InternalCarrier, Callback: (Player, ...any) -> boolean)
	if not IS_SERVER then
		error(ERRORS.NOT_SERVER, 2)
	end

	self._handshake = Callback
	table.clear(self._authed)
	bind(self, EV_HANDSHAKE)
end

function Carrier.Init(self: types.InternalCarrier): any
	if IS_SERVER or self._inited or not alive(self) then
		return self
	end
	self._inited = true

	Network.Ready(self._transformer, self._name)

	return self
end

function Carrier.Handshake(self: types.InternalCarrier, ...: any): boolean
	if IS_SERVER then
		error(ERRORS.NOT_CLIENT, 2)
	end
	if not alive(self) then
		return false
	end

	local granted = Carrier.Call(self, EV_HANDSHAKE, ...)
	self._handshaken = granted == true
	return self._handshaken
end

local function evict(self: types.InternalCarrier, player: Player): boolean
	local admitted = self._authed[player] == true
	self._authed[player] = nil

	for _, room in self._rooms do
		local index = table.find(room, player)
		if index then
			table.remove(room, index)
		end
	end

	local dropped = {}
	for id, staged in self._tables do
		if staged._subscribers and staged._subscribers[player] ~= nil then
			staged._subscribers[player] = nil
			table.insert(dropped, id)
		end
	end

	if #dropped > 0 then
		local resolved, packed = prepare(self, EV_TABLE_REVOKE, player, dropped)
		Network.Broadcast({ player }, self._transformer, wire(self, resolved), packed, false)
	end

	return admitted
end

function Carrier.Revoke(self: types.InternalCarrier, Targets: { Player } | Player): number
	if not IS_SERVER then
		error(ERRORS.NOT_SERVER, 2)
	end
	if not alive(self) then
		return 0
	end

	local revoked = 0
	for _, player in toList(Targets) do
		if evict(self, player) then
			revoked += 1
		end
	end
	return revoked
end

function Carrier.Approved(self: types.InternalCarrier, Targets: { Player }?): { Player }
	local candidates = Targets or Players:GetPlayers()
	if not self._handshake then
		return candidates
	end

	local out = {}
	for _, player in candidates do
		if self._authed[player] then
			table.insert(out, player)
		end
	end
	return out
end

function Carrier.UseIncoming(self: types.InternalCarrier, Callback: types.MiddlewareFunction)
	table.insert(self._incoming, Callback)
end

function Carrier.UseOutgoing(self: types.InternalCarrier, Callback: types.MiddlewareFunction)
	table.insert(self._outgoing, Callback)
end

function Carrier.Emit(self: types.InternalCarrier, event: string, ...: any)
	if IS_SERVER then
		error(ERRORS.NOT_CLIENT, 2)
	end
	if not alive(self) then
		return
	end
	local resolved, packed = prepare(self, event, nil, ...)
	Network.Push(self._transformer, wire(self, resolved), packed, self.Unreliable)
end

function Carrier.BroadcastTo(self: types.InternalCarrier, Targets: { Player } | Player, event: string, ...: any)
	if not IS_SERVER then
		error(ERRORS.NOT_SERVER, 2)
	end
	if not alive(self) then
		return
	end

	local allowed = Carrier.Approved(self, toList(Targets))
	if #allowed == 0 then
		return
	end

	local resolved, packed = prepare(self, event, nil, ...)
	Network.Broadcast(allowed, self._transformer, wire(self, resolved), packed, self.Unreliable)
end

function Carrier.Broadcast(self: types.InternalCarrier, event: string, ...: any)
	if not IS_SERVER then
		error(ERRORS.NOT_SERVER, 2)
	end
	Carrier.BroadcastTo(self, Players:GetPlayers(), event, ...)
end

function Carrier.BroadcastExcept(self: types.InternalCarrier, Skip: { Player } | Player, event: string, ...: any)
	if not IS_SERVER then
		error(ERRORS.NOT_SERVER, 2)
	end

	local skipped = toList(Skip)
	local targets = {}
	for _, player in Players:GetPlayers() do
		if not table.find(skipped, player) then
			table.insert(targets, player)
		end
	end
	Carrier.BroadcastTo(self, targets, event, ...)
end

function Carrier.Call(self: types.InternalCarrier, event: string, ...: any): ...any
	if IS_SERVER then
		error(ERRORS.NOT_CLIENT, 2)
	end
	if not alive(self) then
		return nil
	end

	local resolved, packed = prepare(self, event, nil, ...)
	local ok, response = Network.Call(self._transformer, wire(self, resolved), packed, self.Timeout)
	if not ok or type(response) ~= "table" then
		return nil
	end
	if type(response) ~= "table" then
		return nil
	end
	return table.unpack(response.args, 1, response.n or 0)
end

function Carrier.CallTo(self: types.InternalCarrier, Target: Player, Event: string, ...: any): ...any
	if not IS_SERVER then
		error(ERRORS.NOT_SERVER, 2)
	end
	if not alive(self) then
		return nil
	end
	if self._handshake and not self._authed[Target] then
		return nil
	end

	local resolved, packed = prepare(self, Event, Target, ...)
	local ok, responses =
		Network.BroadcastCall({ Target }, self._transformer, wire(self, resolved), packed, self.Timeout)
	if not ok or type(responses) ~= "table" then
		return nil
	end

	local response = responses[Target]
	if type(response) ~= "table" then
		return nil
	end
	if type(response) ~= "table" then
		return nil
	end
	return table.unpack(response.args, 1, response.n or 0)
end

local function firstUnapproved(self: types.InternalCarrier, members: { Player }): Player?
	if not self._handshake then
		return nil
	end
	for _, player in members do
		if self._authed[player] ~= true then
			return player
		end
	end
	return nil
end

function Carrier.CreateRoom(self: types.InternalCarrier, RoomID: string, Members: { Player })
	if not IS_SERVER then
		error(ERRORS.NOT_SERVER, 2)
	end

	local members: { Player } = Members or {}
	local blocked = firstUnapproved(self, members)
	if blocked then
		error(string.format(ERRORS.NOT_APPROVED, tostring(blocked), RoomID), 2)
	end

	self._rooms[RoomID] = {}
	for _, player in members do
		table.insert(self._rooms[RoomID], player)
	end
end

function Carrier.DestroyRoom(self: types.InternalCarrier, RoomID: string)
	if not IS_SERVER then
		error(ERRORS.NOT_SERVER, 2)
	end
	self._rooms[RoomID] = nil
end

function Carrier.JoinRoom(self: types.InternalCarrier, RoomID: string, Members: { Player } | Player)
	if not IS_SERVER then
		error(ERRORS.NOT_SERVER, 2)
	end

	local members = toList(Members)
	local blocked = firstUnapproved(self, members)
	if blocked then
		error(string.format(ERRORS.NOT_APPROVED, tostring(blocked), RoomID), 2)
	end

	local room = self._rooms[RoomID]
	if not room then
		room = {}
		self._rooms[RoomID] = room
	end
	for _, player in members do
		if not table.find(room, player) then
			table.insert(room, player)
		end
	end
end

function Carrier.LeaveRoom(self: types.InternalCarrier, RoomID: string, Members: { Player } | Player)
	if not IS_SERVER then
		error(ERRORS.NOT_SERVER, 2)
	end

	local room = self._rooms[RoomID]
	if not room then
		return
	end
	for _, player in toList(Members) do
		local index = table.find(room, player)
		if index then
			table.remove(room, index)
		end
	end
end

function Carrier.SendToRoom(self: types.InternalCarrier, Room: string, event: string, ...: any)
	if not IS_SERVER then
		error(ERRORS.NOT_SERVER, 2)
	end

	local room = self._rooms[Room]
	if not room then
		warn(string.format(ERRORS.NO_ROOM, Room))
		return
	end
	Carrier.BroadcastTo(self, room, event, ...)
end

function Carrier.Ping(self: types.InternalCarrier): number
	if IS_SERVER then
		error(ERRORS.NOT_CLIENT, 2)
	end
	local started = os.clock()
	Carrier.Call(self, EV_PING)
	return os.clock() - started
end

function Carrier.CaptureTable(self: types.InternalCarrier, id: string, Table: types.StageTable)
	if not IS_SERVER then
		error(ERRORS.NOT_SERVER, 2)
	end

	local staged = Table :: any
	staged._id = id
	self._tables[id] = staged
	staged._subscribers = staged._subscribers or {}

	staged._onWrite = function(path: { any }, value: any)
		table.insert(staged._queued, { path = path, value = value })

		if staged._flushing then
			return
		end
		staged._flushing = true

		task.defer(function()
			staged._flushing = false

			local patches = staged._queued
			staged._queued = {}
			if #patches == 0 then
				return
			end

			local targets = {}
			for player in staged._subscribers do
				table.insert(targets, player)
			end
			if #targets == 0 then
				return
			end

			Carrier.BroadcastTo(self, targets, EV_TABLE_PATCH, id, patches)
		end)
	end
end

function Carrier.ReleaseTable(self: types.InternalCarrier, id: string)
	if not IS_SERVER then
		error(ERRORS.NOT_SERVER, 2)
	end
	self._tables[id] = nil
end

function Carrier.ForceTable(self: types.InternalCarrier, id: string, Targets: ({ Player } | Player)?)
	if not IS_SERVER then
		error(ERRORS.NOT_SERVER, 2)
	end

	local staged = self._tables[id]
	if not staged then
		error(string.format(ERRORS.NO_TABLE, id), 2)
	end

	local subscribers = staged._subscribers or {}
	staged._subscribers = subscribers

	local targets = if Targets then toList(Targets) else Players:GetPlayers()
	for _, player in targets do
		subscribers[player] = true
	end

	Carrier.BroadcastTo(self, targets, EV_TABLE_SNAPSHOT, id, staged:Snapshot())
end

local function adoptTable(self: types.InternalCarrier, id: string, snapshot: any): types.StageTable
	local existing = self._tables[id]
	if existing then
		existing:ApplySnapshot(snapshot)
		return existing
	end

	local staged = NewStagedTable() :: any
	staged:ApplySnapshot(snapshot)
	staged._id = id
	staged._onWrite = nil
	staged._onRelease = function()
		self._tables[id] = nil
		Carrier.Emit(self, EV_TABLE_RELEASE, id)
	end
	self._tables[id] = staged

	return staged
end

function Carrier.RequestTable(self: types.InternalCarrier, id: string): types.StageTable
	if IS_SERVER then
		error(ERRORS.NOT_CLIENT, 2)
	end

	local existing = self._tables[id]
	if existing then
		return existing
	end

	local granted, snapshot = Carrier.Call(self, EV_TABLE_REQUEST, id)
	if not granted then
		error(string.format(ERRORS.CAPTURE_DENIED, id), 2)
	end

	return adoptTable(self, id, snapshot)
end

function Carrier.Destroy(self: types.InternalCarrier)
	if self._dropped then
		return
	end
	self._dropped = true

	for _, disconnect in self._bound do
		disconnect()
	end
	table.clear(self._bound)

	local unwatch = self._unwatch
	if unwatch then
		self._unwatch = nil
		unwatch()
	end

	table.clear(self._listeners)
	table.clear(self._responder)

	table.clear(self._held)
	table.clear(self._rooms)
	table.clear(self._authed)

	table.clear(self._incoming)
	table.clear(self._outgoing)
	self._handshake = nil
	self._handshaken = false

	for _, staged in self._tables do
		if IS_SERVER then
			staged._onWrite = nil
			if staged._subscribers then
				table.clear(staged._subscribers)
			end
		else
			staged._onRelease = nil
			staged._released = true
		end
	end
	table.clear(self._tables)

	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)

	if self._ownsTransformer then
		self._transformer:Destroy()
	end

	local dropped = self._onDropped
	if dropped then
		self._onDropped = nil
		dropped(self)
	end
end

local function installProtocol(self: types.InternalCarrier)
	if self._dropped then
		return
	end

	if IS_SERVER then
		Carrier.When(self, EV_PING, function()
			return "pong"
		end)

		Carrier.When(self, EV_HANDSHAKE, function(player: Player, ...: any)
			if not self._handshake then
				return true
			end

			local ok, granted = pcall(self._handshake, player, ...)
			if not ok then
				warn(string.format(ERRORS.CALLBACK_ERROR, "handshake", EV_HANDSHAKE, tostring(granted)))
				granted = false
			end

			if granted == true then
				self._authed[player] = true
				return true
			end

			if self._authed[player] == true then
				evict(self, player)
			else
				self._authed[player] = nil
			end
			return false
		end)

		Carrier.When(self, EV_TABLE_REQUEST, function(player: Player, id: string)
			local staged = self._tables[id]
			if not staged then
				warn(string.format(ERRORS.NO_TABLE, id))
				return false, nil
			end
			if not staged:CanCapture(player) then
				return false, nil
			end

			local subscribers = staged._subscribers or {}
			staged._subscribers = subscribers
			subscribers[player] = true
			return true, staged:Snapshot()
		end)

		Carrier.On(self, EV_TABLE_RELEASE, function(player: Player, id: string)
			local staged = self._tables[id]
			if not staged or not staged._subscribers then
				return
			end
			if not staged:CanRelease(player) then
				return
			end
			staged._subscribers[player] = nil
		end)

		local leaving = Players.PlayerRemoving:Connect(function(player: Player)
			self._authed[player] = nil
			for _, room in self._rooms do
				local index = table.find(room, player)
				if index then
					table.remove(room, index)
				end
			end
			for _, staged in self._tables do
				if staged._subscribers then
					staged._subscribers[player] = nil
				end
			end
		end)
		table.insert(self._connections, leaving)
	else
		Carrier.On(self, EV_TABLE_PATCH, function(id: string, patches: { any })
			local staged = self._tables[id]
			if staged then
				staged:ApplyPatches(patches)
			end
		end)

		Carrier.On(self, EV_TABLE_SNAPSHOT, function(id: string, snapshot: any)
			adoptTable(self, id, snapshot)
		end)

		Carrier.On(self, EV_TABLE_REVOKE, function(ids: { string })
			if type(ids) ~= "table" then
				return
			end
			for _, id in ids do
				local staged = self._tables[id]
				if staged then
					self._tables[id] = nil
					staged._onRelease = nil
					staged._released = true
				end
			end
		end)
	end
end

return function(name: string, options: types.CarrierOptions?): types.PigeonCarrier
	if type(name) ~= "string" or name == "" then
		error(ERRORS.NO_NAME, 2)
	end

	local opts: types.CarrierOptions = options or {}

	local supplied = opts.Transformer
	local transformer: types.Transformer
	if supplied == nil then
		transformer = NewTransformer(name)
	elseif typeof(supplied) ~= "table" or type((supplied :: any).uuid) ~= "string" then
		error(ERRORS.NO_TRANSFORMER, 2)
	else
		transformer = supplied
	end

	local self: types.InternalCarrier = setmetatable({
		Unreliable = opts.Unreliable == true,
		Timeout = opts.Timeout,

		_transformer = transformer,
		_name = name,
		_ownsTransformer = opts.Transformer == nil,
		_listeners = {},
		_responder = {},
		_bound = {},
		_held = {},
		_incoming = {},
		_outgoing = {},
		_rooms = {},
		_tables = {},
		_connections = {},
		_dropped = false,
		_inited = false,
		_handshake = nil,
		_handshaken = false,
		_authed = {},
	}, Carrier) :: any

	transformer:Track(function()
		Carrier.Destroy(self)
	end)

	if not self._dropped then
		local disconnect = Network.ReceiveChannel(name, function(wired: string, ...: any)
			route(self, unwire(self, wired), ...)
		end)
		local untrack = transformer:Track(disconnect)
		self._unwatch = function()
			disconnect()
			untrack()
		end
	end

	installProtocol(self)

	return self
end
