local types = require("./Types")

local StagedTable = {}
StagedTable.__index = StagedTable

local ERR_UNSUPPORTED = "ERR_STAGE_UNSUPPORTED | Staged tables carry plain Roblox data only; got %s at %s."
local ERR_BEHAVIOUR = "ERR_STAGE_BEHAVIOUR | Staged tables carry data, not behaviour; got %s at %s."
local ERR_METATABLE = "ERR_STAGE_METATABLE | Staged tables carry plain Roblox data only; got a table with a metatable at %s."
local ERR_CYCLE = "ERR_STAGE_CYCLE | Staged tables cannot contain cycles; %s refers back into itself."
local ERR_TABLE_KEY = "ERR_STAGE_TABLE_KEY | Staged table keys must be values, not tables; got one at %s."

local SERIALIZABLE: { [string]: boolean } = {
	["nil"] = true,
	boolean = true,
	number = true,
	string = true,
	buffer = true,
	Axes = true,
	BrickColor = true,
	CFrame = true,
	CatalogSearchParams = true,
	Color3 = true,
	ColorSequence = true,
	ColorSequenceKeypoint = true,
	DateTime = true,
	EnumItem = true,
	Faces = true,
	Font = true,
	NumberRange = true,
	NumberSequence = true,
	NumberSequenceKeypoint = true,
	OverlapParams = true,
	PathWaypoint = true,
	PhysicalProperties = true,
	Random = true,
	Ray = true,
	RaycastParams = true,
	Rect = true,
	Region3 = true,
	Region3int16 = true,
	TweenInfo = true,
	UDim = true,
	UDim2 = true,
	Vector2 = true,
	Vector2int16 = true,
	Vector3 = true,
	Vector3int16 = true,
}

local function describePath(path: { any }): string
	if #path == 0 then
		return "root"
	end
	local parts = table.create(#path)
	for _, key in path do
		table.insert(parts, tostring(key))
	end
	return "root." .. table.concat(parts, ".")
end

local function rawCopy(value: any, path: { any }?, seen: { [any]: boolean }?): any
	local at = path or {}
	local kind = typeof(value)

	if kind ~= "table" then
		if kind == "function" or kind == "thread" then
			error(string.format(ERR_BEHAVIOUR, kind, describePath(at)), 0)
		end
		if not SERIALIZABLE[kind] then
			error(string.format(ERR_UNSUPPORTED, kind, describePath(at)), 0)
		end
		return value
	end

	if getmetatable(value) ~= nil then
		error(string.format(ERR_METATABLE, describePath(at)), 0)
	end

	local visited = seen or {}
	if visited[value] then
		error(string.format(ERR_CYCLE, describePath(at)), 0)
	end
	visited[value] = true

	local out = {}
	for k, v in value do
		local keyKind = typeof(k)
		if keyKind == "table" then
			error(string.format(ERR_TABLE_KEY, describePath(at)), 0)
		end
		if keyKind == "function" or keyKind == "thread" then
			error(string.format(ERR_BEHAVIOUR, keyKind .. " key", describePath(at)), 0)
		end
		if not SERIALIZABLE[keyKind] then
			error(string.format(ERR_UNSUPPORTED, keyKind .. " key", describePath(at)), 0)
		end
		local childPath = table.clone(at)
		table.insert(childPath, k)
		out[k] = rawCopy(v, childPath, visited)
	end

	visited[value] = nil
	return out
end

local function encode(value: any): any
	if type(value) ~= "table" then
		return value
	end

	local keys, values = {}, {}
	for k, v in value do
		table.insert(keys, k)
		table.insert(values, encode(v))
	end
	return { K = keys, V = values }
end

local function decode(value: any): any
	if type(value) ~= "table" then
		return value
	end

	local out = {}
	local keys = value.K or {}
	local values = value.V or {}
	for index, key in keys do
		out[key] = decode(values[index])
	end
	return out
end

local function descend(root: { [any]: any }, path: { any }): ({ [any]: any }, any)
	local node = root
	for index = 1, #path - 1 do
		local key = path[index]
		local nested = node[key]
		if type(nested) ~= "table" then
			nested = {}
			node[key] = nested
		end
		node = nested
	end
	return node, path[#path]
end

local function wrap(store: { [any]: any }, onWrite: ({ any }, any) -> (), prefix: { any }): { [any]: any }
	local children: { [any]: any } = setmetatable({}, { __mode = "v" }) :: any

	local function pathTo(key: any): { any }
		local path = table.clone(prefix)
		table.insert(path, key)
		return path
	end

	local proxy = newproxy(true)
	local meta = getmetatable(proxy)

	meta.__index = function(_, key: any): any
		local value = store[key]
		if type(value) ~= "table" then
			return value
		end
		local child = children[key]
		if not child then
			child = wrap(value, onWrite, pathTo(key))
			children[key] = child
		end
		return child
	end

	meta.__newindex = function(_, key: any, value: any)
		local path = pathTo(key)
		local copy = rawCopy(value, path)
		children[key] = nil
		store[key] = copy
		onWrite(path, encode(copy))
	end

	meta.__len = function()
		return #store
	end

	meta.__iter = function()
		return next, store
	end

	return proxy :: any
end

function StagedTable.GetTable(self: types.StageTable): { [any]: any }
	return self._proxy
end

function StagedTable.UseCapture(self: types.StageTable, Callback: types.StageGuard)
	table.insert(self._captureGuards, Callback)
end

function StagedTable.UseRelease(self: types.StageTable, Callback: types.StageGuard)
	table.insert(self._releaseGuards, Callback)
end

function StagedTable.CanCapture(self: types.StageTable, player: Player): boolean
	for _, guard in self._captureGuards do
		local ok, allowed = pcall(guard, player, self._id)
		if not ok or allowed == false then
			return false
		end
	end
	return true
end

function StagedTable.CanRelease(self: types.StageTable, player: Player): boolean
	for _, guard in self._releaseGuards do
		local ok, allowed = pcall(guard, player, self._id)
		if not ok or allowed == false then
			return false
		end
	end
	return true
end

function StagedTable.Release(self: types.StageTable)
	if self._released then
		return
	end
	self._released = true
	if self._onRelease then
		self._onRelease(self)
	end
end

function StagedTable.ApplyPatches(self: types.StageTable, patches: { { path: { any }, value: any } })
	for _, patch in patches do
		local container, key = descend(self._store, patch.path)
		container[key] = decode(patch.value)
	end
end

function StagedTable.ApplySnapshot(self: types.StageTable, snapshot: any)
	table.clear(self._store)
	for key, value in decode(snapshot) do
		self._store[key] = value
	end
end

function StagedTable.Snapshot(self: types.StageTable): any
	return encode(self._store)
end

return function(initial: { [any]: any }?): types.StageTable
	local self = setmetatable({}, StagedTable) :: any

	self._store = rawCopy(initial or {})
	self._captureGuards = {}
	self._releaseGuards = {}
	self._released = false
	self._id = nil
	self._onRelease = nil
	self._onWrite = nil
	self._queued = {}
	self._flushing = false

	self._proxy = wrap(self._store, function(path: { any }, value: any)
		if self._onWrite then
			self._onWrite(path, value)
		end
	end, {})

	return self
end
