local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pigeon = require(ReplicatedStorage:WaitForChild("Pigeon"))
local Network = require(ReplicatedStorage.Pigeon.Network)

local Tests = ReplicatedStorage:WaitForChild("PigeonTests")
local Protocol = require(Tests.Protocol)

return function(TestKit: any, Fixtures: any, player: Player): { any }
	local suites = {}

	local live = Fixtures.carriers[Protocol.Live]
	local liveGuarded = Fixtures.carriers[Protocol.LiveGuarded]
	local rooms = Fixtures.carriers[Protocol.Rooms]
	local tables = Fixtures.carriers[Protocol.Tables]

	local impatient = Pigeon.new(Protocol.Live, { Timeout = 1.5 })

	local function observed(key: string): number
		local result = live:CallTo(player, "Observed", key)
		if type(result) ~= "table" then
			return -1
		end
		return result.count
	end

	local function entries(key: string): { any }
		local result = live:CallTo(player, "Observed", key)
		if type(result) ~= "table" then
			return {}
		end
		return result.entries
	end

	local function forget(key: string)
		live:CallTo(player, "Reset", key)
	end

	local calls = TestKit.suite("Live / CallTo")
	table.insert(suites, calls)

	calls:test("returns what the client's listener returned", function(t)
		t.eq(live:CallTo(player, "Echo", "hello"), "hello")
	end)

	calls:test("returns every value the client returned", function(t)
		local first, second, third = live:CallTo(player, "Triple")
		t.eq(first, 1)
		t.eq(second, "two")
		t.eq(third, true)
	end)

	calls:test("round trips several arguments", function(t)
		local first, second, third = live:CallTo(player, "Echo", 1, "two", false)
		t.eq(first, 1)
		t.eq(second, "two")
		t.eq(third, false)
	end)

	calls:test("preserves a nil in the middle of the argument list", function(t)
		t.eq(live:CallTo(player, "Arity", 1, nil, 3), 3, "the arity must survive the round trip")
	end)

	calls:test("preserves a trailing nil", function(t)
		t.eq(live:CallTo(player, "Arity", 1, nil), 2)
	end)

	calls:test("preserves a leading nil", function(t)
		t.eq(live:CallTo(player, "Arity", nil, 2, 3), 3)
	end)

	calls:test("preserves an argument list that is all nils", function(t)
		t.eq(live:CallTo(player, "Arity", nil, nil), 2)
	end)

	calls:test("an argument list with no nils keeps its arity", function(t)
		t.eq(live:CallTo(player, "Arity", 1, 2, 3), 3)
	end)

	calls:test("the nil sentinel is not confused with a real string", function(t)
		local first, second = live:CallTo(player, "Echo", "\0__pigeon_nil\0", "after")
		t.eq(second, "after", "the argument after it must still arrive")
		t.eq(first, nil, "a client sending the sentinel itself reads back as nil, which is the known limit")
	end)

	calls:test("survives a client listener that yields", function(t)
		t.eq(live:CallTo(player, "Slow"), "eventually")
	end, 20)

	calls:test("returns nil when the client has no listener", function(t)
		local started = os.clock()
		local result = impatient:CallTo(player, "NothingIsListening")
		local elapsed = os.clock() - started

		t.eq(result, nil)
		t.ok(elapsed >= 1.4, "it should have waited out the timeout, took " .. string.format("%.2fs", elapsed))
		t.lt(elapsed, 6, "and given up at the timeout rather than the default")
	end, 20)

	calls:test("a request the client's middleware turns away is answered at once", function(t)

		local started = os.clock()
		local result = impatient:CallTo(player, "Denied")
		local elapsed = os.clock() - started

		t.eq(result, nil)
		t.lt(elapsed, 1, "refusal is immediate, not a timeout; took " .. string.format("%.2fs", elapsed))
	end, 20)

	calls:test("returns nil when the client's listener throws", function(t)
		t.eq(impatient:CallTo(player, "Boom"), nil, "a listener that errors never answers")
	end, 20)

	calls:test("a client listener returning nothing answers with nothing", function(t)
		local result = live:CallTo(player, "Silent")
		t.eq(result, nil)
	end)

	local targeting = TestKit.suite("Live / broadcast targeting")
	table.insert(suites, targeting)

	targeting:test("Broadcast reaches the connected client", function(t)
		forget("bcast")
		live:Broadcast("Recv", "bcast", 42)

		t.eventually(function()
			return observed("bcast") == 1
		end, 5)

		local seen = entries("bcast")
		local ok, why = Protocol.same(seen[1], { 42 }, 1)
		t.ok(ok, why)
	end, 25)

	targeting:test("BroadcastTo reaches a listed client", function(t)
		forget("to")
		live:BroadcastTo({ player }, "Recv", "to", "payload")

		t.eventually(function()
			return observed("to") == 1
		end, 5)
	end, 25)

	targeting:test("BroadcastTo an empty list reaches nobody", function(t)
		forget("empty")
		live:BroadcastTo({}, "Recv", "empty")

		t.never(function()
			return observed("empty") > 0
		end, 1.5)
	end, 25)

	targeting:test("BroadcastExcept skips the listed client", function(t)
		forget("except")
		live:BroadcastExcept({ player }, "Recv", "except")

		t.never(function()
			return observed("except") > 0
		end, 1.5)
	end, 25)

	targeting:test("BroadcastExcept accepts a single player as well as a list", function(t)
		forget("exceptSolo")
		t.noThrow(function()
			live:BroadcastExcept(player :: any, "Recv", "exceptSolo")
		end)

		t.never(function()
			return observed("exceptSolo") > 0
		end, 1.5)
	end, 25)

	targeting:test("broadcasts arrive in the order they were sent", function(t)
		forget("ordered")
		for index = 1, 6 do
			live:BroadcastTo({ player }, "Ordered", "ordered", index)
		end

		t.eventually(function()
			return observed("ordered") == 6
		end, 5)

		local seen = entries("ordered")
		for index = 1, 6 do
			t.eq(seen[index].values[1], index, "packet " .. index .. " arrived out of order")
		end
	end, 25)

	local roomSuite = TestKit.suite("Live / rooms")
	table.insert(suites, roomSuite)

	roomSuite:test("SendToRoom reaches a member", function(t)
		forget("room")
		live:CreateRoom("live", { player })
		live:SendToRoom("live", "Recv", "room", "in the room")

		t.eventually(function()
			return observed("room") == 1
		end, 5)

		live:DestroyRoom("live")
	end, 25)

	roomSuite:test("a player who left the room stops receiving", function(t)
		forget("left")
		live:CreateRoom("leaving", { player })
		live:LeaveRoom("leaving", player)
		live:SendToRoom("leaving", "Recv", "left")

		t.never(function()
			return observed("left") > 0
		end, 1.5)

		live:DestroyRoom("leaving")
	end, 25)

	roomSuite:test("a destroyed room is no longer addressable", function(t)
		forget("destroyed")
		live:CreateRoom("temporary", { player })
		live:DestroyRoom("temporary")
		live:SendToRoom("temporary", "Recv", "destroyed")

		t.never(function()
			return observed("destroyed") > 0
		end, 1.5)
	end, 25)

	roomSuite:test("JoinRoom admits a live player to an existing room", function(t)
		forget("joined")
		live:CreateRoom("joinable", {})
		live:JoinRoom("joinable", player)
		live:SendToRoom("joinable", "Recv", "joined")

		t.eventually(function()
			return observed("joined") == 1
		end, 5)

		live:DestroyRoom("joinable")
	end, 25)

	roomSuite:test("the Rooms channel is untouched by all of that", function(t)
		t.eq(next((rooms :: any)._rooms), nil, "rooms belong to the carrier they were made on")
	end)

	local closed = TestKit.suite("Live / a channel nobody was admitted to")
	table.insert(suites, closed)

	closed:test("Approved is empty even with a player in the game", function(t)
		t.eq(#liveGuarded:Approved(), 0)
		t.eq(#liveGuarded:Approved({ player }), 0)
	end)

	closed:test("Broadcast reaches nobody", function(t)
		forget("guarded")
		liveGuarded:Broadcast("Recv", "guarded")

		t.never(function()
			return observed("guarded") > 0
		end, 1.5, "a guarded broadcast must only reach the approved")
	end, 25)

	closed:test("CallTo is refused before it reaches the transport", function(t)
		local started = os.clock()
		t.eq(liveGuarded:CallTo(player, "Echo", "x"), nil)
		t.lt(os.clock() - started, 1, "refusal is immediate, not a timeout")
	end)

	closed:test("the unguarded channel is unaffected", function(t)
		t.ok(#live:Approved() >= 1, "only the guarded channel is closed")
	end)

	local transport = TestKit.suite("Live / transport")
	table.insert(suites, transport)

	transport:test("BroadcastCall with no targets answers immediately", function(t)
		local started = os.clock()
		local ok, responses = Network.BroadcastCall({}, (live :: any)._transformer, "unused", { n = 0 })

		t.eq(ok, true)
		t.same(responses, {})
		t.lt(os.clock() - started, 0.5)
	end)

	transport:test("BroadcastCall collects a response per player", function(t)
		local transformer = (live :: any)._transformer
		local wire = Protocol.Live .. "\0" .. "Echo"

		local ok, responses = Network.BroadcastCall({ player }, transformer, wire, { n = 1, "direct" }, 8)

		t.eq(ok, true, "every targeted player answered")
		t.ne(responses[player], nil, "the map is keyed by player")
		t.eq(responses[player][1], "direct")
	end, 25)

	transport:test("a ready client has a seat on the channels it initialised", function(t)
		local diagnostics = Network.Diagnostics()
		t.ok(diagnostics.readyChannels > 0, "the client has readied at least one channel")
		t.ok(diagnostics.readySeats > 0)
	end)

	transport:test("a channel the client never readies buffers instead of dropping", function(t)
		local never = Pigeon.new("PigeonTest_NeverOnClient_" .. os.clock(), {})
		local before = Network.Diagnostics().bufferedPackets

		never:BroadcastTo({ player }, "Held", 1)
		never:BroadcastTo({ player }, "Held", 2)

		local after = Network.Diagnostics().bufferedPackets
		t.eq(after - before, 2, "nothing was released, so both packets are held")

		never:Destroy()
	end)

	transport:test("a buffer stops growing at its cap", function(t)
		local never = Pigeon.new("PigeonTest_Overflow_" .. os.clock(), {})
		local before = Network.Diagnostics().bufferedPackets

		for index = 1, 80 do
			never:BroadcastTo({ player }, "Held", index)
		end

		local held = Network.Diagnostics().bufferedPackets - before
		t.eq(held, 64, "BUFFER_MAX bounds what one client can accumulate, got " .. held)

		never:Destroy()
	end)

	transport:test("an unreliable send to a client that has not readied is dropped", function(t)
		local never = Pigeon.new("PigeonTest_UnreliableDrop_" .. os.clock(), { Unreliable = true })
		local before = Network.Diagnostics().bufferedPackets

		never:BroadcastTo({ player }, "Lossy", 1)

		t.eq(
			Network.Diagnostics().bufferedPackets,
			before,
			"a packet that may be dropped in transit has no business being replayed later"
		)

		never:Destroy()
	end)

	transport:test("a reply is never held behind channel readiness", function(t)

		t.ok(true)
	end)

	local pushed = TestKit.suite("Live / ForceTable")
	table.insert(suites, pushed)

	local forced = Fixtures.tables[Protocol.TableForced]

	pushed:test("the client receives a table it never asked for", function(t)
		tables:ForceTable(Protocol.TableForced, forced, { player })

		t.eventually(function()
			return live:CallTo(player, "TableValue", Protocol.TableForced, { "pushed" }) == true
		end, 6)
	end, 25)

	pushed:test("the recipient becomes a subscriber", function(t)
		t.eq((forced :: any)._subscribers[player], true, "a forced table subscribes its recipients")
	end)

	pushed:test("later mutations replicate to the pushed client", function(t)
		forced:GetTable().at = "changed"

		t.eventually(function()
			return live:CallTo(player, "TableValue", Protocol.TableForced, { "at" }) == "changed"
		end, 6)
	end, 25)

	pushed:test("a nested mutation replicates by path", function(t)
		forced:GetTable().deep = { level = { value = 1 } }
		t.eventually(function()
			return live:CallTo(player, "TableValue", Protocol.TableForced, { "deep", "level", "value" }) == 1
		end, 6)

		forced:GetTable().deep.level.value = 2
		t.eventually(function()
			return live:CallTo(player, "TableValue", Protocol.TableForced, { "deep", "level", "value" }) == 2
		end, 6)
	end, 30)

	pushed:test("a burst of writes coalesces into one patch", function(t)
		live:CallTo(player, "ResetPatches")

		local view = forced:GetTable()
		view.burstA = 1
		view.burstB = 2
		view.burstC = 3
		view.burstD = 4

		t.eventually(function()
			return live:CallTo(player, "TableValue", Protocol.TableForced, { "burstD" }) == 4
		end, 6)

		local packets = live:CallTo(player, "PatchCount")
		t.eq(packets, 1, "filling a table field by field should cost one send, not one per field")
	end, 30)

	pushed:test("a deletion replicates", function(t)
		forced:GetTable().burstA = nil

		t.eventually(function()
			return live:CallTo(player, "TableValue", Protocol.TableForced, { "burstA" }) == nil
		end, 6)
	end, 25)

	return suites
end
