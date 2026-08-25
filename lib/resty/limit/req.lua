-- Copyright (C) Yichun Zhang (agentzh)
--
-- This library is an approximate Lua port of the standard ngx_limit_req
-- module.


local math = require "math"

local ngx_shared = ngx.shared
local ngx_now = ngx.now
local setmetatable = setmetatable
local type = type
local assert = assert


--- store 3 seconds of request count history
local KEY_TTL = 3


---@class resty.limit.req
---@field dict ngx.shared.DICT
---@field rate number
---@field burst number
local _M = {
    _VERSION = '0.09'
}


local mt = {
    __index = _M
}


---@param dict_name string
---@param rate number
---@param burst number
---@return resty.limit.req?, string?
function _M.new(dict_name, rate, burst)
    local dict = ngx_shared[dict_name]
    if not dict then
        return nil, "shared dict not found"
    end

    assert(rate > 0 and burst >= 0)

    local self = {
        dict = dict,
        rate = rate,
        burst = burst,
    }

    return setmetatable(self, mt), nil
end

-- sees an new incoming event
-- the "commit" argument controls whether should we record the event in shm.
---@param self resty.limit.req
---@param key string|number
---@param commit boolean
function _M.incoming(self, key, commit)
    local dict = self.dict
    local rate = self.rate
    local now_sec = ngx_now()
    local now_ms = now_sec * 1000.0
    local current_second = math.floor(now_sec)
    local current_second_key = key .. ":" .. tostring(current_second)
    local previous_second_key = key .. ":" .. tostring(current_second - 1)

    local prev_req_count = dict:get(previous_second_key)
    if not prev_req_count or type(prev_req_count) ~= "number" then
        prev_req_count = 0
    end

    local curr_req_count = dict:incr(current_second_key, 1, 0, KEY_TTL)
    if not curr_req_count then
        --- something is really wrong
        --- possibly oom in the shared dict
        return nil, "failed to increment request count"
    end

    --- now check if we are within limits
    local elapsed = now_ms - (current_second * 1000.0)

    -- sliding window approach
    -- we assume that requests were uniformly distributed in the last second
    local sliding_window_rate = curr_req_count + (prev_req_count * (1000.0 - elapsed) / 1000.0)

    local to_reject = false
    local to_delay = false
    local delay_ms = 0

    if sliding_window_rate > (rate + self.burst) then
        to_reject = true
    elseif sliding_window_rate > rate then
        to_delay = true
        delay_ms = (sliding_window_rate * 1000 / rate) - 1000
    end

    if not commit then
        dict:incr(current_second_key, -1)
    end

    if to_reject then
        return nil, "rejected"
    elseif to_delay then
        return delay_ms / 1000.0, sliding_window_rate - rate
    else
        return 0, 0
    end
end

---@param self resty.limit.req
---@param key string|number
---@return boolean?, string?
function _M.uncommit(self, key)
    assert(key)
    local dict = self.dict

    local now_sec = ngx_now()
    local current_second = math.floor(now_sec)
    local current_second_key = key .. ":" .. tostring(current_second)

    local curr_req_count, err = dict:incr(current_second_key, -1, 1, KEY_TTL)
    if not curr_req_count then
        return nil, err
    end
    return true
end

---@param self resty.limit.req
---@param rate number
function _M.set_rate(self, rate)
    self.rate = rate
end

---@param self resty.limit.req
---@param burst number
function _M.set_burst(self, burst)
    self.burst = burst
end

return _M
