local Protocol = require(script.Parent.Protocol)

local Recorder = {}
Recorder.__index = Recorder

function Recorder.new(): any
	return setmetatable({ entries = {} }, Recorder)
end

function Recorder.record(self: any, key: string, ...: any)
	local list = self.entries[key]
	if not list then
		list = {}
		self.entries[key] = list
	end
	table.insert(list, Protocol.pack(...))
end

function Recorder.recordFrom(self: any, key: string, player: Player?, ...: any)
	local list = self.entries[key]
	if not list then
		list = {}
		self.entries[key] = list
	end
	local entry = Protocol.pack(...) :: any
	entry.player = if player then player.Name else nil
	table.insert(list, entry)
end

function Recorder.count(self: any, key: string): number
	local list = self.entries[key]
	return if list then #list else 0
end

function Recorder.at(self: any, key: string, index: number?): any
	local list = self.entries[key]
	return if list then list[index or 1] else nil
end

function Recorder.last(self: any, key: string): any
	local list = self.entries[key]
	return if list then list[#list] else nil
end

function Recorder.all(self: any, key: string): { any }
	return self.entries[key] or {}
end

function Recorder.firsts(self: any, key: string): { any }
	local out = {}
	for _, entry in self:all(key) do
		table.insert(out, entry.values[1])
	end
	return out
end

function Recorder.reset(self: any, key: string?)
	if key then
		self.entries[key] = nil
	else
		table.clear(self.entries)
	end
end

function Recorder.hook(self: any, carrier: any, event: string, key: string?)
	local bucket = key or event
	carrier:On(event, function(...: any)
		self:record(bucket, ...)
	end)
end

function Recorder.hookServer(self: any, carrier: any, event: string, key: string?)
	local bucket = key or event
	carrier:On(event, function(player: Player, ...: any)
		self:recordFrom(bucket, player, ...)
	end)
end

return Recorder
