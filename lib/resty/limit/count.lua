-- implement GitHub request rate limiting:
--    https://developer.github.com/v3/#rate-limiting

local ngx_shared = ngx.shared
local setmetatable = setmetatable
local assert = assert


local _M = {
   _VERSION = '0.05'
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


function _M.incoming(self, key, commit)
    local dict = self.dict
    local limit = self.limit
    local window = self.window

    local count, ok, err

    if commit then
        count, err = dict:incr(key, 1, 0, window)

        if not count then
            return nil, err
        end
    else
        count = (dict:get(key) or 0) + 1
    end

    if count > limit then
        if commit then
            ok, err = self:uncommit(key)
            if not ok then
                return nil, err
            end
        end
        return nil, "rejected"
    end

    return 0, limit - count
end

-- uncommit remaining and return remaining value
function _M.uncommit(self, key)
    assert(key)
    local dict = self.dict
    local limit = self.limit

    local count, err = dict:incr(key, -1)
    if not count then
        if err == "not found" then
            count = 0
        else
            return nil, err
        end
    end

    return limit - count
end


return _M
