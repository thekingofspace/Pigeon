local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Tests = ReplicatedStorage:WaitForChild("PigeonTests")
local TestKit = require(Tests.TestKit)
local Protocol = require(Tests.Protocol)
local UnitSuites = require(Tests.UnitSuites)

local Fixtures = require(script.Fixtures)
local LocalSuites = require(script.LocalSuites)
local LiveSuites = require(script.LiveSuites)

local function concat(first: { any }, second: { any }): { any }
	local out = table.clone(first)
	for _, suite in second do
		table.insert(out, suite)
	end
	return out
end

print("[pigeon/server] building fixtures")
Fixtures.build()

local total = TestKit.runAll(
	"server",
	concat(UnitSuites(TestKit, "server"), LocalSuites(TestKit, Fixtures))
)
TestKit.report("server", "server local suites", total)

ReplicatedStorage:SetAttribute(Protocol.ReadyAttribute, true)
print("[pigeon/server] fixtures ready; waiting for a client to drive the live suites")

local liveDone = false

Fixtures.Actions.runLive = function(player: Player)

	if liveDone then
		return { alreadyRan = true, reason = "the live suites have already run for this server" }
	end
	liveDone = true

	print(string.format("[pigeon/server] running live suites against %s", player.Name))

	local result = TestKit.runAll("server", LiveSuites(TestKit, Fixtures, player))
	TestKit.report("server", "server live suites", result)

	return {
		passed = result.passed,
		failed = result.failed,
		known = result.known,
		fixed = result.fixed,
		warned = result.warned,
		skipped = result.skipped,
		seconds = result.seconds,
		failures = result.failures,
	}
end

Fixtures.Actions.clientFinished = function(player: Player, payload: any)
	print(string.format(
		"[pigeon/server] %s finished: %d passed, %d failed, %d known defects, %d warnings",
		player.Name,
		payload.passed or 0,
		payload.failed or 0,
		payload.known or 0,
		payload.warned or 0
	))

	for _, failure in payload.failures or {} do
		print(string.format("[pigeon/server]   client failure: %s", failure))
	end

	return true
end

if #Players:GetPlayers() == 0 then
	print("[pigeon/server] no client connected yet -- start one to run the live and integration suites")
end
