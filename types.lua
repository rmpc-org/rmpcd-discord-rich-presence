---@meta

---@class DiscordCoverArgs
---@field providers? ("musicbrainz_tags"|"musicbrainz_search"|"static")[] Default all three in this order.
---@field static_image? string Asset key or https URL used by the "static" provider. Default "logo".
---@field size? 250|500 Cover Art Archive thumbnail size. Default 500.

---@class DiscordButton
---@field label string
---@field url string

---@class DiscordArgs
---@field client_id? string Discord application id. Defaults to the application shipped with the plugin.
---@field enabled? boolean Default true.
---@field details? string Format for the first line. Default "{title}".
---@field state? string Format for the second line. Default "{artist}".
---@field large_text? string Hover text on the cover. Default "{album}".
---@field show_timestamps? boolean Progress bar. Default true.
---@field on_pause? "clear"|"show" Default "clear". "show" keeps the activity without timestamps.
---@field buttons? DiscordButton[] At most 2. Default none.
---@field status_display? "name"|"state"|"details" Which text the member list shows after "Listening to": the application name (Discord's default when unset), the state line or the details line.
---@field debounce_delay? integer Milliseconds. Default 1000.
---@field cover? DiscordCoverArgs

---@class DiscordConnection
---@field state "disconnected"|"connecting"|"ready"
---@field sock UnixSocket|nil
---@field rx_buf string
---@field nonce integer
---@field retry_ms integer
---@field timers table<string, TimeoutHandle>
---@field generation integer Incremented per connect so callbacks of a stale socket are ignored.

---@class DiscordPlugin: RmpcdPlugin<DiscordArgs>
---@field enabled boolean
---@field client_id string
---@field details_fmt string
---@field state_fmt string
---@field large_text_fmt string
---@field show_timestamps boolean
---@field on_pause "clear"|"show"
---@field buttons DiscordButton[]|nil
---@field status_display_type integer|nil 0 name, 1 state, 2 details; nil leaves Discord's default.
---@field debounce_delay integer
---@field cover { providers: string[], static_image: string, size: integer }
---@field conn DiscordConnection
---@field pending table|false|nil
---@field last_sent table|false|nil
---@field last_sent_ms integer|nil
---@field started_at_ms integer|nil
---@field song_id integer|nil
---@field playing boolean
---@field cover_cache table<string, string|false>
---@field cover_requests integer
---@field cover_transient boolean Set when the current lookup hit a transient failure, which keeps the miss out of the cache.
---@field current table|nil Fields of the song last built into an activity.
---@field update_debounced fun(self: DiscordPlugin)
---@field _internal table

local M = {}
return M
