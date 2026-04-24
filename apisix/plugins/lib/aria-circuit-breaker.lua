--
-- aria-circuit-breaker.lua — Shared circuit breaker for sidecar bridges.
--
-- Used by: aria-mask (NER sidecar bridge), future aria-shield content filter.
-- State lives in an ngx.shared.dict so all workers on one APISIX instance see
-- the same picture. The breaker is advisory — occasional races where one extra
-- call slips through are acceptable and cheaper than strict locking.
--
-- States:
--   closed    → normal; count consecutive failures; flip to open at threshold
--   open      → short-circuit; after cooldown_ms elapses, flip to half_open
--   half_open → let a single probe through; success → closed, failure → open
--
-- API (module-level factory + OO methods):
--   local cb = circuit_breaker.new(shared_dict, "ner", {
--       failure_threshold = 5,
--       cooldown_ms       = 30000,
--   })
--   if cb:allow() then
--       local ok = do_call()
--       if ok then cb:record_success() else cb:record_failure() end
--   end
--
-- Keys used in the backing dict (prefix '_cb:<name>:'):
--   state       integer — 0 closed, 1 open, 2 half_open
--   failures    integer — consecutive failure count while closed
--   opened_at   number  — ngx.now()*1000 when the breaker last opened
--

local ngx = ngx

local _M = { version = "0.1.0" }

local STATE_CLOSED    = 0
local STATE_OPEN      = 1
local STATE_HALF_OPEN = 2

local STATE_NAMES = {
    [STATE_CLOSED]    = "closed",
    [STATE_OPEN]      = "open",
    [STATE_HALF_OPEN] = "half_open",
}

local methods = {}
local cb_mt = { __index = methods }


--- Create a new circuit breaker bound to a shared dict.
-- @param dict    A shared-dict-like object (has get/set/incr). Pass
--                ngx.shared["<name>"] in production; tests may inject a mock.
-- @param name    Unique breaker name (used as key prefix).
-- @param opts    { failure_threshold = 5, cooldown_ms = 30000 }
-- @return breaker (table) on success, or nil, err
function _M.new(dict, name, opts)
    if not dict then
        return nil, "shared dict is required"
    end
    if not name or name == "" then
        return nil, "breaker name is required"
    end
    opts = opts or {}
    return setmetatable({
        dict  = dict,
        name  = name,
        k_state    = "_cb:" .. name .. ":state",
        k_failures = "_cb:" .. name .. ":failures",
        k_opened   = "_cb:" .. name .. ":opened_at",
        failure_threshold = opts.failure_threshold or 5,
        cooldown_ms       = opts.cooldown_ms or 30000,
    }, cb_mt)
end


--- Return the current state, performing the time-based open→half_open
--- transition as a side effect when the cooldown has elapsed.
-- @return integer state code
function methods:raw_state()
    local s = self.dict:get(self.k_state) or STATE_CLOSED
    if s == STATE_OPEN then
        local opened_at = self.dict:get(self.k_opened) or 0
        if (ngx.now() * 1000) - opened_at >= self.cooldown_ms then
            self.dict:set(self.k_state, STATE_HALF_OPEN)
            return STATE_HALF_OPEN
        end
    end
    return s
end


--- Human-readable state: "closed" | "open" | "half_open".
function methods:state()
    return STATE_NAMES[self:raw_state()] or "closed"
end


--- True when a caller should attempt the guarded operation.
-- Callers MUST pair a true return with exactly one record_success() or
-- record_failure() once the call finishes.
function methods:allow()
    return self:raw_state() ~= STATE_OPEN
end


--- Record a successful call outcome.
function methods:record_success()
    local s = self:raw_state()
    if s == STATE_HALF_OPEN then
        -- Probe succeeded → close the breaker and clear failure counter.
        self.dict:set(self.k_state, STATE_CLOSED)
        self.dict:set(self.k_failures, 0)
    elseif s == STATE_CLOSED then
        -- Single success clears the streak; prevents intermittent failures
        -- from tipping us over the edge when the dependency is mostly healthy.
        self.dict:set(self.k_failures, 0)
    end
end


--- Record a failed call outcome.
function methods:record_failure()
    local s = self:raw_state()
    if s == STATE_HALF_OPEN then
        -- Probe failed → reopen immediately.
        self.dict:set(self.k_state, STATE_OPEN)
        self.dict:set(self.k_opened, ngx.now() * 1000)
        return
    end
    local failures = self.dict:incr(self.k_failures, 1, 0) or 0
    if failures >= self.failure_threshold then
        self.dict:set(self.k_state, STATE_OPEN)
        self.dict:set(self.k_opened, ngx.now() * 1000)
    end
end


--- Force-reset the breaker to closed. Useful for admin tooling and tests.
function methods:reset()
    self.dict:set(self.k_state, STATE_CLOSED)
    self.dict:set(self.k_failures, 0)
    self.dict:set(self.k_opened, 0)
end


--- Current consecutive failure count (closed-state only). Exposed for metrics.
function methods:failure_count()
    return self.dict:get(self.k_failures) or 0
end


-- State constants are exposed for consumers that want to export numeric
-- gauges without parsing strings.
_M.STATE_CLOSED    = STATE_CLOSED
_M.STATE_OPEN      = STATE_OPEN
_M.STATE_HALF_OPEN = STATE_HALF_OPEN

return _M
