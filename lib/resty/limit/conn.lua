-- Copyright (C) Yichun Zhang (agentzh)
--
-- This library is an enhanced Lua port of the standard ngx_limit_conn
-- module.


local math = require "math"


local setmetatable = setmetatable
local floor = math.floor
local ngx_shared = ngx.shared
local assert = assert

---@class resty.limit.conn
---@field dict ngx.shared.DICT
---@field max number
---@field burst number
---@field unit_delay number
---@field committed boolean?
local _M = {
    _VERSION = '0.09'
}


local mt = {
    __index = _M
}

---@param dict_name string
---@param max integer
---@param burst integer
---@param default_conn_delay number
---@return table?, string?
function _M.new(dict_name, max, burst, default_conn_delay)
    local dict = ngx_shared[dict_name]
    if not dict then
        return nil, "shared dict not found"
    end

    assert(max > 0 and burst >= 0 and default_conn_delay > 0)

    local self = {
        dict = dict,
        max = max + 0, -- just to ensure the param is good
        burst = burst,
        unit_delay = default_conn_delay,
    }

    return setmetatable(self, mt), nil
end

---@param key string|number
---@param commit boolean
---@return number?, number|((ngx.shared.DICT.error)?)
function _M.incoming(self, key, commit)
    local dict = self.dict
    local max = self.max

    self.committed = false

    ---@type integer?, (ngx.shared.DICT.error)?
    local conn, err
    if commit then
        conn, err = dict:incr(key, 1, 0)
        if not conn then
            return nil, err
        end

        if conn > max + self.burst then
            conn, err = dict:incr(key, -1)
            if not conn then
                return nil, err
            end
            return nil, "rejected"
        end
        self.committed = true
    else
        conn = (dict:get(key) or 0) + 1
        if conn > max + self.burst then
            return nil, "rejected"
        end
    end

    if conn > max then
        -- make the excessive connections wait
        return self.unit_delay * floor((conn - 1) / max), conn
    end

    -- we return a 0 delay by default
    return 0, conn
end

---@return boolean?
function _M.is_committed(self)
    return self.committed
end

---@param key string|number
---@param req_latency number?
---@return integer?, (ngx.shared.DICT.error)?
function _M.leaving(self, key, req_latency)
    assert(key)
    local dict = self.dict

    local conn, err = dict:incr(key, -1)
    if not conn then
        return nil, err
    end

    if req_latency then
        local unit_delay = self.unit_delay
        self.unit_delay = (req_latency + unit_delay) / 2
    end

    return conn
end

---@param key string|number
---@return integer?, (ngx.shared.DICT.error)?, boolean
function _M.uncommit(self, key)
    assert(key)
    local dict = self.dict

    return dict:incr(key, -1)
end

---@param max_conn integer
function _M.set_conn(self, max_conn)
    self.max = max_conn
end

---@param burst integer
function _M.set_burst(self, burst)
    self.burst = burst
end

return _M
