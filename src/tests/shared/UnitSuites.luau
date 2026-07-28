local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pigeon = require(ReplicatedStorage:WaitForChild("Pigeon"))
local Network = require(ReplicatedStorage.Pigeon.Network)

local FAKE_PLAYER = setmetatable({}, { __tostring = function() return "FakePlayer" end }) :: any

local function nameFor(where: string, label: string): string
	return string.format("PigeonUnit_%s_%s", where, label)
end

return function(TestKit: any, where: string): { any }
	local suites = {}
	local counter = 0

	local function unique(label: string): string
		counter += 1
		return nameFor(where, label .. "_" .. counter)
	end

	local transformers = TestKit.suite("Transformer")
	table.insert(suites, transformers)

	transformers:test("generates a uuid when none is given", function(t)
		local first = Pigeon.Transformer()
		local second = Pigeon.Transformer()

		t.isType(first.uuid, "string")
		t.gt(#first.uuid, 0)
		t.eq(first.destroyed, false)
		t.ne(first.uuid, second.uuid, "generated uuids must not collide")

		first:Destroy()
		second:Destroy()
	end)

	transformers:test("adopts an explicit uuid", function(t)
		local transformer = Pigeon.Transformer("PigeonUnit_ExplicitUuid")
		t.eq(transformer.uuid, "PigeonUnit_ExplicitUuid")
		transformer:Destroy()
	end)

	transformers:test("Track runs the teardown on Destroy", function(t)
		local transformer = Pigeon.Transformer()
		local ran = 0
		transformer:Track(function()
			ran += 1
		end)

		t.eq(ran, 0, "the teardown must not run before Destroy")
		transformer:Destroy()
		t.eq(ran, 1)
	end)

	transformers:test("the handle Track returns removes the teardown again", function(t)
		local transformer = Pigeon.Transformer()
		local ran = false
		local untrack = transformer:Track(function()
			ran = true
		end)

		untrack()
		transformer:Destroy()
		t.no(ran, "an untracked teardown must not run")
	end)

	transformers:test("untracking keeps the teardown list from growing", function(t)
		local transformer = Pigeon.Transformer()
		local before = #(transformer :: any)._teardown

		local handles = {}
		for index = 1, 5 do
			handles[index] = transformer:Track(function() end)
		end
		t.eq(#(transformer :: any)._teardown, before + 5)

		for _, untrack in handles do
			untrack()
		end
		t.eq(#(transformer :: any)._teardown, before, "every entry should have been removed")

		transformer:Destroy()
	end)

	transformers:test("Track on an already destroyed transformer runs the teardown inline", function(t)
		local transformer = Pigeon.Transformer()
		transformer:Destroy()

		local ran = false
		local untrack = transformer:Track(function()
			ran = true
		end)

		t.ok(ran, "a late registration must not leak a live connection")
		t.isType(untrack, "function")
		t.noThrow(untrack, "the returned handle must still be callable")
	end)

	transformers:test("Destroy is idempotent", function(t)
		local transformer = Pigeon.Transformer()
		local ran = 0
		transformer:Track(function()
			ran += 1
		end)

		transformer:Destroy()
		transformer:Destroy()
		transformer:Destroy()

		t.eq(ran, 1, "teardowns must run exactly once")
		t.eq(transformer.destroyed, true)
	end)

	transformers:test("a failing teardown does not stop the others", function(t)
		local transformer = Pigeon.Transformer()
		local after = false

		transformer:Track(function()
			error("deliberate teardown failure")
		end)
		transformer:Track(function()
			after = true
		end)

		transformer:Destroy()
		t.ok(after, "the teardown after a failing one must still run")
	end)

	transformers:test("a teardown may untrack itself while it runs", function(t)
		local transformer = Pigeon.Transformer()
		local order = {}

		local first: any
		first = transformer:Track(function()
			table.insert(order, 1)
			first()
		end)
		transformer:Track(function()
			table.insert(order, 2)
		end)

		transformer:Destroy()
		t.same(order, { 1, 2 }, "iterating a snapshot must not skip the entry after a self-removal")
	end)

	transformers:test("Register and Unregister balance the known count", function(t)
		local before = Network.KnownTransformers

		local first = Pigeon.Transformer()
		local second = Pigeon.Transformer()
		t.eq(Network.KnownTransformers, before + 2)

		first:Destroy()
		second:Destroy()
		t.eq(Network.KnownTransformers, before, "the count must return to where it started")
	end)

	transformers:test("a double Destroy does not double-decrement the count", function(t)
		local before = Network.KnownTransformers
		local transformer = Pigeon.Transformer()

		transformer:Destroy()
		transformer:Destroy()

		t.eq(Network.KnownTransformers, before, "a second Destroy must not corrupt the pool size")
	end)

	transformers:test("the same uuid always resolves to the same ref", function(t)
		local first = Pigeon.Transformer("PigeonUnit_StableBucket")
		local second = Pigeon.Transformer("PigeonUnit_StableBucket")

		local left = Pigeon.GetRef(first)
		local right = Pigeon.GetRef(second)

		t.eq(left, right, "bucketing must be a pure function of the uuid")
		t.ok(left:IsA("RemoteEvent"))

		first:Destroy()
		second:Destroy()
	end)

	transformers:test("GetRef is stable across repeated calls", function(t)
		local transformer = Pigeon.Transformer("PigeonUnit_RepeatBucket")
		t.eq(Pigeon.GetRef(transformer), Pigeon.GetRef(transformer))
		transformer:Destroy()
	end)

	local guards = TestKit.suite("StagedTable / accepted data")
	table.insert(suites, guards)

	guards:test("GetTable exposes a live view", function(t)
		local staged = Pigeon.StagedTable({ a = 1 })
		local view = staged:GetTable()

		t.eq(view.a, 1)
		view.b = 2
		t.eq(view.b, 2)
	end)

	guards:test("initial contents are copied, not aliased", function(t)
		local source = { a = 1, nested = { x = 1 } }
		local staged = Pigeon.StagedTable(source)

		source.a = 99
		source.nested.x = 99

		t.eq(staged:GetTable().a, 1, "the top level must be a copy")
		t.eq(staged:GetTable().nested.x, 1, "nested levels must be copies too")
	end)

	guards:test("a stored table is copied, so the caller's reference cannot leak in", function(t)
		local staged = Pigeon.StagedTable()
		local source = { x = 1 }

		staged:GetTable().held = source
		source.x = 99

		t.eq(staged:GetTable().held.x, 1, "what replicates must be the sanitised copy")
	end)

	guards:test("accepts every documented Roblox value type", function(t)
		local view = Pigeon.StagedTable():GetTable()

		t.noThrow(function()
			view.flag = true
			view.count = 7
			view.text = "hello"
			view.blob = buffer.fromstring("bytes")
			view.vector = Vector3.new(1, 2, 3)
			view.cframe = CFrame.new(4, 5, 6)
			view.colour = Color3.new(1, 0, 0)
			view.brick = BrickColor.new("Bright red")
			view.scale = UDim2.fromScale(1, 0.5)
			view.offset = UDim.new(0, 8)
			view.rect = Rect.new(0, 0, 1, 1)
			view.range = NumberRange.new(1, 2)
			view.sequence = NumberSequence.new(0, 1)
			view.gradient = ColorSequence.new(Color3.new(), Color3.new(1, 1, 1))
			view.tween = TweenInfo.new(0.5)
			view.key = Enum.KeyCode.A
			view.stamp = DateTime.now()
			view.ray = Ray.new(Vector3.zero, Vector3.yAxis)
			view.faces = Faces.new(Enum.NormalId.Top)
			view.axes = Axes.new(Enum.Axis.X)
			view.font = Font.fromEnum(Enum.Font.Gotham)
		end)

		t.eq(view.vector, Vector3.new(1, 2, 3))
		t.eq(view.key, Enum.KeyCode.A)
	end)

	guards:test("rejects functions", function(t)
		local view = Pigeon.StagedTable():GetTable()
		t.throws(function()
			view.behaviour = function() end
		end, "ERR_STAGE_BEHAVIOUR")
	end)

	guards:test("rejects threads", function(t)
		local view = Pigeon.StagedTable():GetTable()
		t.throws(function()
			view.thread = coroutine.create(function() end)
		end, "ERR_STAGE_BEHAVIOUR")
	end)

	guards:test("rejects Instances", function(t)
		local view = Pigeon.StagedTable():GetTable()
		local folder = Instance.new("Folder")
		t.throws(function()
			view.instance = folder
		end, "ERR_STAGE_UNSUPPORTED")
		folder:Destroy()
	end)

	guards:test("rejects tables carrying a metatable", function(t)
		local view = Pigeon.StagedTable():GetTable()
		t.throws(function()
			view.proxyish = setmetatable({}, { __index = function() end })
		end, "ERR_STAGE_METATABLE")
	end)

	guards:test("rejects cycles", function(t)
		local view = Pigeon.StagedTable():GetTable()
		local cyclic: any = { name = "loop" }
		cyclic.self = cyclic

		t.throws(function()
			view.cyclic = cyclic
		end, "ERR_STAGE_CYCLE")
	end)

	guards:test("accepts the same table twice on different branches", function(t)
		local view = Pigeon.StagedTable():GetTable()
		local shared = { x = 1 }

		t.noThrow(function()
			view.pair = { left = shared, right = shared }
		end, "a repeated reference is not a cycle")
	end)

	guards:test("rejects table keys", function(t)
		local view = Pigeon.StagedTable():GetTable()
		t.throws(function()
			view.keyed = { [{}] = "value" }
		end, "ERR_STAGE_TABLE_KEY")
	end)

	guards:test("rejects function keys", function(t)
		local view = Pigeon.StagedTable():GetTable()
		t.throws(function()
			view.keyed = { [function() end] = "value" }
		end, "ERR_STAGE_BEHAVIOUR")
	end)

	guards:test("rejects Instance keys", function(t)
		local view = Pigeon.StagedTable():GetTable()
		local folder = Instance.new("Folder")
		t.throws(function()
			view.keyed = { [folder] = "value" }
		end, "ERR_STAGE_UNSUPPORTED")
		folder:Destroy()
	end)

	guards:test("names the offending path in the error", function(t)
		local staged = Pigeon.StagedTable({ stats = { combat = {} } })
		local message = t.throws(function()
			staged:GetTable().stats.combat.weapon = Instance.new("Part")
		end)
		t.matches(message, "root.stats.combat.weapon")
	end)

	guards:test("reports root for a top-level write", function(t)
		local staged = Pigeon.StagedTable()
		local message = t.throws(function()
			staged:GetTable().bad = Instance.new("Part")
		end)
		t.matches(message, "root.bad")
	end)

	guards:test("a rejected write leaves no partial state", function(t)
		local staged = Pigeon.StagedTable()
		local view = staged:GetTable()

		pcall(function()
			view.partial = { ok = 1, bad = Instance.new("Part") }
		end)

		t.eq(view.partial, nil, "nothing should have been stored")
	end)

	local proxy = TestKit.suite("StagedTable / the view")
	table.insert(suites, proxy)

	proxy:test("the view is a userdata proxy, not a table", function(t)
		t.isType(Pigeon.StagedTable():GetTable(), "userdata")
	end)

	proxy:test("writes report the full path from the root", function(t)
		local staged = Pigeon.StagedTable({ a = { b = {} } })
		local seen = {}
		;(staged :: any)._onWrite = function(path: { any }, value: any)
			table.insert(seen, { path = path, value = value })
		end

		staged:GetTable().a.b.c = 7

		t.eq(#seen, 1)
		t.same(seen[1].path, { "a", "b", "c" }, "nested mutation must replicate as precisely as top-level")
		t.eq(seen[1].value, 7)
	end)

	proxy:test("a top-level write reports a single-key path", function(t)
		local staged = Pigeon.StagedTable()
		local seen: any = nil
		;(staged :: any)._onWrite = function(path: { any }, value: any)
			seen = { path = path, value = value }
		end

		staged:GetTable().solo = "x"

		t.same(seen.path, { "solo" })
		t.eq(seen.value, "x")
	end)

	proxy:test("writing a table reports its encoded envelope", function(t)
		local staged = Pigeon.StagedTable()
		local seen: any = nil
		;(staged :: any)._onWrite = function(_path, value)
			seen = value
		end

		staged:GetTable().payload = { only = 1 }

		t.same(seen.K, { "only" }, "tables travel as parallel key/value arrays")
		t.same(seen.V, { 1 })
	end)

	proxy:test("deleting a key writes nil through", function(t)
		local staged = Pigeon.StagedTable({ a = 1 })
		local seen: any = nil
		;(staged :: any)._onWrite = function(path, value)
			seen = { path = path, value = value }
		end

		staged:GetTable().a = nil

		t.eq(staged:GetTable().a, nil)
		t.same(seen.path, { "a" })
		t.eq(seen.value, nil, "a deletion must replicate as a nil, not be skipped")
	end)

	proxy:test("__len reflects the array part", function(t)
		local view = Pigeon.StagedTable({ 1, 2, 3 }):GetTable()
		t.eq(#view, 3)
	end)

	proxy:test("__iter walks the store", function(t)
		local view = Pigeon.StagedTable({ a = 1, b = 2, c = 3 }):GetTable()

		local count, total = 0, 0
		for _, value in view do
			count += 1
			total += value
		end

		t.eq(count, 3)
		t.eq(total, 6)
	end)

	proxy:test("nested reads hand back the same view each time", function(t)
		local view = Pigeon.StagedTable({ a = { x = 1 } }):GetTable()
		t.eq(view.a, view.a, "child views are cached")
	end)

	proxy:test("replacing a nested table invalidates its cached view", function(t)
		local view = Pigeon.StagedTable({ a = { x = 1 } }):GetTable()
		local before = view.a
		t.eq(before.x, 1)

		view.a = { x = 2 }

		t.eq(view.a.x, 2, "a write through the proxy must drop the stale child")
	end)

	proxy:test("nested writes go through the same validation", function(t)
		local view = Pigeon.StagedTable({ a = {} }):GetTable()
		t.throws(function()
			view.a.bad = function() end
		end, "ERR_STAGE_BEHAVIOUR")
	end)

	proxy:known(
		"a cached child view follows its table being replaced by ApplyPatches",
		"wrap() caches child proxies by key and never re-checks that the raw table is still the same object, so a client that held a nested view before a whole-subtable patch keeps reading the old table",
		function(t)
			local staged = Pigeon.StagedTable({ a = { x = 1 } })
			local view = staged:GetTable()

			local held = view.a
			t.eq(held.x, 1)

			staged:ApplyPatches({ { path = { "a" }, value = { K = { "x" }, V = { 2 } } } })

			t.eq(view.a.x, 2, "the view should show the patched value")
		end
	)

	proxy:known(
		"a cached child view follows ApplySnapshot",
		"ApplySnapshot clears and repopulates the raw store with brand new nested tables while wrap()'s child cache still points at the old ones",
		function(t)
			local staged = Pigeon.StagedTable({ a = { x = 1 } })
			local view = staged:GetTable()

			local held = view.a
			t.eq(held.x, 1)

			local replacement = Pigeon.StagedTable({ a = { x = 2 } })
			staged:ApplySnapshot(replacement:Snapshot())

			t.eq(view.a.x, 2, "the view should show the new snapshot")
		end
	)

	local wire = TestKit.suite("StagedTable / snapshots and patches")
	table.insert(suites, wire)

	local function roundTrip(contents: { [any]: any }): any
		local source = Pigeon.StagedTable(contents)
		local target = Pigeon.StagedTable()
		target:ApplySnapshot(source:Snapshot())
		return target:GetTable()
	end

	wire:test("a snapshot round trips primitives", function(t)
		local view = roundTrip({ n = 1, s = "x", b = true })
		t.eq(view.n, 1)
		t.eq(view.s, "x")
		t.eq(view.b, true)
	end)

	wire:test("a snapshot round trips nested structure", function(t)
		local view = roundTrip({ nested = { deep = { 1, 2, 3 } } })
		t.eq(view.nested.deep[2], 2)
		t.eq(#view.nested.deep, 3)
	end)

	wire:test("a snapshot round trips value types", function(t)
		local view = roundTrip({ where = Vector3.new(1, 2, 3), key = Enum.KeyCode.Q })
		t.eq(view.where, Vector3.new(1, 2, 3))
		t.eq(view.key, Enum.KeyCode.Q)
	end)

	wire:test("a snapshot round trips a table mixing key types", function(t)
		local view = roundTrip({
			mixed = { [1] = "one", ["named"] = "two", [true] = "three", [2.5] = "four" },
		})

		t.eq(view.mixed[1], "one", "integer keys survive")
		t.eq(view.mixed.named, "two", "string keys survive")
		t.eq(view.mixed[true], "three", "boolean keys survive")
		t.eq(view.mixed[2.5], "four", "fractional keys survive")
	end)

	wire:test("a snapshot round trips an empty table", function(t)
		local view = roundTrip({ empty = {} })

		local count = 0
		for _ in view.empty do
			count += 1
		end

		t.ne(view.empty, nil, "the key must still exist")
		t.eq(count, 0)
	end)

	wire:test("a snapshot replaces rather than merges", function(t)
		local target = Pigeon.StagedTable({ stale = "gone" })
		local source = Pigeon.StagedTable({ fresh = "here" })

		target:ApplySnapshot(source:Snapshot())

		t.eq(target:GetTable().stale, nil, "ApplySnapshot must clear the old contents")
		t.eq(target:GetTable().fresh, "here")
	end)

	wire:test("ApplyPatches folds in top-level and nested changes", function(t)
		local staged = Pigeon.StagedTable({ a = { b = 1 } })
		staged:ApplyPatches({
			{ path = { "a", "b" }, value = 2 },
			{ path = { "c" }, value = "new" },
		})

		t.eq(staged:GetTable().a.b, 2)
		t.eq(staged:GetTable().c, "new")
	end)

	wire:test("ApplyPatches creates missing intermediate tables", function(t)
		local staged = Pigeon.StagedTable()
		staged:ApplyPatches({ { path = { "x", "y", "z" }, value = 9 } })
		t.eq(staged:GetTable().x.y.z, 9)
	end)

	wire:test("ApplyPatches replaces a non-table on the way down", function(t)
		local staged = Pigeon.StagedTable({ x = "scalar" })
		staged:ApplyPatches({ { path = { "x", "y" }, value = 1 } })
		t.eq(staged:GetTable().x.y, 1, "descend must rebuild a container over a scalar")
	end)

	wire:test("ApplyPatches decodes table values", function(t)
		local staged = Pigeon.StagedTable()
		staged:ApplyPatches({ { path = { "t" }, value = { K = { "k" }, V = { "v" } } } })
		t.eq(staged:GetTable().t.k, "v")
	end)

	wire:test("ApplyPatches applies a deletion", function(t)
		local staged = Pigeon.StagedTable({ gone = 1 })
		staged:ApplyPatches({ { path = { "gone" } } })
		t.eq(staged:GetTable().gone, nil)
	end)

	wire:test("ApplyPatches applies in order", function(t)
		local staged = Pigeon.StagedTable()
		staged:ApplyPatches({
			{ path = { "v" }, value = 1 },
			{ path = { "v" }, value = 2 },
			{ path = { "v" }, value = 3 },
		})
		t.eq(staged:GetTable().v, 3, "the last write in a batch wins")
	end)

	wire:test("ApplyPatches does not echo back out as local writes", function(t)
		local staged = Pigeon.StagedTable()
		local writes = 0
		;(staged :: any)._onWrite = function()
			writes += 1
		end

		staged:ApplyPatches({ { path = { "a" }, value = 1 } })
		staged:ApplySnapshot(Pigeon.StagedTable({ b = 2 }):Snapshot())

		t.eq(writes, 0, "folding in server updates must not look like a local mutation")
	end)

	local access = TestKit.suite("StagedTable / guards and release")
	table.insert(suites, access)

	access:test("capture is allowed when no guard is installed", function(t)
		t.eq(Pigeon.StagedTable():CanCapture(FAKE_PLAYER), true)
	end)

	access:test("release is allowed when no guard is installed", function(t)
		t.eq(Pigeon.StagedTable():CanRelease(FAKE_PLAYER), true)
	end)

	access:test("a capture guard returning false blocks", function(t)
		local staged = Pigeon.StagedTable()
		staged:UseCapture(function()
			return false
		end)
		t.eq(staged:CanCapture(FAKE_PLAYER), false)
	end)

	access:test("a capture guard returning nil allows", function(t)
		local staged = Pigeon.StagedTable()
		staged:UseCapture(function()
			return nil
		end)
		t.eq(staged:CanCapture(FAKE_PLAYER), true, "only an explicit false blocks")
	end)

	access:test("a capture guard that errors blocks", function(t)
		local staged = Pigeon.StagedTable()
		staged:UseCapture(function()
			error("guard blew up")
		end)
		t.eq(staged:CanCapture(FAKE_PLAYER), false, "a broken guard must fail closed")
	end)

	access:test("every capture guard must agree", function(t)
		local staged = Pigeon.StagedTable()
		local reached = false

		staged:UseCapture(function()
			return true
		end)
		staged:UseCapture(function()
			return false
		end)
		staged:UseCapture(function()
			reached = true
			return true
		end)

		t.eq(staged:CanCapture(FAKE_PLAYER), false)
		t.no(reached, "the chain should stop at the first refusal")
	end)

	access:test("a guard is handed the player and the published id", function(t)
		local staged = Pigeon.StagedTable()
		;(staged :: any)._id = "published-id"

		local seenPlayer, seenId
		staged:UseCapture(function(player: any, id: any)
			seenPlayer, seenId = player, id
			return true
		end)

		staged:CanCapture(FAKE_PLAYER)

		t.eq(seenPlayer, FAKE_PLAYER)
		t.eq(seenId, "published-id")
	end)

	access:test("a release guard returning false blocks", function(t)
		local staged = Pigeon.StagedTable()
		staged:UseRelease(function()
			return false
		end)
		t.eq(staged:CanRelease(FAKE_PLAYER), false)
	end)

	access:test("a release guard that errors blocks", function(t)
		local staged = Pigeon.StagedTable()
		staged:UseRelease(function()
			error("guard blew up")
		end)
		t.eq(staged:CanRelease(FAKE_PLAYER), false)
	end)

	access:test("capture and release guards are independent", function(t)
		local staged = Pigeon.StagedTable()
		staged:UseCapture(function()
			return false
		end)

		t.eq(staged:CanCapture(FAKE_PLAYER), false)
		t.eq(staged:CanRelease(FAKE_PLAYER), true)
	end)

	access:test("Release fires its hook exactly once", function(t)
		local staged = Pigeon.StagedTable()
		local released = 0
		;(staged :: any)._onRelease = function()
			released += 1
		end

		staged:Release()
		staged:Release()
		staged:Release()

		t.eq(released, 1)
		t.eq((staged :: any)._released, true)
	end)

	access:test("Release without a hook is harmless", function(t)
		t.noThrow(function()
			Pigeon.StagedTable():Release()
		end)
	end)

	local module = TestKit.suite("Pigeon / module surface")
	table.insert(suites, module)

	module:test("exposes Network and Types", function(t)
		t.ne(Pigeon.Network, nil)
		t.ne(Pigeon.Types, nil)
	end)

	module:test("new caches by name", function(t)
		local name = unique("Cache")
		local first = Pigeon.new(name)
		local second = Pigeon.new(name)

		t.eq(first, second, "a bare name is a lookup")
		first:Destroy()
	end)

	module:test("options bypass the cache", function(t)
		local name = unique("Uncached")
		local cached = Pigeon.new(name)
		local first = Pigeon.new(name, {})
		local second = Pigeon.new(name, {})

		t.ne(first, cached, "options describe one particular carrier")
		t.ne(first, second, "each call with options builds a fresh carrier")

		cached:Destroy()
		first:Destroy()
		second:Destroy()
	end)

	module:test("a destroyed carrier is evicted from the cache", function(t)
		local name = unique("Evict")
		local first = Pigeon.new(name)
		first:Destroy()

		local second = Pigeon.new(name)
		t.ne(first, second, "a dead carrier must never be handed back")
		t.no((second :: any)._dropped)

		second:Destroy()
	end)

	module:test("a carrier whose transformer died is not handed back", function(t)
		local name = unique("TransformerDied")
		local first = Pigeon.new(name)
		;(first :: any)._transformer:Destroy()

		local second = Pigeon.new(name)
		t.ne(first, second)

		second:Destroy()
	end)

	module:test("a name is required", function(t)
		t.throws(function()
			Pigeon.new("")
		end, "ERR_NO_NAME")
		t.throws(function()
			Pigeon.new(nil :: any)
		end, "ERR_NO_NAME")
		t.throws(function()
			Pigeon.new(42 :: any)
		end, "ERR_NO_NAME")
	end)

	module:test("options.Transformer must actually be a transformer", function(t)
		local name = unique("BadTransformer")
		t.throws(function()
			Pigeon.new(name, { Transformer = 5 :: any })
		end, "ERR_NO_TRANSFORMER")
		t.throws(function()
			Pigeon.new(name, { Transformer = {} :: any })
		end, "ERR_NO_TRANSFORMER")
		t.throws(function()
			Pigeon.new(name, { Transformer = { uuid = 5 } :: any })
		end, "ERR_NO_TRANSFORMER")
	end)

	module:test("Unreliable and Timeout are carried onto the carrier", function(t)
		local carrier = Pigeon.new(unique("Options"), { Unreliable = true, Timeout = 2.5 })
		t.eq(carrier.Unreliable, true)
		t.eq((carrier :: any).Timeout, 2.5)
		carrier:Destroy()

		local plain = Pigeon.new(unique("Defaults"))
		t.eq(plain.Unreliable, false, "reliable by default")
		t.eq((plain :: any).Timeout, nil)
		plain:Destroy()
	end)

	module:test("a carrier owns the transformer it made for itself", function(t)
		local carrier = Pigeon.new(unique("Owned"))
		local transformer = (carrier :: any)._transformer

		t.eq((carrier :: any)._ownsTransformer, true)
		carrier:Destroy()
		t.eq(transformer.destroyed, true, "an unshared transformer has no other owner")
	end)

	module:test("a supplied transformer outlives its carrier", function(t)
		local transformer = Pigeon.Transformer()
		local carrier = Pigeon.new(unique("Borrowed"), { Transformer = transformer })

		t.eq((carrier :: any)._ownsTransformer, false)
		carrier:Destroy()
		t.eq(transformer.destroyed, false, "a transformer passed in belongs to the caller")

		transformer:Destroy()
	end)

	module:test("destroying a shared transformer drops every carrier on it", function(t)
		local transformer = Pigeon.Transformer()
		local first = Pigeon.new(unique("ClusterA"), { Transformer = transformer })
		local second = Pigeon.new(unique("ClusterB"), { Transformer = transformer })

		transformer:Destroy()

		t.eq((first :: any)._dropped, true)
		t.eq((second :: any)._dropped, true)
	end)

	module:test("a carrier built on a dead transformer is inert from the start", function(t)
		local transformer = Pigeon.Transformer()
		transformer:Destroy()

		local carrier = Pigeon.new(unique("DeadOnArrival"), { Transformer = transformer })
		t.eq((carrier :: any)._dropped, true, "Track ran the teardown inline during construction")
	end)

	module:test("Destroy is idempotent", function(t)
		local carrier = Pigeon.new(unique("DoubleDrop"))
		carrier:Destroy()
		t.noThrow(function()
			carrier:Destroy()
			carrier:Destroy()
		end)
	end)

	module:test("Destroy clears the carrier's state", function(t)
		local carrier = Pigeon.new(unique("Cleared"), {})
		carrier:On("evt", function() end)
		carrier:UseIncoming(function() end)
		carrier:UseOutgoing(function() end)

		carrier:Destroy()

		t.eq(next((carrier :: any)._listeners), nil)
		t.eq(next((carrier :: any)._bound), nil)
		t.eq(next((carrier :: any)._incoming), nil, "middleware holds user closures and must be released")
		t.eq(next((carrier :: any)._outgoing), nil)
		t.ne((carrier :: any)._transformer, nil, "alive() still reads the transformer on a dead carrier")
		t.eq((carrier :: any)._name ~= nil, true)
	end)

	module:test("Transformer adopts the uuid it is given", function(t)
		local transformer = Pigeon.Transformer("PigeonUnit_ModuleUuid")
		t.eq(transformer.uuid, "PigeonUnit_ModuleUuid")
		transformer:Destroy()
	end)

	module:test("GetRef resolves a RemoteEvent", function(t)
		local transformer = Pigeon.Transformer("PigeonUnit_ModuleRef")
		local ref = Pigeon.GetRef(transformer)

		t.isType(ref, "Instance")
		t.ok(ref:IsA("RemoteEvent"))

		transformer:Destroy()
	end)

	module:test("StagedTable seeds from what it is handed", function(t)
		local staged = Pigeon.StagedTable({ seeded = true })
		t.eq(staged:GetTable().seeded, true)

		local empty = Pigeon.StagedTable()
		t.eq(next((empty :: any)._store), nil)
	end)

	local binding = TestKit.suite("Carrier / listener bookkeeping")
	table.insert(suites, binding)

	binding:test("On binds the transport and Off unbinds it", function(t)
		local carrier = Pigeon.new(unique("Binding"), {})
		local handler = function() end

		carrier:On("evt", handler)
		t.ne((carrier :: any)._bound.evt, nil, "the first listener binds")
		t.eq(#(carrier :: any)._listeners.evt, 1)

		carrier:Off("evt", handler)
		t.eq((carrier :: any)._bound.evt, nil, "the binding drops once nothing is listening")
		t.eq((carrier :: any)._listeners.evt, nil)

		carrier:Destroy()
	end)

	binding:test("several listeners share one binding", function(t)
		local carrier = Pigeon.new(unique("MultiBind"), {})
		local first, second = function() end, function() end

		carrier:On("evt", first)
		carrier:On("evt", second)

		t.eq(#(carrier :: any)._listeners.evt, 2)
		t.ne((carrier :: any)._bound.evt, nil)

		carrier:Off("evt", first)
		t.eq(#(carrier :: any)._listeners.evt, 1)
		t.ne((carrier :: any)._bound.evt, nil, "the binding must survive while a listener remains")

		carrier:Off("evt", second)
		t.eq((carrier :: any)._bound.evt, nil)

		carrier:Destroy()
	end)

	binding:test("Off with no callback drops every listener at once", function(t)
		local carrier = Pigeon.new(unique("OffAll"), {})
		carrier:On("evt", function() end)
		carrier:On("evt", function() end)

		carrier:Off("evt")

		t.eq((carrier :: any)._listeners.evt, nil)
		t.eq((carrier :: any)._bound.evt, nil)

		carrier:Destroy()
	end)

	binding:test("Off on an unknown event is a no-op", function(t)
		local carrier = Pigeon.new(unique("OffUnknown"), {})
		t.noThrow(function()
			carrier:Off("never-bound")
			carrier:Off("never-bound", function() end)
		end)
		carrier:Destroy()
	end)

	binding:test("Off with a callback that was never registered leaves the rest alone", function(t)
		local carrier = Pigeon.new(unique("OffStranger"), {})
		local kept = function() end

		carrier:On("evt", kept)
		carrier:Off("evt", function() end)

		t.eq(#(carrier :: any)._listeners.evt, 1)
		carrier:Destroy()
	end)

	binding:test("unbinding untracks the teardown from the transformer", function(t)
		local transformer = Pigeon.Transformer()
		local carrier = Pigeon.new(unique("Untrack"), { Transformer = transformer })
		local before = #(transformer :: any)._teardown

		carrier:On("a", function() end)
		carrier:On("b", function() end)
		t.eq(#(transformer :: any)._teardown, before + 2)

		carrier:Off("a")
		carrier:Off("b")
		t.eq(
			#(transformer :: any)._teardown,
			before,
			"_teardown must not grow one entry per event ever bound"
		)

		carrier:Destroy()
		transformer:Destroy()
	end)

	binding:test("binding the same event twice does not double-subscribe", function(t)
		local transformer = Pigeon.Transformer()
		local carrier = Pigeon.new(unique("NoDoubleBind"), { Transformer = transformer })
		local before = #(transformer :: any)._teardown

		carrier:On("evt", function() end)
		carrier:On("evt", function() end)
		carrier:On("evt", function() end)

		t.eq(#(transformer :: any)._teardown, before + 1, "one transport binding per event")

		carrier:Destroy()
		transformer:Destroy()
	end)

	binding:test("a dropped carrier goes quiet instead of erroring", function(t)
		local carrier = Pigeon.new(unique("Quiet"), {})
		carrier:Destroy()

		t.noThrow(function()
			carrier:Off("evt")
			carrier:Approved({})
			carrier:UseIncoming(function() end)
			carrier:UseOutgoing(function() end)
		end, "teardown races with in-flight work, so a throw here would cascade")
	end)

	binding:test("a destroyed carrier cannot be revived by On", function(t)

		local transformer = Pigeon.Transformer()
		local carrier = Pigeon.new(unique("Zombie"), { Transformer = transformer })

		carrier:Destroy()
		carrier:On("evt", function() end)

		t.eq((carrier :: any)._bound.evt, nil, "a dead carrier must not re-bind the transport")
		t.eq((carrier :: any)._listeners.evt, nil, "nor hold on to the handler")

		transformer:Destroy()
	end)

	local watching = TestKit.suite("Carrier / channel watching")
	table.insert(suites, watching)

	watching:test("a carrier watches its channel for its whole life", function(t)
		local before = Network.Diagnostics().watchers
		local carrier = Pigeon.new(unique("Watching"), {})

		t.eq(Network.Diagnostics().watchers, before + 1, "one watcher, registered up front")

		carrier:On("evt", function() end)
		carrier:On("other", function() end)
		t.eq(
			Network.Diagnostics().watchers,
			before + 1,
			"listening for events must not add more, the watcher already covers them"
		)

		carrier:Destroy()
		t.eq(Network.Diagnostics().watchers, before, "and it goes when the carrier does")
	end)

	watching:test("a carrier given a transformer still drops its watcher on Destroy", function(t)
		local transformer = Pigeon.Transformer()
		local before = Network.Diagnostics().watchers

		local carrier = Pigeon.new(unique("BorrowedWatcher"), { Transformer = transformer })
		t.eq(Network.Diagnostics().watchers, before + 1)

		carrier:Destroy()
		t.eq(
			Network.Diagnostics().watchers,
			before,
			"the watcher is not in _bound, so Destroy has to drop it by hand"
		)

		transformer:Destroy()
	end)

	watching:test("a carrier built on a dead transformer registers no watcher", function(t)
		local transformer = Pigeon.Transformer()
		transformer:Destroy()

		local before = Network.Diagnostics().watchers
		local carrier = Pigeon.new(unique("DeadWatcher"), { Transformer = transformer })

		t.eq((carrier :: any)._dropped, true)
		t.eq(Network.Diagnostics().watchers, before, "an inert carrier must not subscribe to anything")
	end)

	local network = TestKit.suite("Network / surface")
	table.insert(suites, network)

	network:test("Diagnostics reports every figure it documents", function(t)
		local diagnostics = Network.Diagnostics()

		for _, field in
			{
				"listeners",
				"watchers",
				"orphaned",
				"pending",
				"readySeats",
				"bufferedPackets",
				"readyChannels",
				"bufferedChannels",
				"outbound",
			}
		do
			t.isType(diagnostics[field], "number", field .. " should be a number")
			t.ok(diagnostics[field] >= 0, field .. " should never be negative")
		end
	end)

	network:test("Receive returns a disconnect that removes the listener", function(t)
		local before = Network.Diagnostics().listeners
		local disconnect = Network.Receive("PigeonUnit_ReceiveSurface_" .. where, function() end)

		t.eq(Network.Diagnostics().listeners, before + 1)
		disconnect()
		t.eq(Network.Diagnostics().listeners, before, "the event key is dropped once empty")
	end)

	network:test("a stale disconnect does not clear a rebuilt listener list", function(t)
		local event = "PigeonUnit_StaleDisconnect_" .. where

		local first = Network.Receive(event, function() end)
		first()
		first()

		local second = Network.Receive(event, function() end)
		local after = Network.Diagnostics().listeners

		first()

		t.eq(Network.Diagnostics().listeners, after, "the identity check must protect the rebuilt array")
		second()
	end)

	network:test("GetRefCount is at least one", function(t)
		t.ok(Network.GetRefCount() >= 1, "there is always a pool")
		t.ok(Network.GetRefCount() <= 32, "and never more than MAX_REFS")
	end)

	return suites
end
