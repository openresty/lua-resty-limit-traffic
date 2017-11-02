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

=== TEST 1: take
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
    lua_shared_dict my_locks 100k;
"
--- config
    location /t {
        content_by_lua '
            local limit_token = require "resty.limit.token"
            ngx.shared.store:flush_all()

            local uri = ngx.var.uri
            local lim = limit_token.new("store", 250, 10, 1, {
                locks_shdict_name = "my_locks",
            })

            local now = ngx.now() * 1000
            local delay1, _ = lim:take(uri, 10, nil, now)
            local delay2, _ = lim:take(uri, 2, nil, now)
            local delay3, _ = lim:take(uri, 2, nil, now)
            local delay4, _ = lim:take(uri, 1, nil, now)

            ngx.say("delay1: ", delay1)
            ngx.say("delay2: ", delay2)
            ngx.say("delay3: ", delay3)
            ngx.say("delay4: ", delay4)
        ';
    }
--- request
GET /t
--- response_body
delay1: 0
delay2: 0.5
delay3: 1
delay4: 1.25
--- no_error_log
[error]
[lua]



=== TEST 2: take - offset time
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
    lua_shared_dict locks 100k;
"
--- config
    location /t {
        content_by_lua '
            local limit_token = require "resty.limit.token"
            ngx.shared.store:flush_all()

            local uri = ngx.var.uri
            local lim = limit_token.new("store", 250, 10)

            local now = ngx.now() * 1000
            local delay1, _ = lim:take(uri, 0, nil, now)
            local delay2, _ = lim:take(uri, 10, nil, now)
            local delay3, _ = lim:take(uri, 1, nil, now)
            local delay4, _ = lim:take(uri, 1, nil, now + 250)

            ngx.say("delay1: ", delay1)
            ngx.say("delay2: ", delay2)
            ngx.say("delay3: ", delay3)
            ngx.say("delay4: ", delay4)
        ';
    }
--- request
GET /t
--- response_body
delay1: 0
delay2: 0
delay3: 0.25
delay4: 0.25
--- no_error_log
[error]
[lua]



=== TEST 3: take - more than capacity
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
    lua_shared_dict locks 100k;
"
--- config
    location /t {
        content_by_lua '
            local limit_token = require "resty.limit.token"
            ngx.shared.store:flush_all()

            local uri = ngx.var.uri
            local lim = limit_token.new("store", 1, 10)

            local now = ngx.now() * 1000
            local delay1, _ = lim:take(uri, 10, nil, now)
            local delay2, _ = lim:take(uri, 15, nil, now + 20)

            ngx.say("delay1: ", delay1)
            ngx.say("delay2: ", delay2)
        ';
    }
--- request
GET /t
--- response_body
delay1: 0
delay2: 0.005
--- no_error_log
[error]
[lua]



=== TEST 4: take - offset sub-quantum time
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
    lua_shared_dict locks 100k;
"
--- config
    location /t {
        content_by_lua '
            local limit_token = require "resty.limit.token"
            ngx.shared.store:flush_all()

            local uri = ngx.var.uri
            local lim = limit_token.new("store", 10, 10)

            local now = ngx.now() * 1000
            local delay1, _ = lim:take(uri, 10, nil, now)
            local delay2, _ = lim:take(uri, 1, nil, now + 7)
            local delay3, _ = lim:take(uri, 1, nil, now + 8)
            local delay4, _ = lim:take(uri, 1, nil, now + 10)
            local delay5, _ = lim:take(uri, 1, nil, now + 25)

            ngx.say("delay1: ", delay1)
            ngx.say("delay2: ", delay2)
            ngx.say("delay3: ", delay3)
            ngx.say("delay4: ", delay4)
            ngx.say("delay5: ", delay5)
        ';
    }
--- request
GET /t
--- response_body
delay1: 0
delay2: 0.003
delay3: 0.012
delay4: 0.02
delay5: 0.015
--- no_error_log
[error]
[lua]



