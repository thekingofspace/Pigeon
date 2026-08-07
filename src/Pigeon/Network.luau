--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Types = require("./Types")
local Wire = require("./Wire")
local module = {}

local IS_SERVER = RunService:IsServer()

local LOAD_PER_REF = 16
local MAX_REFS = 32

local REF_FOLDER_NAME = "PigeonRefs"
local REF_PREFIX = "PigeonRef_"
local REF_PREFIX_UNRELIABLE = "PigeonRefU_"

local REF_COUNT_ATTRIBUTE = "RefCount"

local DEFAULT_TIMEOUT = 10

local ORPHAN_TTL = 10
local ORPHAN_MAX = 64

local BUFFER_TTL = 30
local BUFFER_MAX = 64

local OUTBOX_TTL = 30
local OUTBOX_MAX = 64

local nextPromise = 0

local function newPromise(): number
	nextPromise = (nextPromise % 4294967294) + 1
	return nextPromise
end

local function payloadOf(data: any): ({ any }?, number)
	if type(data) ~= "table" then
		return nil, 0
	end
	return data.args, data.n or 0
end

module.KnownTransformers = 0

local refs: { [number]: RemoteEvent } = {}
local unreliableRefs: { [number]: UnreliableRemoteEvent } = {}

local listeners: { [string]: { (...any) -> () } } = {}

type Orphan = { at: number, args: { n: number, [number]: any } }

local orphaned: { [string]: { Orphan } } = {}

type Pending = {
	expires: number,
	resolved: boolean,
	onResolve: (...any) -> (),
}

local pending: { [number]: Pending } = {}

type Buffered = { at: number, bucket: number, args: { n: number, [number]: any } }

local ready: { [string]: { [Player]: boolean } } = {}
local buffered: { [string]: { [Player]: { Buffered } } } = {}

local watchers: { [string]: { (event: string, ...any) -> () } } = {}

type Outbound = {
	at: number,
	uuid: string?,
	bucket: number?,
	auth: string?,
	unreliable: boolean,
	promiseId: number?,
	args: { n: number, [number]: any },
}

local outbox: { Outbound } = {}

local flushOutbox: () -> ()

local function channelOf(event: string): string
	local cut = string.find(event, "\0", 1, true)
	return if cut then string.sub(event, 1, cut - 1) else event
end

