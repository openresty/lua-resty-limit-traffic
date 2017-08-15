-- implement GitHub request rate limiting: https://developer.github.com/v3/#rate-limiting

local ffi = require "ffi"
local math = require "math"

local ngx_shared = ngx.shared
local ngx_time = ngx.time
local setmetatable = setmetatable
local ffi_cast = ffi.cast
local ffi_str = ffi.string
local abs = math.abs
local tonumber = tonumber
local type = type
local assert = assert

-- TODO: we could avoid the tricky FFI cdata when lua_shared_dict supports
-- hash-typed values as in redis.
ffi.cdef[[
    struct lua_resty_limit_ghe_req_rec {
        unsigned short       remaining;  /* number of requests remaining */
        uint64_t             reset;  /* time at which the window resets  */
        /* integer value, 1 corresponds to 1 second */
    };
]]
local const_rec_ptr_type = ffi.typeof("const struct lua_resty_limit_count_rec*")
local rec_size = ffi.sizeof("struct lua_resty_limit_count_rec")

-- we can share the cdata here since we only need it temporarily for
-- serialization inside the shared dict:
local rec_cdata = ffi.new("struct lua_resty_limit_count_rec")


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

    local remaining
    local reset

    -- it's important to anchor the string value for the read-only pointer
    -- cdata:
    local v = dict:get(key)
    if v then
        if type(v) ~= "string" or #v ~= rec_size then
            return nil, "shdict abused by other users"
        end
        local rec = ffi_cast(const_rec_ptr_type, v)
        local ttl = tonumber(rec.reset) - now

        -- print("ttl: ", ttl, "s")

        if ttl > 0 then
            reset = tonumber(rec.reset)
            remaining = tonumber(rec.remaining) - 1
        else
            reset = now + window
            remaining = limit
        end

        if remaining < 0 then
            return -1, reset
        end
    else
        remaining = limit - 1
        reset = now + window
    end

    if commit then
        rec_cdata.remaining = remaining
        rec_cdata.reset = reset
        dict:set(key, ffi_str(rec_cdata, rec_size))
    end

    -- return remaining and time to reset
    return remaining, reset
end

-- uncommit remaining and return remaining value
function _M.uncommit(self, key)
    assert(key)
    local dict  = self.dict
    local limit = self.limit

    local v = dict:get(key)
    if not v then
        return nil, "not found"
    end

    if type(v) ~= "string" or #v ~= rec_size then
        return nil, "shdict abused by other users"
    end

    local rec = ffi_cast(const_rec_ptr_type, v)
    local remaining = tonumber(rec.remaining) + 1

    rec_cdata.remaining = min(remaining, limit)
    rec_cdata.reset = rec.reset

    dict:set(key, ffi_str(rec_cdata, rec_size))
    return rec_cdata.remaining
end

return _M
