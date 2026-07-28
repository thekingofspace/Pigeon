local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pigeon = require(ReplicatedStorage:WaitForChild("Pigeon"))
local Network = require(ReplicatedStorage.Pigeon.Network)

return function(TestKit: any, Fixtures: any): { any }
	local suites = {}
	local counter = 0

	local function unique(label: string): string
		counter += 1
		return string.format("PigeonClient_%s_%d", label, counter)
	end

	local guards = TestKit.suite("Client / environment guards")
	table.insert(suites, guards)

	guards:test("server-only methods refuse to run on the client", function(t)
		local carrier = Pigeon.new(unique("ServerOnly"), {})

		t.throws(function()
			carrier:Broadcast("evt")
		end, "ERR_NOT_SERVER")
		t.throws(function()
			carrier:BroadcastTo({}, "evt")
		end, "ERR_NOT_SERVER")
		t.throws(function()
			carrier:BroadcastExcept({}, "evt")
		end, "ERR_NOT_SERVER")
		t.throws(function()
			carrier:CallTo(nil :: any, "evt")
		end, "ERR_NOT_SERVER")
		t.throws(function()
			carrier:SendToRoom("room", "evt")
		end, "ERR_NOT_SERVER")
		t.throws(function()
			carrier:CreateRoom("room", {})
		end, "ERR_NOT_SERVER")
		t.throws(function()
			carrier:DestroyRoom("room")
		end, "ERR_NOT_SERVER")
		t.throws(function()
			carrier:JoinRoom("room", {})
		end, "ERR_NOT_SERVER")
		t.throws(function()
			carrier:LeaveRoom("room", {})
		end, "ERR_NOT_SERVER")
		t.throws(function()
			carrier:UseHandshake(function()
				return true
			end)
		end, "ERR_NOT_SERVER")
		t.throws(function()
			carrier:Revoke(Players.LocalPlayer)
		end, "ERR_NOT_SERVER")
		t.throws(function()
			carrier:CaptureTable("id", Pigeon.StagedTable())
		end, "ERR_NOT_SERVER")
		t.throws(function()
			carrier:ReleaseTable("id")
		end, "ERR_NOT_SERVER")
		t.throws(function()
			carrier:ForceTable("id", Pigeon.StagedTable())
		end, "ERR_NOT_SERVER")

		carrier:Destroy()
	end)

	guards:test("client-only methods are available here", function(t)
		local carrier = Pigeon.new(unique("ClientOnly"), {})
		carrier:Destroy()

		t.noThrow(function()
			carrier:Emit("evt")
			carrier:Call("evt")
			carrier:Handshake("token")
			carrier:Init()
		end)
	end)

	local init = TestKit.suite("Client / Init")
	table.insert(suites, init)

	init:test("Init returns the carrier for chaining", function(t)
		local carrier = Pigeon.new(unique("InitChain"), {})
		t.eq(carrier:Init(), carrier)
		carrier:Destroy()
	end)

	init:test("Init marks the carrier initialised exactly once", function(t)
		local carrier = Pigeon.new(unique("InitOnce"), {})

		t.eq((carrier :: any)._inited, false)
		carrier:Init()
		t.eq((carrier :: any)._inited, true)

		t.noThrow(function()
			carrier:Init()
			carrier:Init()
		end, "Init is safe to call repeatedly")

		carrier:Destroy()
	end)

	init:test("Init on a dropped carrier does nothing", function(t)
		local carrier = Pigeon.new(unique("InitDropped"), {})
		carrier:Destroy()

		carrier:Init()
		t.eq((carrier :: any)._inited, false, "a dead carrier must not ready a channel")
	end)

	init:test("Init does not block the caller", function(t)
		local carrier = Pigeon.new(unique("InitFast"), {})

		local started = os.clock()
		carrier:Init()
		t.lt(os.clock() - started, 0.2, "resolving the ref can yield, so it is spawned")

		carrier:Destroy()
	end)

	init:test("sending never required Init", function(t)

		t.eq(Fixtures.ask("ping"), "pong")
	end)

	local dropped = TestKit.suite("Client / a dropped carrier")
	table.insert(suites, dropped)

	dropped:test("Emit goes quiet instead of throwing", function(t)
		local carrier = Pigeon.new(unique("EmitDropped"), {})
		carrier:Destroy()

		t.noThrow(function()
			carrier:Emit("evt", 1, 2, 3)
		end, "teardown races with in-flight work")
	end)

	dropped:test("Call returns nil without waiting", function(t)
		local carrier = Pigeon.new(unique("CallDropped"), {})
		carrier:Destroy()

		local started = os.clock()
		t.eq(carrier:Call("evt"), nil)
		t.lt(os.clock() - started, 0.2, "it must not sit out a timeout")
	end)

	dropped:test("Handshake returns false without a round trip", function(t)
		local carrier = Pigeon.new(unique("HandshakeDropped"), {})
		carrier:Destroy()

		local started = os.clock()
		t.eq(carrier:Handshake("token"), false)
		t.lt(os.clock() - started, 0.2)
	end)

	dropped:test("a carrier on a destroyed transformer is dropped with it", function(t)
		local transformer = Pigeon.Transformer()
		local carrier = Pigeon.new(unique("TransformerDropped"), { Transformer = transformer })
		carrier:Init()

		transformer:Destroy()

		t.eq((carrier :: any)._dropped, true)
		t.eq(carrier:Call("evt"), nil)
	end)

	local refs = TestKit.suite("Client / ref discovery")
	table.insert(suites, refs)

	refs:test("the ref folder replicated from the server", function(t)
		local folder = ReplicatedStorage:FindFirstChild("PigeonRefs")
		t.ne(folder, nil, "the client waits for the pool rather than creating it")
	end)

	refs:test("the pool size comes from the server's published count", function(t)
		local folder = ReplicatedStorage:FindFirstChild("PigeonRefs")
		local published = folder:GetAttribute("RefCount")

		t.isType(published, "number")
		t.eq(Network.GetRefCount(), published, "both sides must bucket uuids identically")
	end)

	refs:test("the client's own transformer count does not size its pool", function(t)
		local published = ReplicatedStorage.PigeonRefs:GetAttribute("RefCount")
		local made = {}

		for index = 1, 20 do
			made[index] = Pigeon.Transformer()
		end

		t.eq(
			Network.GetRefCount(),
			published,
			"twenty local transformers must not change how this client buckets"
		)

		for _, transformer in made do
			transformer:Destroy()
		end
	end)

	refs:test("creating a transformer on the client creates no ref", function(t)
		local folder = ReplicatedStorage:FindFirstChild("PigeonRefs")
		local before = #folder:GetChildren()

		local transformer = Pigeon.Transformer(unique("NoRefPlease"))
		t.eq(#folder:GetChildren(), before, "clients never create refs")

		transformer:Destroy()
	end)

	refs:test("every published bucket has replicated", function(t)
		local folder = ReplicatedStorage:FindFirstChild("PigeonRefs")

		for bucket = 1, Network.GetRefCount() do
			t.ne(folder:FindFirstChild("PigeonRef_" .. bucket), nil, "bucket " .. bucket .. " is missing")
		end
	end)

	refs:test("GetRef resolves without stalling once the pool has replicated", function(t)
		local transformer = Pigeon.Transformer(unique("ResolveNow"))

		local started = os.clock()
		local ref = Pigeon.GetRef(transformer)

		t.ok(ref:IsA("RemoteEvent"))
		t.lt(os.clock() - started, 1, "the ref is already bound, so nothing should yield")

		transformer:Destroy()
	end)

	local outbox = TestKit.suite("Client / the send outbox")
	table.insert(suites, outbox)

	outbox:test("nothing is held once the pool has replicated", function(t)
		t.eq(Network.Diagnostics().outbound, 0, "a bound ref leaves nothing to hold")
	end)

	outbox:test("Emit does not block the caller", function(t)
		local carrier = Pigeon.new(unique("EmitFast"), {})

		local started = os.clock()
		carrier:Emit("evt", 1, 2, 3)
		t.lt(os.clock() - started, 0.2, "fire-and-forget must never wait on the transport")

		carrier:Destroy()
	end)

	outbox:test("a carrier built and used in one breath holds nothing back", function(t)
		local carrier = Pigeon.new(unique("Immediate"), {})

		local started = os.clock()
		carrier:Init()
		carrier:Emit("evt", "first")
		carrier:Emit("evt", "second")

		t.lt(os.clock() - started, 0.2, "neither Init nor Emit resolves a ref on the caller's thread")
		t.eq(Network.Diagnostics().outbound, 0, "the refs are already bound, so nothing queued")

		carrier:Destroy()
	end)

	outbox:test("a transformer the server has never seen still sends without stalling", function(t)

		local transformer = Pigeon.Transformer(unique("UnknownToServer"))
		local carrier = Pigeon.new(unique("Unknown"), { Transformer = transformer })

		local started = os.clock()
		carrier:Init()
		carrier:Emit("evt")
		t.lt(os.clock() - started, 0.2)

		carrier:Destroy()
		transformer:Destroy()
	end)

	local transport = TestKit.suite("Client / transport bookkeeping")
	table.insert(suites, transport)

	transport:test("nothing is left pending between suites", function(t)
		t.eventually(function()
			return Network.Diagnostics().pending == 0
		end, 3, "every call should have settled")
	end)

	transport:test("the client holds no ready seats or buffers of its own", function(t)
		local diagnostics = Network.Diagnostics()

		t.eq(diagnostics.readySeats, 0, "readiness is server-side bookkeeping")
		t.eq(diagnostics.bufferedPackets, 0, "so is buffering")
	end)

	transport:test("the fixture carriers are bound", function(t)
		t.ok(Network.Diagnostics().listeners > 0)
	end)

	transport:test("orphans expire rather than accumulating", function(t)
		local before = Network.Diagnostics().orphaned
		t.ok(before >= 0)
		t.lt(before, 64 * 4, "an event nobody subscribes to cannot grow without bound")
	end)

	return suites
end
