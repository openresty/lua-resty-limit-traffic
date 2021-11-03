-- implement GitHub request rate limiting:
--    https://developer.github.com/v3/#rate-limiting

local ngx_shared = ngx.shared
local setmetatable = setmetatable
local assert = assert


local _M = {
   _VERSION = '0.07'
}


local mt = {
    __index = _M
}

local incr_support_init_ttl
local ngx_config = ngx.config
local ngx_lua_v = ngx.config.ngx_lua_version
if not ngx_config or not ngx_lua_v or (ngx_lua_v < 10012) then
    incr_support_init_ttl = false
else
    incr_support_init_ttl = true
end


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

function _M.incoming_new(self, key, commit)
    local dict = self.dict
    local limit = self.limit
    local window = self.window

    local remaining, ok, err

    if commit then
        remaining, err = dict:incr(key, -1, limit, window)
        if not remaining then
            return nil, err
        end
    else
        remaining = (dict:get(key) or limit) - 1
    end

    if remaining < 0 then
        return nil, "rejected"
    end

    return 0, remaining
end

function _M.incoming_old(self, key, commit)
    local dict = self.dict
    local limit = self.limit
    local window = self.window

    local remaining, ok, err

    if commit then
        remaining, err = dict:incr(key, -1, limit)
        if not remaining then
            return nil, err
        end

        if remaining == limit - 1 then
            ok, err = dict:expire(key, window)
            if not ok then
                if err == "not found" then
                    remaining, err = dict:incr(key, -1, limit)
                    if not remaining then
                        return nil, err
                    end

                    ok, err = dict:expire(key, window)
                    if not ok then
                        return nil, err
                    end

                else
                    return nil, err
                end
            end
        end

    else
        remaining = (dict:get(key) or limit) - 1
    end

    if remaining < 0 then
        return nil, "rejected"
    end

    return 0, remaining
end

function _M.incoming(self, key, commit)
    if incr_support_init_ttl then
        return self:incoming_new(key, commit)
    else
        return self:incoming_old(key, commit)
    end
end


-- uncommit remaining and return remaining value
function _M.uncommit(self, key)
    assert(key)
    local dict = self.dict
    local limit = self.limit

    local remaining, err = dict:incr(key, 1)
    if not remaining then
        if err == "not found" then
            remaining = limit
        else
            return nil, err
        end
    end

    return remaining
end


return _M
