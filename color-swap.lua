-- Color Swap Plugin for Aseprite (RGB mode)
-- Replaces a family of similar colors (by HSV similarity to a reference) with
-- a target color family, preserving relative hue/saturation/value offsets.
--
-- Works both as a standalone script (File > Scripts) and as an extension.
--
-- Usage:
--   1. Pick a Reference color (the "anchor" of the range you want to replace).
--   2. Pick a Target color   (the "anchor" of the destination range).
--   3. Tune the three tolerance sliders to widen or narrow the selection.
--   4. Press Apply.
--
-- How the replacement works (all in HSV space):
--   For every pixel whose (H, S, V) is within the given tolerances of the
--   reference color, the plugin computes the per-channel delta from the
--   reference and applies the same delta to the target color, then clamps the
--   result to valid HSV ranges.  Alpha is always preserved.

-- ─── HSV / RGB helpers ───────────────────────────────────────────────────────

local function rgbToHsv(r, g, b)
    r, g, b    = r / 255, g / 255, b / 255
    local maxC = math.max(r, g, b)
    local minC = math.min(r, g, b)
    local d    = maxC - minC
    local h, s, v
    v          = maxC
    s          = (maxC == 0) and 0 or (d / maxC)
    if d == 0 then
        h = 0
    elseif maxC == r then
        h = ((g - b) / d) % 6
    elseif maxC == g then
        h = (b - r) / d + 2
    else
        h = (r - g) / d + 4
    end
    h = h * 60
    if h < 0 then h = h + 360 end
    return h, s, v
end

local function hsvToRgb(h, s, v)
    h = h % 360
    if h < 0 then h = h + 360 end
    if s <= 0 then
        local c = math.floor(v * 255 + 0.5)
        return c, c, c
    end
    local i = math.floor(h / 60)
    local f = h / 60 - i
    local p = v * (1 - s)
    local q = v * (1 - s * f)
    local t = v * (1 - s * (1 - f))
    local r, g, b
    if i == 0 then
        r, g, b = v, t, p
    elseif i == 1 then
        r, g, b = q, v, p
    elseif i == 2 then
        r, g, b = p, v, t
    elseif i == 3 then
        r, g, b = p, q, v
    elseif i == 4 then
        r, g, b = t, p, v
    else
        r, g, b = v, p, q
    end
    return math.floor(r * 255 + 0.5),
        math.floor(g * 255 + 0.5),
        math.floor(b * 255 + 0.5)
end

-- Shortest angular distance between two hues, result in [0, 180].
local function hueDist(h1, h2)
    local d = math.abs(h1 - h2)
    return d > 180 and (360 - d) or d
end

local function clamp(x, lo, hi)
    return math.max(lo, math.min(hi, x))
end

-- ─── Core swap logic ─────────────────────────────────────────────────────────

-- Applies swap to a standalone (unattached) image in-place.
-- selection, offX, offY are optional; when a non-empty selection is given only
-- pixels whose sprite-space coordinates fall inside it are touched.
-- Returns the number of pixels changed.
local function applySwapToImage(img, refH, refS, refV, tgtH, tgtS, tgtV, hueTol, satTol, valTol, selection, offX, offY)
    local count  = 0
    local useSel = selection and not selection.isEmpty
    offX         = offX or 0
    offY         = offY or 0
    for it in img:pixels() do
        if useSel and not selection:contains(Point(it.x + offX, it.y + offY)) then
            goto continue
        end
        local pixVal = it()
        local pr = app.pixelColor.rgbaR(pixVal)
        local pg = app.pixelColor.rgbaG(pixVal)
        local pb = app.pixelColor.rgbaB(pixVal)
        local pa = app.pixelColor.rgbaA(pixVal)
        if pa > 0 then
            local ph, ps, pv = rgbToHsv(pr, pg, pb)
            if hueDist(ph, refH) <= hueTol
                and math.abs(ps - refS) <= satTol
                and math.abs(pv - refV) <= valTol then
                local dh = ph - refH
                if dh > 180 then dh = dh - 360 end
                if dh < -180 then dh = dh + 360 end
                local newH = (tgtH + dh) % 360
                local newS = clamp(tgtS + (ps - refS), 0, 1)
                local newV = clamp(tgtV + (pv - refV), 0, 1)
                local nr, ng, nb = hsvToRgb(newH, newS, newV)
                it(app.pixelColor.rgba(nr, ng, nb, pa))
                count = count + 1
            end
        end
        ::continue::
    end
    return count
end

