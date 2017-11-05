# vim:set ft= ts=4 sw=4 et fdm=marker:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

repeat_each(2);

plan tests => repeat_each() * (blocks() * 4);

#no_diff();
#no_long_string();

my $pwd = cwd();

our $HttpConfig = <<_EOC_;
    lua_package_path "$pwd/../lua-resty-lock/lib/?.lua;$pwd/lib/?.lua;;";
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
    location /t {
        content_by_lua '
            local limit_rate = require "resty.limit.rate"
            ngx.shared.store:flush_all()

            local uri = ngx.var.uri
            local lim = limit_rate.new("store", 25, 10, 1, 1000)
            local begin = ngx.now()
            local uri = ngx.var.uri
            for i = 1, 50 do
                local delay, err = lim:incoming(uri, true)
                if not delay then
                    ngx.say("failed to limit request: ", err)
                    return
                end
                ngx.sleep(delay)
            end
            ngx.sleep(0.001)
            ngx.say("elapsed: ", ngx.now() - begin, " sec.")

        ';
    }
--- request
GET /t
--- response_body_like eval
qr/^elapsed: 1\.00[0-8]\d* sec\.$/
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
    location /t {
        content_by_lua '
            local limit_rate = require "resty.limit.rate"
            ngx.shared.store:flush_all()

            local lim = limit_rate.new("store", 500, 1, 1, 1000)
            local delay1, avail1 = lim:incoming("foo", true)
            local delay2, avail2 = lim:incoming("foo", true)
            local delay3, avail3 = lim:incoming("bar", true)
            local delay4, avail4 = lim:incoming("bar", true)
            ngx.say("delay1: ", delay1)
            ngx.say("avail1: ", avail1)
            ngx.say("delay2: ", delay2)
            ngx.say("avail2: ", avail2)
            ngx.say("delay3: ", delay3)
            ngx.say("avail3: ", avail3)
            ngx.say("delay4: ", delay4)
            ngx.say("avail4: ", avail4)
        ';
    }
--- request
GET /t
--- response_body
delay1: 0
avail1: 0
delay2: 0.5
avail2: -1
delay3: 0
avail3: 0
delay4: 0.5
avail4: -1
--- no_error_log
[error]
[lua]



