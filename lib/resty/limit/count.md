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
    * [uncommit](#uncommit)
* [Limiting Granularity](#limiting-granularity)
* [Installation](#installation)
* [Bugs and Patches](#bugs-and-patches)
* [Authors](#authors)
* [Copyright and License](#copyright-and-license)
* [See Also](#see-also)

Synopsis
========

```nginx
http {
    lua_shared_dict my_limit_count_store 100m;

    init_by_lua_block {
        require "resty.core"
    }

    server {
        location / {
            access_by_lua_block {
                local limit_count = require "resty.limit.count"

                -- rate: 5000 requests per 3600s
                local lim, err = limit_count.new("my_limit_count_store", 5000, 3600)
                if not lim then
                    ngx.log(ngx.ERR, "failed to instantiate a resty.limit.count object: ", err)
                    return ngx.exit(500)
                end

                -- use the Authorization header as the limiting key
                local key = ngx.req.get_headers()["Authorization"] or "public"
                local delay, err = lim:incoming(key, true)

                if not delay then
                    if err == "rejected" then
                        ngx.header["X-RateLimit-Limit"] = "5000"
                        ngx.header["X-RateLimit-Remaining"] = 0
                        return ngx.exit(503)
                    end
                    ngx.log(ngx.ERR, "failed to limit count: ", err)
                    return ngx.exit(500)
                end

                -- the 2nd return value holds the current remaining number
                -- of requests for the specified key.
                local remaining = err

                ngx.header["X-RateLimit-Limit"] = "5000"
                ngx.header["X-RateLimit-Remaining"] = remaining
            }
        }
    }
}
```

Description
===========

This module provides APIs to help the OpenResty/ngx_lua user programmers limit request
rate by a fixed number of requests in given time window.

It is included by default in [OpenResty](https://openresty.org/) 1.13.6.1+.

This Lua module's implementation is similar to [GitHub API Rate Limiting](https://developer.github.com/v3/#rate-limiting) But this Lua
module is flexible in that it can be configured with different rates and window sizes.

This module depends on [lua-resty-core](https://github.com/openresty/lua-resty-core), you should enable it like so:

```nginx
init_by_lua_block {
    require "resty.core"
}
```

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

* `time_window` is the time window in seconds before the request count is reset.

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
this method returns `0` as the delay and the remaining count of allowed requests at the current time (as the 2nd return value).

2. If the request exceeds the `count` limit specified in the [new](#new) method then
this method returns `nil` and the error string `"rejected"`.

3. If an error occurred (like failures when accessing the `lua_shared_dict` shm zone backing
the current object), then this method returns `nil` and a string describing the error.

[Back to TOC](#table-of-contents)

uncommit
--------
**syntax:** `remaining, err = obj:uncommit(key)`

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

Authors
=======

* Ke Zhu <kzhu@us.ibm.com>
* Ming Wen <moonbingbing@gmail.com>

[Back to TOC](#table-of-contents)

Copyright and License
=====================

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
* module [resty.limit.conn](./conn.md)
* module [resty.limit.traffic](./traffic.md)
* library [lua-resty-limit-traffic](../../../README.md)
* the ngx_lua module: https://github.com/openresty/lua-nginx-module
* OpenResty: https://openresty.org/

[Back to TOC](#table-of-contents)
