# vim:set ft= ts=4 sw=4 et fdm=marker:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

repeat_each(2);

plan tests => repeat_each() * (blocks() * 4);

#no_diff();
#no_long_string();

my $pwd = cwd();

our $HttpConfig = <<_EOC_;
    lua_package_path "$pwd/lib/?.lua;;";
_EOC_

no_long_string();
run_tests();

__DATA__

=== TEST 1: a single key (always commit)
--- http_config eval
qq{
$::HttpConfig

    init_by_lua_block {
        local v = require "jit.v"
        -- v.on("/tmp/a.dump")
    }
    lua_shared_dict store 1m;
}
--- config
    location = /t {
        content_by_lua '
            local limit_req = require "resty.limit.req"
            ngx.shared.store:flush_all()
            local lim = limit_req.new("store", 40, 40)
            local begin = ngx.now()
            local uri = ngx.var.uri
            for i = 1, 80 do
                local delay, err = lim:incoming(uri, true)
                ngx.say("i=", i, ", delay=", delay)
                if not delay then
                    ngx.say("failed to limit request: ", err)
                    return
                end
            end
            ngx.say("elapsed: ", ngx.now() - begin, " sec.")
        ';
    }
--- request
    GET /t
--- response_body_like
.*i=57, delay=0.425.*
--- response_body_like
.*i=67, delay=0.675.*
--- response_body_like
i=80, delay=1
--- no_error_log
[error]
[lua]
--- timeout: 10



=== TEST 2: multiple keys
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
"
--- config
    location = /t {
        content_by_lua '
            local limit_req = require "resty.limit.req"
            ngx.shared.store:flush_all()
            local lim = limit_req.new("store", 1, 10)
            local delay1, excess1 = lim:incoming("foo", true)
            local delay2, excess2 = lim:incoming("foo", true)
            local delay3 = lim:incoming("bar", true)
            local delay4 = lim:incoming("bar", true)
            ngx.say("delay1: ", delay1)
            ngx.say("excess1: ", excess1)
            ngx.say("delay2: ", delay2)
            ngx.say("excess2: ", excess2)
            ngx.say("delay3: ", delay3)
            ngx.say("delay4: ", delay4)
        ';
    }
--- request
    GET /t
--- response_body
delay1: 0
excess1: 0
delay2: 1
excess2: 1
delay3: 0
delay4: 1
--- no_error_log
[error]
[lua]



=== TEST 3: burst
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
"
--- config
    location = /t {
        content_by_lua '
            local limit_req = require "resty.limit.req"
            local lim = limit_req.new("store", 2, 0)

            for burst = 0, 2 do
                ngx.shared.store:flush_all()
                if burst > 0 then
                    lim:set_burst(burst)
                end

                for i = 1, 10 do
                    local delay, err = lim:incoming("foo", true)
                    if not delay then
                        ngx.say(i, ": error: ", err)
                        break
                    end
                end
            end
        ';
    }
--- request
    GET /t
--- response_body
3: error: rejected
4: error: rejected
5: error: rejected
--- no_error_log
[error]
[lua]



=== TEST 4: a single key (do not commit since the 3rd time)
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
"
--- config
    location = /t {
        content_by_lua '
            local limit_req = require "resty.limit.req"
            ngx.shared.store:flush_all()
            local lim = limit_req.new("store", 2, 10)
            local key = "bar"
            for i = 1, 4 do
                local delay, err = lim:incoming(key, i < 3 and true or false)
                if not delay then
                    ngx.say("failed to limit request: ", err)
                else
                    ngx.say("delay: ", delay)
                end
            end
        ';
    }
--- request
    GET /t
--- response_body
delay: 0
delay: 0
delay: 0.5
delay: 0.5
--- no_error_log
[error]
[lua]



=== TEST 5: a single key (commit & uncommit)
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
"
--- config
    location = /t {
        content_by_lua '
            local limit_req = require "resty.limit.req"
            ngx.shared.store:flush_all()
            local lim = limit_req.new("store", 40, 40)
            local begin = ngx.now()
            local uri = ngx.var.uri
            for i = 1, 40 do
                local delay, err = lim:incoming(uri, true)
                if not delay or delay ~= 0 then
                    ngx.say("failed to allow request ", i, ": ", err)
                    return
                end
            end
            for i = 41, 80 do
                local delay, err = lim:incoming(uri, true)
                if not delay then
                    ngx.say("failed to delay request ", i, ": ", err)
                    return
                end
                ngx.say(i, ": delay: ", delay)
                -- --[[
                local ok, err = lim:uncommit(uri)
                if not ok then
                    ngx.say("failed to uncommit: ", err)
                    return
                end
                -- ]]
            end
        ';
    }
--- request
    GET /t
--- response_body_like
1: delay: 0
2: delay: 0
3: delay: 0
4: delay: 0
5: delay: 0
--- response_body_like
36: delay: 0
37: delay: 0
38: delay: 0
39: delay: 0
40: delay: 0
--- response_body_like
41: delay: 0.025
42: delay: 0.025
43: delay: 0.025
--- response_body_like
62: delay: 0.025
63: delay: 0.025
64: delay: 0.025
65: delay: 0.025
--- response_body_like
78: delay: 0.025
79: delay: 0.025
80: delay: 0.025
--- no_error_log
[error]
[lua]
