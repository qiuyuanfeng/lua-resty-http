local ngx_socket_tcp = ngx.socket.tcp
local str_gmatch = string.gmatch
local str_lower = string.lower
local str_upper = string.upper
local str_find = string.find
local str_sub = string.sub
local tbl_concat = table.concat
local ngx_encode_args = ngx.encode_args
local ngx_re_match = ngx.re.match
local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local co_wrap = coroutine.wrap
local co_yield = coroutine.yield


local _M = {
    _VERSION = '0.01',
}

local mt = { __index = _M }


local HTTP = {
    [1.0] = " HTTP/1.0\r\n",
    [1.1] = " HTTP/1.1\r\n",
}

local USER_AGENT = "Resty/HTTP " .. _M._VERSION .. " (Lua)"

local DEFAULT_PARAMS = {
    method = "GET",
    path = "/",
    version = 1.1,
}


function _M.new(self)
    local sock, err = ngx_socket_tcp()
    if not sock then
        return nil, err
    end
    return setmetatable({ sock = sock, host = nil }, mt)
end


function _M.set_timeout(self, timeout)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end

    return sock:settimeout(timeout)
end


function _M.connect(self, ...)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end

    self.host = select(1, ...)

    return sock:connect(...)
end


function _M.set_keepalive(self, ...)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end

    return sock:setkeepalive(...)
end


function _M.get_reused_times(self)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end

    return sock:getreusedtimes()
end


function _M.close(self)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end

    return sock:close()
end


local function _should_receive_body(method, code)
    if method == "HEAD" then return nil end
    if code == 204 or code == 304 then return nil end
    if code >= 100 and code < 200 then return nil end
    return true
end


local function _format_request(params)
    local version = params.version
    local headers = params.headers or {}
    local body = params.body

    local query = params.query or ""
    if query then
        if type(query) == "table" then
            query = "?" .. ngx_encode_args(query)
        end
    end

    -- Initialize request
    local req = {
        str_upper(params.method),
        " ",
        params.path,
        query,
        HTTP[version],
        -- Pre-allocate slots for minimum headers and carriage return.
        true,
        true,
        true,
    }
    local c = 6 -- req table index - it's faster to do this inline vs table.insert

    -- Append headers
    for key, values in pairs(headers) do
        if type(values) ~= "table" then
            values = {values}
        end

        key = tostring(key)
        for _, value in pairs(values) do
            req[c] = key .. ": " .. tostring(value) .. "\r\n"
            c = c + 1
        end
    end

    -- Close headers
    req[c] = "\r\n"

    return tbl_concat(req)
end


local function _receive_status(sock)
    local line, err = sock:receive("*l")
    if not line then
        return nil, err
    end

    return tonumber(str_sub(line, 10, 12)), tonumber(str_sub(line, 6, 8))
end


local function _receive_headers(self)
    local sock = self.sock
    local headers = {}

    repeat
        local line = sock:receive()

        for key, val in str_gmatch(line, "([%w%-]+)%s*:%s*(.+)") do
            if headers[key] then
                headers[key] = headers[key] .. ", " .. tostring(val)
            else
                headers[key] = tostring(val)
            end
        end
    until str_find(line, "^%s*$")

    return headers, nil
end


local function _chunked_body_reader(sock)
    return co_wrap(function(max_chunk_size)
        local remaining = 0

        repeat
            local length = 0

            if max_chunk_size and remaining > 0 then -- If we still have data on this chunk

                if remaining > max_chunk_size then
                    -- Consume up to max_chunk_size
                    length = max_chunk_size
                    remaining = remaining - max_chunk_size
                else
                    -- Consume all remaining
                    length = remaining
                    remaining = 0
                end
            else -- This is a fresh chunk 

                -- Receive the chunk size
                local str, err = sock:receive("*l")
                if not str then
                    co_yield(nil, err)
                end

                length = tonumber(str, 16)

                if not length then
                    co_yield(nil, "unable to read chunksize")
                end

                if max_chunk_size and length > max_chunk_size then
                    -- Consume up to max_chunk_size
                    remaining = length - max_chunk_size
                    length = max_chunk_size
                end
            end

            if length > 0 then
                local str, err = sock:receive(length)
                if not str then
                    co_yield(nil, err)
                end
                co_yield(str)

                -- If we're finished with this chunk, read the carriage return.
                if remaining == 0 then
                    sock:receive(2) -- read \r\n
                end
            end

        until length == 0
    end)
end


