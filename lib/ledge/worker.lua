local setmetatable = setmetatable
local co_yield = coroutine.yield

local ngx_get_phase = ngx.get_phase
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR

local tbl_copy_merge_defaults = require("ledge.util").table.copy_merge_defaults
local fixed_field_metatable = require("ledge.util").mt.fixed_field_metatable

local put_background_job = require("ledge.background").put_background_job

local _M = {
    _VERSION = "2.1.3",
}


local defaults = setmetatable({
    interval = 1,
    gc_queue_concurrency = 1,
    purge_queue_concurrency = 1,
    revalidate_queue_concurrency = 1,
}, fixed_field_metatable)


local function new(config)
    assert(ngx_get_phase() == "init_worker",
        "attempt to create ledge worker outside of the init_worker phase")

    -- Take config by value and merge with defaults
    local config = tbl_copy_merge_defaults(config, defaults)
    return setmetatable({ config = config }, {
        __index = _M,
    })
end
_M.new = new


local function run(self)
    assert(ngx_get_phase() == "init_worker",
        "attempt to run ledge worker outside of the init_worker phase")

    local ledge = require("ledge")

    local ql_worker = assert(require("resty.qless.worker").new({
        get_redis_client = ledge.create_qless_connection,
        close_redis_client = ledge.close_redis_connection
    }))

    -- Runs around job exectution, to instantiate necessary connections
    ql_worker.middleware = function(job)
        job.redis = ledge.create_redis_connection()

        co_yield()  -- Perform the job

        ledge.close_redis_connection(job.redis)
    end

    -- Start a worker for each fo the queues

    assert(ql_worker:start({
        interval = self.config.interval,
        concurrency = self.config.gc_queue_concurrency,
        reserver = "ordered",
        queues = { "ledge_gc" },
    }))

    assert(ql_worker:start({
        interval = self.config.interval,
        concurrency = self.config.purge_queue_concurrency,
        reserver = "ordered",
        queues = { "ledge_purge" },
    }))

    assert(ql_worker:start({
        interval = self.config.interval or 1,
        concurrency = self.config.revalidate_queue_concurrency,
        reserver = "ordered",
        queues = { "ledge_revalidate" },
    }))

    -- TODO: configurable interval/concurrency
    assert(ql_worker:start({
        interval = 30,
        concurrency = 1,
        reserver = "ordered",
        queues = { "ledge_housekeeping" },
    }))

    -- Make sure the housekeeping job is scheduled
     local job, err = ngx.timer.at(0, function(premature)
        put_background_job(
            "ledge_housekeeping",
            "ledge.jobs.prune_global_tags",
            {
                keyspace_scan_count = 50 -- TODO: configurable
            },
            {
                jid = "prune_global_tags",
                tags = { "prune_global_tags" },
                priority = 1,
            },
            3600 -- recur - TODO : configurable
        )
    end)
    if err then ngx_log(ngx_ERR, err) end

    return true
end
_M.run = run


return setmetatable(_M, fixed_field_metatable)
