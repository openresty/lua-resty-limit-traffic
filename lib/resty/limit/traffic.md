Name
====

resty.limit.traffic - Lua module for aggregating multiple instances of limiter classes

Table of Contents
=================

* [Name](#name)
* [Synopsis](#synopsis)
* [Description](#description)
* [Methods](#methods)
    * [combine](#combine)
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

                print("sleeping ", delay, " sec, states: ", table.concat(states, ", "))

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

This module can combine multiple limiters at once. For example, you may want to use
two request rate limiters for different keys (one for host names and one for the remote
client''s IP address), as well as one limiter for concurrency level at a key of the remote
client address. This module can take into account all the limiters involved without
introducing any extra delays for the current request.

The concrete limiters supplied can be an instance of the [resty.limit.req](./req.md) class
or an instance of the [resty.limit.conn](./conn.md) class, or an instance of the [resty.limit.count](./count.md) class, or an instance of any user class
which has a compatible API (see the [combine](#combine) class method for more details).

Methods
=======

[Back to TOC](#table-of-contents)

combine
-------
**syntax:** `delay, err = class.combine(limiters, keys)`

**syntax:** `delay, err = class.combine(limiters, keys, states)`

Combines all the concrete limiter objects and the limiting keys specified, calculates
the over-all delay across all the limiters, and (optionally) records any current
state information returned by each concrete limiter object (if any).

This method takes the following parameters:

* `limiters` is an array-shaped Lua table that holds all the concrete limiter objects
(for example, instances of the [resty.limit.req](lib/resty/limit/req.md) and/or
[resty.limit.conn](lib/resty/limit/conn.md) and/or
[resty.limit.count](lib/resty/limit/count.md) classes or other compatible objects).

    The limiter object must have a method named `incoming` which takes two parameters,
`key` and `commit`, just like the [resty.limit.req](lib/resty/limit/req.md) objects.
In addition, this `incoming` method must return a delay and another opaque value representing
the current state (or a string describing the error when the first return value is `nil`).

    In addition, the limiter object should also take a method named `uncommit` which can be
used to undo whatever is committed in the `incoming` method call (approximately if not possible to do precisely).
* `keys` is an array-shaped Lua table that holds all the user keys corresponding to each of the
concrete limiter object specified in the (previous) `limiters` parameter. The number of elements
in this table must equate that of the `limiters` table.
* `states` is an optional user-supplied Lua table that can be used to output all the
state information returned by each of the concrete limiter object.

    For example, instances
of the [resty.limit.req](lib/resty/limit/req.md) class return the current number of excessive
requests per second (if exceeding the rate threshold) while instances of the [resty.limit.conn](lib/resty/conn.md) class return the current concurrency level.

    When missing or set to `nil`, this method does not bother outputting any state information.

This method returns the delay in seconds (the caller should sleep before processing
the current request) across all the concrete limiter objects specified upon each
of the corresponding limiting keys (under the hood, the delay is just the maximum of all the delays dictated by the limiters).

If any of the limiters reject the current request immediately, then this method ensure
the current request incoming event is not committed in any of these concrete limiters.
In this case, this method returns `nil` and the error string `"rejected"`.

In case of other errors, it returns `nil` and a string describing the error.

Like each of concrete limiter objects, this method never sleeps itself. It simply returns a delay if necessary and requires the caller
to later invoke the [ngx.sleep](https://github.com/openresty/lua-nginx-module#ngxsleep)
method to sleep.

[Back to TOC](#table-of-contents)

Instance Sharing
================

This class itself carries no state information at all.
The states are stored in each of the concrete limiter objects. Thus, as long as
all those user-supplied concrete limiters support [worker-level sharing](https://github.com/openresty/lua-nginx-module#data-sharing-within-an-nginx-worker),
this class does.

[Back to TOC](#table-of-contents)

Limiting Granularity
====================

All the concrete limiter objects must follow the same granularity (usually being the
NGINX server instance level, across all its worker processes).

Unmatched limiting granularity can cause unexpected results (which cannot happen if you
limit yourself to the concrete limiter classes provided by this library, which is always
on the NGINX server instance level).

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
* module [resty.limit.conn](./conn.md)
* module [resty.limit.count](./count.md)
* library [lua-resty-limit-traffic](../../../README.md)
* the ngx_lua module: https://github.com/openresty/lua-nginx-module
* OpenResty: https://openresty.org/

[Back to TOC](#table-of-contents)