-- Applies swap to all cels inside a transaction (generates undo history).
-- Works by cloning each cel image, modifying the clone, then assigning it
-- back to the cel -- the assignment is what Aseprite records for undo.
local function applySwapWithUndo(sprite, refH, refS, refV, tgtH, tgtS, tgtV, hueTol, satTol, valTol)
    local replaced = 0
    local sel      = sprite.selection
    app.transaction("Color Swap", function()
        for _, cel in ipairs(sprite.cels) do
            if cel.layer.isVisible then
                local copy = cel.image:clone()
                local n = applySwapToImage(copy, refH, refS, refV, tgtH, tgtS, tgtV, hueTol, satTol, valTol,
                    sel, cel.position.x, cel.position.y)
                if n > 0 then
                    cel.image = copy -- assignment to cel.image is recorded by undo
                    replaced = replaced + n
                end
            end
        end
    end)
    return replaced
end

-- Applies swap to a new (or existing) layer named "Color Swap" at the top of
-- the layer stack.  Original pixels are never modified.  Matching pixels from
-- every layer/cel are composited onto the target layer with their swapped
-- colours; non-matching pixels are left transparent.
--
-- Each frame is collected and written independently to prevent any possibility
-- of cross-frame accumulation.  Layer identity is checked by name rather than
-- by Lua object identity, since Aseprite may return a fresh wrapper object on
-- each property access.
local function applySwapToNewLayer(sprite, refH, refS, refV, tgtH, tgtS, tgtV, hueTol, satTol, valTol)
    local replaced = 0
    local sel      = sprite.selection
    app.transaction("Color Swap (New Layer)", function()
        -- Find or create the "Color Swap" layer.
        local swapLayer = nil
        for _, layer in ipairs(sprite.layers) do
            if layer.name == "Color Swap" then
                swapLayer = layer
                break
            end
        end
        if not swapLayer then
            swapLayer            = sprite:newLayer()
            swapLayer.name       = "Color Swap"
            swapLayer.stackIndex = #sprite.layers -- move to top
        end

        -- Process one frame at a time: collect then write before moving on.
        -- This guarantees each frame's image is isolated and committed before
        -- the next frame's image is even created.
        for _, frame in ipairs(sprite.frames) do
            local frameNum = frame.frameNumber
            local fi       = nil -- result image for this frame (lazy init)
            local useSel   = sel and not sel.isEmpty

            -- Collect matching pixels from every visible non-swap cel on this frame.
            for _, cel in ipairs(sprite.cels) do
                if cel.frameNumber == frameNum and cel.layer.isVisible and cel.layer.name ~= "Color Swap" then
                    local img  = cel.image
                    local offX = cel.position.x
                    local offY = cel.position.y

                    for it in img:pixels() do
                        local inSel = (not useSel) or sel:contains(Point(it.x + offX, it.y + offY))
                        if inSel then
                            local pixVal = it()
                            local pr     = app.pixelColor.rgbaR(pixVal)
                            local pg     = app.pixelColor.rgbaG(pixVal)
                            local pb     = app.pixelColor.rgbaB(pixVal)
                            local pa     = app.pixelColor.rgbaA(pixVal)
                            if pa > 0 then
                                local ph, ps, pv = rgbToHsv(pr, pg, pb)
                                if hueDist(ph, refH) <= hueTol
                                    and math.abs(ps - refS) <= satTol
                                    and math.abs(pv - refV) <= valTol then
                                    if not fi then
                                        fi = Image(sprite.width, sprite.height, sprite.colorMode)
                                        fi:clear(app.pixelColor.rgba(0, 0, 0, 0))
                                    end
                                    local dh = ph - refH
                                    if dh > 180 then dh = dh - 360 end
                                    if dh < -180 then dh = dh + 360 end
                                    local newH = (tgtH + dh) % 360
                                    local newS = clamp(tgtS + (ps - refS), 0, 1)
                                    local newV = clamp(tgtV + (pv - refV), 0, 1)
                                    local nr, ng, nb = hsvToRgb(newH, newS, newV)
                                    fi:putPixel(
                                        it.x + offX, it.y + offY,
                                        app.pixelColor.rgba(nr, ng, nb, pa))
                                    replaced = replaced + 1
                                end
                            end
                        end
                    end
                end
            end

            -- Write this frame's result immediately before processing the next frame.
            if fi then
                local existingCel = nil
                for _, cel in ipairs(sprite.cels) do
                    if cel.layer.name == "Color Swap" and cel.frameNumber == frameNum then
                        existingCel = cel
                        break
                    end
                end
                if existingCel then
                    existingCel.image    = fi
                    existingCel.position = Point(0, 0)
                else
                    sprite:newCel(swapLayer, frameNum, fi, Point(0, 0))
                end
            end
        end
    end)
    return replaced