local departed: { [Player]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function reachable(player: Player?): boolean
	if typeof(player) ~= "Instance" then
		return false
	end
	local target = player :: Player
	if departed[target] then
		return false
	end
	return target.Parent ~= nil
end

local function hashString(s: string): number
	local hash = 2166136261
	for i = 1, #s do
		hash = bit32.bxor(hash, string.byte(s, i))
		hash = (hash * 16777619) % 4294967296
	end
	return hash
end

local function holdOrphan(event: string, ...: any)
	local queue = orphaned[event]
	if not queue then
		queue = {}
		orphaned[event] = queue
	end
	if #queue >= ORPHAN_MAX then
		table.remove(queue, 1)
	end
	table.insert(queue, { at = os.clock(), args = table.pack(...) })
end

local function dispatch(event: string, ...: any)
	local list = listeners[event]
	if list and #list > 0 then
		for _, callback in table.clone(list) do
			task.spawn(callback, ...)
		end
		return
	end

	local watching = watchers[channelOf(event)]
	if watching and #watching > 0 then
		for _, callback in table.clone(watching) do
			task.spawn(callback, event, ...)
		end
		return
	end

	holdOrphan(event, ...)
end

local function resolvePending(id: number, ...: any)
	local waiter = pending[id]
	if waiter and not waiter.resolved then
		waiter.resolved = true
		pending[id] = nil
		waiter.onResolve(...)
	end
end

local function getRefFolder(): Folder
	if IS_SERVER then
		local folder = ReplicatedStorage:FindFirstChild(REF_FOLDER_NAME)
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = REF_FOLDER_NAME
			folder.Parent = ReplicatedStorage
		end
		return folder :: Folder
	end
	return ReplicatedStorage:WaitForChild(REF_FOLDER_NAME) :: Folder
end

local function onClientPacket(bucket: number, meta: buffer, values: { any }?)
	local kind, event, promiseId, args, count = Wire.unpack(meta, values)
	local payload = { args = args, n = count }

	if kind == Wire.RESPOND then
		resolvePending(promiseId :: number, true, payload)
	elseif kind == Wire.PUSH then
		dispatch(event, bucket, payload)
	elseif kind == Wire.CALL then
		dispatch(event, bucket, payload, promiseId)
	end
end

local function flushBuffer(channel: string, player: Player)
	if not reachable(player) then
		return
	end

	local seats = ready[channel]
	if not seats then
		seats = {}
		ready[channel] = seats
	end
	seats[player] = true

	local queues = buffered[channel]
	local queue = queues and queues[player]
	if not queue then
		return
	end
	queues[player] = nil
	if next(queues) == nil then
		buffered[channel] = nil
	end

	for _, packet in queue do
		local ref = refs[packet.bucket]
		if ref then
			pcall(ref.FireClient, ref, player, table.unpack(packet.args, 1, packet.args.n))
		end
	end
end

local function onServerPacket(bucket: number, player: Player, meta: buffer, values: { any }?)
	local kind, event, promiseId, args, count = Wire.unpack(meta, values)

	if kind == Wire.AUTH then
		if event ~= "" then
			flushBuffer(event, player)
		end
		return
	end

	local payload = { args = args, n = count }

	if kind == Wire.RESPOND then
		resolvePending(promiseId :: number, true, payload)
	elseif kind == Wire.PUSH then
		dispatch(event, player, bucket, payload)
	elseif kind == Wire.CALL then
		dispatch(event, player, bucket, payload, promiseId)
	end
end

local function bindClientUnreliable(bucket: number, twin: UnreliableRemoteEvent): UnreliableRemoteEvent
	local cached = unreliableRefs[bucket]
	if cached then
		return cached
	end
	unreliableRefs[bucket] = twin
	twin.OnClientEvent:Connect(function(...)
		onClientPacket(bucket, ...)
	end)
	return twin
end

local function bindClientRef(bucket: number, remote: RemoteEvent)
	if refs[bucket] then
		return
	end
	refs[bucket] = remote
	remote.OnClientEvent:Connect(function(...)
		onClientPacket(bucket, ...)
	end)

	local folder = remote.Parent
	local twin = folder and folder:FindFirstChild(REF_PREFIX_UNRELIABLE .. bucket)
	if twin and twin:IsA("UnreliableRemoteEvent") then
		bindClientUnreliable(bucket, twin)
	end

	flushOutbox()
end

local function createRef(bucket: number): RemoteEvent
	local cached = refs[bucket]
	if cached then
		return cached
	end

	local folder = getRefFolder()

	local name = REF_PREFIX .. bucket
	local found = folder:FindFirstChild(name)
	local remote: RemoteEvent
	if found then
		remote = found :: RemoteEvent
	else
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = folder
	end
	refs[bucket] = remote
	remote.OnServerEvent:Connect(function(player: Player, ...: any)
		onServerPacket(bucket, player, ...)
	end)

	local uname = REF_PREFIX_UNRELIABLE .. bucket
	local ufound = folder:FindFirstChild(uname)
	local uremote: UnreliableRemoteEvent
	if ufound then
		uremote = ufound :: UnreliableRemoteEvent
	else
		uremote = Instance.new("UnreliableRemoteEvent")
		uremote.Name = uname
		uremote.Parent = folder
	end
	unreliableRefs[bucket] = uremote
	uremote.OnServerEvent:Connect(function(player: Player, ...: any)
		onServerPacket(bucket, player, ...)
	end)

	return remote
end

local function findRef(bucket: number): RemoteEvent?
	local cached = refs[bucket]
	if cached then
		return cached
	end
	if IS_SERVER then
		return createRef(bucket)
	end

	local folder = ReplicatedStorage:FindFirstChild(REF_FOLDER_NAME)
	local event = folder and folder:FindFirstChild(REF_PREFIX .. bucket)
	if event then
		bindClientRef(bucket, event :: RemoteEvent)
		return refs[bucket]
	end
	return nil
end

local function awaitRef(bucket: number): RemoteEvent
	local existing = findRef(bucket)
	if existing then
		return existing
	end

	local remote = getRefFolder():WaitForChild(REF_PREFIX .. bucket) :: RemoteEvent
	bindClientRef(bucket, remote)
	return refs[bucket]
end

function module.GetRefCount(): number
	if IS_SERVER then
		local desired = math.ceil(module.KnownTransformers / LOAD_PER_REF)
		return math.clamp(desired, 1, MAX_REFS)
	end

	local folder = ReplicatedStorage:FindFirstChild(REF_FOLDER_NAME)
	local published = folder and folder:GetAttribute(REF_COUNT_ATTRIBUTE)
	if typeof(published) == "number" then
		return published
	end
	return 1
end

local function bucketOf(uuid: string): number
	return (hashString(uuid) % module.GetRefCount()) + 1
end

local function syncPool()
	local count = module.GetRefCount()
	for bucket = 1, count do
		createRef(bucket)
	end
	getRefFolder():SetAttribute(REF_COUNT_ATTRIBUTE, count)
end

local function resolveRef(uuid: string): RemoteEvent
	return awaitRef(bucketOf(uuid))
end

local function resolveUnreliable(bucket: number): UnreliableRemoteEvent?
	local cached = unreliableRefs[bucket]
	if cached then
		return cached
	end
	if IS_SERVER then
		createRef(bucket)
		return unreliableRefs[bucket]
	end

	local folder = ReplicatedStorage:FindFirstChild(REF_FOLDER_NAME)
	local event = folder and folder:FindFirstChild(REF_PREFIX_UNRELIABLE .. bucket)
	if event and event:IsA("UnreliableRemoteEvent") then
		return bindClientUnreliable(bucket, event)
	end
	return nil
end

local function deliver(packet: Outbound): boolean
	local bucket = packet.bucket or bucketOf(packet.uuid :: string)

	if packet.unreliable then
		local uref = resolveUnreliable(bucket)
		if uref then
			uref:FireServer(table.unpack(packet.args, 1, packet.args.n))
			return true
		end
	end

	local ref = findRef(bucket)
	if not ref then
		return false
	end
	ref:FireServer(table.unpack(packet.args, 1, packet.args.n))
	return true
end

local function hold(packet: Outbound)
	if packet.auth then
		for _, held in outbox do
			if held.auth == packet.auth and held.uuid == packet.uuid then
				return
			end
		end
		table.insert(outbox, packet)
		return
	end

	local count, oldest = 0, nil :: number?
	for index, held in outbox do
		if not held.auth then
			count += 1
			if not oldest then
				oldest = index
			end
		end
	end
	if count >= OUTBOX_MAX and oldest then
		table.remove(outbox, oldest)
	end

	table.insert(outbox, packet)
end

local function sendOrHold(packet: Outbound)
	if not deliver(packet) then
		hold(packet)
	end
end

local flushing = false

flushOutbox = function()
	if flushing or #outbox == 0 then
		return
	end
	flushing = true

	local held = outbox
	outbox = {}

	local ordered = (table.create(#held) :: any) :: { Outbound }
	for _, packet in held do
		if packet.auth then
			table.insert(ordered, packet)
		end
	end
	for _, packet in held do
		if not packet.auth then
			table.insert(ordered, packet)
		end
	end

	for _, packet in ordered do

		if packet.promiseId and not pending[packet.promiseId] then
			continue
		end

		local ok, sent = pcall(deliver, packet)
		if not ok then
			warn(`[Pigeon] A held packet could not be replayed: {sent}`)
		elseif not sent then
			hold(packet)
		end
	end

	flushing = false
end

local function fireOrBuffer(channel: string, bucket: number, player: Player, unreliable: boolean, ...: any)
	if not reachable(player) then
		return
	end

	local seats = ready[channel]
	local isReady = seats and seats[player]

	if unreliable then
		if isReady then
			local uref = resolveUnreliable(bucket)
			if uref then
				pcall(uref.FireClient, uref, player, ...)
			end
		end
		return
	end

	if isReady then
		local ref = refs[bucket]
		if ref then
			pcall(ref.FireClient, ref, player, ...)
			return
		end
	end

	local queues = buffered[channel]
	if not queues then
		queues = {}
		buffered[channel] = queues
	end
	local queue = queues[player]
	if not queue then
		queue = {}
		queues[player] = queue
	end
	if #queue >= BUFFER_MAX then
		table.remove(queue, 1)
	end
	table.insert(queue, { at = os.clock(), bucket = bucket, args = table.pack(...) })
end

function module.Register(Transformer: Types.Transformer)
	module.KnownTransformers += 1
	if IS_SERVER then
		syncPool()
		resolveRef(Transformer.uuid)
	end
end

function module.Unregister(_Transformer: Types.Transformer)
	module.KnownTransformers = math.max(0, module.KnownTransformers - 1)
	if IS_SERVER then
		syncPool()
	end
end

function module.GetRef(Transformer: Types.Transformer): RemoteEvent
	return resolveRef(Transformer.uuid)
end

function module.Receive(event: string, callback: (...any) -> ()): () -> ()
	local list = listeners[event]
	if not list then
		list = {}
		listeners[event] = list
	end
	table.insert(list, callback)

	local held = orphaned[event]
	if held then
		orphaned[event] = nil
		for _, packet in held do
			task.spawn(callback, table.unpack(packet.args, 1, packet.args.n))
		end
	end

	return function()
		local index = table.find(list, callback)
		if index then
			table.remove(list, index)
		end

		if #list == 0 and listeners[event] == list then
			listeners[event] = nil
		end
	end
end

function module.ReceiveChannel(channel: string, callback: (event: string, ...any) -> ()): () -> ()
	local list = watchers[channel]
	if not list then
		list = {}
		watchers[channel] = list
	end
	table.insert(list, callback)

	for event, queue in orphaned do
		if channelOf(event) == channel then
			orphaned[event] = nil
			for _, packet in queue do
				task.spawn(callback, event, table.unpack(packet.args, 1, packet.args.n))
			end
		end
	end

	return function()
		local index = table.find(list, callback)
		if index then
			table.remove(list, index)
		end

		if #list == 0 and watchers[channel] == list then
			watchers[channel] = nil
		end
	end
end

function module.Diagnostics()
	local out = {
		listeners = 0,
		watchers = 0,
		orphaned = 0,
		pending = 0,
		readySeats = 0,
		bufferedPackets = 0,
		readyChannels = 0,
		bufferedChannels = 0,
		outbound = #outbox,
	}

	for _ in listeners do
		out.listeners += 1
	end
	for _, list in watchers do
		out.watchers += #list
	end
	for _, queue in orphaned do
		out.orphaned += #queue
	end
	for _ in pending do
		out.pending += 1
	end
	for _, seats in ready do
		out.readyChannels += 1
		for _ in seats do
			out.readySeats += 1
		end
	end
	for _, queues in buffered do
		out.bufferedChannels += 1
		for _, queue in queues do
			out.bufferedPackets += #queue
		end
	end

	return out
end

function module.Ready(Transformer: Types.Transformer, channel: string)
	sendOrHold({
		at = os.clock(),
		uuid = Transformer.uuid,
		auth = channel,
		unreliable = false,
		args = table.pack(Wire.pack(Wire.AUTH, channel, nil, nil, 0)),
	})
end

function module.Push(Transformer: Types.Transformer, event: string, data: any, unreliable: boolean?)
	sendOrHold({
		at = os.clock(),
		uuid = Transformer.uuid,
		unreliable = unreliable == true,
		args = table.pack(Wire.pack(Wire.PUSH, event, nil, payloadOf(data))),
	})
end

function module.Broadcast(
	players: { Player },
	Transformer: Types.Transformer,
	event: string,
	data: any,
	unreliable: boolean?
)
	local bucket = bucketOf(Transformer.uuid)
	local channel = channelOf(event)
	createRef(bucket)
	for _, player in players do
		fireOrBuffer(channel, bucket, player, unreliable == true, Wire.pack(Wire.PUSH, event, nil, payloadOf(data)))
	end
end

function module.Call(Transformer: Types.Transformer, event: string, data: any, timeout: number?): (boolean, any)
	local promiseId = newPromise()
	local thread = coroutine.running()

	local settled, settledOk, settledResult = false, false, nil :: any

	pending[promiseId] = {
		expires = os.clock() + (timeout or DEFAULT_TIMEOUT),
		resolved = false,
		onResolve = function(ok: boolean, result: any)
			if coroutine.status(thread) == "suspended" then
				task.spawn(thread, ok, result)
			else
				settled, settledOk, settledResult = true, ok, result
			end
		end,
	}

	sendOrHold({
		at = os.clock(),
		uuid = Transformer.uuid,
		unreliable = false,
		promiseId = promiseId,
		args = table.pack(Wire.pack(Wire.CALL, event, promiseId, payloadOf(data))),
	})

	if settled then
		return settledOk, settledResult
	end
	return coroutine.yield()
end

function module.Respond(bucket: number, promiseId: number, data: any, player: Player?)
	local meta, values = Wire.pack(Wire.RESPOND, "", promiseId, payloadOf(data))

	if IS_SERVER then
		local target = player :: Player
		if not reachable(target) then
			return
		end

		local ref = createRef(bucket)
		pcall(ref.FireClient, ref, target, meta, values)
	else
		sendOrHold({
			at = os.clock(),
			bucket = bucket,
			unreliable = false,
			args = table.pack(meta, values),
		})
	end
end

function module.BroadcastCall(
	players: { Player },
	Transformer: Types.Transformer,
	event: string,
	data: any,
	timeout: number?
): (boolean, any)
	local responses: { [Player]: any } = {}
	if #players == 0 then
		return true, responses
	end

	local thread = coroutine.running()
	local bucket = bucketOf(Transformer.uuid)
	local channel = channelOf(event)
	createRef(bucket)

	local deadline = os.clock() + (timeout or DEFAULT_TIMEOUT)
	local remaining = #players
	local ids: { [Player]: number } = {}
	local finished = false
	local leaveConn: RBXScriptConnection

	local settled, settledOk, settledResult = false, false, nil :: any

	local function finish(ok: boolean, result: any)
		if finished then
			return
		end
		finished = true
		if leaveConn then
			leaveConn:Disconnect()
		end
		for _, id in ids do
			pending[id] = nil
		end

		if coroutine.status(thread) == "suspended" then
			task.spawn(thread, ok, result)
		else
			settled, settledOk, settledResult = true, ok, result
		end
	end

	for _, player in players do
		local promiseId = newPromise()
		ids[player] = promiseId
		pending[promiseId] = {
			expires = deadline,
			resolved = false,
			onResolve = function(_ok: boolean, result: any)
				responses[player] = result
				remaining -= 1
				if remaining <= 0 then
					finish(true, responses)
				end
			end,
		}
		fireOrBuffer(channel, bucket, player, false, Wire.pack(Wire.CALL, event, promiseId, payloadOf(data)))
	end

	leaveConn = Players.PlayerRemoving:Connect(function(leaving: Player)
		if ids[leaving] then
			finish(false, "player_left")
		end
	end)

	if settled then
		return settledOk, settledResult
	end
	return coroutine.yield()
end

if IS_SERVER then

	Players.PlayerRemoving:Connect(function(player: Player)
		departed[player] = true

		for channel, seats in ready do
			seats[player] = nil
			if next(seats) == nil then
				ready[channel] = nil
			end
		end
		for channel, queues in buffered do
			queues[player] = nil
			if next(queues) == nil then
				buffered[channel] = nil
			end
		end
	end)
else

	task.spawn(function()
		local folder = getRefFolder()
		local function consider(child: Instance)
			local bucket = tonumber((child.Name:match("^" .. REF_PREFIX .. "(%d+)$")))
			if bucket and child:IsA("RemoteEvent") then
				bindClientRef(bucket, child)
				return
			end
			local ubucket = tonumber((child.Name:match("^" .. REF_PREFIX_UNRELIABLE .. "(%d+)$")))
			if ubucket and child:IsA("UnreliableRemoteEvent") then
				resolveUnreliable(ubucket)
				flushOutbox()
			end
		end

		for _, child in folder:GetChildren() do
			consider(child)
		end
		folder.ChildAdded:Connect(consider)

		folder:GetAttributeChangedSignal(REF_COUNT_ATTRIBUTE):Connect(flushOutbox)

		flushOutbox()
	end)
end

RunService.Heartbeat:Connect(function()
	local now = os.clock()
	for id, waiter in pending do
		if not waiter.resolved and now >= waiter.expires then
			waiter.resolved = true
			pending[id] = nil
			waiter.onResolve(false, "timeout")
		end
	end

	for event, queue in orphaned do
		for index = #queue, 1, -1 do
			if now - queue[index].at >= ORPHAN_TTL then
				table.remove(queue, index)
			end
		end
		if #queue == 0 then
			orphaned[event] = nil
		end
	end

	for channel, queues in buffered do
		for player, queue in queues do
			for index = #queue, 1, -1 do
				if now - queue[index].at >= BUFFER_TTL then
					table.remove(queue, index)
				end
			end
			if #queue == 0 then
				queues[player] = nil
			end
		end
		if next(queues) == nil then
			buffered[channel] = nil
		end
	end

	for index = #outbox, 1, -1 do
		local packet = outbox[index]
		if not packet.auth and now - packet.at >= OUTBOX_TTL then
			table.remove(outbox, index)
		end
	end
end)

return module
