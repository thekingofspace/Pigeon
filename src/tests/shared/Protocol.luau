local Protocol = {}

Protocol.NIL = "\1pigeon-test-nil\1"

Protocol.ReadyAttribute = "PigeonTestsServerReady"

Protocol.Control = "PigeonTest_Control"
Protocol.Echo = "PigeonTest_Echo"
Protocol.Guarded = "PigeonTest_Guarded"
Protocol.Rooms = "PigeonTest_Rooms"
Protocol.Tables = "PigeonTest_Tables"
Protocol.Middleware = "PigeonTest_Middleware"
Protocol.Unreliable = "PigeonTest_Unreliable"
Protocol.UnreliableBuffer = "PigeonTest_UnreliableBuffer"
Protocol.Late = "PigeonTest_Late"

Protocol.Buffered = "PigeonTest_Buffered"
Protocol.BufferedB = "PigeonTest_BufferedB"
Protocol.BufferedC = "PigeonTest_BufferedC"
Protocol.BufferedD = "PigeonTest_BufferedD"
Protocol.SharedA = "PigeonTest_SharedA"
Protocol.SharedB = "PigeonTest_SharedB"
Protocol.Mismatch = "PigeonTest_Mismatch"
Protocol.ClusterA = "PigeonTest_ClusterA"
Protocol.ClusterB = "PigeonTest_ClusterB"
Protocol.Doomed = "PigeonTest_Doomed"
Protocol.Live = "PigeonTest_Live"
Protocol.LiveGuarded = "PigeonTest_LiveGuarded"
Protocol.Revoke = "PigeonTest_Revoke"
Protocol.CallBack = "PigeonTest_CallBack"

Protocol.SharedTransformer = "PigeonTest_SharedTransformer"
Protocol.ClusterTransformer = "PigeonTest_ClusterTransformer"
Protocol.MismatchTransformer = "PigeonTest_MismatchTransformer"

Protocol.TableMain = "main"
Protocol.TableGuarded = "guarded"
Protocol.TableForced = "forced"
Protocol.TableMixed = "mixed"
Protocol.TableSticky = "sticky"
Protocol.TableRevoke = "revocable"
Protocol.TableMissing = "no-such-table"

Protocol.GoodToken = "open-sesame"
Protocol.BadToken = "let-me-in"

function Protocol.pack(...: any): { n: number, values: { any } }
	local count = select("#", ...)
	local values = table.create(count)
	for index = 1, count do
		local value = select(index, ...)
		values[index] = if value == nil then Protocol.NIL else value
	end
	return { n = count, values = values }
end

function Protocol.unpack(entry: any): ...any
	if type(entry) ~= "table" then
		return
	end
	local count = entry.n or 0
	local out = table.create(count)
	for index = 1, count do
		local value = entry.values[index]
		out[index] = if value == Protocol.NIL then nil else value
	end
	return table.unpack(out, 1, count)
end

function Protocol.same(entry: any, expected: { any }, arity: number?): (boolean, string)
	if type(entry) ~= "table" then
		return false, "no record: " .. tostring(entry)
	end

	local count = arity or #expected
	if entry.n ~= count then
		return false, string.format("expected %d arguments, got %s", count, tostring(entry.n))
	end

	for index = 1, count do
		local actual = entry.values[index]
		local wanted = expected[index]
		if actual ~= wanted then
			return false,
				string.format("argument %d: expected %s, got %s", index, tostring(wanted), tostring(actual))
		end
	end

	return true, "ok"
end

function Protocol.render(entry: any): string
	if type(entry) ~= "table" then
		return "<none>"
	end
	local parts = {}
	for index = 1, entry.n or 0 do
		local value = entry.values[index]
		table.insert(parts, if value == Protocol.NIL then "nil" else tostring(value))
	end
	return "(" .. table.concat(parts, ", ") .. ")"
end

return Protocol
