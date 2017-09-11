-- implement GitHub request rate limiting: https://developer.github.com/v3/#rate-limiting

local ngx_shared = ngx.shared
local ngx_time = ngx.time
local setmetatable = setmetatable
local assert = assert


local _M = {
    _VERSION = 'alpha'
}


local mt = {
    __index = _M
}

-- the "limit" argument controls number of request allowed in a time window.
-- time "window" argument controls the time window in seconds.
function _M.new(dict_name, limit, window)
    local dict = ngx_shared[dict_name]
    if not dict then
        return nil, "shared dict not found"
    end

    assert(limit > 0 and window > 0)

    local self = {
        dict = dict,
        limit = limit,
        window = window,
    }

    return setmetatable(self, mt)
end


-- sees an new incoming event
-- the "commit" argument controls whether should we record the event in shm.
-- FIXME we have a (small) race-condition window between dict:get() and
-- dict:set() across multiple nginx worker processes. The size of the
-- window is proportional to the number of workers.
function _M.incoming(self, key, commit)
    local dict = self.dict
    local limit = self.limit
    local window = self.window
    local now = ngx_time()

    local remaining, reset = dict:get(key)
    if remaining then
        remaining = remaining - 1
        if remaining < 0 then
            return nil, "rejected", reset
        end
        if commit then
            local new_val, err = dict:incr(key, -1)
            if not new_val then
                return nil, err, reset
            end
        end

    else
        remaining = limit - 1
        reset = now + window
        if commit then
            local success, err, forcible = dict:set(key, remaining, window, reset)
            if not success then
                return nil, err, reset
            end
        end
    end

    return 0, remaining, reset
end

-- uncommit remaining and return remaining value
function _M.uncommit(self, key)
    assert(key)
    local dict = self.dict

    local remaining, err = dict:incr(key, 1)
    if not remaining then
        return nil, err
    end

    return remaining
end

return _M
