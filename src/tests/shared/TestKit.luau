local TestKit = {}

local DEFAULT_TIMEOUT = 15

local ASSERT_TAG = "\1pigeon-assert\1"

local function isAssertion(message: any): boolean
	return type(message) == "string" and string.find(message, ASSERT_TAG, 1, true) ~= nil
end

local function strip(message: any): string
	local text = tostring(message)
	local at = string.find(text, ASSERT_TAG, 1, true)
	if at then
		return string.sub(text, at + #ASSERT_TAG)
	end
	return text
end

local function describe(value: any, depth: number?): string
	local level = depth or 0
	local kind = typeof(value)

	if kind == "string" then
		return string.format("%q", value)
	end
	if kind ~= "table" then
		return tostring(value)
	end
	if level >= 2 then
		return "{...}"
	end

	local parts, count = {}, 0
	for key, item in value do
		count += 1
		if count > 8 then
			table.insert(parts, "...")
			break
		end
		table.insert(parts, string.format("%s = %s", tostring(key), describe(item, level + 1)))
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

TestKit.describe = describe

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, value in a do
		if not deepEqual(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

TestKit.deepEqual = deepEqual

local function newContext(): any
	local ctx: any = { logs = {} }

	local function fail(message: string): never
		error(ASSERT_TAG .. message, 0)
	end

	local function prefix(message: string?): string
		return if message then message .. ": " else ""
	end

	ctx.fail = fail

	function ctx.log(...: any)
		local parts = {}
		for index = 1, select("#", ...) do
			parts[index] = tostring((select(index, ...)))
		end
		table.insert(ctx.logs, table.concat(parts, " "))
	end

	function ctx.ok(value: any, message: string?)
		if not value then
			fail(prefix(message) .. "expected a truthy value, got " .. describe(value))
		end
	end

	function ctx.no(value: any, message: string?)
		if value then
			fail(prefix(message) .. "expected a falsy value, got " .. describe(value))
		end
	end

	function ctx.eq(actual: any, expected: any, message: string?)
		if actual ~= expected then
			fail(prefix(message) .. string.format("expected %s, got %s", describe(expected), describe(actual)))
		end
	end

	function ctx.ne(actual: any, unexpected: any, message: string?)
		if actual == unexpected then
			fail(prefix(message) .. string.format("expected anything but %s", describe(unexpected)))
		end
	end

	function ctx.same(actual: any, expected: any, message: string?)
		if not deepEqual(actual, expected) then
			fail(prefix(message) .. string.format("expected %s, got %s", describe(expected), describe(actual)))
		end
	end

	function ctx.near(actual: number, expected: number, tolerance: number, message: string?)
		if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
			fail(prefix(message) .. string.format("expected %s within %s, got %s", tostring(expected), tostring(tolerance), describe(actual)))
		end
	end

	function ctx.gt(actual: number, floor: number, message: string?)
		if type(actual) ~= "number" or actual <= floor then
			fail(prefix(message) .. string.format("expected something above %s, got %s", tostring(floor), describe(actual)))
		end
	end

	function ctx.lt(actual: number, ceiling: number, message: string?)
		if type(actual) ~= "number" or actual >= ceiling then
			fail(prefix(message) .. string.format("expected something below %s, got %s", tostring(ceiling), describe(actual)))
		end
	end

	function ctx.matches(text: any, needle: string, message: string?)
		if type(text) ~= "string" or not string.find(text, needle, 1, true) then
			fail(prefix(message) .. string.format("expected %s to contain %q", describe(text), needle))
		end
	end

	function ctx.isType(value: any, expected: string, message: string?)
		local actual = typeof(value)
		if actual ~= expected then
			fail(prefix(message) .. string.format("expected a %s, got a %s (%s)", expected, actual, describe(value)))
		end
	end

	function ctx.throws(fn: () -> (), needle: string?): string
		local ok, err = pcall(fn)
		if ok then
			fail(string.format("expected an error%s, but the call returned", if needle then " containing " .. string.format("%q", needle) else ""))
		end
		local message = strip(err)
		if needle and not string.find(message, needle, 1, true) then
			fail(string.format("expected the error to contain %q, got %s", needle, describe(message)))
		end
		return message
	end

	function ctx.noThrow(fn: () -> (), message: string?)
		local ok, err = pcall(fn)
		if not ok then
			fail(prefix(message) .. "expected no error, got " .. strip(err))
		end
	end

	function ctx.wait(seconds: number)
		local deadline = os.clock() + seconds
		while os.clock() < deadline do
			task.wait()
		end
	end

	function ctx.eventually(predicate: () -> any, timeout: number?, message: string?)
		local deadline = os.clock() + (timeout or 5)
		repeat
			if predicate() then
				return
			end
			task.wait()
		until os.clock() >= deadline
		fail(prefix(message) .. string.format("condition never held within %.1fs", timeout or 5))
	end

	function ctx.never(predicate: () -> any, window: number?, message: string?)
		local deadline = os.clock() + (window or 1)
		repeat
			if predicate() then
				fail(prefix(message) .. "condition held when it should not have")
			end
			task.wait()
		until os.clock() >= deadline
	end

	function ctx.settle(predicate: () -> any, timeout: number?): boolean
		local deadline = os.clock() + (timeout or 5)
		repeat
			if predicate() then
				return true
			end
			task.wait()
		until os.clock() >= deadline
		return false
	end

	return ctx
end

local Suite = {}
Suite.__index = Suite

function TestKit.suite(label: string): any
	return setmetatable({ label = label, cases = {} }, Suite)
end

function Suite.test(self: any, name: string, fn: (any) -> (), timeout: number?)
	table.insert(self.cases, { kind = "test", name = name, fn = fn, timeout = timeout or DEFAULT_TIMEOUT })
end

function Suite.known(self: any, name: string, note: string, fn: (any) -> (), timeout: number?)
	table.insert(self.cases, { kind = "known", name = name, note = note, fn = fn, timeout = timeout or DEFAULT_TIMEOUT })
end

function Suite.diagnostic(self: any, name: string, fn: (any) -> (), timeout: number?)
	table.insert(self.cases, { kind = "diagnostic", name = name, fn = fn, timeout = timeout or DEFAULT_TIMEOUT })
end

function Suite.skip(self: any, name: string, why: string)
	table.insert(self.cases, { kind = "skip", name = name, note = why })
end

local function execute(case: any): (boolean, string?, any)
	local ctx = newContext()
	local finished, passed, failure = false, false, nil :: any

	local thread = task.spawn(function()
		passed, failure = xpcall(function()
			case.fn(ctx)
		end, function(err: any)
			if isAssertion(err) then
				return err
			end
			return "unexpected error: " .. tostring(err) .. "\n" .. debug.traceback(nil, 2)
		end)
		finished = true
	end)

	local deadline = os.clock() + case.timeout
	while not finished and os.clock() < deadline do
		task.wait()
	end

	if not finished then
		pcall(task.cancel, thread)
		return false, string.format("timed out after %.1fs", case.timeout), ctx
	end

	return passed, if passed then nil else strip(failure), ctx
end

function Suite.run(self: any, prefix: string): any
	local result = {
		label = self.label,
		passed = 0,
		failed = 0,
		known = 0,
		fixed = 0,
		warned = 0,
		skipped = 0,
		failures = {},
	}

	print(string.format("[pigeon/%s] ---- %s ----", prefix, self.label))

	for _, case in self.cases do
		if case.kind == "skip" then
			result.skipped += 1
			print(string.format("[pigeon/%s]   SKIP  %s -- %s", prefix, case.name, case.note))
			continue
		end

		local ok, failure, ctx = execute(case)

		local tag
		if case.kind == "known" then
			if ok then
				result.fixed += 1
				tag = "FIXED"
			else
				result.known += 1
				tag = "KNOWN"
			end
		elseif case.kind == "diagnostic" then
			if ok then
				result.passed += 1
				tag = "PASS "
			else
				result.warned += 1
				tag = "WARN "
			end
		else
			if ok then
				result.passed += 1
				tag = "PASS "
			else
				result.failed += 1
				tag = "FAIL "
				table.insert(result.failures, { name = case.name, message = failure })
			end
		end

		print(string.format("[pigeon/%s]   %s %s", prefix, tag, case.name))

		if not ok then
			if case.kind == "known" then
				print(string.format("[pigeon/%s]         known defect: %s", prefix, case.note))
			end
			print(string.format("[pigeon/%s]         %s", prefix, (failure or ""):gsub("\n", "\n[pigeon/" .. prefix .. "]         ")))
			for _, line in ctx.logs do
				print(string.format("[pigeon/%s]         | %s", prefix, line))
			end
		elseif case.kind == "known" then
			print(string.format("[pigeon/%s]         this defect looks fixed -- drop the :known marker", prefix))
		end
	end

	return result
end

function TestKit.runAll(prefix: string, suites: { any }): any
	local total = { passed = 0, failed = 0, known = 0, fixed = 0, warned = 0, skipped = 0, failures = {} }
	local started = os.clock()

	for _, suite in suites do
		local result = suite:run(prefix)
		total.passed += result.passed
		total.failed += result.failed
		total.known += result.known
		total.fixed += result.fixed
		total.warned += result.warned
		total.skipped += result.skipped
		for _, failure in result.failures do
			table.insert(total.failures, string.format("%s / %s: %s", result.label, failure.name, failure.message))
		end
	end

	total.seconds = os.clock() - started
	return total
end

function TestKit.report(prefix: string, title: string, total: any)
	print(string.format("[pigeon/%s] ================ %s ================", prefix, title))
	print(string.format(
		"[pigeon/%s] %d passed, %d failed, %d known defects, %d newly fixed, %d warnings, %d skipped in %.1fs",
		prefix,
		total.passed,
		total.failed,
		total.known,
		total.fixed,
		total.warned,
		total.skipped,
		total.seconds or 0
	))

	if #total.failures > 0 then
		print(string.format("[pigeon/%s] failures:", prefix))
		for index, failure in total.failures do
			print(string.format("[pigeon/%s]   %d. %s", prefix, index, failure))
		end
	end
end

return TestKit
