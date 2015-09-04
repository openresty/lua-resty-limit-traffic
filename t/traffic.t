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

=== TEST 1: sanity (output states)
--- http_config eval
"
$::HttpConfig

    lua_shared_dict req 1m;
    lua_shared_dict conn 1m;
"
--- config
    location = /t {
        content_by_lua '
            local limit_conn = require "resty.limit.conn"
            local limit_req = require "resty.limit.req"
            local limit_traffic = require "resty.limit.traffic"

            local lim1 = limit_req.new("req", 3, 2)
            local lim2 = limit_req.new("req", 2, 3)
            local lim3 = limit_conn.new("conn", 4, 1, 2)

            local limiters = {lim1, lim2, lim3}

            ngx.shared.req:flush_all()
            ngx.shared.conn:flush_all()

            local keys = {"foo", "bar", "foo"}
            local states = {}
            for i = 1, 6 do
                local delay, err = limit_traffic.combine(limiters, keys, states)
                if not delay then
                    ngx.say("failed to limit traffic: ", err)
                else
                    ngx.say(i, ": ", delay,
                            ", conn committed: ", lim3:is_committed(),
                            ", states: ", table.concat(states, ", "))
                end
                if i == 4 then
                    ngx.sleep(1)
                end
            end
        ';
    }
--- request
    GET /t
--- response_body_like eval
qr/^1: 0, conn committed: true, states: 0, 0, 1
2: 0\.5, conn committed: true, states: 1, 1, 2
3: 1, conn committed: true, states: 2, 2, 3
failed to limit traffic: rejected
5: 0\.(?:4[6-9]|5|5[0-4])\d*, conn committed: true, states: 0, (?:1|1\.0[0-4]\d*|0\.9[6-9]\d*), 4
6: 2, conn committed: true, states: 1, (?:2|2\.0[0-4]\d*|1\.9[6-9]\d*), 5
$/s
--- no_error_log
[error]
[lua]



=== TEST 2: sanity (no output states)
--- http_config eval
"
$::HttpConfig

    lua_shared_dict req 1m;
    lua_shared_dict conn 1m;
"
--- config
    location = /t {
        content_by_lua '
            local limit_conn = require "resty.limit.conn"
            local limit_req = require "resty.limit.req"
            local limit_traffic = require "resty.limit.traffic"

            local lim1 = limit_req.new("req", 3, 2)
            local lim2 = limit_req.new("req", 2, 3)
            local lim3 = limit_conn.new("conn", 4, 1, 2)

            local limiters = {lim1, lim2, lim3}

            ngx.shared.req:flush_all()
            ngx.shared.conn:flush_all()

            local keys = {"foo", "bar", "foo"}
            for i = 1, 6 do
                local delay, err = limit_traffic.combine(limiters, keys)
                if not delay then
                    ngx.say("failed to limit traffic: ", err)
                else
                    ngx.say(i, ": ", delay,
                            ", conn committed: ", lim3:is_committed())
                end
                if i == 4 then
                    ngx.sleep(1)
                end
            end
        ';
    }
--- request
    GET /t
--- response_body_like eval
qr/^1: 0, conn committed: true
2: 0\.5, conn committed: true
3: 1, conn committed: true
failed to limit traffic: rejected
5: 0\.(?:4[6-9]|5|5[0-4])\d*, conn committed: true
6: 2, conn committed: true
$/s
--- no_error_log
[error]
[lua]
