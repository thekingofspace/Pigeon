local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pigeon = require(ReplicatedStorage:WaitForChild("Pigeon"))
local Network = require(ReplicatedStorage.Pigeon.Network)

local function fakePlayer(name: string): any
	local stand = Instance.new("Folder")
	stand.Name = name
	return stand :: any
end

return function(TestKit: any, Fixtures: any): { any }
	local suites = {}
	local counter = 0

	local function unique(label: string): string
		counter += 1
		return string.format("PigeonServer_%s_%d", label, counter)
	end

	local guards = TestKit.suite("Server / environment guards")
	table.insert(suites, guards)

	guards:test("client-only methods refuse to run on the server", function(t)
		local carrier = Pigeon.new(unique("ClientOnly"), {})

		t.throws(function()
			carrier:Emit("evt")
		end, "ERR_NOT_CLIENT")
		t.throws(function()
			carrier:Call("evt")
		end, "ERR_NOT_CLIENT")
		t.throws(function()
			carrier:Ping()
		end, "ERR_NOT_CLIENT")
		t.throws(function()
			carrier:Handshake("token")
		end, "ERR_NOT_CLIENT")
		t.throws(function()
			carrier:RequestTable("id")
		end, "ERR_NOT_CLIENT")

		carrier:Destroy()
	end)

	guards:test("Init is a no-op on the server so shared code can call it", function(t)
		local carrier = Pigeon.new(unique("InitNoop"), {})

		t.noThrow(function()
			t.eq(carrier:Init(), carrier, "Init returns the carrier for chaining")
			carrier:Init()
		end)
		t.eq((carrier :: any)._inited, false, "the server never marks itself inited")

		carrier:Destroy()
	end)

	guards:test("server-only methods are available here", function(t)
		local carrier = Pigeon.new(unique("ServerOnly"), {})

		t.noThrow(function()
			carrier:CreateRoom("room", {})
			carrier:JoinRoom("room", {})
			carrier:LeaveRoom("room", {})
			carrier:DestroyRoom("room")
			carrier:UseHandshake(function()
				return true
			end)
			carrier:Approved({})
		end)

		carrier:Destroy()
	end)

	local rooms = TestKit.suite("Server / rooms")
	table.insert(suites, rooms)

	local function roomOf(carrier: any, id: string): any
		return (carrier :: any)._rooms[id]
	end

	rooms:test("CreateRoom seeds the members it is given", function(t)
		local carrier = Pigeon.new(unique("RoomCreate"), {})
		local alice, bob = fakePlayer("Alice"), fakePlayer("Bob")

		carrier:CreateRoom("lobby", { alice, bob })

		t.eq(#roomOf(carrier, "lobby"), 2)
		carrier:Destroy()
	end)

	rooms:test("CreateRoom persists a room that is empty", function(t)
		local carrier = Pigeon.new(unique("RoomEmpty"), {})
		carrier:CreateRoom("empty", {})

		t.ne(roomOf(carrier, "empty"), nil, "an empty room lives until DestroyRoom")
		t.eq(#roomOf(carrier, "empty"), 0)

		carrier:Destroy()
	end)

	rooms:test("CreateRoom replaces an existing room", function(t)
		local carrier = Pigeon.new(unique("RoomReplace"), {})
		local alice, bob = fakePlayer("Alice"), fakePlayer("Bob")

		carrier:CreateRoom("lobby", { alice })
		carrier:CreateRoom("lobby", { bob })

		t.eq(#roomOf(carrier, "lobby"), 1)
		t.eq(roomOf(carrier, "lobby")[1], bob)

		carrier:Destroy()
	end)

	rooms:test("JoinRoom creates the room when it is absent", function(t)
		local carrier = Pigeon.new(unique("RoomAutoCreate"), {})
		carrier:JoinRoom("fresh", fakePlayer("Alice"))

		t.ne(roomOf(carrier, "fresh"), nil)
		t.eq(#roomOf(carrier, "fresh"), 1)

		carrier:Destroy()
	end)

	rooms:test("JoinRoom accepts one player or a list", function(t)
		local carrier = Pigeon.new(unique("RoomList"), {})
		local alice, bob, carol = fakePlayer("Alice"), fakePlayer("Bob"), fakePlayer("Carol")

		carrier:JoinRoom("lobby", alice)
		carrier:JoinRoom("lobby", { bob, carol })

		t.eq(#roomOf(carrier, "lobby"), 3)
		carrier:Destroy()
	end)

	rooms:test("JoinRoom does not add the same player twice", function(t)
		local carrier = Pigeon.new(unique("RoomDedupe"), {})
		local alice = fakePlayer("Alice")

		carrier:JoinRoom("lobby", alice)
		carrier:JoinRoom("lobby", alice)
		carrier:JoinRoom("lobby", { alice, alice })

		t.eq(#roomOf(carrier, "lobby"), 1)
		carrier:Destroy()
	end)

	rooms:test("LeaveRoom removes one player or a list", function(t)
		local carrier = Pigeon.new(unique("RoomLeave"), {})
		local alice, bob, carol = fakePlayer("Alice"), fakePlayer("Bob"), fakePlayer("Carol")

		carrier:CreateRoom("lobby", { alice, bob, carol })
		carrier:LeaveRoom("lobby", alice)
		t.eq(#roomOf(carrier, "lobby"), 2)

		carrier:LeaveRoom("lobby", { bob, carol })
		t.eq(#roomOf(carrier, "lobby"), 0)

		carrier:Destroy()
	end)

	rooms:test("LeaveRoom on an unknown room or member is a no-op", function(t)
		local carrier = Pigeon.new(unique("RoomLeaveMissing"), {})
		carrier:CreateRoom("lobby", { fakePlayer("Alice") })

		t.noThrow(function()
			carrier:LeaveRoom("nowhere", fakePlayer("Bob"))
			carrier:LeaveRoom("lobby", fakePlayer("Stranger"))
		end)
		t.eq(#roomOf(carrier, "lobby"), 1)

		carrier:Destroy()
	end)

	rooms:test("DestroyRoom drops the room", function(t)
		local carrier = Pigeon.new(unique("RoomDestroy"), {})
		carrier:CreateRoom("lobby", { fakePlayer("Alice") })

		carrier:DestroyRoom("lobby")
		t.eq(roomOf(carrier, "lobby"), nil)

		t.noThrow(function()
			carrier:DestroyRoom("lobby")
		end, "destroying twice is harmless")

		carrier:Destroy()
	end)

	rooms:test("SendToRoom on a missing room warns instead of throwing", function(t)
		local carrier = Pigeon.new(unique("RoomSendMissing"), {})
		t.noThrow(function()
			carrier:SendToRoom("nowhere", "evt", 1)
		end)
		carrier:Destroy()
	end)

	rooms:test("SendToRoom on an empty room sends nothing and does not throw", function(t)
		local carrier = Pigeon.new(unique("RoomSendEmpty"), {})
		carrier:CreateRoom("empty", {})

		t.noThrow(function()
			carrier:SendToRoom("empty", "evt", 1)
		end)

		carrier:Destroy()
	end)

	rooms:test("rooms are per carrier", function(t)
		local first = Pigeon.new(unique("RoomIsolationA"), {})
		local second = Pigeon.new(unique("RoomIsolationB"), {})

		first:CreateRoom("lobby", { fakePlayer("Alice") })

		t.eq(roomOf(second, "lobby"), nil, "one carrier's rooms are invisible to another")

		first:Destroy()
		second:Destroy()
	end)

	rooms:test("Destroy clears every room", function(t)
		local carrier = Pigeon.new(unique("RoomCleared"), {})
		carrier:CreateRoom("lobby", { fakePlayer("Alice") })

		carrier:Destroy()
		t.eq(next((carrier :: any)._rooms), nil)
	end)

	local handshake = TestKit.suite("Server / handshake admission")
	table.insert(suites, handshake)

	handshake:test("Approved returns everyone when no guard is installed", function(t)
		local carrier = Pigeon.new(unique("ApprovedOpen"), {})
		local alice, bob = fakePlayer("Alice"), fakePlayer("Bob")

		t.same(carrier:Approved({ alice, bob }), { alice, bob })
		carrier:Destroy()
	end)

	handshake:test("Approved defaults to every player in the game", function(t)
		local carrier = Pigeon.new(unique("ApprovedDefault"), {})
		t.eq(#carrier:Approved(), #Players:GetPlayers())
		carrier:Destroy()
	end)

	handshake:test("installing a guard closes the channel immediately", function(t)
		local carrier = Pigeon.new(unique("ApprovedClosed"), {})
		local alice = fakePlayer("Alice")

		carrier:UseHandshake(function()
			return true
		end)

		t.eq(#carrier:Approved({ alice }), 0, "nobody is admitted until they handshake")
		carrier:Destroy()
	end)

	handshake:test("Approved narrows to the clients the guard admitted", function(t)
		local carrier = Pigeon.new(unique("ApprovedSubset"), {})
		local alice, bob = fakePlayer("Alice"), fakePlayer("Bob")

		carrier:UseHandshake(function()
			return true
		end)
		;(carrier :: any)._authed[alice] = true

		t.same(carrier:Approved({ alice, bob }), { alice })
		carrier:Destroy()
	end)

	handshake:test("an explicit false in _authed is not an admission", function(t)
		local carrier = Pigeon.new(unique("ApprovedFalse"), {})
		local alice = fakePlayer("Alice")

		carrier:UseHandshake(function()
			return true
		end)
		;(carrier :: any)._authed[alice] = false

		t.eq(#carrier:Approved({ alice }), 0, "a refusal is stored as false, not as absence")
		carrier:Destroy()
	end)

	handshake:test("replacing the guard revokes everyone already admitted", function(t)
		local carrier = Pigeon.new(unique("ApprovedReplace"), {})
		local alice = fakePlayer("Alice")

		carrier:UseHandshake(function()
			return true
		end)
		;(carrier :: any)._authed[alice] = true
		t.eq(#carrier:Approved({ alice }), 1)

		carrier:UseHandshake(function()
			return true
		end)

		t.eq(#carrier:Approved({ alice }), 0, "clients vetted by the old rules must prove themselves again")
		carrier:Destroy()
	end)

	handshake:test("BroadcastTo returns early when nobody is approved", function(t)
		local carrier = Pigeon.new(unique("BroadcastNobody"), {})
		carrier:UseHandshake(function()
			return true
		end)

		t.noThrow(function()
			carrier:BroadcastTo({ fakePlayer("Alice") }, "evt", 1)
		end, "a guarded broadcast with no approved recipients must not reach the transport")

		carrier:Destroy()
	end)

	handshake:test("CallTo refuses a client that has not been admitted", function(t)
		local carrier = Pigeon.new(unique("CallToUnauthed"), {})
		carrier:UseHandshake(function()
			return true
		end)

		t.eq(carrier:CallTo(fakePlayer("Alice"), "evt"), nil, "an unauthed target is refused before the send")
		carrier:Destroy()
	end)

	handshake:test("Destroy clears the admission list", function(t)
		local carrier = Pigeon.new(unique("ApprovedDropped"), {})
		local alice = fakePlayer("Alice")

		carrier:UseHandshake(function()
			return true
		end)
		;(carrier :: any)._authed[alice] = true
		carrier:Destroy()

		t.eq(next((carrier :: any)._authed), nil)

		t.eq(#carrier:Approved({ alice }), 1, "with the guard gone, Approved stops filtering")
	end)

	handshake:test("Revoke turns a member out of every room on the carrier", function(t)
		local carrier = Pigeon.new(unique("RevokeRooms"), {})
		local alice, bob = fakePlayer("Alice"), fakePlayer("Bob")

		carrier:UseHandshake(function()
			return true
		end)
		;(carrier :: any)._authed[alice] = true
		;(carrier :: any)._authed[bob] = true

		carrier:CreateRoom("lobby", { alice, bob })
		carrier:CreateRoom("match", { alice })

		carrier:Revoke(alice)

		t.same(roomOf(carrier, "lobby"), { bob }, "only the revoked player leaves")
		t.eq(#roomOf(carrier, "match"), 0)

		carrier:Destroy()
	end)

	handshake:test("a guard that throws does not leave a member admitted", function(t)
		local carrier = Pigeon.new(unique("GuardThrows"), {})
		local alice = fakePlayer("Alice")

		carrier:UseHandshake(function()
			return true
		end)
		;(carrier :: any)._authed[alice] = true
		t.eq(#carrier:Approved({ alice }), 1)

		carrier:UseHandshake(function()
			error("the guard blew up")
		end)
		;(carrier :: any)._authed[alice] = true

		local listener = (carrier :: any)._listeners["__pigeon_handshake"][1]
		local answer = listener(alice)

		t.eq(answer, false, "the client is told no")
		t.eq(
			(carrier :: any)._authed[alice],
			nil,
			"and the server must agree, or it would keep sending to someone it just refused"
		)

		carrier:Destroy()
	end)

	handshake:test("losing an admission turns the member out of rooms and tables", function(t)
		local carrier = Pigeon.new(unique("RejectEvicts"), {})
		local alice = fakePlayer("Alice")
		local allow = true

		carrier:UseHandshake(function()
			return allow
		end)

		local staged = Pigeon.StagedTable({ secret = 1 })
		carrier:CaptureTable("secret", staged)

		;(carrier :: any)._authed[alice] = true
		carrier:JoinRoom("lobby", alice)
		;(staged :: any)._subscribers[alice] = true

		allow = false
		local listener = (carrier :: any)._listeners["__pigeon_handshake"][1]
		t.eq(listener(alice), false)

		t.eq((carrier :: any)._authed[alice], nil)
		t.eq(#roomOf(carrier, "lobby"), 0, "a refused member should not stay in the room")
		t.eq((staged :: any)._subscribers[alice], nil, "nor stay subscribed to the table")

		carrier:Destroy()
	end)

	handshake:test("a guarded carrier refuses to put an unapproved player in a room", function(t)
		local carrier = Pigeon.new(unique("RoomNeedsApproval"), {})
		local alice = fakePlayer("Alice")

		carrier:UseHandshake(function()
			return true
		end)

		local message = t.throws(function()
			carrier:JoinRoom("match", alice)
		end, "ERR_NOT_APPROVED")
		t.matches(message, "Alice", "the error should name the player")
		t.matches(message, "match", "and the room")

		t.throws(function()
			carrier:CreateRoom("lobby", { alice })
		end, "ERR_NOT_APPROVED")

		carrier:Destroy()
	end)

	handshake:test("an approved player may be put in a room", function(t)
		local carrier = Pigeon.new(unique("RoomApproved"), {})
		local alice = fakePlayer("Alice")

		carrier:UseHandshake(function()
			return true
		end)
		;(carrier :: any)._authed[alice] = true

		t.noThrow(function()
			carrier:JoinRoom("match", alice)
			carrier:CreateRoom("lobby", { alice })
		end)
		t.eq(#roomOf(carrier, "match"), 1)

		carrier:Destroy()
	end)

	handshake:test("a refused room call changes nothing", function(t)
		local carrier = Pigeon.new(unique("RoomAtomic"), {})
		local alice, bob = fakePlayer("Alice"), fakePlayer("Bob")

		carrier:UseHandshake(function()
			return true
		end)
		;(carrier :: any)._authed[alice] = true

		carrier:JoinRoom("match", alice)

		t.throws(function()
			carrier:JoinRoom("match", { alice, bob })
		end, "ERR_NOT_APPROVED")

		t.same(roomOf(carrier, "match"), { alice }, "one bad name must not half apply the call")

		t.throws(function()
			carrier:CreateRoom("fresh", { alice, bob })
		end, "ERR_NOT_APPROVED")
		t.eq(roomOf(carrier, "fresh"), nil, "and must not leave an empty room behind")

		carrier:Destroy()
	end)

	handshake:test("a carrier with no guard puts anyone in a room", function(t)
		local carrier = Pigeon.new(unique("RoomNoGuard"), {})
		local alice = fakePlayer("Alice")

		t.noThrow(function()
			carrier:JoinRoom("match", alice)
			carrier:CreateRoom("lobby", { alice })
		end, "the rule only applies once a channel is guarded")

		carrier:Destroy()
	end)

	handshake:test("Revoke takes an admission away", function(t)
		local carrier = Pigeon.new(unique("RevokeOne"), {})
		local alice, bob = fakePlayer("Alice"), fakePlayer("Bob")

		carrier:UseHandshake(function()
			return true
		end)
		;(carrier :: any)._authed[alice] = true
		;(carrier :: any)._authed[bob] = true

		t.eq(carrier:Revoke(alice), 1, "one admitted client was removed")
		t.eq((carrier :: any)._authed[alice], nil)
		t.same(carrier:Approved({ alice, bob }), { bob })

		carrier:Destroy()
	end)

	handshake:test("Revoke accepts a list as well as one player", function(t)
		local carrier = Pigeon.new(unique("RevokeMany"), {})
		local alice, bob = fakePlayer("Alice"), fakePlayer("Bob")

		carrier:UseHandshake(function()
			return true
		end)
		;(carrier :: any)._authed[alice] = true
		;(carrier :: any)._authed[bob] = true

		t.eq(carrier:Revoke({ alice, bob }), 2)
		t.eq(#carrier:Approved({ alice, bob }), 0)

		carrier:Destroy()
	end)

	handshake:test("Revoke counts only the clients that were admitted", function(t)
		local carrier = Pigeon.new(unique("RevokeCount"), {})
		local alice, bob = fakePlayer("Alice"), fakePlayer("Bob")

		carrier:UseHandshake(function()
			return true
		end)
		;(carrier :: any)._authed[alice] = true
		;(carrier :: any)._authed[bob] = false

		t.eq(carrier:Revoke({ alice, bob }), 1, "a refused client was never admitted")
		t.eq(carrier:Revoke(alice), 0, "and revoking twice removes nobody")

		carrier:Destroy()
	end)

	handshake:test("Revoke drops the client from every staged table on the carrier", function(t)
		local carrier = Pigeon.new(unique("RevokeTables"), {})
		local alice = fakePlayer("Alice")

		carrier:UseHandshake(function()
			return true
		end)
		;(carrier :: any)._authed[alice] = true

		local first = Pigeon.StagedTable({ a = 1 })
		local second = Pigeon.StagedTable({ b = 2 })
		carrier:CaptureTable("first", first)
		carrier:CaptureTable("second", second)
		;(first :: any)._subscribers[alice] = true
		;(second :: any)._subscribers[alice] = true

		carrier:Revoke(alice)

		t.eq((first :: any)._subscribers[alice], nil)
		t.eq((second :: any)._subscribers[alice], nil)

		carrier:Destroy()
	end)

	handshake:test("Revoke leaves other subscribers alone", function(t)
		local carrier = Pigeon.new(unique("RevokeOthers"), {})
		local alice, bob = fakePlayer("Alice"), fakePlayer("Bob")

		carrier:UseHandshake(function()
			return true
		end)

		local staged = Pigeon.StagedTable()
		carrier:CaptureTable("shared", staged)
		;(staged :: any)._subscribers[alice] = true
		;(staged :: any)._subscribers[bob] = true

		carrier:Revoke(alice)

		t.eq((staged :: any)._subscribers[alice], nil)
		t.eq((staged :: any)._subscribers[bob], true)

		carrier:Destroy()
	end)

	handshake:test("Revoke on a dropped carrier does nothing", function(t)
		local carrier = Pigeon.new(unique("RevokeDropped"), {})
		carrier:UseHandshake(function()
			return true
		end)
		carrier:Destroy()

		t.eq(carrier:Revoke(fakePlayer("Alice")), 0)
	end)

	handshake:test("Destroy forgets the guard", function(t)
		local carrier = Pigeon.new(unique("GuardCleared"), {})
		carrier:UseHandshake(function()
			return true
		end)

		carrier:Destroy()
		t.eq((carrier :: any)._handshake, nil)
		t.eq((carrier :: any)._handshaken, false)
	end)

	local staged = TestKit.suite("Server / staged table pointers")
	table.insert(suites, staged)

	staged:test("CaptureTable publishes under an id and stamps it", function(t)
		local carrier = Pigeon.new(unique("Capture"), {})
		local table_ = Pigeon.StagedTable({ a = 1 })

		carrier:CaptureTable("published", table_)

		t.eq((carrier :: any)._tables.published, table_)
		t.eq((table_ :: any)._id, "published")
		t.ne((table_ :: any)._onWrite, nil, "capture is what wires replication up")

		carrier:Destroy()
	end)

	staged:test("a captured write queues a patch rather than sending one each", function(t)
		local carrier = Pigeon.new(unique("Batching"), {})
		local table_ = Pigeon.StagedTable()
		carrier:CaptureTable("batched", table_)

		local view = table_:GetTable()
		view.a = 1
		view.b = 2
		view.c = 3

		t.eq(#(table_ :: any)._queued, 3, "a burst coalesces into one flush")
		t.eq((table_ :: any)._flushing, true, "a flush is already scheduled")

		carrier:Destroy()
	end)

	staged:test("the queue drains on the next resumption", function(t)
		local carrier = Pigeon.new(unique("Drain"), {})
		local table_ = Pigeon.StagedTable()
		carrier:CaptureTable("drained", table_)

		table_:GetTable().a = 1
		t.eventually(function()
			return #(table_ :: any)._queued == 0
		end, 2, "the deferred flush should have emptied the queue")
		t.eq((table_ :: any)._flushing, false)

		carrier:Destroy()
	end)

	staged:test("a flush with no subscribers sends nothing and clears the queue", function(t)
		local carrier = Pigeon.new(unique("NoSubscribers"), {})
		local table_ = Pigeon.StagedTable()
		carrier:CaptureTable("lonely", table_)

		t.noThrow(function()
			table_:GetTable().a = 1
		end)
		t.eventually(function()
			return #(table_ :: any)._queued == 0
		end, 2)

		carrier:Destroy()
	end)

	staged:test("ReleaseTable drops the pointer but leaves the table replicating", function(t)
		local carrier = Pigeon.new(unique("ReleasePointer"), {})
		local table_ = Pigeon.StagedTable()
		carrier:CaptureTable("pointed", table_)

		carrier:ReleaseTable("pointed")

		t.eq((carrier :: any)._tables.pointed, nil, "the carrier is only a pointer")
		t.ne((table_ :: any)._onWrite, nil, "subscribers live on the table, not the carrier")

		carrier:Destroy()
	end)

	staged:test("a staged table survives the carrier that published it", function(t)
		local first = Pigeon.new(unique("SurvivorA"), {})
		local table_ = Pigeon.StagedTable({ kept = true })
		first:CaptureTable("shared", table_)

		first:Destroy()
		t.eq((table_ :: any)._onWrite, nil, "Destroy detaches the replication hook")
		t.eq(table_:GetTable().kept, true, "but the data is untouched")

		local second = Pigeon.new(unique("SurvivorB"), {})
		second:CaptureTable("shared", table_)
		t.ne((table_ :: any)._onWrite, nil, "and it can be captured again")

		second:Destroy()
	end)

	staged:test("Destroy clears the subscriber list on the server", function(t)
		local carrier = Pigeon.new(unique("SubscribersCleared"), {})
		local table_ = Pigeon.StagedTable()
		carrier:CaptureTable("subscribed", table_)

		;(table_ :: any)._subscribers[fakePlayer("Alice")] = true
		carrier:Destroy()

		t.eq(next((table_ :: any)._subscribers), nil)
	end)

	staged:test("ForceTable captures the table first if it was never published", function(t)
		local carrier = Pigeon.new(unique("ForceCapture"), {})
		local table_ = Pigeon.StagedTable({ pushed = true })

		carrier:ForceTable("forced", table_, {})

		t.eq((carrier :: any)._tables.forced, table_)
		t.eq((table_ :: any)._id, "forced")

		carrier:Destroy()
	end)

	staged:test("ForceTable does not consult the capture guards", function(t)
		local carrier = Pigeon.new(unique("ForceIgnoresGuards"), {})
		local table_ = Pigeon.StagedTable()
		local consulted = false

		table_:UseCapture(function()
			consulted = true
			return false
		end)

		carrier:ForceTable("forced", table_, {})

		t.no(consulted, "guards vet client requests; this is the server deciding")
		carrier:Destroy()
	end)

	staged:test("ForceTable subscribes the players it targets", function(t)
		local carrier = Pigeon.new(unique("ForceSubscribes"), {})
		local table_ = Pigeon.StagedTable()
		local alice = fakePlayer("Alice")

		carrier:UseHandshake(function()
			return true
		end)
		carrier:ForceTable("forced", table_, { alice })

		t.eq((table_ :: any)._subscribers[alice], true, "the subscription is recorded before the send is filtered")
		carrier:Destroy()
	end)

	local pool = TestKit.suite("Server / ref pool")
	table.insert(suites, pool)

	pool:test("the ref folder exists under ReplicatedStorage", function(t)
		local folder = ReplicatedStorage:FindFirstChild("PigeonRefs")
		t.ne(folder, nil, "the server creates the pool eagerly")
		t.ok(folder:IsA("Folder"))
	end)

	pool:test("every bucket has a reliable ref and an unreliable twin", function(t)
		local folder = ReplicatedStorage:FindFirstChild("PigeonRefs")

		for bucket = 1, Network.GetRefCount() do
			local reliable = folder:FindFirstChild("PigeonRef_" .. bucket)
			local unreliable = folder:FindFirstChild("PigeonRefU_" .. bucket)

			t.ne(reliable, nil, "bucket " .. bucket .. " should have a reliable ref")
			t.ok(reliable:IsA("RemoteEvent"))
			t.ne(unreliable, nil, "bucket " .. bucket .. " should have an unreliable twin")
			t.ok(unreliable:IsA("UnreliableRemoteEvent"))
		end
	end)

	pool:test("the published count matches what the server computes", function(t)
		local folder = ReplicatedStorage:FindFirstChild("PigeonRefs")
		local published = folder:GetAttribute("RefCount")

		t.isType(published, "number")
		t.eq(published, Network.GetRefCount(), "clients size the pool from the authority's count")
	end)

	pool:test("the pool is one ref per sixteen transformers, clamped", function(t)

		local saved = Network.KnownTransformers
		local samples = {}

		for _, count in { 0, 1, 16, 17, 32, 512, 100000 } do
			Network.KnownTransformers = count
			samples[count] = Network.GetRefCount()
		end

		Network.KnownTransformers = saved

		t.eq(samples[0], 1, "there is always at least one ref")
		t.eq(samples[1], 1)
		t.eq(samples[16], 1, "sixteen transformers still fit one ref")
		t.eq(samples[17], 2, "the seventeenth opens a second bucket")
		t.eq(samples[32], 2)
		t.eq(samples[512], 32, "and never more than MAX_REFS")
		t.eq(samples[100000], 32)
		t.eq(Network.KnownTransformers, saved, "the real count is restored")
	end)

	pool:test("a transformer resolves to a bucket inside the pool", function(t)
		local transformer = Pigeon.Transformer(unique("Bucket"))
		local ref = Pigeon.GetRef(transformer)

		local bucket = tonumber(ref.Name:match("^PigeonRef_(%d+)$"))
		t.ne(bucket, nil, "the ref should be a pooled one")
		t.ok(bucket >= 1 and bucket <= Network.GetRefCount(), "and inside the published pool")

		transformer:Destroy()
	end)

	pool:test("creating a transformer never destroys an existing ref", function(t)
		local folder = ReplicatedStorage:FindFirstChild("PigeonRefs")
		local before = #folder:GetChildren()

		local transformer = Pigeon.Transformer(unique("PoolGrowth"))
		t.ok(#folder:GetChildren() >= before, "the pool only ever grows")

		transformer:Destroy()
		t.ok(#folder:GetChildren() >= before, "and shrinking the count does not delete refs")
	end)

	pool:test("Diagnostics starts with nothing pending", function(t)
		local diagnostics = Network.Diagnostics()
		t.eq(diagnostics.pending, 0, "no call should be in flight between suites")
		t.ok(diagnostics.listeners > 0, "the fixture carriers are bound")
	end)

	local fixtures = TestKit.suite("Server / fixtures")
	table.insert(suites, fixtures)

	fixtures:test("every fixture carrier is alive", function(t)
		local count = 0
		for name, carrier in Fixtures.carriers do
			count += 1
			t.no((carrier :: any)._dropped, name .. " should not be dropped")
			t.no((carrier :: any)._transformer.destroyed, name .. "'s transformer should be alive")
		end
		t.ok(count >= 15, "the run needs a channel per behaviour under test")
	end)

	fixtures:test("the shared-transformer pair really shares one transformer", function(t)
		local first = Fixtures.carriers["PigeonTest_SharedA"]
		local second = Fixtures.carriers["PigeonTest_SharedB"]

		t.eq((first :: any)._transformer, (second :: any)._transformer)
		t.eq(Pigeon.GetRef((first :: any)._transformer), Pigeon.GetRef((second :: any)._transformer))
		t.ne((first :: any)._name, (second :: any)._name, "but they are different channels")
	end)

	fixtures:test("the cluster pair shares a transformer neither of them owns", function(t)
		local first = Fixtures.carriers["PigeonTest_ClusterA"]
		local second = Fixtures.carriers["PigeonTest_ClusterB"]

		t.eq((first :: any)._ownsTransformer, false)
		t.eq((second :: any)._ownsTransformer, false)
		t.eq((first :: any)._transformer, Fixtures.transformers.cluster)
	end)

	fixtures:test("every published staged table is captured", function(t)
		local tables = (Fixtures.carriers["PigeonTest_Tables"] :: any)._tables

		for _, id in { "main", "guarded", "mixed", "sticky" } do
			t.ne(tables[id], nil, id .. " should be published")
			t.ne((tables[id] :: any)._onWrite, nil, id .. " should be replicating")
		end

		t.eq(tables["forced"], nil, "the forced table is published only when it is pushed")
	end)

	return suites
end
