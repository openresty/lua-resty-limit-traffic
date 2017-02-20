# vim:set ft= ts=4 sw=4 et fdm=marker:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

repeat_each(2);

plan tests => repeat_each() * (blocks() * 4);

#no_diff();
#no_long_string();

my $pwd = cwd();

our $HttpConfig = <<_EOC_;
    lua_package_path "$pwd/../lua-resty-core/lib/?.lua;../lua-resty-lrucache/lib/?.lua;$pwd/lib/?.lua;;";
    init_by_lua_block {
        local v = require "jit.v"
        -- v.on("/tmp/a.dump")
        require "resty.core"
    }
    lua_shared_dict store 1m;
_EOC_

no_long_string();
run_tests();

__DATA__

=== TEST 1: a single key (always commit)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local limit_count = require "resty.limit.count"
            ngx.shared.store:flush_all()
            local lim = limit_count.new("store", 10, 100)
            local uri = ngx.var.uri
            for i = 1, 12 do
                local delay, err = lim:incoming(uri, true)
                if not delay then
                    ngx.say(err)
                else
                    local remaining = err
                    ngx.say("remaining: ", remaining)
                end
            end
        }
    }
--- request
    GET /t
--- response_body
remaining: 9
remaining: 8
remaining: 7
remaining: 6
remaining: 5
remaining: 4
remaining: 3
remaining: 2
remaining: 1
remaining: 0
rejected
rejected
--- no_error_log
[error]
[lua]



=== TEST 2: multiple keys
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local limit_count = require "resty.limit.count"
            ngx.shared.store:flush_all()
            local lim = limit_count.new("store", 1, 10)
            local delay1, err1 = lim:incoming("foo", true)
            local delay2, err2 = lim:incoming("foo", true)
            local delay3, err3 = lim:incoming("bar", true)
            local delay4, err4 = lim:incoming("bar", true)
            if not delay1 then
                ngx.say(err1)
            else
                local remaining1 = err1
                ngx.say("remaining1: ", remaining1)
            end

            if not delay2 then
                ngx.say(err2)
            else
                local remaining2 = err2
                ngx.say("remaining2: ", remaining2)
            end

            if not delay3 then
                ngx.say(err3)
            else
                local remaining3 = err3
                ngx.say("remaining3: ", remaining3)
            end

            if not delay4 then
                ngx.say(err4)
            else
                local remaining4 = err4
                ngx.say("remaining4: ", remaining4)
            end
        }
    }
--- request
    GET /t
--- response_body
remaining1: 0
rejected
remaining3: 0
rejected
--- no_error_log
[error]
[lua]



=== TEST 3: reset limit window
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local limit_count = require "resty.limit.count"
            ngx.shared.store:flush_all()
            local lim = limit_count.new("store", 1, 1)

            local uri = ngx.var.uri
            for i = 1, 2 do
                local delay, err = lim:incoming(uri, true)
                if not delay then
                    ngx.say(err)
                else
                    local remaining = err
                    ngx.say("remaining: ", remaining)
                end

                local delay, err = lim:incoming(uri, true)
                if not delay then
                    ngx.say(err)
                else
                    local remaining = err
                    ngx.say("remaining: ", remaining)
                end
                ngx.sleep(1)
            end
        }
    }
--- request
    GET /t
--- response_body
remaining: 0
rejected
remaining: 0
rejected
--- no_error_log
[error]
[lua]



=== TEST 4: a single key (do not commit since the 3rd time)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local limit_count = require "resty.limit.count"
            ngx.shared.store:flush_all()
            local lim = limit_count.new("store", 5, 10)
            local begin = ngx.time()

            for i = 1, 4 do
                local delay, err = lim:incoming("foo", i < 3)
                if not delay then
                    ngx.say(err)
                else
                    local remaining = err
                    ngx.say("remaining: ", remaining)
                end
            end
        }
    }
--- request
    GET /t
--- response_body
remaining: 4
remaining: 3
remaining: 2
remaining: 2
--- no_error_log
[error]
[lua]



=== TEST 5: a single key (commit & uncommit)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local limit_count = require "resty.limit.count"
            local lim = limit_count.new("store", 2, 10)
            ngx.shared.store:flush_all()
            local key = "foo"
            for i = 1, 3 do
                local delay, err = lim:incoming(key, true)
                if not delay then
                    ngx.say("failed to limit count: ", err)
                else
                    local remaining = err
                    ngx.say("remaining: ", remaining)
                end
                local ok, err = lim:uncommit(key)
                if not ok then
                    ngx.say("failed to uncommit: ", err)
                end
            end
        }
    }
--- request
    GET /t
--- response_body
remaining: 1
remaining: 1
remaining: 1
--- no_error_log
[error]
[lua]