local function _body_reader(sock, content_length)
    return co_wrap(function(max_chunk_size)
        if not content_length and not max_chunk_size then
            -- HTTP 1.0 with no length will close connection. Read to the end.
            local str, err = sock:receive("*a")
            if not str then
                co_yield(nil, err)
            end

            co_yield(str)

        elseif not max_chunk_size then
            -- We have a length and potentially keep-alive, but want the whole thing.
            local str, err = sock:receive(content_length)
            if not str then
                co_yield(nil, err)
            end

            co_yield(str)

        else
            -- We have a length and potentially a keep-alive, and wish to stream
            -- the response.
            local received = 0
            repeat
                local length = max_chunk_size
                if received + length > content_length then
                    length = content_length - received
                end

                if length > 0 then
                    local str, err = sock:receive(length)
                    if not str then
                        co_yield(nil, err)
                    end
                    received = received + length

                    co_yield(str)
                end

            until length == 0
        end
    end)
end


function _M.parse_uri(self, uri)
    local m, err = ngx_re_match(uri, [[^(http[s]*)://([^:/]+)(?::(\d+))?(.*)]], "jo")

    if not m then
        if err then
            return nil, "failed to match the uri: " .. err
        end

        return nil, "bad uri"
    end

    local t_uri = {
        m[1],
        m[2],
        m[3] or 80,
        m[4] or "/",
    }

    return t_uri, nil
end


function _M.request(self, params)
    local sock = self.sock

    -- Apply defaults
    for k,v in pairs(DEFAULT_PARAMS) do
        if not params[k] then
            params[k] = v
        end
    end
    
    local body = params.body
    local headers = params.headers or {}
    
    -- Ensure minimal headers are set
    if body then
        headers["Content-Length"] = #body
    end
    if not headers["Host"] then
        headers["Host"] = self.host
    end
    if not headers["User-Agent"] then
        headers["User-Agent"] = USER_AGENT
    end
    if params.version == 1.0 and not headers["Connection"] then
        headers["Connection"] = "Keep-Alive"
    end

    params.headers = headers

    -- Format and send request
    local req = _format_request(params)
    ngx_log(ngx_DEBUG, "\n"..req)
    sock:send(req)

    -- Send the request body
    if body then
        local bytes, err = sock:send(body)
        if not bytes then
            return nil, err
        end
    end

    -- Receive the status and headers
    local status, version = _receive_status(sock)
    local res_headers = _receive_headers(self)

    local keepalive = true
    local body_reader, err = nil, nil

    -- Receive the body_reader
    if _should_receive_body(params.method, status) then
        local length = tonumber(res_headers["Content-Length"])
        local encoding = res_headers["Transfer-Encoding"] or ""

        if version == 1.1 and str_lower(encoding) == "chunked" then
            body_reader, err = _chunked_body_reader(sock)
        else
            body_reader, err = _body_reader(sock, length)
        end
    end

    if err then
        return nil, err
    else
        return { status = status, headers = res_headers, reader = body_reader }
    end
end


function _M.read_body(self, reader)
    if not reader then 
        -- Most likely HEAD or 304 etc.
        return nil, "no body to be read"
    end

    local chunks = {}
    local c = 1

    local chunk
    repeat
        ngx_log(ngx_DEBUG, "calling reader")
        chunk, err = reader()

        if err then
            return nil, err, tbl_concat(chunks) -- Return any data so far.
        end
        if chunk then
            ngx_log(ngx_DEBUG, "got chunk of length: "..#chunk)
            chunks[c] = chunk
            c = c + 1
        end
    until not chunk

    return tbl_concat(chunks)
end


function _M.read_trailers(self, headers)
    if headers and headers["Trailer"] then
        local trailers = _receive_headers(self)
        if trailers then
            for k,v in pairs(trailers) do
                headers[k] = v
            end
        end
    end
end


function _M.request_uri(self, uri, params)
    if not params then params = {} end

    local parsed_uri, err = self:parse_uri(uri)
    if not parsed_uri then
        return nil, err
    end

    local scheme, host, port, path = unpack(parsed_uri)
    if path then params.path = path end

    local c, err = self:connect(host, port)
    if not c then
        return nil, err
    end

    local res, err = self:request(params)
    if not res then
        return nil, err
    end

    local body, err = self:read_body(res.reader)
    if not body then
        return nil, err
    end
    
    res.body = body

    -- TODO: keepalive / close logic
    self:close()

    return res, nil
end


return _M
