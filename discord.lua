---@type DiscordPlugin
---@diagnostic disable-next-line: missing-fields
local M = {
    enabled = true,
}

-- Helpers live on this table so tests can drive them and replace them. They
-- always call each other through the table, never through cached locals.
local internal = {}
M._internal = internal

local USER_AGENT = "rmpcd-discord-rich-presence (https://github.com/rmpc-org/rmpcd-discord-rich-presence)"
-- Application used when setup gets no client_id. Its name is what Discord shows
-- after "Listening to" and its "logo" asset backs the static cover provider.
local DEFAULT_CLIENT_ID = "1569394987265818644"
local MAX_FRAME_LEN = 1048576
local MIN_TEXT_CHARS = 2
local MAX_TEXT_CHARS = 128
local MAX_IMAGE_URL_LEN = 256
-- os.time() has one second resolution, so a window measured on it can pass
-- up to a second early; five seconds keeps every real gap above four and
-- therefore at most five sends per twenty seconds.
local THROTTLE_WINDOW_MS = 5000
local TIMESTAMP_TOLERANCE_MS = 2000
local ELLIPSIS = "…"
local DEFAULT_PROVIDERS = { "musicbrainz_tags", "musicbrainz_search", "static" }
-- Discord's status_display_type: which text the member list shows after
-- "Listening to". Unset means Discord's default, the application name.
local STATUS_DISPLAY = { name = 0, state = 1, details = 2 }

internal.USER_AGENT = USER_AGENT
internal.MAX_IMAGE_URL_LEN = MAX_IMAGE_URL_LEN

---@return integer
function internal.now_ms()
    return os.time() * 1000
end

-- Framing -------------------------------------------------------------------

