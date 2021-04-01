Name
====

resty.limit.req - Lua module for limiting request rate for OpenResty/ngx_lua.

Table of Contents
=================

* [Name](#name)
* [Synopsis](#synopsis)
* [Description](#description)
* [Methods](#methods)
    * [new](#new)
    * [incoming](#incoming)
    * [set_rate](#set_rate)
    * [set_burst](#set_burst)
    * [uncommit](#uncommit)
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
                    -- the 2nd return value holds  the number of excess requests
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

Description
===========

This module provides APIs to help the OpenResty/ngx_lua user programmers limit request
rate using the "leaky bucket" method.

If you want to use multiple different instances of this class at once or use one instance
of this class with instances of other classes (like [resty.limit.conn](./conn.md)),
then you *must* use the [resty.limit.traffic](./traffic.md) module to combine them.

This Lua module's implementation is similar to NGINX's standard module
[ngx_limit_req](http://nginx.org/en/docs/http/ngx_http_limit_req_module.html). But this Lua
module is more flexible in that it can be used in almost arbitrary contexts.

Methods
=======

[Back to TOC](#table-of-contents)

new
---
**syntax:** `obj, err = class.new(shdict_name, rate, burst)`

Instantiates an object of this class. The `class` value is returned by the call `require "resty.limit.req"`.

This method takes the following arguments:

* `shdict_name` is the name of the [lua_shared_dict](https://github.com/openresty/lua-nginx-module#lua_shared_dict) shm zone.

    It is best practice to use separate shm zones for different kinds of limiters.
* `rate` is the specified request rate (number per second) threshold.

    Requests exceeding this rate (and below `burst`) will get delayed to conform to the rate.
* `burst` is the number of excessive requests per second allowed to be delayed.

    Requests exceeding this hard limit
will get rejected immediately.

On failure, this method returns `nil` and a string describing the error (like a bad `lua_shared_dict` name).

[Back to TOC](#table-of-contents)

incoming
--------
**syntax:** `delay, err = obj:incoming(key, commit)`

Fires a new request incoming event and calculates the delay needed (if any) for the current request
upon the specified key or whether the user should reject it immediately.

This method accepts the following arguments:

* `key` is the user specified key to limit the rate.

    For example, one can use the host name (or server zone)
as the key so that we limit rate per host name. Otherwise, we can also use the client address as the
key so that we can avoid a single client from flooding our service.

    Please note that this module
does not prefix nor suffix the user key so it is the user's responsibility to ensure the key
is unique in the `lua_shared_dict` shm zone).
* `commit` is a boolean value. If set to `true`, the object will actually record the event
in the shm zone backing the current object; otherwise it would just be a "dry run" (which is the default).

The return values depend on the following cases:

1. If the request does not exceed the `rate` value specified in the [new](#new) method, then
this method returns `0` as the delay and the (zero) number of excessive requests per second at
the current time.
2. If the request exceeds the `rate` limit specified in the [new](#new) method but not
the `rate` + `burst` value, then
this method returns a proper delay (in seconds) for the current request so that it still conform to
the `rate` threshold as if it came a bit later rather than now.

    In addition, this method
also returns a second return value indicating the number of excessive requests per second
at this point (including the current request). This 2nd return value can be used to monitor the
unadjusted incoming request rate.
3. If the request exceeds the `rate` + `burst` limit, then this method returns `nil` and
the error string `"rejected"`.
4. If an error occurred (like failures when accessing the `lua_shared_dict` shm zone backing
the current object), then this method returns `nil` and a string describing the error.

This method never sleeps itself. It simply returns a delay if necessary and requires the caller
to later invoke the [ngx.sleep](https://github.com/openresty/lua-nginx-module#ngxsleep)
method to sleep.

[Back to TOC](#table-of-contents)

set_rate
--------
**syntax:** `obj:set_rate(rate)`

Overwrites the `rate` threshold as specified in the [new](#new) method.

[Back to TOC](#table-of-contents)

set_burst
---------
**syntax:** `obj:set_burst(burst)`

Overwrites the `burst` threshold as specified in the [new](#new) method.

[Back to TOC](#table-of-contents)

uncommit
--------
**syntax:** `ok, err = obj:uncommit(key)`

This tries to undo the commit of the `incoming` call. This is simply an approximation
and should be used with care. This method is mainly for being used in the [resty.limit.traffic](./traffic.md)
Lua module when combining multiple limiters at the same time.

[Back to TOC](#table-of-contents)

Instance Sharing
================

Each instance of this class carries no state information but the `rate` and `burst`
threshold values. The real limiting states based on keys are stored in the `lua_shared_dict`
shm zone specified in the [new](#new) method. So it is safe to share instances of
this class [on the nginx worker process level](https://github.com/openresty/lua-nginx-module#data-sharing-within-an-nginx-worker)
as long as the combination of `rate` and `burst` do not change.

Even if the `rate` and `burst`
combination *does* change, one can still share a single instance as long as he always
calls the [set_rate](#set_rate) and/or [set_burst](#set_burst) methods *right before*
the [incoming](#incoming) call.

[Back to TOC](#table-of-contents)

Limiting Granularity
====================

The limiting works on the granularity of an individual NGINX server instance (including all
its worker processes). Thanks to the shm mechanism; we can share state cheaply across
all the workers in a single NGINX server instance.

If you are running multiple NGINX server instances (like running multiple boxes), then
you need to ensure that the incoming traffic is (more or less) evenly distributed across
all the different NGINX server instances (or boxes). So if you want a limit rate of N req/sec
across all the servers, then you just need to specify a limit of `N/n` req/sec in each server's configuration. This simple strategy can save all the (big) overhead of sharing a global state across
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
* module [resty.limit.conn](./conn.md)
* module [resty.limit.count](./count.md)
* module [resty.limit.traffic](./traffic.md)
* library [lua-resty-limit-traffic](../../../README.md)
* the ngx_lua module: https://github.com/openresty/lua-nginx-module
* OpenResty: https://openresty.org/

[Back to TOC](#table-of-contents)

