-- Pramprem extension entry point
-- Loads both plugin modules and registers them under the "Pramprem" menu.

_PRAMPREM_INIT = true

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    -- source starts with "@" when loaded from a file
    return src:sub(2):match("(.*[/\\])") or ""
end

local dir = scriptDir()
dofile(dir .. "color-swap.lua")
dofile(dir .. "noise-texture.lua")

function init(plugin)
    plugin:newMenuGroup {
        id    = "pramprem_group",
        title = "Pramprem",
        group = "edit_fill",
    }
    plugin:newCommand {
        id        = "PrampremColorSwap",
        title     = "Color Swap...",
        group     = "pramprem_group",
        onclick   = colorSwap,
        onenabled = function() return app.sprite ~= nil end,
    }
    plugin:newCommand {
        id        = "PrampremNoiseTexture",
        title     = "Noise Texture...",
        group     = "pramprem_group",
        onclick   = showDialog,
        onenabled = function() return app.sprite ~= nil end,
    }
end

function exit(plugin) end
