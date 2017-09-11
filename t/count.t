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
            local limit_count = require "resty.limit.count"
            ngx.shared.store:flush_all()
            local lim = limit_count.new("store", 10, 100)
            local begin = ngx.time()
            local uri = ngx.var.uri
            for i = 1, 12 do
                local delay, err, reset = lim:incoming(uri, true)
                if not delay then
                    ngx.say(err)
                    ngx.say("reset after 100s: ", reset == (begin + 100))
                else
                    local remaining = err
                    ngx.say("remaining: ", remaining, ", reset after 100s: ", reset == (begin + 100))
                end
            end
        ';
    }
--- request
    GET /t
--- response_body
remaining: 9, reset after 100s: true
remaining: 8, reset after 100s: true
remaining: 7, reset after 100s: true
remaining: 6, reset after 100s: true
remaining: 5, reset after 100s: true
remaining: 4, reset after 100s: true
remaining: 3, reset after 100s: true
remaining: 2, reset after 100s: true
remaining: 1, reset after 100s: true
remaining: 0, reset after 100s: true
rejected
reset after 100s: true
rejected
reset after 100s: true
--- no_error_log
[error]
[lua]



=== TEST 2: multiple keys
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
"
--- config
    location = /t {
        content_by_lua '
            local limit_count = require "resty.limit.count"
            ngx.shared.store:flush_all()
            local lim = limit_count.new("store", 1, 10)
            local begin = ngx.time()
            local delay1, err1, reset1 = lim:incoming("foo", true)
            local delay2, err2, reset2 = lim:incoming("foo", true)
            local delay3, err3, reset3 = lim:incoming("bar", true)
            local delay4, err4, reset4 = lim:incoming("bar", true)
            if not delay1 then
                ngx.say(err1)
                ngx.say("reset1 after 10s: ", reset1 == (begin + 10))
            else
                local remaining1 = err1
                ngx.say("remaining1: ", remaining1, ", reset1 after 10s: ", reset1 == (begin + 10))
            end

            if not delay2 then
                ngx.say(err2)
                ngx.say("reset2 after 10s: ", reset2 == (begin + 10))
            else
                local remaining2 = err2
                ngx.say("remaining2: ", remaining2, ", reset2 after 10s: ", reset2 == (begin + 10))
            end

            if not delay3 then
                ngx.say(err3)
                ngx.say("reset3 after 10s: ", reset3 == (begin + 10))
            else
                local remaining3 = err3
                ngx.say("remaining3: ", remaining3, ", reset3 after 10s: ", reset3 == (begin + 10))
            end

            if not delay4 then
                ngx.say(err4)
                ngx.say("reset4 after 10s: ", reset4 == (begin + 10))
            else
                local remaining4 = err4
                ngx.say("remaining4: ", remaining4, ", reset1 after 10s: ", reset4 == (begin + 10))
            end
        ';
    }
--- request
    GET /t
--- response_body
remaining1: 0, reset1 after 10s: true
rejected
reset2 after 10s: true
remaining3: 0, reset3 after 10s: true
rejected
reset4 after 10s: true
--- no_error_log
[error]
[lua]



=== TEST 3: reset limit window
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
"
--- config
    location = /t {
        content_by_lua '
            local limit_count = require "resty.limit.count"
            ngx.shared.store:flush_all()
            local lim = limit_count.new("store", 1, 1)
            local begin = ngx.time()

            local uri = ngx.var.uri
            for i = 1, 2 do
                local delay, err, reset = lim:incoming(uri, true)
                if not delay then
                    ngx.say(err)
                    ngx.say("reset - begin: ", tostring(reset - begin))
                else
                    local remaining = err
                    ngx.say("remaining: ", remaining, ", reset - begin: ", tostring(reset - begin))
                end

                local delay, err, reset = lim:incoming(uri, true)
                if not delay then
                    ngx.say(err)
                    ngx.say("reset - begin: ", tostring(reset - begin))
                else
                    local remaining = err
                    ngx.say("remaining: ", remaining, ", reset - begin: ", tostring(reset - begin))
                end
                ngx.sleep(1)
            end
        ';
    }
--- request
    GET /t
--- response_body
remaining: 0, reset - begin: 1
rejected
reset - begin: 1
remaining: 0, reset - begin: 2
rejected
reset - begin: 2
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
            local limit_count = require "resty.limit.count"
            ngx.shared.store:flush_all()
            local lim = limit_count.new("store", 5, 10)
            local begin = ngx.time()

            for i = 1, 4 do
                local delay, err, reset = lim:incoming("foo", i < 3 and true or false)
                if not delay then
                    ngx.say(err)
                    ngx.say("reset - begin: ", tostring(reset - begin))
                else
                    local remaining = err
                    ngx.say("remaining: ", remaining, ", reset - begin: ", tostring(reset - begin))
                end
            end
        ';
    }
--- request
    GET /t
--- response_body
remaining: 4, reset - begin: 10
remaining: 3, reset - begin: 10
remaining: 2, reset - begin: 10
remaining: 2, reset - begin: 10
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
            local limit_count = require "resty.limit.count"
            local lim = limit_count.new("store", 2, 10)
            ngx.shared.store:flush_all()
            local key = "foo"
            local begin = ngx.time()
            for i = 1, 3 do
                local delay, err, reset = lim:incoming(key, true)
                if not delay then
                    ngx.say("failed to limit count: ", err)
                else
                    local remaining = err
                    ngx.say("remaining: ", remaining, ", reset - begin: ", tostring(reset - begin))
                end
                local ok, err = lim:uncommit(key)
                if not ok then
                    ngx.say("failed to uncommit: ", err)
                end
            end
        ';
    }
--- request
    GET /t
--- response_body
remaining: 1, reset - begin: 10
remaining: 1, reset - begin: 10
remaining: 1, reset - begin: 10
--- no_error_log
[error]
[lua]
