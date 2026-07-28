local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pigeon = require(ReplicatedStorage:WaitForChild("Pigeon"))
local Network = require(ReplicatedStorage.Pigeon.Network)

local ME = Players.LocalPlayer.Name

local Tests = ReplicatedStorage:WaitForChild("PigeonTests")
local Protocol = require(Tests.Protocol)

local QUIET = 1.25

return function(TestKit: any, Fixtures: any): { any }
	local suites = {}

	local inbox = Fixtures.inbox
	local ask = Fixtures.ask
	local withArgs = Fixtures.withArgs

	local echo = Fixtures.carriers[Protocol.Echo]
	local guarded = Fixtures.carriers[Protocol.Guarded]
	local rooms = Fixtures.carriers[Protocol.Rooms]
	local tables = Fixtures.carriers[Protocol.Tables]
	local middleware = Fixtures.carriers[Protocol.Middleware]
	local unreliable = Fixtures.carriers[Protocol.Unreliable]

	local impatient = Pigeon.new(Protocol.Echo, { Timeout = 1.5 }):Init()

	local function serverBroadcast(carrier: string, event: string, ...: any)
		ask("broadcastTo", withArgs({ carrier = carrier, event = event }, ...))
	end

	local function serverBroadcastAll(carrier: string, event: string, ...: any)
		ask("broadcast", withArgs({ carrier = carrier, event = event }, ...))
	end

	local outbound = TestKit.suite("Integration / client to server")
	table.insert(suites, outbound)

	outbound:test("Emit reaches the server with its payload", function(t)
		Fixtures.serverForget("Echo.Emit")
		echo:Emit("Emit", "payload", 7, true)

		t.eventually(function()
			return Fixtures.serverCount("Echo.Emit") == 1
		end, 5)

		local entry = Fixtures.serverEntries("Echo.Emit")[1]
		local ok, why = Protocol.same(entry, { "payload", 7, true }, 3)
		t.ok(ok, why)
	end)

	outbound:test("the sending player is prepended for the server listener", function(t)
		Fixtures.serverForget("Echo.Emit")
		echo:Emit("Emit", "who")

		t.eventually(function()
			return Fixtures.serverCount("Echo.Emit") == 1
		end, 5)

		local entry = Fixtures.serverEntries("Echo.Emit")[1]
		t.eq(entry.player, ME)
		t.eq(entry.n, 1, "the player is not part of the payload")
	end)

	outbound:test("Emit with no payload arrives as no arguments", function(t)
		Fixtures.serverForget("Echo.Emit")
		echo:Emit("Emit")

		t.eventually(function()
			return Fixtures.serverCount("Echo.Emit") == 1
		end, 5)

		t.eq(Fixtures.serverEntries("Echo.Emit")[1].n, 0)
	end)

	outbound:known(
		"a nil in the middle of the payload is preserved",
		"the { [1] = ..., n = count } envelope mixes integer and string keys, so Roblox strips n in transit and the payload truncates at the first nil",
		function(t)
			Fixtures.serverForget("Echo.Emit")
			echo:Emit("Emit", 1, nil, 3)

			t.eventually(function()
				return Fixtures.serverCount("Echo.Emit") == 1
			end, 5)

			local entry = Fixtures.serverEntries("Echo.Emit")[1]
			t.eq(entry.n, 3, "the packed arity must survive the wire")
			local ok, why = Protocol.same(entry, { 1, Protocol.NIL, 3 }, 3)
			t.ok(ok, why)
		end
	)

	outbound:known(
		"a trailing nil is preserved",
		"same dropped n; with no hole in the payload this isolates the cause to the mixed-key envelope rather than to the nil itself",
		function(t)
			Fixtures.serverForget("Echo.Emit")
			echo:Emit("Emit", "a", nil)

			t.eventually(function()
				return Fixtures.serverCount("Echo.Emit") == 1
			end, 5)

			t.eq(Fixtures.serverEntries("Echo.Emit")[1].n, 2, "a trailing nil cannot be truncated away")
		end
	)

	outbound:test("a payload with no nils keeps its arity", function(t)
		Fixtures.serverForget("Echo.Emit")
		echo:Emit("Emit", 1, 2, 3)

		t.eventually(function()
			return Fixtures.serverCount("Echo.Emit") == 1
		end, 5)

		t.eq(Fixtures.serverEntries("Echo.Emit")[1].n, 3, "#args agrees with n when nothing is missing")
	end)

	outbound:test("emits arrive in the order they were sent", function(t)
		Fixtures.serverForget("Echo.Emit")
		for index = 1, 8 do
			echo:Emit("Emit", index)
		end

		t.eventually(function()
			return Fixtures.serverCount("Echo.Emit") == 8
		end, 5)

		local entries = Fixtures.serverEntries("Echo.Emit")
		for index = 1, 8 do
			t.eq(entries[index].values[1], index, "packet " .. index .. " arrived out of order")
		end
	end)

	outbound:test("an event with no server listener is silently dropped", function(t)
		t.noThrow(function()
			echo:Emit("NobodyIsListening", 1)
		end)
	end)

	local requests = TestKit.suite("Integration / Call")
	table.insert(suites, requests)

	requests:test("returns what the server's listener returned", function(t)
		t.eq(echo:Call("Sum", 20, 22), 42)
	end)

	requests:test("returns every value the server returned", function(t)
		local first, second, third = echo:Call("Multi")
		t.eq(first, 1)
		t.eq(second, "two")
		t.eq(third, true)
	end)

	requests:test("round trips its arguments", function(t)
		local first, second = echo:Call("Echo", "there", "and back")
		t.eq(first, "there")
		t.eq(second, "and back")
	end)

	requests:diagnostic("a nil among the returned values survives", function(t)
		local first, second, third = echo:Call("Trailing")

		t.log(string.format("got (%s, %s, %s)", tostring(first), tostring(second), tostring(third)))
		t.eq(first, "first")
		t.eq(second, nil)
		t.eq(third, "third", "the response arity was recovered from # rather than from n")
	end)

	requests:test("a listener returning nothing answers with nothing", function(t)
		t.eq(echo:Call("Nothing"), nil)
	end)

	requests:test("the server sees who is calling", function(t)
		local name = echo:Call("WhoAmI")
		t.eq(name, ME)
	end)

	requests:test("survives a server listener that yields", function(t)
		t.eq(echo:Call("Slow"), "eventually")
	end, 20)

	requests:test("gives up at the configured timeout when nothing answers", function(t)
		local started = os.clock()
		local result = impatient:Call("NobodyIsListening")
		local elapsed = os.clock() - started

		t.eq(result, nil)
		t.ok(elapsed >= 1.4, "it should have waited the full timeout, took " .. string.format("%.2f", elapsed))
		t.lt(elapsed, 6, "and not fallen back to the ten second default")
	end, 20)

	requests:test("returns nil when the server's listener throws", function(t)
		t.eq(impatient:Call("Fails"), nil, "a listener that errors never answers")
	end, 20)

	requests:test("Ping measures a plausible round trip", function(t)
		local latency = echo:Ping()

		t.isType(latency, "number")
		t.ok(latency > 0, "a round trip takes some time")
		t.lt(latency, 5, "and not that much: " .. tostring(latency))
	end, 20)

	requests:test("concurrent calls settle independently", function(t)
		local results = {}

		for index = 1, 5 do
			task.spawn(function()
				results[index] = echo:Call("Sum", index, index)
			end)
		end

		t.eventually(function()
			for index = 1, 5 do
				if results[index] ~= index * 2 then
					return false
				end
			end
			return true
		end, 8, "each promise id must settle its own waiter")
	end, 20)

	requests:test("nothing is left pending afterwards", function(t)
		t.eventually(function()
			return Network.Diagnostics().pending == 0
		end, 5)
	end)

	local inbound = TestKit.suite("Integration / server to client")
	table.insert(suites, inbound)

	inbound:test("Broadcast reaches this client", function(t)
		inbox:reset("Echo.Recv")
		serverBroadcastAll(Protocol.Echo, "Recv", "hello", 3)

		t.eventually(function()
			return inbox:count("Echo.Recv") == 1
		end, 5)

		local ok, why = Protocol.same(inbox:at("Echo.Recv"), { "hello", 3 }, 2)
		t.ok(ok, why)
	end)

	inbound:test("a client listener is handed no player", function(t)
		inbox:reset("Echo.Recv")
		serverBroadcast(Protocol.Echo, "Recv", "solo")

		t.eventually(function()
			return inbox:count("Echo.Recv") == 1
		end, 5)

		local entry = inbox:at("Echo.Recv")
		t.eq(entry.n, 1, "the client side of a listener sees only the payload")
		t.eq(entry.values[1], "solo")
	end)

	inbound:known(
		"a nil in the middle of a broadcast is preserved",
		"the same stripped n as on the outbound path -- the envelope is built by the same prepare() in both directions, so server to client truncates at the first nil too",
		function(t)
			inbox:reset("Echo.Recv")
			serverBroadcast(Protocol.Echo, "Recv", "a", nil, "c")

			t.eventually(function()
				return inbox:count("Echo.Recv") == 1
			end, 5)

			local ok, why = Protocol.same(inbox:at("Echo.Recv"), { "a", Protocol.NIL, "c" }, 3)
			t.ok(ok, why)
		end
	)

	inbound:test("BroadcastExcept leaves this client out", function(t)
		inbox:reset("Echo.Recv")
		ask("broadcastExcept", withArgs({ carrier = Protocol.Echo, event = "Recv" }, "skipped"))

		t.never(function()
			return inbox:count("Echo.Recv") > 0
		end, QUIET)
	end)

	inbound:test("broadcasts arrive in the order they were sent", function(t)
		inbox:reset("Echo.Ordered")
		ask("broadcastSeries", { carrier = Protocol.Echo, event = "Ordered", count = 10 })

		t.eventually(function()
			return inbox:count("Echo.Ordered") == 10
		end, 6)

		t.same(inbox:firsts("Echo.Ordered"), { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 })
	end)

	inbound:test("every listener on an event fires", function(t)
		local extra = 0
		local handler = function()
			extra += 1
		end

		echo:On("Recv", handler)
		inbox:reset("Echo.Recv")
		serverBroadcast(Protocol.Echo, "Recv", "both")

		t.eventually(function()
			return inbox:count("Echo.Recv") == 1 and extra == 1
		end, 5)

		echo:Off("Recv", handler)
	end)

	inbound:test("Off stops delivery", function(t)
		local seen = 0
		local handler = function()
			seen += 1
		end

		local quiet = Pigeon.new(Protocol.Echo, {}):Init()
		quiet:On("Recv", handler)
		quiet:Off("Recv", handler)

		inbox:reset("Echo.Recv")
		serverBroadcast(Protocol.Echo, "Recv", "ignored")

		t.eventually(function()
			return inbox:count("Echo.Recv") == 1
		end, 5, "the broadcast should still have arrived")
		t.eq(seen, 0, "but not at the listener that was removed")

		quiet:Destroy()
	end, 25)

	local roomSuite = TestKit.suite("Integration / rooms")
	table.insert(suites, roomSuite)

	roomSuite:test("a member receives a room send", function(t)
		inbox:reset("Rooms.Recv")
		ask("roomCreate", { carrier = Protocol.Rooms, room = "alpha", includeCaller = true })
		ask("roomSend", withArgs({ carrier = Protocol.Rooms, room = "alpha", event = "Recv" }, "in the room"))

		t.eventually(function()
			return inbox:count("Rooms.Recv") == 1
		end, 5)

		ask("roomDestroy", { carrier = Protocol.Rooms, room = "alpha" })
	end)

	roomSuite:test("JoinRoom admits this client", function(t)
		inbox:reset("Rooms.Recv")
		ask("roomCreate", { carrier = Protocol.Rooms, room = "beta", includeCaller = false })
		ask("roomJoin", { carrier = Protocol.Rooms, room = "beta" })

		local members = ask("roomMembers", { carrier = Protocol.Rooms, room = "beta" })
		t.eq(#members, 1)

		ask("roomSend", withArgs({ carrier = Protocol.Rooms, room = "beta", event = "Recv" }, "joined"))
		t.eventually(function()
			return inbox:count("Rooms.Recv") == 1
		end, 5)

		ask("roomDestroy", { carrier = Protocol.Rooms, room = "beta" })
	end)

	roomSuite:test("a non-member receives nothing", function(t)
		inbox:reset("Rooms.Recv")
		ask("roomCreate", { carrier = Protocol.Rooms, room = "gamma", includeCaller = false })
		ask("roomSend", withArgs({ carrier = Protocol.Rooms, room = "gamma", event = "Recv" }, "not for you"))

		t.never(function()
			return inbox:count("Rooms.Recv") > 0
		end, QUIET)

		ask("roomDestroy", { carrier = Protocol.Rooms, room = "gamma" })
	end)

	roomSuite:test("leaving a room stops delivery", function(t)
		inbox:reset("Rooms.Recv")
		ask("roomCreate", { carrier = Protocol.Rooms, room = "delta", includeCaller = true })
		ask("roomLeave", { carrier = Protocol.Rooms, room = "delta" })

		t.eq(#ask("roomMembers", { carrier = Protocol.Rooms, room = "delta" }), 0)

		ask("roomSend", withArgs({ carrier = Protocol.Rooms, room = "delta", event = "Recv" }, "gone"))
		t.never(function()
			return inbox:count("Rooms.Recv") > 0
		end, QUIET)

		ask("roomDestroy", { carrier = Protocol.Rooms, room = "delta" })
	end)

	roomSuite:test("a destroyed room is no longer addressable", function(t)
		inbox:reset("Rooms.Recv")
		ask("roomCreate", { carrier = Protocol.Rooms, room = "epsilon", includeCaller = true })
		ask("roomDestroy", { carrier = Protocol.Rooms, room = "epsilon" })

		t.eq(ask("roomMembers", { carrier = Protocol.Rooms, room = "epsilon" }), nil)

		ask("roomSend", withArgs({ carrier = Protocol.Rooms, room = "epsilon", event = "Recv" }, "vanished"))
		t.never(function()
			return inbox:count("Rooms.Recv") > 0
		end, QUIET)
	end)

	local buffering = TestKit.suite("Integration / Init and buffering")
	table.insert(suites, buffering)

	buffering:test("nothing arrives on a channel that was never initialised", function(t)
		local held = Pigeon.new(Protocol.Buffered, {})
		local seen = 0
		held:On("Recv", function()
			seen += 1
		end)

		ask("broadcastSeries", { carrier = Protocol.Buffered, event = "Recv", count = 3 })

		t.never(function()
			return seen > 0
		end, QUIET, "the server holds everything until the channel is readied")

		held:Destroy()
	end, 25)

	buffering:test("Init releases the backlog, oldest first", function(t)
		local received = {}
		local held = Pigeon.new(Protocol.BufferedB, {})
		held:On("Recv", function(index: number)
			table.insert(received, index)
		end)

		ask("broadcastSeries", { carrier = Protocol.BufferedB, event = "Recv", count = 5 })
		t.wait(0.5)
		t.eq(#received, 0, "still holding")

		held:Init()

		t.eventually(function()
			return #received == 5
		end, 6, "the queue should arrive in the order it was held")
		t.same(received, { 1, 2, 3, 4, 5 })

		held:Destroy()
	end, 30)

	buffering:test("readying one channel does not flush another's backlog", function(t)
		local firstSeen, secondSeen = 0, 0

		local first = Pigeon.new(Protocol.BufferedC, {})
		first:On("Recv", function()
			firstSeen += 1
		end)

		local second = Pigeon.new(Protocol.BufferedD, {})
		second:On("Recv", function()
			secondSeen += 1
		end)

		ask("broadcastSeries", { carrier = Protocol.BufferedC, event = "Recv", count = 2 })
		ask("broadcastSeries", { carrier = Protocol.BufferedD, event = "Recv", count = 2 })

		first:Init()

		t.eventually(function()
			return firstSeen == 2
		end, 6, "the readied channel should release")
		t.never(function()
			return secondSeen > 0
		end, QUIET, "one channel coming up early must not flush another's backlog")

		second:Init()
		t.eventually(function()
			return secondSeen == 2
		end, 6, "and the other releases when it asks")

		first:Destroy()
		second:Destroy()
	end, 40)

	buffering:test("a packet with no listener yet is replayed to the first one", function(t)
		local late = Fixtures.carriers[Protocol.Late]
		local seen = {}

		serverBroadcast(Protocol.Late, "Replayed", "held-for-later")
		t.wait(0.6)

		late:On("Replayed", function(payload: string)
			table.insert(seen, payload)
		end)

		t.eventually(function()
			return #seen == 1
		end, 6, "a packet that arrived before anything was listening should be held, not discarded")
		t.eq(seen[1], "held-for-later")

		late:Off("Replayed")
	end, 25)

	buffering:test("Emit works before Init", function(t)
		local early = Pigeon.new(Protocol.Echo, {})
		Fixtures.serverForget("Echo.Emit")

		early:Emit("Emit", "sent before init")

		t.eventually(function()
			return Fixtures.serverCount("Echo.Emit") == 1
		end, 5, "only the inbound direction waits")

		early:Destroy()
	end, 25)

	local handshake = TestKit.suite("Integration / handshake")
	table.insert(suites, handshake)

	handshake:test("an unguarded carrier admits everyone", function(t)
		ask("setGuard", { carrier = Protocol.Guarded, mode = "none" })
		t.eq(guarded:Handshake(), true, "a carrier with no guard admits everyone")
	end, 25)

	handshake:test("a guarded channel reaches nobody until they are admitted", function(t)
		ask("setGuard", { carrier = Protocol.Guarded, mode = "token" })
		inbox:reset("Guarded.Recv")

		serverBroadcastAll(Protocol.Guarded, "Recv", "for members only")

		t.never(function()
			return inbox:count("Guarded.Recv") > 0
		end, QUIET, "a broadcast on a guarded carrier reaches only the approved")
	end, 25)

	handshake:test("a guarded channel ignores what an unadmitted client sends", function(t)
		Fixtures.serverForget("Guarded.Emit")
		guarded:Emit("Emit", "let me in")

		t.never(function()
			return Fixtures.serverCount("Guarded.Emit") > 0
		end, QUIET, "the gate is the single door every inbound packet passes through")
	end, 25)

	handshake:test("the wrong credentials are refused", function(t)
		t.eq(guarded:Handshake(Protocol.BadToken), false)
		t.eq(ask("isAuthed", { carrier = Protocol.Guarded }), false)
	end, 25)

	handshake:test("the right credentials are admitted", function(t)
		t.eq(guarded:Handshake(Protocol.GoodToken), true)
		t.eq(ask("isAuthed", { carrier = Protocol.Guarded }), true)

		local approved = ask("approved", { carrier = Protocol.Guarded })
		t.eq(#approved, 1)
		t.eq(approved[1], ME)
	end, 25)

	handshake:test("an admitted client receives broadcasts", function(t)
		inbox:reset("Guarded.Recv")
		serverBroadcastAll(Protocol.Guarded, "Recv", "welcome")

		t.eventually(function()
			return inbox:count("Guarded.Recv") == 1
		end, 5)
	end, 25)

	handshake:test("an admitted client can send", function(t)
		Fixtures.serverForget("Guarded.Emit")
		guarded:Emit("Emit", "hello from a member")

		t.eventually(function()
			return Fixtures.serverCount("Guarded.Emit") == 1
		end, 5)
	end, 25)

	handshake:test("an admitted client can call", function(t)
		t.eq(guarded:Call("Ask"), "answered")
	end, 25)

	handshake:test("a later refusal revokes an earlier grant", function(t)
		t.eq(guarded:Handshake(Protocol.BadToken), false, "the most recent answer is the one that counts")
		t.eq(ask("isAuthed", { carrier = Protocol.Guarded }), false)

		inbox:reset("Guarded.Recv")
		serverBroadcastAll(Protocol.Guarded, "Recv", "revoked")
		t.never(function()
			return inbox:count("Guarded.Recv") > 0
		end, QUIET, "revocation is how access is taken away")
	end, 30)

	handshake:test("a client refused once can be admitted later", function(t)
		t.eq(guarded:Handshake(Protocol.GoodToken), true, "every attempt is judged afresh")
		t.eq(ask("isAuthed", { carrier = Protocol.Guarded }), true)
	end, 25)

	handshake:test("replacing the guard re-closes the channel", function(t)
		ask("setGuard", { carrier = Protocol.Guarded, mode = "allow" })

		t.eq(
			ask("isAuthed", { carrier = Protocol.Guarded }),
			false,
			"clients vetted by the old rules must prove themselves again"
		)

		inbox:reset("Guarded.Recv")
		serverBroadcastAll(Protocol.Guarded, "Recv", "after the swap")
		t.never(function()
			return inbox:count("Guarded.Recv") > 0
		end, QUIET, "and they are not told, so they must handshake again")
	end, 30)

	handshake:test("handshaking again after a guard swap gets back in", function(t)
		t.eq(guarded:Handshake(), true, "the replacement guard admits everyone who asks")
		t.eq(ask("isAuthed", { carrier = Protocol.Guarded }), true)
	end, 25)

	handshake:test("a guard that refuses everyone keeps everyone out", function(t)
		ask("setGuard", { carrier = Protocol.Guarded, mode = "deny" })
		t.eq(guarded:Handshake(Protocol.GoodToken), false)
	end, 25)

	handshake:test("a guard that throws refuses", function(t)
		ask("setGuard", { carrier = Protocol.Guarded, mode = "error" })
		t.eq(guarded:Handshake(), false, "a broken guard must fail closed")
	end, 25)

	handshake:test("the channel reopens when the guard is removed", function(t)
		ask("setGuard", { carrier = Protocol.Guarded, mode = "none" })
		inbox:reset("Guarded.Recv")

		serverBroadcastAll(Protocol.Guarded, "Recv", "open again")
		t.eventually(function()
			return inbox:count("Guarded.Recv") == 1
		end, 5)
	end, 25)

	local mw = TestKit.suite("Integration / middleware")
	table.insert(suites, mw)

	mw:test("outgoing middleware sees the direction and event", function(t)
		inbox:reset("Mw.ClientOutgoing")
		middleware:Emit("Plain", "one", "two")

		t.eventually(function()
			return inbox:count("Mw.ClientOutgoing") >= 1
		end, 5)

		local entry = inbox:at("Mw.ClientOutgoing")
		t.eq(entry.values[1], "outgoing")
		t.eq(entry.values[2], "Plain")
		t.eq(entry.values[3], 2, "and the argument list it may rewrite")
	end)

	mw:test("outgoing middleware can rewrite the event name", function(t)
		Fixtures.serverForget("Mw.Plain")
		middleware:Emit("Alias", "renamed on the way out")

		t.eventually(function()
			return Fixtures.serverCount("Mw.Plain") == 1
		end, 5, "the server should have handled it under the rewritten name")
	end)

	mw:test("outgoing middleware can rewrite the arguments", function(t)
		Fixtures.serverForget("Mw.Grow")
		middleware:Emit("Grow", "original")

		t.eventually(function()
			return Fixtures.serverCount("Mw.Grow") == 1
		end, 5)

		local entry = Fixtures.serverEntries("Mw.Grow")[1]
		t.eq(entry.n, 2, "the appended argument should have travelled")
		t.eq(entry.values[1], "original")
		t.eq(entry.values[2], "added-by-client-outgoing")
	end)

	mw:test("a throwing middleware does not stop the packet", function(t)
		Fixtures.serverForget("Mw.Plain")
		middleware:Emit("Alias", "survived the broken middleware")

		t.eventually(function()
			return Fixtures.serverCount("Mw.Plain") == 1
		end, 5, "applyMiddleware pcalls each entry, so a failure is a warning not a drop")
	end)

	mw:test("incoming middleware on the server sees the sending player", function(t)
		Fixtures.serverForget("Mw.Incoming")
		middleware:Emit("Plain", "tagged")

		t.eventually(function()
			return Fixtures.serverCount("Mw.Incoming") >= 1
		end, 5)

		local entry = Fixtures.serverEntries("Mw.Incoming")[1]
		t.eq(entry.player, ME)
		t.eq(entry.values[1], "incoming")
	end)

	mw:test("incoming middleware on the server can rewrite the event name", function(t)
		Fixtures.serverForget("Mw.Target")
		Fixtures.serverForget("Mw.RenamedRanDirectly")

		middleware:Emit("Renamed", "arrives as Target")

		t.eventually(function()
			return Fixtures.serverCount("Mw.Target") == 1
		end, 5)
		t.eq(
			Fixtures.serverCount("Mw.RenamedRanDirectly"),
			0,
			"dispatch is by the resolved name, so the original event's own listener is skipped"
		)
	end)

	mw:test("incoming middleware can rename an unbound event onto a live listener", function(t)

		Fixtures.serverForget("Mw.Target")
		middleware:Emit("Unbound", "arrives as Target anyway")

		t.eventually(function()
			return Fixtures.serverCount("Mw.Target") == 1
		end, 5, "middleware sees every packet on the channel, not only the bound ones")
	end, 25)

	mw:test("incoming middleware sees a packet nothing listens for", function(t)

		Fixtures.serverForget("Mw.Incoming")
		middleware:Emit("Ignored", "seen but not handled")

		t.eventually(function()
			for _, entry in Fixtures.serverEntries("Mw.Incoming") do
				if entry.values[2] == "Ignored" then
					return true
				end
			end
			return false
		end, 5, "an event with no listener must still reach the chain")
	end, 25)

	mw:test("incoming middleware on the server can rewrite the arguments", function(t)
		Fixtures.serverForget("Mw.Appended")
		middleware:Emit("Appended", "first")

		t.eventually(function()
			return Fixtures.serverCount("Mw.Appended") == 1
		end, 5)

		local entry = Fixtures.serverEntries("Mw.Appended")[1]
		t.eq(entry.n, 2, "the appended argument should reach the listener")
		t.eq(entry.values[2], "added-by-server-incoming")
	end)

	mw:test("outgoing middleware on the server rewrites what leaves it", function(t)
		inbox:reset("Mw.Delivered")
		inbox:reset("Mw.Rewritten")

		serverBroadcast(Protocol.Middleware, "Rewritten", "payload")

		t.eventually(function()
			return inbox:count("Mw.Delivered") == 1
		end, 5, "the client should have handled it under the rewritten name")
		t.eq(inbox:count("Mw.Rewritten"), 0, "and not under the original")

		local entry = inbox:at("Mw.Delivered")
		t.eq(entry.n, 2)
		t.eq(entry.values[2], "added-by-server-outgoing")
	end)

	mw:test("incoming middleware on the client rewrites before listeners see it", function(t)
		inbox:reset("Mw.ClientHeard")
		inbox:reset("Mw.ServerSaid")

		serverBroadcast(Protocol.Middleware, "ServerSaid", "hello")

		t.eventually(function()
			return inbox:count("Mw.ClientHeard") == 1
		end, 5)
		t.eq(inbox:count("Mw.ServerSaid"), 0, "listeners see the rewritten name only")

		local entry = inbox:at("Mw.ClientHeard")
		t.eq(entry.values[2], "seen-by-client-incoming")
	end)

	mw:test("incoming middleware can turn a packet away from a bound listener", function(t)
		inbox:reset("Mw.Denied")
		serverBroadcast(Protocol.Middleware, "Denied", "turned away")

		t.never(function()
			return inbox:count("Mw.Denied") > 0
		end, QUIET, "rerouting to a name nothing listens for is how a packet is refused")
	end, 25)

	local staged = TestKit.suite("Integration / staged tables")
	table.insert(suites, staged)

	staged:test("RequestTable yields a mirror of the server's contents", function(t)
		local mirror = tables:RequestTable(Protocol.TableMain)
		local view = mirror:GetTable()

		t.eq(view.counter, 0)
		t.eq(view.label, "initial")
		t.eq(view.stats.hp, 100)
		t.eq(view.list[2], 2)
	end, 25)

	staged:test("asking again hands back the same live object", function(t)
		local first = tables:RequestTable(Protocol.TableMain)

		local started = os.clock()
		local second = tables:RequestTable(Protocol.TableMain)

		t.eq(first, second, "mirrors are cached per id")
		t.lt(os.clock() - started, 0.2, "and asking again costs no round trip")
	end, 25)

	staged:test("a server write replicates", function(t)
		local view = tables:RequestTable(Protocol.TableMain):GetTable()
		ask("tableSet", { id = Protocol.TableMain, path = { "label" }, value = "changed" })

		t.eventually(function()
			return view.label == "changed"
		end, 6)
	end, 25)

	staged:test("a nested server write replicates by path", function(t)
		local view = tables:RequestTable(Protocol.TableMain):GetTable()
		ask("tableSet", { id = Protocol.TableMain, path = { "stats", "hp" }, value = 55 })

		t.eventually(function()
			return view.stats.hp == 55
		end, 6)
		t.eq(view.stats.mp, 50, "a nested patch must not clobber its siblings")
	end, 25)

	staged:test("a server deletion replicates", function(t)
		local view = tables:RequestTable(Protocol.TableMain):GetTable()
		ask("tableSet", { id = Protocol.TableMain, path = { "label" }, value = Protocol.NIL })

		t.eventually(function()
			return view.label == nil
		end, 6)
	end, 25)

	staged:test("a burst of server writes arrives as one patch", function(t)
		local view = tables:RequestTable(Protocol.TableMain):GetTable()
		Fixtures.patchPackets = 0

		ask("tableBurst", { id = Protocol.TableMain, count = 6 })

		t.eventually(function()
			return view.burst6 == 6
		end, 6)

		t.eq(Fixtures.patchPackets, 1, "filling a table field by field should cost one send")
		t.eq(view.burst1, 1)
	end, 25)

	staged:test("a table mixing key types replicates intact", function(t)
		local view = tables:RequestTable(Protocol.TableMixed):GetTable()

		t.eq(view.keys[1], "one", "integer keys survive the wire")
		t.eq(view.keys.named, "two", "string keys survive the wire")
		t.eq(view.keys[true], "three", "boolean keys survive the wire")
		t.eq(view.keys[4.5], "four", "fractional keys survive the wire")
	end, 25)

	staged:test("writing to a mirror does not loop back to the server", function(t)
		local mirror = tables:RequestTable(Protocol.TableMain)
		mirror:GetTable().localOnly = "client wrote this"

		t.eq(mirror:GetTable().localOnly, "client wrote this", "the local view updates")

		t.wait(0.6)
		local onServer = ask("tableSnapshotValue", { id = Protocol.TableMain, path = { "localOnly" } })
		t.eq(onServer, nil, "the mirror is server-authoritative, so its write hook is unset")
	end, 25)

	staged:test("a mirror enforces the same data rules", function(t)
		local mirror = tables:RequestTable(Protocol.TableMain)
		t.throws(function()
			mirror:GetTable().bad = Instance.new("Part")
		end, "ERR_STAGE_UNSUPPORTED")
	end, 25)

	staged:test("a capture guard can refuse a request", function(t)
		ask("tableGuardMode", { capture = "deny" })

		t.throws(function()
			tables:RequestTable(Protocol.TableGuarded)
		end, "ERR_CAPTURE_DENIED")

		ask("tableGuardMode", { capture = "allow" })
	end, 25)

	staged:test("an allowed request goes through once the guard relents", function(t)
		local mirror = tables:RequestTable(Protocol.TableGuarded)
		t.eq(mirror:GetTable().secret, "hidden")
	end, 25)

	staged:test("requesting an id the server never published is refused", function(t)
		t.throws(function()
			tables:RequestTable(Protocol.TableMissing)
		end, "ERR_CAPTURE_DENIED")
	end, 25)

	staged:test("Release drops the subscription and the cache entry", function(t)
		local mirror = tables:RequestTable(Protocol.TableGuarded)
		t.eq(ask("tableSubscribers", { id = Protocol.TableGuarded }), 1)

		mirror:Release()

		t.eventually(function()
			return ask("tableSubscribers", { id = Protocol.TableGuarded }) == 0
		end, 6, "the client tells the server to stop sending")

		local fresh = tables:RequestTable(Protocol.TableGuarded)
		t.ne(fresh, mirror, "the cache entry is dropped, so a later request re-fetches")
	end, 30)

	staged:test("a release guard can keep a client subscribed", function(t)
		local mirror = tables:RequestTable(Protocol.TableGuarded)
		ask("tableGuardMode", { release = "deny" })

		mirror:Release()
		t.wait(0.8)

		t.eq(
			ask("tableSubscribers", { id = Protocol.TableGuarded }),
			1,
			"returning false from a release guard keeps the client subscribed"
		)

		ask("tableGuardMode", { release = "allow" })
	end, 30)

	staged:test("ReleaseTable on the server does not disturb a client already receiving", function(t)
		local view = tables:RequestTable(Protocol.TableSticky):GetTable()
		ask("tableReleasePointer", { id = Protocol.TableSticky })

		ask("tableSet", { id = Protocol.TableSticky, path = { "ticks" }, value = 99 })

		t.eventually(function()
			return view.ticks == 99
		end, 6, "subscribers live on the staged table, not on the carrier")
	end, 30)

	staged:test("a released pointer can no longer be requested", function(t)

		local fresh = Pigeon.new(Protocol.Tables, {}):Init()

		t.throws(function()
			fresh:RequestTable(Protocol.TableSticky)
		end, "ERR_CAPTURE_DENIED")

		fresh:Destroy()
	end, 30)

	local revocation = TestKit.suite("Integration / Revoke")
	table.insert(suites, revocation)

	local revocable = Fixtures.carriers[Protocol.Revoke]
	local revokedMirror: any = nil

	revocation:test("a client admitted by the guard can use the channel", function(t)
		t.eq(revocable:Handshake(Protocol.GoodToken), true)
		t.eq(ask("isAuthed", { carrier = Protocol.Revoke }), true)

		inbox:reset("Revoke.Recv")
		serverBroadcastAll(Protocol.Revoke, "Recv", "before")
		t.eventually(function()
			return inbox:count("Revoke.Recv") == 1
		end, 5)
	end, 25)

	revocation:test("and can hold a staged table from it", function(t)
		revokedMirror = revocable:RequestTable(Protocol.TableRevoke)
		t.eq(revokedMirror:GetTable().secret, "members only")
		t.eq(ask("tableSubscribers", { id = Protocol.TableRevoke }), 1)
	end, 25)

	revocation:test("Revoke reports how many admitted clients it removed", function(t)
		t.eq(ask("revoke", { carrier = Protocol.Revoke }), 1)
		t.eq(ask("isAuthed", { carrier = Protocol.Revoke }), false)
	end, 25)

	revocation:test("the server drops them as a staged table subscriber", function(t)
		t.eq(ask("tableSubscribers", { id = Protocol.TableRevoke }), 0)
	end, 25)

	revocation:test("the client is made to let its mirror go", function(t)
		t.eventually(function()
			return (revokedMirror :: any)._released == true
		end, 6, "the revoke message should have released the mirror")

		t.eq((revocable :: any)._tables[Protocol.TableRevoke], nil, "the cache entry is dropped")
	end, 25)

	revocation:test("later writes to that table do not reach them", function(t)
		ask("tableSet", { id = Protocol.TableRevoke, path = { "ticks" }, value = 99 })
		t.wait(0.8)
		t.ne(revokedMirror:GetTable().ticks, 99, "a released mirror stops being updated")
	end, 25)

	revocation:test("broadcasts no longer reach them", function(t)
		inbox:reset("Revoke.Recv")
		serverBroadcastAll(Protocol.Revoke, "Recv", "after")

		t.never(function()
			return inbox:count("Revoke.Recv") > 0
		end, QUIET)
	end, 25)

	revocation:test("what they send is ignored", function(t)
		Fixtures.serverForget("Revoke.Emit")
		revocable:Emit("Emit", "still here?")

		t.never(function()
			return Fixtures.serverCount("Revoke.Emit") > 0
		end, QUIET)
	end, 25)

	revocation:test("revoking again removes nobody", function(t)
		t.eq(ask("revoke", { carrier = Protocol.Revoke }), 0, "they were not admitted this time")
	end, 25)

	revocation:test("they can be admitted again by handshaking", function(t)
		t.eq(revocable:Handshake(Protocol.GoodToken), true)
		t.eq(ask("isAuthed", { carrier = Protocol.Revoke }), true)

		inbox:reset("Revoke.Recv")
		serverBroadcastAll(Protocol.Revoke, "Recv", "welcome back")
		t.eventually(function()
			return inbox:count("Revoke.Recv") == 1
		end, 5)
	end, 25)

	revocation:test("and can take the staged table again", function(t)
		local fresh = revocable:RequestTable(Protocol.TableRevoke)

		t.ne(fresh, revokedMirror, "a released mirror is re-fetched, not reused")
		t.eq(fresh:GetTable().ticks, 99, "and arrives with everything it missed")
		t.eq(ask("tableSubscribers", { id = Protocol.TableRevoke }), 1)
	end, 25)

	local routing = TestKit.suite("Integration / routing and teardown")
	table.insert(suites, routing)

	routing:test("two channels on one transformer do not hear each other outbound", function(t)
		Fixtures.serverForget("SharedA.Ping")
		Fixtures.serverForget("SharedB.Ping")

		Fixtures.carriers[Protocol.SharedA]:Emit("Ping", "only A")

		t.eventually(function()
			return Fixtures.serverCount("SharedA.Ping") == 1
		end, 5)
		t.eq(
			Fixtures.serverCount("SharedB.Ping"),
			0,
			"the carrier name prefix is what keeps two channels on one transformer apart"
		)
	end, 25)

	routing:test("two channels on one transformer do not hear each other inbound", function(t)
		inbox:reset("SharedA.Recv")
		inbox:reset("SharedB.Recv")

		serverBroadcast(Protocol.SharedB, "Recv", "only B")

		t.eventually(function()
			return inbox:count("SharedB.Recv") == 1
		end, 5)
		t.eq(inbox:count("SharedA.Recv"), 0)
	end, 25)

	routing:test("a channel routes by name even across mismatched transformers", function(t)
		Fixtures.serverForget("Mismatch.Emit")
		Fixtures.carriers[Protocol.Mismatch]:Emit("Emit", "different bucket")

		t.eventually(function()
			return Fixtures.serverCount("Mismatch.Emit") == 1
		end, 5, "a transformer only decides which pooled remote a packet leaves on")

		inbox:reset("Mismatch.Recv")
		serverBroadcast(Protocol.Mismatch, "Recv", "and back")

		t.eventually(function()
			return inbox:count("Mismatch.Recv") == 1
		end, 5)
	end, 25)

	routing:test("the two halves really are on different transformers", function(t)
		local mine = (Fixtures.carriers[Protocol.Mismatch] :: any)._transformer
		t.eq(mine.uuid, Protocol.MismatchTransformer)
		t.ne(mine.uuid, Protocol.Mismatch, "the server's half derives its transformer from the channel name")
	end)

	routing:test("two carriers with the same name both hear a broadcast", function(t)
		local second = Pigeon.new(Protocol.Echo, {}):Init()
		local seen = 0
		second:On("Recv", function()
			seen += 1
		end)

		inbox:reset("Echo.Recv")
		serverBroadcast(Protocol.Echo, "Recv", "heard twice")

		t.eventually(function()
			return inbox:count("Echo.Recv") == 1 and seen == 1
		end, 5, "same-named carriers on one machine all hear the same packets")

		second:Destroy()
	end, 25)

	routing:test("a destroyed carrier stops receiving", function(t)
		local doomed = Fixtures.carriers[Protocol.Doomed]
		inbox:reset("Doomed.Recv")

		serverBroadcast(Protocol.Doomed, "Recv", "before")
		t.eventually(function()
			return inbox:count("Doomed.Recv") == 1
		end, 5)

		doomed:Destroy()
		inbox:reset("Doomed.Recv")

		serverBroadcast(Protocol.Doomed, "Recv", "after")
		t.never(function()
			return inbox:count("Doomed.Recv") > 0
		end, QUIET)
	end, 30)

	routing:test("a destroyed carrier stops sending", function(t)
		local doomed = Fixtures.carriers[Protocol.Doomed]
		Fixtures.serverForget("Doomed.Emit")

		t.noThrow(function()
			doomed:Emit("Emit", "should not leave")
		end, "a dropped carrier goes quiet rather than erroring")

		t.never(function()
			return Fixtures.serverCount("Doomed.Emit") > 0
		end, QUIET, "nothing it sends can leave")
	end, 25)

	routing:test("destroying a transformer drops every channel riding on it", function(t)
		inbox:reset("ClusterA.Recv")
		inbox:reset("ClusterB.Recv")

		serverBroadcast(Protocol.ClusterA, "Recv", "alive")
		serverBroadcast(Protocol.ClusterB, "Recv", "alive")

		t.eventually(function()
			return inbox:count("ClusterA.Recv") == 1 and inbox:count("ClusterB.Recv") == 1
		end, 6)

		Fixtures.transformers.cluster:Destroy()

		t.eq((Fixtures.carriers[Protocol.ClusterA] :: any)._dropped, true)
		t.eq((Fixtures.carriers[Protocol.ClusterB] :: any)._dropped, true)

		inbox:reset("ClusterA.Recv")
		inbox:reset("ClusterB.Recv")

		serverBroadcast(Protocol.ClusterA, "Recv", "gone")
		serverBroadcast(Protocol.ClusterB, "Recv", "gone")

		t.never(function()
			return inbox:count("ClusterA.Recv") > 0 or inbox:count("ClusterB.Recv") > 0
		end, QUIET, "a cluster of related channels is torn down by destroying its transformer")
	end, 40)

	routing:test("the server can drop its half independently", function(t)
		ask("destroyCarrier", { carrier = Protocol.Doomed })

		Fixtures.serverForget("Echo.Emit")
		t.noThrow(function()
			ask("broadcast", withArgs({ carrier = Protocol.Doomed, event = "Recv" }, "from a dead carrier"))
		end, "a dropped carrier goes quiet rather than erroring")
	end, 25)

	local lossy = TestKit.suite("Integration / unreliable transport")
	table.insert(suites, lossy)

	lossy:test("an unreliable carrier is flagged as such", function(t)
		t.eq(unreliable.Unreliable, true)
		t.eq(echo.Unreliable, false)
	end)

	lossy:diagnostic("an unreliable emit reaches the server", function(t)
		Fixtures.serverForget("Unreliable.Emit")
		for _ = 1, 5 do
			unreliable:Emit("Emit", "lossy")
		end

		t.eventually(function()
			return Fixtures.serverCount("Unreliable.Emit") >= 1
		end, 5, "the unreliable lane may drop, so this reports rather than fails")
	end, 25)

	lossy:diagnostic("an unreliable broadcast reaches the client", function(t)
		inbox:reset("Unreliable.Recv")
		for index = 1, 5 do
			serverBroadcast(Protocol.Unreliable, "Recv", index)
		end

		t.eventually(function()
			return inbox:count("Unreliable.Recv") >= 1
		end, 5)
	end, 25)

	lossy:test("an unreliable packet is delivered once, not twice", function(t)
		inbox:reset("Unreliable.Recv")
		for index = 1, 10 do
			serverBroadcast(Protocol.Unreliable, "Recv", index)
		end

		t.wait(1.5)
		local received = inbox:count("Unreliable.Recv")
		t.log(string.format("sent 10, received %d", received))

		t.ok(received <= 10, string.format("received %d of 10, so the twin is bound twice", received))
	end, 30)

	lossy:test("an unreliable send to a channel that was never readied is dropped", function(t)
		local held = Pigeon.new(Protocol.UnreliableBuffer, { Unreliable = true })
		local seen = 0
		held:On("Recv", function()
			seen += 1
		end)

		ask("broadcastSeries", { carrier = Protocol.UnreliableBuffer, event = "Recv", count = 3 })
		t.wait(0.5)

		held:Init()

		t.never(function()
			return seen > 0
		end, 2, "a packet that may be dropped in transit has no business being replayed later")

		held:Destroy()
	end, 30)

	local health = TestKit.suite("Integration / transport health")
	table.insert(suites, health)

	health:test("the server holds a ready seat for every channel this client initialised", function(t)
		local diagnostics = ask("diagnostics")

		t.ok(diagnostics.readyChannels >= 10, "got " .. tostring(diagnostics.readyChannels))
		t.ok(diagnostics.readySeats >= 10, "got " .. tostring(diagnostics.readySeats))
	end)

	health:test("no call is left in flight on either side", function(t)
		t.eventually(function()
			return Network.Diagnostics().pending == 0
		end, 5, "the client should have settled everything")

		t.eventually(function()
			return ask("diagnostics").pending == 0
		end, 5, "and so should the server")
	end)

	health:test("held packets drain rather than accumulating", function(t)
		local diagnostics = ask("diagnostics")
		t.lt(diagnostics.bufferedPackets, 64 * 6, "buffers are capped and expire")
		t.lt(Network.Diagnostics().orphaned, 64 * 6, "so do orphans")
		t.eq(Network.Diagnostics().outbound, 0, "and the outbox emptied when the pool replicated")
	end)

	health:test("both sides agree on the pool size", function(t)
		t.eq(Network.GetRefCount(), ask("refCount"), "clients size the pool from the authority")
	end)

	return suites
end
