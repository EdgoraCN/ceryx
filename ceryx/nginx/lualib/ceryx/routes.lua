local redis = require "ceryx.redis"

local exports = {}

function getRouteKeyForSource(source)
    return redis.prefix .. ":routes:" .. source
end

function getSettingsKeyForSource(source)
    return redis.prefix .. ":settings:" .. source
end

function getSecretKeyForSource(source)
    return redis.prefix .. ":secret:" .. source
end

function targetIsInValid(target)
    return not target or target == ngx.null
end

function getTargetForSource(source, redisClient)
    -- Construct Redis key and then
    -- try to get target for host
    local key = getRouteKeyForSource(source)
    local target, _ = redisClient:get(key)

    if targetIsInValid(target) then
        ngx.log(ngx.INFO, "Could not find target for " .. source .. ".")

        -- Construct Redis key for $wildcard
        key = getRouteKeyForSource("$wildcard")
        target, _ = redisClient:get(wildcardKey)

        if targetIsInValid(target) then
            return nil
        end

        ngx.log(ngx.DEBUG, "Falling back to " .. target .. ".")
    end

    return target
end

function getAccessForSource(source, redisClient)
    ngx.log(ngx.DEBUG, "Get routing access for " .. source .. ".")
    local settings_key = getSettingsKeyForSource(source)
    local access, _ = redisClient:hget(settings_key, "access")

    if access == ngx.null then
        access = "@public" -- default access
    end

    return access
end

function getSecretFromRedis(source, redisClient)
    ngx.log(ngx.DEBUG, "Get routing secret for " .. source .. ".")
    local secret_key = getSecretKeyForSource(source)
    local secret, _ = redisClient:get(secret_key)

    if secret == ngx.null then
        secret = "*" -- default secret
    end

    return secret
end

function getModeForSource(source, redisClient)
    -- ngx.log(ngx.DEBUG, "Get routing mode for " .. source .. ".")
    -- local settings_key = getSettingsKeyForSource(source)
    -- local mode, _ = redisClient:hget(settings_key, "mode")

    -- if mode == ngx.null or not mode then
    --    mode = "proxy"
    -- end
    local mode = "proxy"
    return mode
end

function getSecretForSource(source)
    local _
    local cache = ngx.shared.ceryx
    local redisClient = redis:client()
    local keyName = source .. ".secret"
    local cached_secret, _ = cache:get(keyName)
    if cached_secret then
        ngx.log(ngx.DEBUG, "Cache hit for " .. keyName)
        return cached_secret
    else
        ngx.log(ngx.DEBUG, "Cache miss for " .. keyName)
        local secret = getSecretFromRedis(source,redisClient)
        cache:set(keyName, secret, 10)
        return secret
    end
end

function getRouteForSource(source)
    local _
    local route = {}
    local cache = ngx.shared.ceryx
    local redisClient = redis:client()

    ngx.log(ngx.DEBUG, "Looking for a route for " .. source)
    -- Check if key exists in local cache
    local cached_value, _ = cache:get(source)

    if cached_value then
        ngx.log(ngx.DEBUG, "Cache hit for " .. source .. ".")
        route.target = cached_value
    else
        ngx.log(ngx.DEBUG, "Cache miss for " .. source .. ".")
        route.target = getTargetForSource(source, redisClient)

        if targetIsInValid(route.target) then
            return nil
        end
        cache:set(host, res, 5)
        ngx.log(ngx.DEBUG, "Caching from " .. source .. " to " .. route.target .. " for 5 seconds.")
    end

    route.mode = getModeForSource(source, redisClient)

    local keyName = source .. ".access"
    local cached_access, _ = cache:get(keyName)
    if cached_access then
        ngx.log(ngx.DEBUG, "Cache hit for " .. keyName)
        route.access = cached_access
    else
        ngx.log(ngx.DEBUG, "Cache miss for " .. keyName)
        route.access = getAccessForSource(source,redisClient)
        cache:set(keyName, route.access, 10)
        ngx.log(ngx.DEBUG, "Caching from " .. keyName .. " to " .. route.access .. " for 10 seconds.")
    end
    return route
end

exports.getSettingsKeyForSource = getSettingsKeyForSource
exports.getRouteForSource = getRouteForSource
exports.getTargetForSource = getTargetForSource
exports.getSecretForSource = getSecretForSource

return exports
