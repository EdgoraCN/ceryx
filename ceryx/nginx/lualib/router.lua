local redis = require "ceryx.redis"
local routes = require "ceryx.routes"
local utils = require "ceryx.utils"

local redisClient = redis:client()

local host = ngx.var.host
local cache = ngx.shared.ceryx

local is_not_https = (ngx.var.scheme ~= "https")

function formatTarget(target)
    target = utils.ensure_protocol(target)
    target = utils.ensure_no_trailing_slash(target)

    return target .. ngx.var.request_uri
end

function redirect(source, target)
    ngx.log(ngx.INFO, "Redirecting request for " .. source .. " to " .. target .. ".")
    return ngx.redirect(target, ngx.HTTP_MOVED_PERMANENTLY)
end

function proxy(source, target)
    ngx.var.target = target
    ngx.log(ngx.INFO, "Proxying request for " .. source .. " to " .. target .. ".")
end

function routeRequest(source, target, mode)
    ngx.log(ngx.DEBUG, "Received " .. mode .. " routing request from " .. source .. " to " .. target)

    target = formatTarget(target)

    if mode == "redirect" then
        return redirect(source, target)
    end

    return proxy(source, target)
end

if is_not_https then
    local settings_key = routes.getSettingsKeyForSource(host)
    local enforce_https, flags = cache:get(host .. ":enforce_https")

    if enforce_https == nil then
        local res, flags = redisClient:hget(settings_key, "enforce_https")
        enforce_https = tonumber(res)
        cache:set(host .. ":enforce_https", enforce_https, 5)
    end

    if enforce_https == 1 then
        return ngx.redirect("https://" .. host .. ngx.var.request_uri, ngx.HTTP_MOVED_PERMANENTLY)
    end
end

ngx.log(ngx.INFO, "HOST " .. host)
local route = routes.getRouteForSource(host)

if route == nil then
    ngx.log(ngx.INFO, "No $wildcard target configured for fallback. Exiting with Bad Gateway.")
    return ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
end

if route.access ==  "@token" then
    local token = ngx.req.get_headers()["x-auth-token"]
    if token == nil then
        ngx.log(ngx.DEBUG,"token is missing")
        return ngx.exit(ngx.HTTP_FORBIDDEN)
    end
    local secret = routes.getSecretForSource(host)
    if secret == "*" and token ~= secret then
        ngx.log(ngx.DEBUG,"token is wrong")
        return ngx.exit(ngx.HTTP_FORBIDDEN)
    end
elseif route.access ==  "@cookie" then
    local cookie_name = "X_AUTH_TOKEN"
    local var_name = "cookie_" .. cookie_name
    local cookie_value = ngx.var[var_name]
    if cookie_value == nil then
        ngx.log(ngx.DEBUG,"cookie_value is missing")
        return ngx.exit(ngx.HTTP_FORBIDDEN)
    end
    local secret = routes.getSecretForSource(host)
    if secret == "*" or cookie_value ~= secret then
        ngx.log(ngx.DEBUG,"cookie_value is wrong")
        return ngx.exit(ngx.HTTP_FORBIDDEN)
    end
elseif route.access ~=  "@public" then
    -- for key, value in pairs(ngx.req.get_headers()) do
    --   ngx.log(ngx.DEBUG,key .. "=" .. value)
    -- end
    local user = ngx.req.get_headers()["x-forwarded-user"]
    if user == nil then
        ngx.log(ngx.DEBUG,"forwarded user is missing")
        return ngx.exit(ngx.HTTP_FORBIDDEN)
    end
    if string.find(route.access, "{" .. tostring(user) .. "}") then
        return routeRequest(host, route.target, route.mode)
    end

    if role ~= nil and string.find(route.access, "{" .. tostring("#" .. role) .. "}") then
        return  routeRequest(host, route.target, route.mode)
    end

    if group ~= nil and  string.find(route.access, "{" .. tostring("%" .. group) .. "}") then
        return  routeRequest(host, route.target, route.mode)
    end

    ngx.log(ngx.DEBUG,"forwarded user is forbidden")
    return ngx.exit(ngx.HTTP_FORBIDDEN)
end

-- Save found key to local cache for 5 seconds
routeRequest(host, route.target, route.mode)