=== TEST 3: max wait
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
"
--- config
    location /t {
        content_by_lua '
            local limit_rate = require "resty.limit.rate"
            local lim = limit_rate.new("store", 500, 2)

            local max_wait = {1000, 2000, 3000}

            for t = 0, 3 do
                ngx.shared.store:flush_all()
                if t > 0 then
                    lim:set_max_wait(max_wait[t])
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
5: error: rejected
7: error: rejected
9: error: rejected
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
    location /t {
        content_by_lua '
            local limit_rate = require "resty.limit.rate"
            ngx.shared.store:flush_all()

            local lim = limit_rate.new("store", 500, 1)
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
    location /t {
        content_by_lua '
            local limit_rate = require "resty.limit.rate"
            ngx.shared.store:flush_all()
            local key = "bar"
            ngx.shared.store:set("bar", 32)
            local lim = limit_rate.new("store", 500, 1)
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
    location /t {
        content_by_lua '
            local limit_rate = require "resty.limit.rate"
            ngx.shared.store:flush_all()
            local key = "bar"
            ngx.shared.store:set("bar", "a")
            local lim = limit_rate.new("store", 500, 1)
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



=== TEST 7: a single key (commit & uncommit)
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
"
--- config
    location /t {
        content_by_lua '
            local limit_rate = require "resty.limit.rate"
            ngx.shared.store:flush_all()
            local lim = limit_rate.new("store", 25, 1)
            local begin = ngx.now()
            local uri = ngx.var.uri
            for i = 1, 5 do
                local delay, err = lim:incoming(uri, true)
                if not delay then
                    ngx.say("failed to limit request: ", err)
                    return
                end
                ngx.say(i, ": delay: ", delay)
                -- --[[
                if i > 1 then
                    local ok, err = lim:uncommit(uri)
                    if not ok then
                        ngx.say("failed to uncommit: ", err)
                    end
                end
                -- ]]
            end
        ';
    }
--- request
GET /t
--- response_body
1: delay: 0
2: delay: 0.025
3: delay: 0.025
4: delay: 0.025
5: delay: 0.025
--- no_error_log
[error]
[lua]



=== TEST 8: take and lock enabled
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
    lua_shared_dict my_locks 100k;
"
--- config
    location /t {
        content_by_lua '
            local limit_rate = require "resty.limit.rate"
            ngx.shared.store:flush_all()

            local uri = ngx.var.uri
            local lim = limit_rate.new("store", 250, 10, 1, nil, {
                lock_enable = true,
                locks_shdict_name = "my_locks",
            })

            local now = ngx.now() * 1000
            local delay1, avail1 = lim:take(uri, 10, true, now)
            local delay2, avail2 = lim:take(uri, 2, true, now)
            local delay3, avail3 = lim:take(uri, 2, true, now)
            local delay4, avail4 = lim:take(uri, 1, true, now)

            ngx.say("delay1: ", delay1)
            ngx.say("avail1: ", avail1)
            ngx.say("delay2: ", delay2)
            ngx.say("avail2: ", avail2)
            ngx.say("delay3: ", delay3)
            ngx.say("avail3: ", avail3)
            ngx.say("delay4: ", delay4)
            ngx.say("avail4: ", avail4)
        ';
    }
--- request
GET /t
--- response_body
delay1: 0
avail1: 0
delay2: 0.5
avail2: -2
delay3: 1
avail3: -4
delay4: 1.25
avail4: -5
--- no_error_log
[error]
[lua]



=== TEST 9: take - offset time and default locks shdict name
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
    lua_shared_dict locks 100k;
"
--- config
    location /t {
        content_by_lua '
            local limit_rate = require "resty.limit.rate"
            ngx.shared.store:flush_all()

            local uri = ngx.var.uri
            local lim = limit_rate.new("store", 250, 10, 1, nil, {
                lock_enable = true,
            })

            local now = ngx.now() * 1000
            local delay1, avail1 = lim:take(uri, 10, true, now)
            local delay2, avail2 = lim:take(uri, 1, true, now)
            local delay3, avail3 = lim:take(uri, 1, true, now + 250)

            ngx.say("delay1: ", delay1)
            ngx.say("avail1: ", avail1)
            ngx.say("delay2: ", delay2)
            ngx.say("avail2: ", avail2)
            ngx.say("delay3: ", delay3)
            ngx.say("avail3: ", avail3)
        ';
    }
--- request
GET /t
--- response_body
delay1: 0
avail1: 0
delay2: 0.25
avail2: -1
delay3: 0.25
avail3: -1
--- no_error_log
[error]
[lua]



=== TEST 10: take - more than capacity
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
"
--- config
    location /t {
        content_by_lua '
            local limit_rate = require "resty.limit.rate"
            ngx.shared.store:flush_all()

            local uri = ngx.var.uri
            local lim = limit_rate.new("store", 1, 10)

            local now = ngx.now() * 1000
            local delay1, avail1 = lim:take(uri, 10, true, now)
            local delay2, avail2 = lim:take(uri, 15, true, now + 20)

            ngx.say("delay1: ", delay1)
            ngx.say("avail1: ", avail1)
            ngx.say("delay2: ", delay2)
            ngx.say("avail2: ", avail2)
        ';
    }
--- request
GET /t
--- response_body
delay1: 0
avail1: 0
delay2: 0.005
avail2: -5
--- no_error_log
[error]
[lua]



=== TEST 11: take - offset sub-quantum time
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
"
--- config
    location /t {
        content_by_lua '
            local limit_rate = require "resty.limit.rate"
            ngx.shared.store:flush_all()

            local uri = ngx.var.uri
            local lim = limit_rate.new("store", 10, 10)

            local now = ngx.now() * 1000
            local delay1, avail1 = lim:take(uri, 10, true, now)
            local delay2, avail2 = lim:take(uri, 1, true, now + 7)
            local delay3, avail3 = lim:take(uri, 1, true, now + 8)
            local delay4, avail4 = lim:take(uri, 1, true, now + 10)
            local delay5, avail5 = lim:take(uri, 1, true, now + 25)

            ngx.say("delay1: ", delay1)
            ngx.say("avail1: ", avail1)
            ngx.say("delay2: ", delay2)
            ngx.say("avail2: ", avail2)
            ngx.say("delay3: ", delay3)
            ngx.say("avail3: ", avail3)
            ngx.say("delay4: ", delay4)
            ngx.say("avail4: ", avail4)
            ngx.say("delay5: ", delay5)
            ngx.say("avail5: ", avail5)
        ';
    }
--- request
GET /t
--- response_body
delay1: 0
avail1: 0
delay2: 0.003
avail2: -1
delay3: 0.012
avail3: -2
delay4: 0.02
avail4: -2
delay5: 0.015
avail5: -2
--- no_error_log
[error]
[lua]




=== TEST 12: take - within capacity
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
"
--- config
    location /t {
        content_by_lua '
            local limit_rate = require "resty.limit.rate"
            ngx.shared.store:flush_all()

            local uri = ngx.var.uri
            local lim = limit_rate.new("store", 10, 5)

            local now = ngx.now() * 1000
            local delay1, avail1 = lim:take(uri, 5, true, now)
            local delay2, avail2 = lim:take(uri, 5, true, now + 60)
            local delay3, avail3 = lim:take(uri, 1, true, now + 60)
            local delay4, avail4 = lim:take(uri, 2, true, now + 80)

            ngx.say("delay1: ", delay1)
            ngx.say("avail1: ", avail1)
            ngx.say("delay2: ", delay2)
            ngx.say("avail2: ", avail2)
            ngx.say("delay3: ", delay3)
            ngx.say("avail3: ", avail3)
            ngx.say("delay4: ", delay4)
            ngx.say("avail4: ", avail4)
        ';
    }
--- request
GET /t
--- response_body
delay1: 0
avail1: 0
delay2: 0
avail2: 0
delay3: 0.01
avail3: -1
delay4: 0.01
avail4: -1
--- no_error_log
[error]
[lua]



=== TEST 13: take - max wait
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
"
--- config
    location /t {
        content_by_lua '
            local limit_rate = require "resty.limit.rate"
            ngx.shared.store:flush_all()

            local uri = ngx.var.uri
            local lim = limit_rate.new("store", 1, 10)

            local now = ngx.now() * 1000
            local delay1, err1 = lim:take(uri, 10, true, now)
            lim:set_max_wait(4)
            local delay2, err2 = lim:take(uri, 15, true, now + 20)
            local delay3, err3 = lim:take(uri, 10, true, now + 25)

            ngx.say("delay1: ", delay1)
            ngx.say("err1: ", err1)
            ngx.say("delay2: ", delay2)
            ngx.say("err2: ", err2)
            ngx.say("delay3: ", delay3)
            ngx.say("err3: ", err3)
        ';
    }
--- request
GET /t
--- response_body
delay1: 0
err1: 0
delay2: nil
err2: rejected
delay3: 0
err3: 0
--- no_error_log
[error]
[lua]



=== TEST 14: take - count greater than capacity
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
"
--- config
    location /t {
        content_by_lua '
            local limit_rate = require "resty.limit.rate"
            ngx.shared.store:flush_all()

            local uri = ngx.var.uri
            local lim = limit_rate.new("store", 1, 10, 1, 4)

            local now = ngx.now() * 1000
            local delay1, err1 = lim:take(uri, 15, true, now)
            lim:set_max_wait()
            local delay2, err2 = lim:take(uri, 15, true, now + 20)

            ngx.say("delay1: ", delay1)
            ngx.say("err1: ", err1)
            ngx.say("delay2: ", delay2)
            ngx.say("err2: ", err2)
        ';
    }
--- request
GET /t
--- response_body
delay1: nil
err1: rejected
delay2: 0.005
err2: -5
--- no_error_log
[error]
[lua]



=== TEST 15: take_available
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
"
--- config
    location /t {
        content_by_lua '
            local limit_rate = require "resty.limit.rate"
            ngx.shared.store:flush_all()

            local uri = ngx.var.uri
            local lim = limit_rate.new("store", 250, 10)

            local now = ngx.now() * 1000
            local count1, _ = lim:take_available(uri, 5, now)
            local count2, _ = lim:take_available(uri, 2, now)
            local count3, _ = lim:take_available(uri, 5, now)
            local count4, _ = lim:take_available(uri, 1, now)

            ngx.say("count1: ", count1)
            ngx.say("count2: ", count2)
            ngx.say("count3: ", count3)
            ngx.say("count4: ", count4)
        ';
    }
--- request
GET /t
--- response_body
count1: 5
count2: 2
count3: 3
count4: 0
--- no_error_log
[error]
[lua]



=== TEST 16: take_available - offset time
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
"
--- config
    location /t {
        content_by_lua '
            local limit_rate = require "resty.limit.rate"
            ngx.shared.store:flush_all()

            local uri = ngx.var.uri
            local lim = limit_rate.new("store", 250, 10)

            local now = ngx.now() * 1000
            local count1, _ = lim:take_available(uri, 0, now)
            local count2, _ = lim:take_available(uri, 10, now)
            local count3, _ = lim:take_available(uri, 1, now)
            local count4, _ = lim:take_available(uri, 1, now + 250)

            ngx.say("count1: ", count1)
            ngx.say("count2: ", count2)
            ngx.say("count3: ", count3)
            ngx.say("count4: ", count4)
        ';
    }
--- request
GET /t
--- response_body
count1: 0
count2: 10
count3: 0
count4: 1
--- no_error_log
[error]
[lua]



=== TEST 17: take_available - more than capacity
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
"
--- config
    location /t {
        content_by_lua '
            local limit_rate = require "resty.limit.rate"
            ngx.shared.store:flush_all()

            local uri = ngx.var.uri
            local lim = limit_rate.new("store", 1, 10)

            local now = ngx.now() * 1000
            local count1, _ = lim:take_available(uri, 10, now)
            local count2, _ = lim:take_available(uri, 15, now + 20)

            ngx.say("count1: ", count1)
            ngx.say("count2: ", count2)
        ';
    }
--- request
GET /t
--- response_body
count1: 10
count2: 10
--- no_error_log
[error]
[lua]



=== TEST 18: take_available - within capacity
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
"
--- config
    location /t {
        content_by_lua '
            local limit_rate = require "resty.limit.rate"
            ngx.shared.store:flush_all()

            local uri = ngx.var.uri
            local lim = limit_rate.new("store", 10, 5)

            local now = ngx.now() * 1000
            local count1, _ = lim:take_available(uri, 5, now)
            local count2, _ = lim:take_available(uri, 5, now + 60)
            local count3, _ = lim:take_available(uri, 1, now + 70)

            ngx.say("count1: ", count1)
            ngx.say("count2: ", count2)
            ngx.say("count3: ", count3)
        ';
    }
--- request
GET /t
--- response_body
count1: 5
count2: 5
count3: 1
--- no_error_log
[error]
[lua]
