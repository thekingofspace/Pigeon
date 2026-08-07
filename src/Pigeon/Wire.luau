--!strict

local Wire = {}

Wire.PUSH = 0
Wire.CALL = 1
Wire.RESPOND = 2
Wire.AUTH = 3

local FLAG_PROMISE = 0b0000_0100
local FLAG_ARGS = 0b0000_1000

local function maskBytes(count: number): number
	return math.ceil(count / 8)
end

function Wire.pack(
	kind: number,
	event: string,
	promiseId: number?,
	args: { any }?,
	count: number?
): (buffer, { any })
	local total = count or 0
	if total > 255 then
		error("ERR_TOO_MANY_ARGUMENTS | A single message carries at most 255 arguments.", 0)
	end
	local values: { any } = table.create(total)

	local flags = bit32.band(kind, 0b11)
	if promiseId then
		flags = bit32.bor(flags, FLAG_PROMISE)
	end
	if total > 0 then
		flags = bit32.bor(flags, FLAG_ARGS)
	end

	local nils = maskBytes(total)
	local size = 1 + 2 + #event
	if promiseId then
		size += 4
	end
	if total > 0 then
		size += 1 + nils
	end

	local meta = buffer.create(size)
	local at = 0

	buffer.writeu8(meta, at, flags)
	at += 1

	buffer.writeu16(meta, at, #event)
	at += 2

	if promiseId then
		buffer.writeu32(meta, at, promiseId)
		at += 4
	end

	if total > 0 then
		buffer.writeu8(meta, at, total)
		at += 1

		local base = at
		for index = 0, nils - 1 do
			buffer.writeu8(meta, base + index, 0)
		end

		for index = 1, total do
			local value = if args then args[index] else nil
			if value == nil then
				local byte = base + math.floor((index - 1) / 8)
				local bit = (index - 1) % 8
				buffer.writeu8(meta, byte, bit32.bor(buffer.readu8(meta, byte), bit32.lshift(1, bit)))
				values[index] = false
			else
				values[index] = value
			end
		end
		at += nils
	end

	if #event > 0 then
		buffer.writestring(meta, at, event)
	end

	return meta, values
end

function Wire.unpack(meta: buffer, values: { any }?): (number, string, number?, { any }, number)
	if typeof(meta) ~= "buffer" or buffer.len(meta) < 3 then
		return Wire.PUSH, "", nil, {}, 0
	end

	local at = 0

	local flags = buffer.readu8(meta, at)
	at += 1

	local kind = bit32.band(flags, 0b11)

	local eventLen = buffer.readu16(meta, at)
	at += 2

	local promiseId: number? = nil
	if bit32.band(flags, FLAG_PROMISE) ~= 0 then
		promiseId = buffer.readu32(meta, at)
		at += 4
	end

	local count = 0
	local base = 0
	if bit32.band(flags, FLAG_ARGS) ~= 0 then
		count = buffer.readu8(meta, at)
		at += 1
		base = at
		at += maskBytes(count)
	end

	local event = if eventLen > 0 then buffer.readstring(meta, at, eventLen) else ""

	local args: { any } = table.create(count)
	for index = 1, count do
		local byte = base + math.floor((index - 1) / 8)
		local bit = (index - 1) % 8
		local isNil = bit32.band(buffer.readu8(meta, byte), bit32.lshift(1, bit)) ~= 0
		if not isNil and values then
			args[index] = values[index]
		end
	end

	return kind, event, promiseId, args, count
end

return Wire