---@param opcode integer
---@param payload table
---@return string
function internal.encode_frame(opcode, payload)
    local json, err = util.json_encode(payload)
    if json == nil then
        log.error("discord: failed to encode frame payload: " .. tostring(err))
        json = "{}"
    end
    return string.pack("<I4I4", opcode, #json) .. json
end

---@param buf string
---@return { opcode: integer, payload: any }|nil frame, string rest, string|nil err
function internal.take_frame(buf)
    if #buf < 8 then
        return nil, buf
    end
    local opcode, len = string.unpack("<I4I4", buf)
    if len > MAX_FRAME_LEN then
        return nil, "", "too_large"
    end
    if #buf < 8 + len then
        return nil, buf
    end
    local body = buf:sub(9, 8 + len)
    local rest = buf:sub(9 + len)
    local payload, err = util.json_decode(body)
    if err ~= nil then
        return nil, rest, "invalid_json"
    end
    return { opcode = opcode, payload = payload }, rest
end

-- Text ----------------------------------------------------------------------

---@param s string
---@return string
function internal.clamp_text(s)
    local len = utf8.len(s)
    if len == nil then
        s = s:gsub("[\128-\255]", "?")
        len = #s
    end
    if len < MIN_TEXT_CHARS then
        return s .. string.rep(" ", MIN_TEXT_CHARS - len)
    end
    if len > MAX_TEXT_CHARS then
        local cut = utf8.offset(s, MAX_TEXT_CHARS)
        return s:sub(1, cut - 1) .. ELLIPSIS
    end
    return s
end

---@param fmt string
---@param fields table<string, any>
---@return string
function internal.format_text(fmt, fields)
    local text = fmt:gsub("{([%w_]+)}", function(key)
        local value = fields[key]
        if value == nil then
            return ""
        end
        return tostring(value)
    end)
    return internal.clamp_text(text)
end

local function first_tag(tag)
    if tag == nil then
        return nil
    end
    return tag:first()
end

local function last_path_segment(path)
    return path:match("([^/]+)$") or path
end

---@param song Song
---@return table
function internal.song_fields(song)
    return {
        title = first_tag(song.title) or last_path_segment(song.file),
        artist = first_tag(song.artist) or "Unknown Artist",
        artist_tag = first_tag(song.artist),
        album = first_tag(song.album) or "",
        album_artist = first_tag(song.album_artist) or "",
        date = first_tag(song.date) or "",
        musicbrainz_album_id = first_tag(song.musicbrainz_album_id),
        musicbrainz_release_group_id = first_tag(song.musicbrainz_release_group_id),
        musicbrainz_track_id = first_tag(song.musicbrainz_track_id),
        file = song.file,
        duration = song.duration,
    }
end

-- Activity ------------------------------------------------------------------

---@param fields table
---@param opts table
---@return table
function internal.build_activity(fields, opts)
    local activity = {
        type = 2,
        details = internal.format_text(opts.details, fields),
        state = internal.format_text(opts.state, fields),
    }
    if opts.show_timestamps and opts.playing and (opts.duration_ms or 0) > 0 then
        local start = math.floor(opts.now_ms - opts.elapsed_ms)
        activity.timestamps = { start = start, ["end"] = math.floor(start + opts.duration_ms) }
    end
    if opts.cover ~= nil then
        activity.assets = {
            large_image = opts.cover,
            large_text = internal.format_text(opts.large_text, fields),
        }
    end
    if type(opts.buttons) == "table" and #opts.buttons > 0 then
        activity.buttons = opts.buttons
    end
    if opts.status_display_type ~= nil then
        activity.status_display_type = opts.status_display_type
    end
    return activity
end

local function deep_equal(a, b)
    if type(a) ~= type(b) then
        return false
    end
    if type(a) ~= "table" then
        return a == b
    end
    for k, v in pairs(a) do
        if not deep_equal(v, b[k]) then
            return false
        end
    end
    for k, _ in pairs(b) do
        if a[k] == nil then
            return false
        end
    end
    return true
end

local function timestamps_equal(a, b)
    if a == nil and b == nil then
        return true
    end
    if a == nil or b == nil then
        return false
    end
    return math.abs(a.start - b.start) < TIMESTAMP_TOLERANCE_MS
        and math.abs(a["end"] - b["end"]) < TIMESTAMP_TOLERANCE_MS
end

---@param a table|false|nil
---@param b table|false|nil
---@return boolean
function internal.activities_equal(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return a == b
    end
    if not timestamps_equal(a.timestamps, b.timestamps) then
        return false
    end
    for k, v in pairs(a) do
        if k ~= "timestamps" and not deep_equal(v, b[k]) then
            return false
        end
    end
    for k, _ in pairs(b) do
        if k ~= "timestamps" and a[k] == nil then
            return false
        end
    end
    return true
end

---@param now_ms integer
---@param last_sent_ms integer|nil
---@return boolean send_now, integer delay_ms
function internal.throttle_decide(now_ms, last_sent_ms)
    if last_sent_ms == nil then
        return true, 0
    end
    local elapsed = now_ms - last_sent_ms
    if elapsed >= THROTTLE_WINDOW_MS then
        return true, 0
    end
    return false, THROTTLE_WINDOW_MS - elapsed
end

-- Covers --------------------------------------------------------------------

---@param fields table
---@return string|nil
function internal.cover_cache_key(fields)
    local album_id = fields.musicbrainz_album_id
    if album_id ~= nil and album_id ~= "" then
        return album_id
    end
    local artist, album = fields.artist, fields.album
    if artist ~= nil and artist ~= "" and album ~= nil and album ~= "" then
        return artist:lower() .. "\0" .. album:lower()
    end
    return nil
end

---@param caa_json any
---@param size integer
---@return string|nil
function internal.pick_front_thumbnail(caa_json, size)
    local images = type(caa_json) == "table" and caa_json.images or nil
    if type(images) ~= "table" or #images == 0 then
        return nil
    end
    local chosen = images[1]
    for _, image in ipairs(images) do
        if image.front == true then
            chosen = image
            break
        end
    end
    local thumbs = chosen.thumbnails
    if type(thumbs) == "table" and type(thumbs[tostring(size)]) == "string" then
        return thumbs[tostring(size)]
    end
    if type(chosen.image) == "string" then
        return chosen.image
    end
    return nil
end

-- Connection ----------------------------------------------------------------
--
-- A three state machine driven by socket callbacks: "disconnected",
-- "connecting" (handshake written, waiting for READY) and "ready". The plugin
-- never waits for Discord; it writes, returns, and reacts when bytes arrive.

local SOCKET_LAYOUTS = { "", "app/com.discordapp.Discord/", "snap.discord/" }
local HANDSHAKE_TIMEOUT_MS = 5000
local RETRY_MIN_MS = 5000
local RETRY_MAX_MS = 60000

---@param env table<string, string|nil>
---@return string[]
function internal.candidate_paths(env)
    local bases = {}
    for _, name in ipairs({ "XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP" }) do
        local value = env[name]
        if value ~= nil and value ~= "" then
            table.insert(bases, (value:gsub("/+$", "")))
        end
    end
    table.insert(bases, "/tmp")

    local paths = {}
    for _, base in ipairs(bases) do
        for _, layout in ipairs(SOCKET_LAYOUTS) do
            for n = 0, 9 do
                table.insert(paths, base .. "/" .. layout .. "discord-ipc-" .. n)
            end
        end
    end
    return paths
end

---@param self DiscordPlugin
---@param name string
function internal.cancel_timer(self, name)
    local timer = self.conn.timers[name]
    if timer ~= nil then
        timer.cancel()
        self.conn.timers[name] = nil
    end
end

---@param self DiscordPlugin
---@return boolean connected
function internal.connect(self)
    if not self.enabled or self.client_id == nil then
        return false
    end
    if self.conn.state ~= "disconnected" then
        return true
    end
    internal.cancel_timer(self, "retry")

    local generation = self.conn.generation + 1
    self.conn.generation = generation

    local env = {
        XDG_RUNTIME_DIR = os.getenv("XDG_RUNTIME_DIR"),
        TMPDIR = os.getenv("TMPDIR"),
        TMP = os.getenv("TMP"),
        TEMP = os.getenv("TEMP"),
    }
    for _, path in ipairs(internal.candidate_paths(env)) do
        -- Only paths that exist are tried, so an idle machine without Discord
        -- costs a few stats per attempt and produces no connection noise.
        if fs.exists(path) then
            local sock = socket.connect_unix(path, {
                on_data = function(data)
                    if self.conn.generation == generation then
                        internal.on_data(self, data)
                    end
                end,
                on_close = function(reason)
                    if self.conn.generation == generation then
                        internal.on_close(self, reason)
                    end
                end,
            })
            if sock ~= nil then
                log.debug("discord: connected to " .. path)
                internal.begin_handshake(self, sock)
                return true
            end
        end
    end

    log.debug("discord: no discord ipc socket found")
    internal.schedule_retry(self)
    return false
end

---@param self DiscordPlugin
---@param sock UnixSocket
function internal.begin_handshake(self, sock)
    local conn = self.conn
    if conn.sock ~= nil and conn.sock ~= sock then
        conn.sock:close()
    end
    conn.sock = sock
    conn.state = "connecting"
    conn.rx_buf = ""

    internal.cancel_timer(self, "retry")
    internal.cancel_timer(self, "handshake")
    conn.timers.handshake = sync.set_timeout(HANDSHAKE_TIMEOUT_MS, function()
        conn.timers.handshake = nil
        if conn.state == "connecting" then
            log.warn("discord: handshake timed out")
            internal.drop_connection(self, "handshake timeout")
        end
    end)

    local ok, err = sock:write(internal.encode_frame(0, { v = 1, client_id = self.client_id }))
    if not ok then
        internal.drop_connection(self, err or "write failed")
    end
end

---@param self DiscordPlugin
---@param chunk string
function internal.on_data(self, chunk)
    local conn = self.conn
    if conn.sock == nil then
        return
    end

    conn.rx_buf = conn.rx_buf .. chunk
    while conn.sock ~= nil do
        local frame, rest, err = internal.take_frame(conn.rx_buf)
        if err ~= nil then
            log.warn("discord: dropping connection, malformed frame: " .. err)
            internal.drop_connection(self, err)
            return
        end
        conn.rx_buf = rest
        if frame == nil then
            return
        end
        internal.handle_frame(self, frame)
    end
end

local function describe_error(payload)
    if type(payload) ~= "table" then
        return "unknown"
    end
    return tostring(payload.code) .. ": " .. tostring(payload.message)
end

---@param self DiscordPlugin
---@param frame { opcode: integer, payload: any }
function internal.handle_frame(self, frame)
    local conn = self.conn
    local payload = frame.payload

    if frame.opcode == 3 then
        local ok, err = conn.sock:write(internal.encode_frame(4, payload))
        if not ok then
            internal.drop_connection(self, err or "write failed")
        end
    elseif frame.opcode == 2 then
        log.warn("discord: connection closed by discord, " .. describe_error(payload))
        internal.drop_connection(self, "close frame")
    elseif frame.opcode == 1 and type(payload) == "table" then
        if conn.state == "connecting" and payload.evt == "READY" then
            internal.cancel_timer(self, "handshake")
            conn.state = "ready"
            conn.retry_ms = RETRY_MIN_MS
            log.info("discord: connected")
            if self.pending ~= nil then
                internal.flush(self)
            else
                internal.request_update(self)
            end
        elseif payload.evt == "ERROR" then
            log.warn("discord: error " .. describe_error(payload.data))
        end
    end
end

---@param self DiscordPlugin
---@param reason string|nil
function internal.on_close(self, reason)
    internal.drop_connection(self, reason)
end

---@param self DiscordPlugin
---@param reason string|nil
function internal.drop_connection(self, reason)
    local conn = self.conn
    if conn.sock == nil and conn.state == "disconnected" then
        -- Discord sends a close frame and then closes the socket; the second
        -- notification must not double the backoff.
        return
    end
    if conn.sock ~= nil then
        conn.sock:close()
        conn.sock = nil
    end
    conn.state = "disconnected"
    conn.rx_buf = ""
    internal.cancel_timer(self, "handshake")
    -- A fresh connection shows nothing, so a pending clear is moot and the
    -- next activity must be sent again even if it equals the last one.
    self.last_sent = nil
    if self.pending == false then
        self.pending = nil
    end
    log.debug("discord: disconnected, " .. tostring(reason))
    internal.schedule_retry(self)
end

---@param self DiscordPlugin
function internal.schedule_retry(self)
    if not (self.playing or self.pending == false) then
        return
    end

    local conn = self.conn
    internal.cancel_timer(self, "retry")
    conn.timers.retry = sync.set_timeout(conn.retry_ms, function()
        conn.timers.retry = nil
        internal.connect(self)
    end)
    conn.retry_ms = math.min(conn.retry_ms * 2, RETRY_MAX_MS)
end

---@param self DiscordPlugin
function internal.cancel_retry(self)
    internal.cancel_timer(self, "retry")
end

local function set_activity_frame(self, activity)
    local conn = self.conn
    conn.nonce = conn.nonce + 1
    local args = { pid = process.pid() }
    if activity ~= nil and activity ~= false then
        args.activity = activity
    end
    return internal.encode_frame(1, { cmd = "SET_ACTIVITY", args = args, nonce = tostring(conn.nonce) })
end

---@param self DiscordPlugin
function internal.flush(self)
    local conn = self.conn
    if conn.state == "connecting" then
        return
    end
    if self.pending == nil then
        return
    end
    if conn.state == "disconnected" then
        internal.connect(self)
        return
    end

    local ok, err = conn.sock:write(set_activity_frame(self, self.pending))
    if not ok then
        internal.drop_connection(self, err or "write failed")
        return
    end
    self.last_sent = self.pending
    self.last_sent_ms = internal.now_ms()
    self.pending = nil
end

---@param self DiscordPlugin
function internal.shutdown(self)
    local conn = self.conn
    if conn.state == "ready" and conn.sock ~= nil then
        conn.sock:write(set_activity_frame(self, false))
    end
    for name, _ in pairs(conn.timers) do
        internal.cancel_timer(self, name)
    end
    if conn.sock ~= nil then
        conn.sock:close()
        conn.sock = nil
    end
    conn.state = "disconnected"
    conn.rx_buf = ""
    self.pending = nil
end

-- Send path -----------------------------------------------------------------
--
-- Triggers only ever call request_update, which debounces. The debounced
-- do_update fetches status, resolves the cover, builds the activity and hands
-- it to submit, which throttles sends to Discord's rate limit.

---@param self DiscordPlugin
---@param activity table|false
function internal.submit(self, activity)
    -- A fresh connection shows nothing, so clearing nothing is a no-op.
    if activity == false and self.last_sent == nil then
        self.pending = nil
        return
    end
    if internal.activities_equal(activity, self.last_sent) then
        self.pending = nil
        return
    end
    self.pending = activity

    local send_now, delay = internal.throttle_decide(internal.now_ms(), self.last_sent_ms)
    if send_now then
        internal.cancel_timer(self, "throttle")
        internal.flush(self)
        return
    end
    if self.conn.timers.throttle == nil then
        self.conn.timers.throttle = sync.set_timeout(delay, function()
            self.conn.timers.throttle = nil
            internal.flush(self)
        end)
    end
end

---@param self DiscordPlugin
function internal.do_update(self)
    if not self.enabled then
        return
    end
    local status = mpd.get_status()
    if status == nil then
        return
    end
    local song = mpd.get_current_song()
    self.playing = status.state == "play"

    local clear = song == nil
        or status.state == "stop"
        or (status.state == "pause" and self.on_pause == "clear")
    if clear then
        self.current = nil
        self.started_at_ms = nil
        self.song_id = nil
        internal.submit(self, false)
        if not self.playing then
            internal.cancel_retry(self)
        end
        return
    end

    local fields = internal.song_fields(song)
    self.current = fields
    local cover = internal.cover_lookup(self, fields)

    local now = internal.now_ms()
    local elapsed = status.elapsed or 0
    local duration = status.duration
    if duration == nil or duration <= 0 then
        duration = song.duration or 0
    end
    local activity = internal.build_activity(fields, {
        details = self.details_fmt,
        state = self.state_fmt,
        large_text = self.large_text_fmt,
        show_timestamps = self.show_timestamps,
        now_ms = now,
        elapsed_ms = elapsed,
        duration_ms = duration,
        playing = self.playing,
        cover = cover,
        buttons = self.buttons,
        status_display_type = self.status_display_type,
    })
    self.song_id = status.song_id
    self.started_at_ms = now - elapsed
    internal.submit(self, activity)
end

---@param self DiscordPlugin
function internal.request_update(self)
    if self.update_debounced ~= nil then
        self.update_debounced(self)
    end
end

---@param self DiscordPlugin
function internal.disable(self)
    self.enabled = false
    internal.cancel_timer(self, "throttle")
    internal.cancel_retry(self)
    self.pending = nil
    self.current = nil
    self.started_at_ms = nil
    self.song_id = nil
    if self.conn.state == "ready" then
        self.pending = false
        internal.flush(self)
    end
end

-- Seek ----------------------------------------------------------------------

---@param started_at_ms integer
---@param now_ms integer
---@param elapsed_ms integer
---@return boolean
function internal.seek_delta_exceeds(started_at_ms, now_ms, elapsed_ms)
    return math.abs((now_ms - elapsed_ms) - started_at_ms) > TIMESTAMP_TOLERANCE_MS
end

---@param self DiscordPlugin
function internal.on_idle_player(self)
    if not (self.enabled and self.playing and self.started_at_ms ~= nil) then
        return
    end
    local status = mpd.get_status()
    if status == nil or status.state ~= "play" or status.song_id ~= self.song_id then
        return
    end
    if internal.seek_delta_exceeds(self.started_at_ms, internal.now_ms(), status.elapsed or 0) then
        internal.request_update(self)
    end
end

-- Cover providers -----------------------------------------------------------

local MUSICBRAINZ_URL = "https://musicbrainz.org/ws/2"
local CAA_URL = "https://coverartarchive.org"
local MAX_RELEASES = 3
local REQUEST_TIMEOUT_MS = 10000
local REQUEST_SPACING_MS = 1000

-- MusicBrainz asks anonymous clients for one request per second, so every
-- request after the first within one lookup waits.
local function api_get(self, url, params)
    if (self.cover_requests or 0) > 0 then
        sync.sleep(REQUEST_SPACING_MS)
    end
    self.cover_requests = (self.cover_requests or 0) + 1
    return http.get(url, {
        headers = { ["User-Agent"] = USER_AGENT, ["Accept"] = "application/json" },
        params = params,
        timeout_ms = REQUEST_TIMEOUT_MS,
    })
end

---Splits an http response into a decoded JSON body and a flag saying whether
---a failure was transient (busy server, rate limit, timeout, transport error)
---rather than a definitive miss such as 404.
---@param resp table|nil
---@return table|nil json, boolean transient
function internal.classify_response(resp)
    local code = resp and resp.code
    if type(code) ~= "number" then
        return nil, true
    end
    if code == 429 or code >= 500 then
        return nil, true
    end
    if code ~= 200 then
        return nil, false
    end
    if resp.error ~= nil then
        return nil, true
    end
    local ok, json = pcall(resp.json, resp)
    if not ok or type(json) ~= "table" then
        return nil, false
    end
    return json, false
end

local function response_json(self, resp)
    local json, transient = internal.classify_response(resp)
    if transient then
        self.cover_transient = true
    end
    return json
end

---@param self DiscordPlugin
---@param kind "release"|"release-group"
---@param mbid string
---@return string|nil
function internal.caa_front_url(self, kind, mbid)
    local json = response_json(self, api_get(self, CAA_URL .. "/" .. kind .. "/" .. mbid))
    if json == nil then
        return nil
    end
    return internal.pick_front_thumbnail(json, self.cover.size)
end

local function first_release_cover(self, releases)
    if type(releases) ~= "table" then
        return nil
    end
    for i = 1, math.min(#releases, MAX_RELEASES) do
        local id = type(releases[i]) == "table" and releases[i].id or nil
        if type(id) == "string" then
            local url = internal.caa_front_url(self, "release", id)
            if url ~= nil then
                return url
            end
        end
    end
    return nil
end

internal.providers = {}

---@param self DiscordPlugin
---@param fields table
---@return string|nil
function internal.providers.musicbrainz_tags(self, fields)
    if fields.musicbrainz_album_id ~= nil then
        local url = internal.caa_front_url(self, "release", fields.musicbrainz_album_id)
        if url ~= nil then
            return url
        end
    end
    if fields.musicbrainz_release_group_id ~= nil then
        local url = internal.caa_front_url(self, "release-group", fields.musicbrainz_release_group_id)
        if url ~= nil then
            return url
        end
    end
    if fields.musicbrainz_track_id ~= nil then
        local json = response_json(self, api_get(self, MUSICBRAINZ_URL .. "/recording/" .. fields.musicbrainz_track_id, {
            inc = "releases",
            fmt = "json",
        }))
        if json ~= nil then
            return first_release_cover(self, json.releases)
        end
    end
    return nil
end

local function lucene_quote(s)
    return '"' .. (s:gsub('"', '\\"')) .. '"'
end

---@param self DiscordPlugin
---@param fields table
---@return string|nil
function internal.providers.musicbrainz_search(self, fields)
    local artist, album = fields.artist_tag, fields.album
    if artist == nil or artist == "" or album == nil or album == "" then
        return nil
    end
    local json = response_json(self, api_get(self, MUSICBRAINZ_URL .. "/release/", {
        query = "release:" .. lucene_quote(album) .. " AND artist:" .. lucene_quote(artist),
        fmt = "json",
        limit = tostring(MAX_RELEASES),
    }))
    if json == nil then
        return nil
    end
    return first_release_cover(self, json.releases)
end

---@param self DiscordPlugin
---@param _fields table
---@return string|nil
function internal.providers.static(self, _fields)
    return self.cover.static_image
end

---@param self DiscordPlugin
---@param fields table
---@return string|nil
function internal.cover_lookup(self, fields)
    local key = internal.cover_cache_key(fields)
    if key ~= nil then
        local cached = self.cover_cache[key]
        if cached ~= nil then
            return cached or nil
        end
    end

    self.cover_requests = 0
    self.cover_transient = false
    local found = nil
    for _, name in ipairs(self.cover.providers) do
        local provider = internal.providers[name]
        if provider == nil then
            log.warn("discord: unknown cover provider " .. tostring(name))
        else
            local url = provider(self, fields)
            if type(url) == "string" then
                -- Cover Art Archive hands out http:// links; it serves https too.
                url = (url:gsub("^http://", "https://"))
            end
            if type(url) == "string" and url ~= "" and #url <= MAX_IMAGE_URL_LEN then
                found = url
                break
            elseif url ~= nil then
                log.debug("discord: cover provider " .. name .. " returned an unusable url")
            end
        end
    end

    -- A transient failure (busy MusicBrainz, timeout) is retried on the next
    -- lookup; only definitive misses are remembered.
    if key ~= nil and (found ~= nil or not self.cover_transient) then
        self.cover_cache[key] = found or false
    end
    return found
end

-- Triggers ------------------------------------------------------------------

M.start = function(self)
    internal.request_update(self)
end

M.song_change = function(self, _old_song, _new_song)
    internal.request_update(self)
end

M.state_change = function(self, _old_state, _new_state)
    internal.request_update(self)
end

M.reconnect = function(self)
    internal.request_update(self)
end

M.idle_event = function(self, event)
    if event == "player" then
        internal.on_idle_player(self)
    end
end

M.shutdown = function(self)
    internal.shutdown(self)
end

local function enable(self)
    self.enabled = true
    internal.request_update(self)
end

M.message = function(self, _channel, message)
    if message == "enable" then
        log.info("Enabling discord plugin")
        enable(self)
    elseif message == "disable" then
        log.info("Disabling discord plugin")
        internal.disable(self)
    elseif message == "toggle" then
        log.info("Toggling discord plugin to: " .. tostring(not self.enabled))
        if self.enabled then
            internal.disable(self)
        else
            enable(self)
        end
    end
end

-- Setup ---------------------------------------------------------------------

M.setup = function(self, args)
    args = args or {}
    self.client_id = args.client_id
    if type(self.client_id) == "number" then
        self.client_id = string.format("%d", self.client_id)
    end
    if self.client_id == nil or self.client_id == "" then
        self.client_id = DEFAULT_CLIENT_ID
    end
    self.enabled = args.enabled == nil or args.enabled

    self.details_fmt = args.details or "{title}"
    self.state_fmt = args.state or "{artist}"
    self.large_text_fmt = args.large_text or "{album}"
    self.show_timestamps = args.show_timestamps == nil or args.show_timestamps
    self.on_pause = args.on_pause or "clear"
    self.buttons = nil
    if type(args.buttons) == "table" and #args.buttons > 0 then
        self.buttons = { args.buttons[1], args.buttons[2] }
    end
    self.debounce_delay = args.debounce_delay or 1000
    self.status_display_type = nil
    if args.status_display ~= nil then
        self.status_display_type = STATUS_DISPLAY[args.status_display]
        if self.status_display_type == nil then
            log.error(
                "discord: unknown status_display '"
                    .. tostring(args.status_display)
                    .. "', expected \"name\", \"state\" or \"details\""
            )
        end
    end

    local cover = args.cover or {}
    self.cover = {
        providers = cover.providers or { table.unpack(DEFAULT_PROVIDERS) },
        static_image = cover.static_image or "logo",
        size = cover.size or 500,
    }

    self.conn = {
        state = "disconnected",
        sock = nil,
        rx_buf = "",
        nonce = 0,
        retry_ms = 5000,
        timers = {},
        generation = 0,
    }
    self.pending = nil
    self.last_sent = nil
    self.last_sent_ms = nil
    self.started_at_ms = nil
    self.song_id = nil
    self.playing = false
    self.current = nil
    self.cover_cache = {}
    self.cover_requests = 0
    self.cover_transient = false

    local update = function(plugin)
        internal.do_update(plugin)
    end
    if self.debounce_delay < 0 then
        self.update_debounced = update
    else
        self.update_debounced = sync.debounce(self.debounce_delay, update)
    end
end

M.subscribed_channels = { "rmpcd.discord" }

return M
