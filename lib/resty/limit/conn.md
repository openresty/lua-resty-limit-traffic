Name
====

resty.limit.conn - Lua module for limiting request concurrency (or concurrent connections) for OpenResty/ngx_lua.

Table of Contents
=================

* [Name](#name)
* [Synopsis](#synopsis)
* [Description](#description)
* [Methods](#methods)
    * [new](#new)
    * [incoming](#incoming)
    * [is_committed](#is_committed)
    * [leaving](#leaving)
    * [set_conn](#set_conn)
    * [set_burst](#set_burst)
    * [uncommit](#uncommit)
* [Caveats](#caveats)
    * [Out-of-Sync Counter Prevention](#out-of-sync-counter-prevention)
* [Instance Sharing](#instance-sharing)
* [Limiting Granularity](#limiting-granularity)
* [Installation](#installation)
* [Community](#community)
    * [English Mailing List](#english-mailing-list)
    * [Chinese Mailing List](#chinese-mailing-list)
* [Bugs and Patches](#bugs-and-patches)
* [Author](#author)
* [Copyright and License](#copyright-and-license)
* [See Also](#see-also)

Synopsis
========

```nginx
# demonstrate the usage of the resty.limit.conn module (alone!)
http {
    lua_shared_dict my_limit_conn_store 100m;

    server {
        location / {
            access_by_lua_block {
                -- well, we could put the require() and new() calls in our own Lua
                -- modules to save overhead. here we put them below just for
                -- convenience.

                local limit_conn = require "resty.limit.conn"

                -- limit the requests under 200 concurrent requests (normally just
                -- incoming connections unless protocols like SPDY is used) with
                -- a burst of 100 extra concurrent requests, that is, we delay
                -- requests under 300 concurrent connections and above 200
                -- connections, and reject any new requests exceeding 300
                -- connections.
                -- also, we assume a default request time of 0.5 sec, which can be
                -- dynamically adjusted by the leaving() call in log_by_lua below.
                local lim, err = limit_conn.new("my_limit_conn_store", 200, 100, 0.5)
                if not lim then
                    ngx.log(ngx.ERR,
                            "failed to instantiate a resty.limit.conn object: ", err)
                    return ngx.exit(500)
                end

                -- the following call must be per-request.
                -- here we use the remote (IP) address as the limiting key
                local key = ngx.var.binary_remote_addr
                local delay, err = lim:incoming(key, true)
                if not delay then
                    if err == "rejected" then
                        return ngx.exit(503)
                    end
                    ngx.log(ngx.ERR, "failed to limit req: ", err)
                    return ngx.exit(500)
                end

                if lim:is_committed() then
                    local ctx = ngx.ctx
                    ctx.limit_conn = lim
                    ctx.limit_conn_key = key
                    ctx.limit_conn_delay = delay
                end

                -- the 2nd return value holds the current concurrency level
                -- for the specified key.
                local conn = err

                if delay >= 0.001 then
                    -- the request exceeding the 200 connections ratio but below
                    -- 300 connections, so
                    -- we intentionally delay it here a bit to conform to the
                    -- 200 connection limit.
                    -- ngx.log(ngx.WARN, "delaying")
                    ngx.sleep(delay)
                end
            }

            # content handler goes here. if it is content_by_lua, then you can
            # merge the Lua code above in access_by_lua into your
            # content_by_lua's Lua handler to save a little bit of CPU time.

            log_by_lua_block {
                local ctx = ngx.ctx
                local lim = ctx.limit_conn
                if lim then
                    -- if you are using an upstream module in the content phase,
                    -- then you probably want to use $upstream_response_time
                    -- instead of ($request_time - ctx.limit_conn_delay) below.
                    local latency = tonumber(ngx.var.request_time) - ctx.limit_conn_delay
                    local key = ctx.limit_conn_key
                    assert(key)
                    local conn, err = lim:leaving(key, latency)
                    if not conn then
                        ngx.log(ngx.ERR,
                                "failed to record the connection leaving ",
                                "request: ", err)
                        return
                    end
                end
            }
        }
    }
}
```

Description
===========

This module provides APIs to help the OpenResty/ngx_lua user programmers limit request
concurrency levels.

If you want to use multiple different instances of this class at once or use one instance
of this class with instances of other classes (like [resty.limit.req](./req.md)),
then you *must* use the [resty.limit.traffic](./traffic.md) module to combine them.

In contrast with NGINX's standard
[ngx_limit_conn](http://nginx.org/en/docs/http/ngx_http_limit_conn_module.html) module,
this Lua module supports connection delaying in addition to immediate rejection when the
concurrency level threshold is exceeded.

Methods
=======

[Back to TOC](#table-of-contents)

new
---
**syntax:** `obj, err = class.new(shdict_name, conn, burst, default_conn_delay)`

Instantiates an object of this class. The `class` value is returned by the call `require "resty.limit.conn"`.

This method takes the following arguments:

* `shdict_name` is the name of the
[lua_shared_dict](https://github.com/openresty/lua-nginx-module#lua_shared_dict) shm zone.

    It is best to use separate shm zones for different kinds of limiters.
* `conn` is the maximum number of concurrent requests allowed. Requests exceeding this ratio (and below `conn` + `burst`)
will get delayed to conform to this threshold.
* `burst` is the number of excessive concurrent requests (or connections) allowed to be
delayed.

    Requests exceeding this hard limit should get rejected immediately.
* `default_conn_delay` is the default processing latency of a typical connection (or request).

    This delay is used as a basic unit for the extra delay introduced for excessive concurrent requests (or connections),
which can later get adjusted dynamically by the subsequent [leaving](#leaving) method
calls in [log_by_lua*](https://github.com/openresty/lua-nginx-module#log_by_lua).

On failure, this method returns `nil` and a string describing the error (like a bad `lua_shared_dict` name).

[Back to TOC](#table-of-contents)

incoming
--------
**syntax:** `delay, err = obj:incoming(key, commit)`

[Back to TOC](#table-of-contents)

Fires a new concurrent request (or new connection) incoming event and
calculates the delay needed (if any) for the current request
upon the specified key or whether the user should reject it immediately.

This method accepts the following arguments:

* `key` is the user specified key to limit the concurrency level.

    For example, one can use the host name (or server zone)
as the key so that we limit concurrency per host name. Otherwise, we can also use the client address as the
key so that we can avoid a single client from flooding our service with too many parallel connections or requests.

    Please note that this module
does not prefix nor suffix the user key so it is the user's responsibility to ensure the key
is unique in the `lua_shared_dict` shm zone).
* `commit` is a boolean value. If set to `true`, the object will actually record the event
in the shm zone backing the current object; otherwise it would just be a "dry run" (which is the default).

The return values depend on the following cases:

1. If the request does not exceed the `conn` value specified in the [new](#new) method, then
this method returns `0` as the delay as well as the number of concurrent
requests (or connections) at the current time (as the 2nd return value).
2. If the request (or connection) exceeds the `conn` limit specified in the [new](#new) method but not
the `conn` + `burst` value, then
this method returns a proper delay (in seconds) for the current request so that it still conform to
the `conn` threshold as if it came a bit later rather than now.

    In addition, like the previous case, this method
also returns a second return value indicating the number of concurrent requests (or connections)
at this point (including the current request). This 2nd return value can be used to monitor the
unadjusted incoming concurrency level.
3. If the request exceeds the `conn` + `burst` limit, then this method returns `nil` and
the error string `"rejected"`.
4. If an error occurred (like failures when accessing the `lua_shared_dict` shm zone backing
the current object), then this method returns `nil` and a string describing the error.

This method does not sleep itself. It simply returns a delay if necessary and requires the caller
to later invoke the [ngx.sleep](https://github.com/openresty/lua-nginx-module#ngxsleep)
method to sleep.

This method must be paired with a [leaving](#leaving) method call typically in the
[log_by_lua*](https://github.com/openresty/lua-nginx-module#log_by_lua) context if
and only if this method actually records the event in the shm zone (designated by
a subsequent [is_committed](#is_committed) method call.

is_committed
------------
**syntax:** `bool = obj:is_committed()`

Returns `true` if the previous [incoming](#incoming) call actually commits the event
into the `lua_shared_dict` shm store; returns `false` otherwise.

This result is important in that one should only pair the [leaving](#leaving) method call
with a [incoming](#incoming) call
if and only if this `is_committed` method call returns `true`.

[Back to TOC](#table-of-contents)

leaving
--------
**syntax:** `conn = obj:leaving(key, req_latency?)`

Fires an event that the current request (or connection) is being finalized. Such events
essentially reduce the current concurrency level.

This method call usually pairs with an earlier [incoming](#incoming) call unless
the [is_committed](#is_committed) call returns `false` after that [incoming](#incoming) call.

This method takes the following parameters:

* `key` is the same key string used in the paired [incoming](#incoming) method call.
* `req_latency` is the actual latency of the current request (or connection), which is optional.

    Often we use the value of either the `$request_time` or `$upstream_response_time` nginx builtin variables here. One can, of course, record the latency himself.

The method returns the new concurrency level (or number of active connections). Unlike
[incoming](#incoming), this method always commits the changes to the shm zone.

[Back to TOC](#table-of-contents)

set_conn
--------
**syntax:** `obj:set_conn(conn)`

Overwrites the `conn` threshold value as specified in the [new](#new) method.

[Back to TOC](#table-of-contents)

set_burst
---------
**syntax:** `obj:set_burst(burst)`

Overwrites the `burst` threshold value as specified in the [new](#new) method.

[Back to TOC](#table-of-contents)

uncommit
--------
**syntax:** `ok, err = obj:uncommit(key)`

This tries to undo the commit of the `incoming` call. This method is mainly for being used in the [resty.limit.traffic](./traffic.md)
Lua module when combining multiple limiters at the same time.

This method should not be used replace of the [leaving](#leaving) method though they are
similar in effect and implementation.

[Back to TOC](#table-of-contents)

Caveats
========

[Back to TOC](#table-of-contents)

Out-of-Sync Counter Prevention
------------------------------

Under extreme conditions, like nginx worker processes crash in the middle of request processing,
the counters stored in the shm zones can go out of sync. This can lead to catastrophic
consequences like blindly rejecting *all* the incoming connections for ever. (Note that
the standard `ngx_limit_conn` module also suffers from this issue.) We may
add automatic protection for such cases to this Lua module in the near future.

Also, it is very important to ensure that the `leaving` call appears first in your
`log_by_lua*` handler code to minimize the chance that other `log_by_lua*` Lua code
throws out an exception and prevents the `leaving` call from running.

[Back to TOC](#table-of-contents)

Instance Sharing
================

Each instance of this class carries no state information but the `conn` and `burst`
threshold values. The real limiting states based on keys are stored in the `lua_shared_dict`
shm zone specified in the [new](#new) method. So it is safe to share instances of
this class [on the nginx worker process level](https://github.com/openresty/lua-nginx-module#data-sharing-within-an-nginx-worker)
as long as the combination of `conn` and `burst` do not change.

Even if the `conn` and `burst`
combination *does* change, one can still share a single instance as long as he always
calls the [set_conn](#set_conn) and/or [set_burst](#set_burst) methods *right before*
the [incoming](#incoming) call.

[Back to TOC](#table-of-contents)

Limiting Granularity
====================

The limiting works on the granularity of an individual NGINX server instance (including all
its worker processes). Thanks to the shm mechanism; we can share state cheaply across
all the workers in a single NGINX server instance.

If you are running multiple NGINX server instances (like running multiple boxes), then
you need to ensure that the incoming traffic is (more or less) evenly distributed across
all the different NGINX server instances (or boxes). So if you want a limit of N connections
across all the servers, then you just need to specify a limit of `N/n` in each server's configuration. This simple strategy can save all the (big) overhead of sharing a global state across
machine boundaries.

[Back to TOC](#table-of-contents)

Installation
============

Please see [library installation instructions](../../../README.md#installation).

[Back to TOC](#table-of-contents)

Community
=========

[Back to TOC](#table-of-contents)

English Mailing List
--------------------

The [openresty-en](https://groups.google.com/group/openresty-en) mailing list is for English speakers.

[Back to TOC](#table-of-contents)

Chinese Mailing List
--------------------

The [openresty](https://groups.google.com/group/openresty) mailing list is for Chinese speakers.

[Back to TOC](#table-of-contents)

Bugs and Patches
================

Please report bugs or submit patches by

1. creating a ticket on the [GitHub Issue Tracker](https://github.com/openresty/lua-resty-limit-traffic/issues),
1. or posting to the [OpenResty community](#community).

[Back to TOC](#table-of-contents)

Author
======

Yichun "agentzh" Zhang (章亦春) <agentzh@gmail.com>, CloudFlare Inc.

[Back to TOC](#table-of-contents)

Copyright and License
=====================

This module is licensed under the BSD license.

Copyright (C) 2015-2016, by Yichun "agentzh" Zhang, CloudFlare Inc.

All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

[Back to TOC](#table-of-contents)

See Also
========
* module [resty.limit.req](./req.md)
* module [resty.limit.count](./count.md)
* module [resty.limit.traffic](./traffic.md)
* library [lua-resty-limit-traffic](../../../README.md)
* the ngx_lua module: https://github.com/openresty/lua-nginx-module
* OpenResty: https://openresty.org/

[Back to TOC](#table-of-contents)

