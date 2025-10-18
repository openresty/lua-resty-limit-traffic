Name
====

lua-resty-limit-traffic - Lua library for limiting and controlling traffic in OpenResty/ngx_lua

Table of Contents
=================

* [Name](#name)
* [Status](#status)
* [Synopsis](#synopsis)
* [Description](#description)
* [Installation](#installation)
* [Community](#community)
    * [English Mailing List](#english-mailing-list)
    * [Chinese Mailing List](#chinese-mailing-list)
* [Bugs and Patches](#bugs-and-patches)
* [Author](#author)
* [Copyright and License](#copyright-and-license)
* [See Also](#see-also)

Status
======

This library is already usable though still highly experimental.

The Lua API is still in flux and may change in the near future without notice.

Synopsis
========

```nginx
# demonstrate the usage of the resty.limit.req module (alone!)
http {
    lua_shared_dict my_limit_req_store 100m;

    server {
        location / {
            access_by_lua_block {
                -- well, we could put the require() and new() calls in our own Lua
                -- modules to save overhead. here we put them below just for
                -- convenience.

                local limit_req = require "resty.limit.req"

                -- limit the requests under 200 req/sec with a burst of 100 req/sec,
                -- that is, we delay requests under 300 req/sec and above 200
                -- req/sec, and reject any requests exceeding 300 req/sec.
                local lim, err = limit_req.new("my_limit_req_store", 200, 100)
                if not lim then
                    ngx.log(ngx.ERR,
                            "failed to instantiate a resty.limit.req object: ", err)
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

                if delay >= 0.001 then
                    -- the 2nd return value holds the number of excess requests
                    -- per second for the specified key. for example, number 31
                    -- means the current request rate is at 231 req/sec for the
                    -- specified key.
                    local excess = err

                    -- the request exceeding the 200 req/sec but below 300 req/sec,
                    -- so we intentionally delay it here a bit to conform to the
                    -- 200 req/sec rate.
                    ngx.sleep(delay)
                end
            }

            # content handler goes here. if it is content_by_lua, then you can
            # merge the Lua code above in access_by_lua into your content_by_lua's
            # Lua handler to save a little bit of CPU time.
        }
    }
}
```

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

```nginx
# demonstrate the usage of the resty.limit.traffic module
http {
    lua_shared_dict my_req_store 100m;
    lua_shared_dict my_conn_store 100m;

    server {
        location / {
            access_by_lua_block {
                local limit_conn = require "resty.limit.conn"
                local limit_req = require "resty.limit.req"
                local limit_traffic = require "resty.limit.traffic"

                local lim1, err = limit_req.new("my_req_store", 300, 200)
                assert(lim1, err)
                local lim2, err = limit_req.new("my_req_store", 200, 100)
                assert(lim2, err)
                local lim3, err = limit_conn.new("my_conn_store", 1000, 1000, 0.5)
                assert(lim3, err)

                local limiters = {lim1, lim2, lim3}

                local host = ngx.var.host
                local client = ngx.var.binary_remote_addr
                local keys = {host, client, client}

                local states = {}

                local delay, err = limit_traffic.combine(limiters, keys, states)
                if not delay then
                    if err == "rejected" then
                        return ngx.exit(503)
                    end
                    ngx.log(ngx.ERR, "failed to limit traffic: ", err)
                    return ngx.exit(500)
                end

                if lim3:is_committed() then
                    local ctx = ngx.ctx
                    ctx.limit_conn = lim3
                    ctx.limit_conn_key = keys[3]
                end

                print("sleeping ", delay, " sec, states: ",
                      table.concat(states, ", "))

                if delay >= 0.001 then
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
                    -- instead of $request_time below.
                    local latency = tonumber(ngx.var.request_time)
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

This library provides several Lua modules to help OpenResty/ngx_lua users to control and
limit
the traffic, either request rate or request concurrency (or both).

* [resty.limit.req](lib/resty/limit/req.md) provides request rate limiting and adjustment based on the "leaky bucket" + "sliding window" method.
* [resty.limit.count](lib/resty/limit/count.md) provides rate limiting based on a "fixed window" implementation since OpenResty 1.13.6.1+.
* [resty.limit.conn](lib/resty/limit/conn.md) provides request concurrency level limiting and adjustment based on extra delays.
* [resty.limit.traffic](lib/resty/limit/traffic.md) provides an aggregator to combine multiple instances of the [resty.limit.req](lib/resty/limit/req.md), [resty.limit.count](lib/resty/limit/count.md), or [resty.limit.conn](lib/resty/limit/conn.md) classes (or all).

Please check out these Lua modules' own documentation for more details.

This library provides more flexible alternatives to NGINX's standard modules
[ngx_limit_req](http://nginx.org/en/docs/http/ngx_http_limit_req_module.html)
and [ngx_limit_conn](http://nginx.org/en/docs/http/ngx_http_limit_conn_module.html).
For example, the Lua-based limiters provided by this library can be used in any contexts
like right before the downstream SSL handshaking procedure (as with `ssl_certificate_by_lua`)
or right before issuing backend requests.

[Back to TOC](#table-of-contents)

Installation
============

This library is enabled by default in [OpenResty](https://openresty.org/) 1.11.2.2+.

If you have to install this library manually,
then ensure you are using at least OpenResty 1.11.2.1 or a custom nginx build including ngx_lua 0.10.6+. Also, You need to configure
the [lua_package_path](https://github.com/openresty/lua-nginx-module#lua_package_path) directive to
add the path of your `lua-resty-limit-traffic` source tree to ngx_lua's Lua module search path, as in

```nginx
# nginx.conf
http {
    lua_package_path "/path/to/lua-resty-limit-traffic/lib/?.lua;;";
    ...
}
```

and then load one of the modules provided by this library in Lua. For example,

```lua
local limit_req = require "resty.limit.req"
```

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

Yichun "agentzh" Zhang (章亦春) <agentzh@gmail.com>, OpenResty Inc.

[Back to TOC](#table-of-contents)

Copyright and License
=====================

This module is licensed under the BSD license.

Copyright (C) 2015-2019, by Yichun "agentzh" Zhang, OpenResty Inc.

All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

[Back to TOC](#table-of-contents)

See Also
========
* module [resty.limit.req](lib/resty/limit/req.md)
* module [resty.limit.count](lib/resty/limit/count.md)
* module [resty.limit.conn](lib/resty/limit/conn.md)
* module [resty.limit.traffic](lib/resty/limit/traffic.md)
* the ngx_lua module: https://github.com/openresty/lua-nginx-module
* OpenResty: https://openresty.org/

[Back to TOC](#table-of-contents)

