-- limit request rate using the token bucket method:
--    https://en.wikipedia.org/wiki/Token_bucket


local ffi = require "ffi"
local math = require "math"
local lock = require "resty.lock"


local ffi_cast = ffi.cast
local ffi_str = ffi.string

local type = type
local assert = assert
local ngx_now = ngx.now
local floor = math.floor
local ngx_shared = ngx.shared
local setmetatable = setmetatable


ffi.cdef[[
    struct lua_resty_limit_token_rec {
        int64_t        avail;
        uint64_t       last;  /* time in milliseconds */
    };
]]
local const_rec_ptr_type = ffi.typeof("const struct lua_resty_limit_token_rec*")
local rec_size = ffi.sizeof("struct lua_resty_limit_token_rec")

local rec_cdata = ffi.new("struct lua_resty_limit_token_rec")


local _M = {
    _VERSION = "0.01",
}


local mt = {
    __index = _M
}


local is_str = function(s) return type(s) == "string" end
local is_num = function(n) return type(n) == "number" end


local function acquire_lock(self, key)
    local lock, err = lock:new(self.locks_shdict_name)
    if not lock then
        return nil, err
    end

    self.lock = lock

    return lock:lock(key)
end


local function release_lock(self)
    local lock = self.lock

    return lock:unlock()
end


local function update(self, key, avail, last)
    local dict = self.dict

    rec_cdata.avail = avail
    rec_cdata.last = last
    dict:set(key, ffi_str(rec_cdata, rec_size))

    -- ngx.log(ngx.ERR, "key = ", key, " avail = ", avail, " last = ", last)
end


local function adjust(self, key, now)
    local dict = self.dict

    local res = {
        last = now,
        avail = self.capacity
    }

    local v = dict:get(key)
    if v then
        if not is_str(v) or #v ~= rec_size then
            return nil, "shdict abused by other users"
        end

        local rec = ffi_cast(const_rec_ptr_type, v)

        res.last = tonumber(rec.last)
        res.avail = tonumber(rec.avail)
    end

    local tick = floor((now - res.last) / self.interval)
    res.last = res.last + tick * self.interval

    if res.avail >= self.capacity then
        return res
    end

    res.avail = res.avail + tick * self.quantum
    if res.avail > self.capacity then
        res.avail = self.capacity
    end

    return res
end


function _M.new(dict_name, interval, capacity, quantum, opts)
    local dict = ngx_shared[dict_name]
    if not dict then
        return nil, "shared dict not found"
    end

    if not quantum then
        quantum = 1
    end

    assert(interval > 0 and capacity > 0 and quantum > 0)

    if not opts then
        opts = {}
    end

    local locks_shdict_name = opts.locks_shdict_name or "locks"

    local self = {
        dict = dict,
        interval = interval,
        capacity = capacity,
        quantum = quantum,

        locks_shdict_name = locks_shdict_name,
    }

    return setmetatable(self, mt)
end


function _M.rate(self)
    return 1000 * self.quantum / self.interval
end


function _M.take(self, key, count, max_wait, fake_now)
    if not is_str(key) or count <= 0 then
        return 0
    end

    local now = ngx_now() * 1000

    -- just for testing
    if is_num(fake_now) then
        now = fake_now
    end

    local res, err = acquire_lock(self, key)
    if not res then
        return nil, err
    end

    local res, err = adjust(self, key, now)
    if not res then
        release_lock(self)
        return nil, err
    end

    local last = res.last
    local avail = res.avail

    avail = avail - count
    if avail >= 0 then
        update(self, key, avail, last)
        release_lock(self)
        return 0
    end

    local quantum = self.quantum
    local tick = floor((-avail + quantum - 1) / quantum)
    local wait_time = tick * self.interval - (now - last)

    if is_num(max_wait) and wait_time > max_wait then
        update(self, key, avail + count, last)
        release_lock(self)
        return nil, "rejected"
    end

    update(self, key, avail, last)
    release_lock(self)

    return wait_time / 1000
end


function _M.take_available(self, key, count, fake_now)
    if not is_str(key) or count <= 0 then
        return 0
    end

    local now = ngx_now() * 1000

    -- just for testing
    if is_num(fake_now) then
        now = fake_now
    end

    local res, err = acquire_lock(self, key)
    if not res then
        return nil, err
    end

    local res, err = adjust(self, key, now)
    if not res then
        release_lock(self)
        return nil, err
    end

    local last = res.last
    local avail = res.avail

    if avail <= 0 then
        update(self, key, avail, last)
        release_lock(self)
        return 0
    end

    if count > avail then
        count = avail
    end

    avail = avail - count
    update(self, key, avail, last)
    release_lock(self)

    return count
end


return _M
