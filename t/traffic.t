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
    lua_shared_dict count 1m;
"
--- config
    location = /t {
        content_by_lua_block {
            local limit_conn = require "resty.limit.conn"
            local limit_req = require "resty.limit.req"
            local limit_count = require "resty.limit.count"
            local limit_traffic = require "resty.limit.traffic"

            local lim1 = limit_req.new("req", 3, 2)
            local lim2 = limit_req.new("req", 2, 3)
            local lim3 = limit_conn.new("conn", 4, 1, 2)
            local lim4 = limit_count.new("count", 10, 100)

            local limiters = {lim1, lim2, lim3, lim4}

            ngx.shared.req:flush_all()
            ngx.shared.conn:flush_all()
            ngx.shared.count:flush_all()

            local keys = {"foo", "bar", "foo", "bar"}
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
        }
    }
--- request
    GET /t
--- response_body_like eval
qr/^1: 0, conn committed: true, states: 0, 0, 1, 9
2: 0\.5, conn committed: true, states: 1, 1, 2, 8
3: 1, conn committed: true, states: 2, 2, 3, 7
failed to limit traffic: rejected
5: 0\.(?:4[6-9]|5|5[0-4])\d*, conn committed: true, states: 0, (?:1|1\.0[0-4]\d*|0\.9[6-9]\d*), 4, 6
6: 2, conn committed: true, states: 1, (?:2|2\.0[0-4]\d*|1\.9[6-9]\d*), 5, 5
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
    lua_shared_dict count 1m;
"
--- config
    location = /t {
        content_by_lua_block {
            local limit_conn = require "resty.limit.conn"
            local limit_req = require "resty.limit.req"
            local limit_count = require "resty.limit.count"
            local limit_traffic = require "resty.limit.traffic"

            local lim1 = limit_req.new("req", 3, 2)
            local lim2 = limit_req.new("req", 2, 3)
            local lim3 = limit_conn.new("conn", 4, 1, 2)
            local lim4 = limit_count.new("count", 10, 100)

            local limiters = {lim1, lim2, lim3, lim4}

            ngx.shared.req:flush_all()
            ngx.shared.conn:flush_all()
            ngx.shared.count:flush_all()

            local keys = {"foo", "bar", "foo", "bar"}
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
        }
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



=== TEST 3: block by limit-count (output states)
--- http_config eval
"
$::HttpConfig

    lua_shared_dict req 1m;
    lua_shared_dict conn 1m;
    lua_shared_dict count 1m;
"
--- config
    location = /t {
        content_by_lua_block {
            local limit_conn = require "resty.limit.conn"
            local limit_req = require "resty.limit.req"
            local limit_count = require "resty.limit.count"
            local limit_traffic = require "resty.limit.traffic"

            local lim1 = limit_req.new("req", 3, 2)
            local lim2 = limit_req.new("req", 2, 3)
            local lim3 = limit_conn.new("conn", 4, 1, 2)
            local lim4 = limit_count.new("count", 2, 100)

            local limiters = {lim1, lim2, lim3, lim4}

            ngx.shared.req:flush_all()
            ngx.shared.conn:flush_all()
            ngx.shared.count:flush_all()

            local keys = {"foo", "bar", "foo", "bar"}
            local states = {}
            for i = 1, 6 do
                local delay, err = limit_traffic.combine(limiters, keys, states)
                if not delay then
                    ngx.say("failed to limit traffic: ", err)
                    ngx.say("states: ", table.concat(states, ", "))
                else
                    ngx.say(i, ": ", delay,
                            ", conn committed: ", lim3:is_committed(),
                            ", states: ", table.concat(states, ", "))
                end
            end
        }
    }
--- request
    GET /t
--- response_body_like eval
qr/^1: 0, conn committed: true, states: 0, 0, 1, 1
2: 0\.5, conn committed: true, states: 1, 1, 2, 0
failed to limit traffic: rejected
states: 1, 1, 2, 0
failed to limit traffic: rejected
states: 1, 1, 2, 0
failed to limit traffic: rejected
states: 1, 1, 2, 0
failed to limit traffic: rejected
states: 1, 1, 2, 0
$/s
--- no_error_log
[error]
[lua]



=== TEST 4: sanity (uncommit() previous limiters if a limiter rejects while committing a state)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local limit_traffic = require "resty.limit.traffic"

            local limit_mock = {}
            limit_mock.__index = limit_mock

            function limit_mock.new(_, _, reject_on_commit)
                return setmetatable({
                    counters = {},
                    reject_on_commit = reject_on_commit,
                }, limit_mock)
            end

            function limit_mock:incoming(key, commit)
                local count = self.counters[key] or 0

                count = count + 1

                if commit then
                    self.counters[key] = count

                    if self.reject_on_commit then
                        return nil, "rejected by mock limiter"
                    end
                end

                return count
            end

            function limit_mock:uncommit(key)
                local count = self.counters[key] or 0
                if count > 0 then
                    count = count - 1
                end

                self.counters[key] = count
            end

            local lim1 = limit_mock.new(nil, 2)
            local lim2 = limit_mock.new(nil, 2)
            local lim3 = limit_mock.new(nil, 2, true)
            local lim4 = limit_mock.new(nil, 2)

            local limiters = {lim1, lim2, lim3, lim4}

            local keys = {"foo", "bar", "baz", "bat"}

            local delay, err = limit_traffic.combine(limiters, keys)
            if not delay then
                ngx.say(err)
            end

            ngx.say("state lim1: ", lim1:incoming(keys[1])) -- should be 1 because previous combine() call was uncommitted
            ngx.say("state lim2: ", lim2:incoming(keys[2])) -- should be 1 because previous combine() call was uncommitted
            ngx.say("state lim3: ", lim3:incoming(keys[3]))
        }
    }
