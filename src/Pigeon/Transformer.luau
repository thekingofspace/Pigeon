local HttpService = game:GetService("HttpService")
local Transformer = {}
local types = require("./Types")
local Network = require("./Network")
Transformer.__index = Transformer

function Transformer.Track(self:types.Transformer, disconnect:() -> ()): () -> ()
    if self.destroyed then
        disconnect()
        return function() end
    end
    table.insert(self._teardown, disconnect)

    return function()
        local index = table.find(self._teardown, disconnect)
        if index then
            table.remove(self._teardown, index)
        end
    end
end

function Transformer.Destroy(self:types.Transformer)
    if self.destroyed then
        return
    end
    self.destroyed = true

    for _, disconnect in table.clone(self._teardown) do
        local ok, err = pcall(disconnect)
        if not ok then
            warn(`[Pigeon] Transformer teardown failed for '{self.uuid}': {err}`)
        end
    end
    table.clear(self._teardown)

    Network.Unregister(self)
end

return function(uuid: string?)
    local self:types.Transformer = setmetatable({}, Transformer)
    self.uuid = uuid or HttpService:GenerateGUID()
    self.destroyed = false
    self._teardown = {}
    Network.Register(self)
    return self
end
