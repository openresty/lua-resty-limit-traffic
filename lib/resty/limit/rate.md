Name
====

lua-resty-limit-rate - Lua module for limiting request rate for OpenResty/ngx_lua, using the "token bucket" method.

Table of Contents
=================

* [Status](#status)
* [Synopsis](#synopsis)
* [Description](#description)
* [Methods](#methods)
  * [new](#new)
  * [incoming](#incoming)
  * [set_max_wait](#set_max_wait)
  * [take](#take)
  * [take_available](#take_available)
  * [uncommit](#uncommit)
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
    lua_shared_dict my_limit_rate_store 100m;
    lua_shared_dict my_locks 100k;

    server {
        location / {
            access_by_lua_block {
                local limit_rate = require "resty.limit.rate"

                local lim, err = limit_rate.new("my_limit_rate_store", 500, 10, 3, 200, {
                    lock_enable = true, -- use lua-resty-lock
                    locks_shdict_name = "my_locks",
                })

                if not lim then
                    ngx.log(ngx.ERR,
                            "failed to instantiate a resty.limit.rate object: ", err)
                    return ngx.exit(500)
                end

                -- the following call must be per-request.
                -- here we use the remote (IP) address as the limiting key
                local key = ngx.var.binary_remote_addr
                local delay, err = lim:incoming(key, true)
                -- local delay, err = lim:take(key, 1, ture)
                if not delay then
                    if err == "rejected" then
                        return ngx.exit(503)
                    end
                    ngx.log(ngx.ERR, "failed to take token: ", err)
                    return ngx.exit(500)
                end

                if delay >= 0.001 then
                    -- the 2nd return value holds the current avail tokens number
                    -- of requests for the specified key
                    local avail = err

                    ngx.sleep(delay)
                end
            }

            # content handler goes here. if it is content_by_lua, then you can
            # merge the Lua code above in access_by_lua into your content_by_lua's
            # Lua handler to save a little bit of CPU time.
        }

        location /take_available {
            access_by_lua_block {
                local limit_rate = require "resty.limit.rate"

                -- global 20r/s 6000r/5m
                local lim_global = limit_rate.new("my_limit_rate_store", 100, 6000, 2, nil, {
                    lock_enable = true,
                    locks_shdict_name = "my_locks",
                })

                if not lim_global then
                    return ngx.exit(500)
                end

                -- single 2r/s 600r/5m
                local lim_single = limit_rate.new("my_limit_rate_store", 500, 600, 1, nil, {
                    locks_shdict_name = "my_locks",
                })

                if not lim_single then
                    return ngx.exit(500)
                end

                local t0, err = lim_global:take_available("__global__", 1)
                if not t0 then
                    ngx.log(ngx.ERR, "failed to take global: ", err)
                    return ngx.exit(500)
                end

                -- here we use the userid as the limiting key
                local key = ngx.var.arg_userid or "__single__"

                local t1, err = lim_single:take_available(key, 1)
                if not t1 then
                    ngx.log(ngx.ERR, "failed to take single: ", err)
                    return ngx.exit(500)
                end

                if t0 == 1 then
                    return -- global bucket is not hungry
                else
                    if t1 == 1 then
                        return -- single bucket is not hungry
                    else
                        return ngx.exit(503)
                    end
                end
            }
        }
    }
}
```

Description
===========

This module provides APIs to help the OpenResty/ngx_lua user programmers limit request rate using the "[token bucket](https://en.wikipedia.org/wiki/Token_bucket)" method.

If you want to use multiple different instances of this class at once or use one instance of this class with instances of other classes (like [resty.limit.conn](./conn.md)), then you *must* use the [resty.limit.traffic](./traffic.md) module to combine them.

The main difference between this module and [resty.limit.req](./req.md):

* [resty.limit.req](./req.md) limit request rate using the "leaky bucket" method, this module using the "token bucket" method.

The main difference between this module and [resty.limit.count](./count.md):

* [resty.limit.count](./count.md) offers a straightforward mental model that limit request rate by a fixed number of requests in given time window, but it can sometimes let through twice the number of allowed requests per minute. For example, if our rate limit were 10 requests per minute and a user made 10 requests at 10:00:59, they could make 10 more requests at 10:01:00 because a new counter begins at the start of each minute. In this case, this module able to control more precisely and smoothly.

Methods
=======

[Back to TOC](#table-of-contents)

new
---
**syntax:** `obj, err = class.new(shdict_name, interval, capacity, quantum?, max_wait?, opts?)`

Instantiates an object of this class. The `class` value is returned by the call `require "resty.limit.rate"`.

The method returns a new token bucket that fills at the rate of `quantum` number tokens every `interval`, up to the given maximum `capacity`. The bucket is initially full.

This method takes the following arguments and an optional options table `opts`:

* `shdict_name` is the name of the [lua_shared_dict](https://github.com/openresty/lua-nginx-module#lua_shared_dict) shm zone.

    It is best practice to use separate shm zones for different kinds of limiters.

* `interval` is the time passing between adding tokens, in milliseconds.

* `capacity` is the maximum number of tokens to hold in the bucket.

* `quantum` is the number of tokens to add to the bucket in one interval, this argument is optional, default `1`.

* `max_wait` is the maximum time that we would wait for enough tokens to be added, in milliseconds, this argument is optional, default `nil`, it means infinity.

The options table accepts the following options:

* `lock_enable` When enabled, update shdict state across multiple nginx worker process is atomic; otherwise will have a (small) race-condition window between the "read-and-then-write" behavior, default `false`. See [lua-resty-lock](http://github.com/openresty/lua-resty-lock) for more details.

* `locks_shdict_name` Specifies the shared dictionary name (created by [lua_shared_dict](http://https://github.com/openresty/lua-nginx-module#lua_shared_dict)) for the lock, default `locks`.

On failure, this method returns `nil` and a string describing the error (like a bad `lua_shared_dict` name).

[Back to TOC](#table-of-contents)

incoming
--------
**syntax:** `delay, err = obj:take(key, commit)`

Fires a new request incoming event and calculates the delay needed (if any) for the current request
upon the specified key or whether the user should reject it immediately.

Similar to the [take](#take) method, but this method only takes one token from the bucket at a time.

This method accepts the following arguments:

* `key` is the user specified key to limit the rate.

    Please note that this module does not prefix nor suffix the user key so it is the user's responsibility to ensure the key is unique in the `lua_shared_dict` shm zone.

* `commit` is a boolean value. If set to `true`, the object will actually record the event in the shm zone backing the current object; otherwise it would just be a "dry run" (which is the default).

[Back to TOC](#table-of-contents)

set_max_wait
------------
**syntax:** `obj:set_max_wait(max_wait?)`

Overwrites the `max_wait` threshold as specified in the [new](#new) method.

[Back to TOC](#table-of-contents)

take
----
**syntax:** `delay, err = obj:take(key, count, commit)`

The method takes count tokens from the bucket without blocking.

This method accepts the following arguments:

* `key` is the user specified key to limit the rate.

    Please note that this module does not prefix nor suffix the user key so it is the user's responsibility to ensure the key is unique in the `lua_shared_dict` shm zone.

* `count` is the number of tokens to remove.

* `commit` is a boolean value. If set to `true`, the object will actually record the event in the shm zone backing the current object; otherwise it would just be a "dry run" (which is the default).

The return values depend on the following cases:

1. If the `max_wait` vaule specified in the [new](#new) or [set_max_wait](#set_max_wait) method, the method will only take tokens from the bucket if the wait time for the tokens is no greater than `max_wait`, and returns the time that the caller should wait until the tokens are actually available, otherwise it returns `nil` and the error string `"rejected"`.

2. If the `max_wait` vaule is nil, it returns the time that the caller should wait until the tokens are actually available.

In addition, this method also returns a second return value indicating the number of the current avail tokens at this point.

If an error occurred (like failures when accessing the `lua_shared_dict` shm zone backing the current object), then this method returns nil and a string describing the error.

This method never sleeps itself. It simply returns a delay if necessary and requires the caller to later invoke the [ngx.sleep](https://github.com/openresty/lua-nginx-module#ngxsleep) method to sleep.

[Back to TOC](#table-of-contents)

take_available
--------------
**syntax:** `count, err = obj:take_available(key, count)`

The method takes up to count immediately available tokens from the bucket. It returns the number of tokens removed, or zero if there are no available tokens. It does not block.

This method accepts the following arguments:

* `key` is the user specified key to limit the rate.

    Please note that this module does not prefix nor suffix the user key so it is the user's responsibility to ensure the key is unique in the `lua_shared_dict` shm zone.

* `count` is the number of tokens to remove.

If an error occurred (like failures when accessing the lua_shared_dict shm zone backing the current object), then this method returns nil and a string describing the error.

[Back to TOC](#table-of-contents)

uncommit
--------
**syntax:** `ok, err = obj:uncommit(key)`

This tries to undo the commit of the `incoming` call. This is simply an approximation and should be used with care. This method is mainly for being used in the [resty.limit.traffic](./traffic.md) Lua module when combining multiple limiters at the same time.

[Back to TOC](#table-of-contents)

Limiting Granularity
====================

The limiting works on the granularity of an individual NGINX server instance (including all its worker processes). Thanks to the shm mechanism; we can share state cheaply across all the workers in a single NGINX server instance.

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

Monkey Zhang <timebug.info@gmail.com>, UPYUN Inc.

[Back to TOC](#table-of-contents)

# Copyright and License

This module is licensed under the BSD license.

Copyright (C) 2016-2017, by Yichun "agentzh" Zhang, OpenResty Inc.

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
* module [resty.limit.traffic](./traffic.md)
* library [lua-resty-limit-traffic](../../../README.md)
* the ngx_lua module: https://github.com/openresty/lua-nginx-module
* OpenResty: https://openresty.org/

[Back to TOC](#table-of-contents)