--- request
    GET /t
--- response_body
rejected by mock limiter
state lim1: 1
state lim2: 1
state lim3: 2
--- no_error_log
[error]
[lua]



=== TEST 5: sanity (uncommit() the previous limiters and the last limiter if a limiter rejects while committing a state)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local limit_traffic = require "resty.limit.traffic"

            local limit_mock = {}
            limit_mock.__index = limit_mock

            function limit_mock.new(_, _, reject_on_commit)
                return setmetatable({
                    counters = {},
                    reject_on_commit = reject_on_commit,
                }, limit_mock)
            end

            function limit_mock:incoming(key, commit)
                local count = self.counters[key] or 0

                count = count + 1

                if commit then
                    self.counters[key] = count

                    if self.reject_on_commit then
                        return nil, "rejected by mock limiter"
                    end
                end

                return count
            end

            function limit_mock:uncommit(key)
                local count = self.counters[key] or 0
                if count > 0 then
                    count = count - 1
                end

                self.counters[key] = count
            end

            local lim1 = limit_mock.new(nil, 2)
            local lim2 = limit_mock.new(nil, 2, true)
            local lim3 = limit_mock.new(nil, 2)
            local lim4 = limit_mock.new(nil, 2)

            local limiters = {lim1, lim2, lim3, lim4}

            local keys = {"foo", "bar", "baz", "bat"}

            local delay, err = limit_traffic.combine(limiters, keys)
            if not delay then
                ngx.say(err)
            end

            ngx.say("state lim1: ", lim1:incoming(keys[1])) -- should be 1 because previous combine() call was uncommitted
            ngx.say("state lim2: ", lim2:incoming(keys[2]))
            ngx.say("state lim3: ", lim3:incoming(keys[3])) -- should be 1 because previous combine() call was uncommitted
            ngx.say("state lim4: ", lim4:incoming(keys[4])) -- should be 1 because previous combine() call was uncommitted
        }
    }
--- request
    GET /t
--- response_body
rejected by mock limiter
state lim1: 1
state lim2: 2
state lim3: 1
state lim4: 1
--- no_error_log
[error]
[lua]
