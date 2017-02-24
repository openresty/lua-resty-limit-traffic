Name
====

resty.limit.count - Lua module for limiting request counts for OpenResty/ngx_lua.

Table of Contents
=================

* [Name](#name)
* [Synopsis](#synopsis)
* [Description](#description)
* [Methods](#methods)
    * [new](#new)
    * [incoming](#incoming)
* [Installation](#installation)
* [Author](#author)
* [See Also](#see-also)

Synopsis
========

```nginx
http {
    lua_shared_dict my_limit_count_store 100m;

    server {
        location / {
            access_by_lua_block {
                local limit_count = require "resty.limit.count"

                -- rate: 5000 requests per 3600s
                local lim, err = limit_count.new("api_limit_count_store", 5000, 3600)
                if not lim then
                    ngx.log(ngx.ERR, "failed to instantiate a resty.limit.count object: ", err)
                    return ngx.exit(500)
                end

                -- use the Authorization header as the limiting key
                local key = ngx.req.get_headers()["Authorization"] or "public"
                local remaining, reset = lim:incoming(key, true)

                ngx.header["X-RateLimit-Limit"] = "5000"
                ngx.header["X-RateLimit-Reset"] = reset

                if remaining < 0 then
                    ngx.header["X-RateLimit-Remaining"] = 0
                    ngx.log(ngx.WARN, "rate limit exceeded")
                    return ngx.exit(403)
                else
                    ngx.header["X-RateLimit-Remaining"] = remaining
                end
            }
        }
    }
}
```

Description
===========

This module provides APIs to help the OpenResty/ngx_lua user programmers limit request
rate by a fixed number of requests in given time window.

This Lua module's implementation is similar to [GitHub API Rate Limiting](https://developer.github.com/v3/#rate-limiting) But this Lua
module is flexible in that it can be configured with different rate.

Methods
=======

[Back to TOC](#table-of-contents)

new
---
**syntax:** `obj, err = class.new(shdict_name, count, time_window)`

Instantiates an object of this class. The `class` value is returned by the call `require "resty.limit.count"`.

This method takes the following arguments:

* `shdict_name` is the name of the [lua_shared_dict](https://github.com/openresty/lua-nginx-module#lua_shared_dict) shm zone.

    It is best practice to use separate shm zones for different kinds of limiters.
* `count` is the specified number of requests threshold.

* `time_window` is the time window in second before the request count is reset.

[Back to TOC](#table-of-contents)

incoming
--------
**syntax:** `delay, err = obj:incoming(key, commit)`

Fires a new request incoming event and calculates the delay needed (if any) for the current request
upon the specified key or whether the user should reject it immediately.

This method accepts the following arguments:

* `key` is the user specified key to limit the rate.

    For example, one can use the host name (or server zone)
as the key so that we limit rate per host name. Otherwise, we can also use the authorization header value as the
key so that we can set a rate for individual user.

    Please note that this module does not prefix nor suffix the user key so it is the user's responsibility to ensure the key is unique in the `lua_shared_dict` shm zone).
* `commit` is a boolean value. If set to `true`, the object will actually record the event
in the shm zone backing the current object; otherwise it would just be a "dry run" (which is the default).

The return values depend on the following cases:

1. If the request does not exceed the `count` value specified in the [new](#new) method, then
this method returns remaining count of allowed requests.
2. If the request exceeds the `count` limit specified in the [new](#new) method then
this method returns an negative number representing exceeded count.

    In addition, this method also returns a second return value indicating the time (Epoch) to reset given count.

4. If an error occurred (like failures when accessing the `lua_shared_dict` shm zone backing
the current object), then this method returns `nil` and a string describing the error.

uncommit
--------

**syntax:** `remaining = obj:uncommit(key)`

Undo the commit of the count of incoming call. This method is mainly for excluding specified requests from counting
against limit like conditional requests.

[Back to TOC](#table-of-contents)

Limiting Granularity
====================

The limiting works on the granularity of an individual NGINX server instance (including all
its worker processes). Thanks to the shm mechanism; we can share state cheaply across
all the workers in a single NGINX server instance.

[Back to TOC](#table-of-contents)

Installation
============

Please see [library installation instructions](../../../README.md#installation).

[Back to TOC](#table-of-contents)

Bugs and Patches
================

Please report bugs or submit patches by

1. creating a ticket on the [GitHub Issue Tracker](https://github.com/openresty/lua-resty-limit-traffic/issues),

[Back to TOC](#table-of-contents)

Author
======

Ke Zhu <kzhu@us.ibm.com>.

[Back to TOC](#table-of-contents)

See Also
========
* module [resty.limit.conn](./conn.md)
* module [resty.limit.traffic](./traffic.md)
* library [lua-resty-limit-traffic](../../../README.md)
* the ngx_lua module: https://github.com/openresty/lua-nginx-module
* OpenResty: https://openresty.org/

[Back to TOC](#table-of-contents)
