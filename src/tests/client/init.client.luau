local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Tests = ReplicatedStorage:WaitForChild("PigeonTests")
local TestKit = require(Tests.TestKit)
local Protocol = require(Tests.Protocol)
local UnitSuites = require(Tests.UnitSuites)

local Fixtures = require(script.Fixtures)
local LocalSuites = require(script.LocalSuites)
local IntegrationSuites = require(script.IntegrationSuites)

local function concat(first: { any }, second: { any }): { any }
	local out = table.clone(first)
	for _, suite in second do
		table.insert(out, suite)
	end
	return out
end

if ReplicatedStorage:GetAttribute(Protocol.ReadyAttribute) ~= true then
	print("[pigeon/client] waiting for the server's fixtures")

	local waiting = ReplicatedStorage:GetAttributeChangedSignal(Protocol.ReadyAttribute)
	while ReplicatedStorage:GetAttribute(Protocol.ReadyAttribute) ~= true do
		waiting:Wait()
	end
end

print("[pigeon/client] building fixtures")
Fixtures.build()

local local_ = TestKit.runAll(
	"client",
	concat(UnitSuites(TestKit, "client"), LocalSuites(TestKit, Fixtures))
)
TestKit.report("client", "client local suites", local_)

print("[pigeon/client] handing over to the server's live suites")

local ok, live = Fixtures.patientControl:Call("Do", "runLive", {})
if ok ~= true then
	warn("[pigeon/client] the server's live suites did not run: " .. tostring(live))
elseif live.alreadyRan then
	print("[pigeon/client] the server's live suites were already run: " .. tostring(live.reason))
else
	print(string.format(
		"[pigeon/client] server live suites: %d passed, %d failed, %d known defects, %d warnings in %.1fs",
		live.passed or 0,
		live.failed or 0,
		live.known or 0,
		live.warned or 0,
		live.seconds or 0
	))
	for _, failure in live.failures or {} do
		print("[pigeon/client]   server failure: " .. tostring(failure))
	end
end

local integration = TestKit.runAll("client", IntegrationSuites(TestKit, Fixtures))
TestKit.report("client", "client integration suites", integration)

local total = {
	passed = local_.passed + integration.passed,
	failed = local_.failed + integration.failed,
	known = local_.known + integration.known,
	fixed = local_.fixed + integration.fixed,
	warned = local_.warned + integration.warned,
	skipped = local_.skipped + integration.skipped,
	seconds = local_.seconds + integration.seconds,
	failures = concat(local_.failures, integration.failures),
}

TestKit.report("client", "client total", total)

pcall(function()
	Fixtures.control:Call("Do", "clientFinished", {
		passed = total.passed,
		failed = total.failed,
		known = total.known,
		warned = total.warned,
		failures = total.failures,
	})
end)
