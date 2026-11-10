A plugin that shows the song currently playing in MPD as a Discord "Listening to" activity (rich
presence), including album art looked up on MusicBrainz and the Cover Art Archive.

Requires the Discord desktop client running on the same machine and an rmpcd version with unix
socket support.

## AI disclosure

Note that this plugin, unlike rmpc/rmpcd is heavily AI assisted. It hhas been proofread by me, but
you know what you are getting into.

## Installation

Put the following inside your `init.lua`. The plugin will be automatically downloaded and installed.

```lua
rmpcd.install({ url = "https://github.com/rmpc-org/rmpcd-discord-rich-presence.git" })
```

## Configuration

All options are optional. The values below are the defaults.

```lua
rmpcd.install({ url = "https://github.com/rmpc-org/rmpcd-discord-rich-presence.git" }):setup({
	-- Discord application to show the activity under, see below
	client_id = "1569394987265818644",
	enabled = true,
	-- First and second line of the activity and the hover text of the cover
	details = "{title}",
	state = "{artist}",
	large_text = "{album}",
	-- Show the progress bar
	show_timestamps = true,
	-- "clear" removes the activity while paused, "show" keeps it without the progress bar
	on_pause = "clear",
	-- Up to two buttons, for example { { label = "Website", url = "https://example.com" } }
	buttons = nil,
	-- Which text the member list shows after "Listening to": "name" (the application name,
	-- Discord's default when unset), "state" or "details"
	status_display = nil,
	-- How long to wait for player changes to settle before updating, in milliseconds
	debounce_delay = 1000,
	cover = {
		-- Tried in order until one returns a cover
		providers = { "musicbrainz_tags", "musicbrainz_search", "static" },
		-- Asset key or https URL used by the "static" provider
		static_image = "logo",
		-- Cover Art Archive thumbnail size, 250 or 500
		size = 500,
	},
})
```

The `details`, `state` and `large_text` formats can use these placeholders: `{title}`, `{artist}`,
`{album}`, `{album_artist}`, `{date}`, `{file}` and `{duration}`.

The plugin ships with its own Discord application. To use a different name after "Listening to"
or your own art assets, create an application at <https://discord.com/developers/applications> and
pass its Application ID as `client_id`. Upload an image named `logo` under Rich Presence > Art
Assets to have a fallback cover for songs without album art.

Cover providers:

- `musicbrainz_tags` uses the MusicBrainz release, release group or recording id from the song's
  tags.
- `musicbrainz_search` searches MusicBrainz by the artist and album tags.
- `static` always uses `cover.static_image`.

## Type definitions

The plugin ships LuaLS type definitions in `types.lua`. They are picked up when rmpcd's plugins
directory is listed under `workspace.library` in the `.luarc.json` next to your `init.lua`, see
the LuaLS section of the [rmpcd README](https://github.com/mierak/rmpc/blob/master/rmpcd/README.md).
Annotate the installed plugin to get completion for the `setup` arguments:

```lua
---@type DiscordPlugin
local discord = rmpcd.install({ url = "https://github.com/rmpc-org/rmpcd-discord-rich-presence.git" })
discord:setup({
	on_pause = "show",
})
```

## Runtime control

The plugin can be enabled, disabled or toggled at runtime by sending a message to the
`rmpcd.discord` MPD channel, for example with rmpc's CLI:

```sh
rmpc sendmessage rmpcd.discord disable
rmpc sendmessage rmpcd.discord enable
rmpc sendmessage rmpcd.discord toggle
```