=== TEST 5: take - within capacity
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
    lua_shared_dict locks 100k;
"
--- config
    location /t {
        content_by_lua '
            local limit_token = require "resty.limit.token"
            ngx.shared.store:flush_all()

            local uri = ngx.var.uri
            local lim = limit_token.new("store", 10, 5)

            local now = ngx.now() * 1000
            local delay1, _ = lim:take(uri, 5, nil, now)
            local delay2, _ = lim:take(uri, 5, nil, now + 60)
            local delay3, _ = lim:take(uri, 1, nil, now + 60)
            local delay4, _ = lim:take(uri, 2, nil, now + 80)

            ngx.say("delay1: ", delay1)
            ngx.say("delay2: ", delay2)
            ngx.say("delay3: ", delay3)
            ngx.say("delay4: ", delay4)
        ';
    }
--- request
GET /t
--- response_body
delay1: 0
delay2: 0
delay3: 0.01
delay4: 0.01
--- no_error_log
[error]
[lua]



=== TEST 6: take - max wait
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
    lua_shared_dict locks 100k;
"
--- config
    location /t {
        content_by_lua '
            local limit_token = require "resty.limit.token"
            ngx.shared.store:flush_all()

            local uri = ngx.var.uri
            local lim = limit_token.new("store", 1, 10)

            local now = ngx.now() * 1000
            local delay1, err1 = lim:take(uri, 10, nil, now)
            local delay2, err2 = lim:take(uri, 15, 4, now + 20)
            local delay3, err3 = lim:take(uri, 10, 4, now + 25)

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
err1: nil
delay2: nil
err2: rejected
delay3: 0
err3: nil
--- no_error_log
[error]
[lua]



=== TEST 7: take - count greater than capacity
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
    lua_shared_dict locks 100k;
"
--- config
    location /t {
        content_by_lua '
            local limit_token = require "resty.limit.token"
            ngx.shared.store:flush_all()

            local uri = ngx.var.uri
            local lim = limit_token.new("store", 1, 10)

            local now = ngx.now() * 1000
            local delay1, err1 = lim:take(uri, 15, 4, now)
            local delay2, err2 = lim:take(uri, 15, nil, now + 20)

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
err2: nil
--- no_error_log
[error]
[lua]



=== TEST 8: take_available
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
    lua_shared_dict locks 100k;
"
--- config
    location /t {
        content_by_lua '
            local limit_token = require "resty.limit.token"
            ngx.shared.store:flush_all()

            local uri = ngx.var.uri
            local lim = limit_token.new("store", 250, 10)

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



=== TEST 9: take_available - offset time
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
    lua_shared_dict locks 100k;
"
--- config
    location /t {
        content_by_lua '
            local limit_token = require "resty.limit.token"
            ngx.shared.store:flush_all()

            local uri = ngx.var.uri
            local lim = limit_token.new("store", 250, 10)

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



=== TEST 10: take_available - more than capacity
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
    lua_shared_dict locks 100k;
"
--- config
    location /t {
        content_by_lua '
            local limit_token = require "resty.limit.token"
            ngx.shared.store:flush_all()

            local uri = ngx.var.uri
            local lim = limit_token.new("store", 1, 10)

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



=== TEST 11: take_available - within capacity
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
    lua_shared_dict locks 100k;
"
--- config
    location /t {
        content_by_lua '
            local limit_token = require "resty.limit.token"
            ngx.shared.store:flush_all()

            local uri = ngx.var.uri
            local lim = limit_token.new("store", 10, 5)

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



=== TEST 12: rate
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
    lua_shared_dict locks 100k;
"
--- config
    location /t {
        content_by_lua '
            local limit_token = require "resty.limit.token"
            ngx.shared.store:flush_all()

            local uri = ngx.var.uri
            local lim = limit_token.new("store", 500, 5, 2)
            ngx.say("rate: ", lim:rate())
        ';
    }
--- request
GET /t
--- response_body
rate: 4
--- no_error_log
[error]
[lua]