end

-- ─── Session-persistent settings (survive re-opens within the same session) ──
-- Must be a global (not local) so it survives re-execution of the script file.

if not _colorSwapSettings then
    _colorSwapSettings = {
        ref_color = nil, -- Color object; nil → use app.fgColor on first open
        tgt_color = nil, -- Color object; nil → use app.bgColor on first open
        hue_tol   = 30,
        sat_tol   = 20,
        val_tol   = 20,
        preview   = false,
        new_layer = false,
    }
end
local lastSettings = _colorSwapSettings

-- ─── Dialog ──────────────────────────────────────────────────────────────────

function colorSwap()
    local sprite = app.sprite
    if not sprite then
        app.alert("No active sprite.")
        return
    end
    if sprite.colorMode ~= ColorMode.RGB then
        app.alert(
            "Color Swap only works with RGB sprites.\n" ..
            "Convert the sprite to RGB first (Sprite > Color Mode > RGB).")
        return
    end

    -- ── Snapshots of every cel image (used to restore before each preview) ──
    -- IMPORTANT: we keep the exact same cel Lua objects captured here.
    -- Re-fetching sprite.cels later returns new wrapper objects that won't
    -- match as table keys, so we use a parallel numeric index instead.
    local celList   = {}
    local snapBytes = {}
    for i, cel in ipairs(sprite.cels) do
        celList[i]   = cel
        snapBytes[i] = cel.image.bytes -- raw byte string; cheap to store
    end

    local function restoreAll()
        for i, cel in ipairs(celList) do
            cel.image.bytes = snapBytes[i]
        end
    end

    -- applied flag: prevents onclose from restoring after a successful Apply
    local applied = false
    -- guard flag: set to false in onclose so the sitechange listener becomes a no-op
    local dlgActive = true

    -- Forward declaration so button callbacks can reference dlg
    local dlg

    local function saveSettings()
        local d                = dlg.data
        lastSettings.ref_color = d.ref_color
        lastSettings.tgt_color = d.tgt_color
        lastSettings.hue_tol   = d.hue_tol
        lastSettings.sat_tol   = d.sat_tol
        lastSettings.val_tol   = d.val_tol
        lastSettings.preview   = d.preview
        lastSettings.new_layer = d.new_layer
    end

    local function getHsvParams()
        local data             = dlg.data
        local refC             = data.ref_color
        local tgtC             = data.tgt_color
        local refH, refS, refV = rgbToHsv(refC.red, refC.green, refC.blue)
        local tgtH, tgtS, tgtV = rgbToHsv(tgtC.red, tgtC.green, tgtC.blue)
        return refH, refS, refV, tgtH, tgtS, tgtV,
            data.hue_tol,
            data.sat_tol / 100,
            data.val_tol / 100
    end

    -- Preview: restore then apply only to the currently visible frame
    local function applyPreview()
        restoreAll()
        local refH, refS, refV, tgtH, tgtS, tgtV, hueTol, satTol, valTol = getHsvParams()
        local frameNum                                                   = app.frame.frameNumber
        local sel                                                        = sprite.selection
        for _, cel in ipairs(sprite.cels) do
            if cel.frameNumber == frameNum and cel.layer.isVisible then
                applySwapToImage(cel.image,
                    refH, refS, refV,
                    tgtH, tgtS, tgtV,
                    hueTol, satTol, valTol,
                    sel, cel.position.x, cel.position.y)
            end
        end
        app.refresh()
    end

    -- Reference color: disable preview and restore so the eyedropper sees
    -- unmodified pixels.
    local function onRefColorChange()
        dlg:modify { id = "preview", selected = false }
        restoreAll()
        app.refresh()
    end

    -- Target color: it is safe to keep the preview active; just re-run it.
    local function onTgtColorChange()
        if dlg.data.preview then
            applyPreview()
        end
    end

    -- Sliders apply preview only when the preview checkbox is on.
    local function onSliderChange()
        if dlg.data.preview then
            applyPreview()
        end
    end

    dlg = Dialog {
        title   = "Color Swap",
        onclose = function()
            dlgActive = false
            if not applied then
                restoreAll()
                app.refresh()
            end
        end
    }

    dlg:color { id = "ref_color", label = "Reference color:", color = lastSettings.ref_color or app.fgColor, onchange = onRefColorChange }
    dlg:color { id = "tgt_color", label = "Target color:", color = lastSettings.tgt_color or app.bgColor, onchange = onTgtColorChange }

    dlg:separator { text = "Similarity range (reference ± tolerance)" }

    dlg:slider { id = "hue_tol", label = "Hue tolerance (deg):", min = 0, max = 180, value = lastSettings.hue_tol, onchange = onSliderChange }
    dlg:slider { id = "sat_tol", label = "Saturation tolerance (%):", min = 0, max = 100, value = lastSettings.sat_tol, onchange = onSliderChange }
    dlg:slider { id = "val_tol", label = "Brightness tolerance (%):", min = 0, max = 100, value = lastSettings.val_tol, onchange = onSliderChange }

    dlg:separator { text = "Expand range to include another source color" }

    -- Extra source color picker: picking a color and pressing the button widens
    -- the three tolerance sliders just enough to include that color.
    dlg:color { id = "extra_color", label = "Extra source color:",
        color = lastSettings.ref_color or app.fgColor
    }
    dlg:newrow()
    dlg:button { text = "Add source color", onclick = function()
        local data             = dlg.data
        local refC             = data.ref_color
        local extra            = data.extra_color

        local refH, refS, refV = rgbToHsv(refC.red, refC.green, refC.blue)
        local exH, exS, exV    = rgbToHsv(extra.red, extra.green, extra.blue)

        -- Minimum tolerance needed to include the extra color, plus 1 unit margin
        local needHue          = math.ceil(hueDist(exH, refH)) + 1
        local needSat          = math.ceil(math.abs(exS - refS) * 100) + 1
        local needVal          = math.ceil(math.abs(exV - refV) * 100) + 1

        -- Only expand, never shrink
        local newHue           = math.max(data.hue_tol, needHue)
        local newSat           = math.max(data.sat_tol, needSat)
        local newVal           = math.max(data.val_tol, needVal)

        -- Clamp to slider maxima
        newHue                 = math.min(newHue, 180)
        newSat                 = math.min(newSat, 100)
        newVal                 = math.min(newVal, 100)

        dlg:modify { id = "hue_tol", value = newHue }
        dlg:modify { id = "sat_tol", value = newSat }
        dlg:modify { id = "val_tol", value = newVal }

        -- Re-run preview with the updated tolerances if it is active
        if data.preview then
            applyPreview()
        end
    end }

    dlg:separator {}

    dlg:check { id = "preview", label = "Preview:", text = "Show preview",
        selected = lastSettings.preview,
        onclick = function()
            if dlg.data.preview then
                applyPreview()
            else
                restoreAll()
                app.refresh()
            end
        end
    }

    dlg:check { id = "new_layer", label = "New layer:", text = "Apply into \"Color Swap\" layer",
        selected = lastSettings.new_layer
    }

    dlg:separator {}

    dlg:button { id = "ok", text = "Apply", focus = true, onclick = function()
        local refH, refS, refV, tgtH, tgtS, tgtV, hueTol, satTol, valTol = getHsvParams()
        -- Restore to originals so the transaction starts from a clean slate
        restoreAll()
        local replaced
        if dlg.data.new_layer then
            replaced = applySwapToNewLayer(sprite,
                refH, refS, refV, tgtH, tgtS, tgtV, hueTol, satTol, valTol)
        else
            replaced = applySwapWithUndo(sprite,
                refH, refS, refV, tgtH, tgtS, tgtV, hueTol, satTol, valTol)
        end
        saveSettings()
        applied = true
        app.refresh()
        dlg:close()
        if replaced == 0 then
            app.alert("No pixels matched the reference color with the given tolerances.")
        end
    end }

    dlg:button { id = "cancel", text = "Cancel", onclick = function()
        saveSettings()
        restoreAll()
        app.refresh()
        applied = true -- prevent double-restore in onclose
        dlg:close()
    end }

    -- Re-run preview whenever the user navigates to a different frame.
    local prevSiteFrame = app.frame and app.frame.frameNumber
    app.events:on('sitechange', function()
        if not dlgActive then return end
        local curFrame = app.frame and app.frame.frameNumber
        if curFrame == prevSiteFrame then return end
        prevSiteFrame = curFrame
        if dlg.data.preview then
            applyPreview()
        end
    end)

    -- Show non-blocking so we can update the preview live
    dlg:show { wait = false }

    -- If preview was on last session, apply it immediately on open
    if lastSettings.preview then
        applyPreview()
    end
end

-- ─── Standalone execution (when run via File > Scripts, not as extension) ────

if not _PRAMPREM_INIT then
    colorSwap()
end
