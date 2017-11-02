Name
====

lua-resty-limit-token - Lua module for limiting request rate for OpenResty/ngx_lua, using the token bucket method.

Table of Contents
=================

* [Status](#status)
* [Synopsis](#synopsis)
* [Description](#description)
* [Methods](#methods)
  * [new](#new)
  * [rate](#rate)
  * [take](#take)
  * [take_available](#take_available)
* [Limiting Granularity](#limiting-granularity)
* [Installation](#installation)
* [Bugs and Patches](#bugs-and-patches)
* [Author](#author)
* [Copyright and License](#copyright-and-license)
* [See Also](#see-also)

Synopsis
========

```nginx
http {
    lua_shared_dict my_limit_token_store 100m;
    lua_shared_dict my_locks 100k;

    server {
        location / {
            access_by_lua_block {
                local limit_token = require "resty.limit.token"

                local lim, err = limit_token.new("my_limit_token_store", 500, 10, 3, {
                    locks_shdict_name = "my_locks", -- use lua-resty-lock
                })

                if not lim then
                    ngx.log(ngx.ERR,
                            "failed to instantiate a resty.limit.token object: ", err)
                    return ngx.exit(500)
                end

                -- the following call must be per-request.
                -- here we use the remote (IP) address as the limiting key
                local key = ngx.var.binary_remote_addr
                local delay, err = lim:take(key, 2, 200)
                if not delay then
                    if err == "rejected" then
                        return ngx.exit(503)
                    end
                    ngx.log(ngx.ERR, "failed to take token: ", err)
                    return ngx.exit(500)
                end

                if delay >= 0.001 then
                    ngx.sleep(delay)
                end
            }

            # content handler goes here. if it is content_by_lua, then you can
            # merge the Lua code above in access_by_lua into your content_by_lua's
            # Lua handler to save a little bit of CPU time.
        }

        location /available {
            access_by_lua_block {
                local limit_token = require "resty.limit.token"

                -- global 20r/s 6000r/5m
                local lim_global, err = limit_token.new("my_limit_token_store", 100, 6000, 2, {
                    locks_shdict_name = "my_locks",
                })

                if not lim_global then
                    ngx.log(ngx.ERR,
                            "failed to instantiate a resty.limit.token object: ", err)
                    return ngx.exit(500)
                end

                -- single 2r/s 600r/5m
                local lim_single, err = limit_token.new("my_limit_token_store", 500, 600, 1, {
                    locks_shdict_name = "my_locks",
                })

                if not lim_single then
                    ngx.log(ngx.ERR,
                            "failed to instantiate a resty.limit.token object: ", err)
                    return ngx.exit(500)
                end

                local t0, err = lim_global:take_available("__global__", 1)
                if not t0 then
                    ngx.log(ngx.ERR, "failed to take available: ", err)
                    return ngx.exit(500)
                end

                -- here we use the userid as the limiting key
                local key = ngx.var.arg_userid or "__single__"

                local t1, err = lim_single:take_available(key, 1)
                if not t1 then
                    ngx.log(ngx.ERR, "failed to take available: ", err)
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

Methods
=======

[Back to TOC](#table-of-contents)

new
===

**syntax:** `obj, err = class.new(shdict_name, interval, capacity, quantum?, opts?)`

Instantiates an object of this class. The `class` value is returned by the call `require "resty.limit.token"`.

The method returns a new token bucket that fills at the rate of `quantum` number tokens every `interval`, up to the given maximum `capacity`. The bucket is initially full.

This method takes the following arguments and an optional options table `opts`:

* `shdict_name` is the name of the [lua_shared_dict](https://github.com/openresty/lua-nginx-module#lua_shared_dict) shm zone.

    It is best practice to use separate shm zones for different kinds of limiters.

* `interval` is the time passing between adding tokens, in milliseconds.

* `capacity` is the maximum number of tokens to hold in the bucket.

* `quantum` is the number of tokens to add to the bucket in one interval, default `1`.

The options table accepts the following options:

* `locks_shdict_name` Specifies the shared dictionary name (created by [lua_shared_dict](http://https://github.com/openresty/lua-nginx-module#lua_shared_dict)) for the lock, default `locks`. See [lua-resty-lock](http://github.com/agentzh/lua-resty-lock) for more details.

On failure, this method returns `nil` and a string describing the error (like a bad `lua_shared_dict` name).


[Back to TOC](#table-of-contents)

rate
====

**syntax:** `rate = obj:rate()`

The method returns the fill rate of the bucket, in tokens per second.

[Back to TOC](#table-of-contents)

take
====

**syntax:** `delay, err = obj:take(key, count, max_wait?)`

The method takes count tokens from the bucket without blocking. If the 3rd argument is `nil`, it returns the time that the caller should wait until the tokens are actually available.

This method accepts the following arguments:

* `key` is the user specified key to limit the rate.

    Please note that this module does not prefix nor suffix the user key so it is the user's responsibility to ensure the key is unique in the `lua_shared_dict` shm zone.

* `count` is the number of tokens to remove.

* `max_wait` is the maximum time that we would wait for enough tokens to be added, in milliseconds. This argument is optional.

    In this way, the method will only take tokens from the bucket if the wait time for the tokens is no greater than `max_wait`, and returns the time that the caller should wait until the tokens are actually available, otherwise it returns `nil` and the error string `"rejected"`.

If an error occurred (like failures when accessing the lua_shared_dict shm zone backing the current object), then this method returns nil and a string describing the error.

[Back to TOC](#table-of-contents)

take_available
==============

**syntax:** `count, err = obj:take_available(key, count)`

The method takes up to count immediately available tokens from the bucket. It returns the number of tokens removed, or zero if there are no available tokens. It does not block.

This method accepts the following arguments:

* `key` is the user specified key to limit the rate.

    Please note that this module does not prefix nor suffix the user key so it is the user's responsibility to ensure the key is unique in the `lua_shared_dict` shm zone.

* `count` is the number of tokens to remove.

If an error occurred (like failures when accessing the lua_shared_dict shm zone backing the current object), then this method returns nil and a string describing the error.

[Back to TOC](#table-of-contents)

Limiting Granularity
====================

The limiting works on the granularity of an individual NGINX server instance (including all its worker processes). Thanks to the shm mechanism; we can share state cheaply across all the workers in a single NGINX server instance.

[Back to TOC](#table-of-contents)

Installation
============

Please see [library installation instructions](../../../README.md#installation).

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

* module [resty.limit.traffic](./traffic.md)
* library [lua-resty-limit-traffic](../../../README.md)
* the ngx_lua module: https://github.com/openresty/lua-nginx-module
* OpenResty: https://openresty.org/

[Back to TOC](#table-of-contents)
