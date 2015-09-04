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
            for i = 1, 80 do
                local delay, err = lim:incoming(uri, true)
                if not delay then
                    ngx.say("failed to limit request: ", err)
                    return
                end
                ngx.sleep(delay)
            end
            ngx.say("elapsed: ", ngx.now() - begin, " sec.")
        ';
    }
--- request
    GET /t
--- response_body_like eval
qr/^elapsed: 1\.9[6-9]\d* sec\.$/
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
            local limit_req = require "resty.limit.req"
            ngx.shared.store:flush_all()
            local lim = limit_req.new("store", 2, 10)
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
delay2: 0.5
excess2: 1
delay3: 0
delay4: 0.5
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
2: error: rejected
3: error: rejected
4: error: rejected
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
delay: 0.5
delay: 1
delay: 1
--- no_error_log
[error]
[lua]



=== TEST 5: bad value in shdict (integer type)
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
            local key = "bar"
            ngx.shared.store:set("bar", 32)
            local lim = limit_req.new("store", 2, 10)
            local delay, err = lim:incoming(key, true)
            if not delay then
                ngx.say("failed to limit request: ", err)
            else
                ngx.say("delay: ", delay)
            end
        ';
    }
--- request
    GET /t
--- response_body
failed to limit request: shdict abused by other users
--- no_error_log
[error]
[lua]



=== TEST 6: bad value in shdict (string type, and wrong size)
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
            local key = "bar"
            ngx.shared.store:set("bar", "a")
            local lim = limit_req.new("store", 2, 10)
            local delay, err = lim:incoming(key, true)
            if not delay then
                ngx.say("failed to limit request: ", err)
            else
                ngx.say("delay: ", delay)
            end
        ';
    }
--- request
    GET /t
--- response_body
failed to limit request: shdict abused by other users
--- no_error_log
[error]
[lua]
