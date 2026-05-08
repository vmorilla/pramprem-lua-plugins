-- Court Texture Plugin for Aseprite
-- Applies noise dithering to a flat colour

-- ─── Noise pattern (return true = use dark pixel) ──────────────────────────
local function patternNoise(x, y, density)
  local n = math.sin(x * 127.1 + y * 311.7) * 43758.5453
  local frac = n - math.floor(n)
  return frac < density
end

-- ─── Colour helpers ────────────────────────────────────────────────────────

local function rgbToHsv(r, g, b)
  r, g, b = r / 255, g / 255, b / 255
  local max = math.max(r, g, b)
  local min = math.min(r, g, b)
  local d = max - min
  local h, s, v
  v = max
  s = (max == 0) and 0 or (d / max)
  if d == 0 then
    h = 0
  elseif max == r then
    h = ((g - b) / d) % 6
  elseif max == g then
    h = (b - r) / d + 2
  else
    h = (r - g) / d + 4
  end
  h = h * 60
  if h < 0 then h = h + 360 end
  return h, s, v
end

-- Circular hue distance (0..180)
local function hueDist(h1, h2)
  local d = math.abs(h1 - h2)
  return d > 180 and (360 - d) or d
end

-- Returns the closest darker palette color to `baseCol` with a similar hue,
-- or baseCol itself if none found
local function closestDarkerPaletteColor(baseCol)
  local sprite = app.sprite
  if not sprite then return baseCol end
  local palette = sprite.palettes[1]
  if not palette then return baseCol end

  local baseH, baseS, baseV = rgbToHsv(baseCol.red, baseCol.green, baseCol.blue)
  local bestScore = math.huge
  local bestColor = baseCol

  for i = 0, #palette - 1 do
    local pc = palette:getColor(i)
    if pc.alpha > 0 then
      local h, s, v = rgbToHsv(pc.red, pc.green, pc.blue)
      -- Must be darker
      if v < baseV then
        -- Hue distance (0..180), weighted heavily
        local hd = hueDist(baseH, h)
        -- Saturation distance
        local sd = math.abs(s - baseS)
        -- Value distance (prefer slightly darker, not extremely dark)
        local vd = math.abs(baseV - v)
        -- Score: hue matters most, then saturation, then value
        local score = hd * 4 + sd * 100 + vd * 50
        if score < bestScore then
          bestScore = score
          bestColor = Color { r = pc.red, g = pc.green, b = pc.blue, a = pc.alpha }
        end
      end
    end
  end

  return bestColor
end

-- ─── Main apply function ───────────────────────────────────────────────────
local function applyTexture(opts)
  local sprite = app.sprite
  if not sprite then
    app.alert("No active sprite!")
    return
  end

  local cel = app.activeCel
  if not cel then
    app.alert("No active cel/layer!")
    return
  end

  local image   = cel.image
  local baseCol = opts.baseColor
  local darkCol = opts.noiseColor
  local density = opts.density
  local patFn   = opts.patternFn

  local indexed = (sprite.colorMode == ColorMode.INDEXED)
  local palette = sprite.palettes[1]

  -- Find or add a palette index for a given Color (indexed mode only)
  local function findOrAddIndex(col)
    for i = 0, #palette - 1 do
      local pc = palette:getColor(i)
      if pc.red == col.red and pc.green == col.green and pc.blue == col.blue then
        return i
      end
    end
    -- Not found: append to palette
    local idx = #palette
    palette:resize(idx + 1)
    palette:setColor(idx, col)
    return idx
  end

  local darkIdx, baseIdx
  if indexed then
    darkIdx = findOrAddIndex(darkCol)
    baseIdx = findOrAddIndex(baseCol)
  end

  app.transaction(function()
    local matchCount = 0
    local totalCount = 0
    local sampleR, sampleG, sampleB, sampleA = 0, 0, 0, 0

    for y = 0, image.height - 1 do
      for x = 0, image.width - 1 do
        local px = image:getPixel(x, y)
        local pr, pg, pb, pa

        if indexed then
          local pc = palette:getColor(px)
          pr, pg, pb, pa = pc.red, pc.green, pc.blue, pc.alpha
        else
          pr = app.pixelColor.rgbaR(px)
          pg = app.pixelColor.rgbaG(px)
          pb = app.pixelColor.rgbaB(px)
          pa = app.pixelColor.rgbaA(px)
        end

        -- Capture first pixel for debug
        if totalCount == 0 then
          sampleR, sampleG, sampleB, sampleA = pr, pg, pb, pa
        end
        totalCount = totalCount + 1

        local dr = math.abs(pr - baseCol.red)
        local dg = math.abs(pg - baseCol.green)
        local db = math.abs(pb - baseCol.blue)

        if dr < 30 and dg < 30 and db < 30 and pa > 0 then
          matchCount = matchCount + 1
          local useDark = patFn(x, y, density)
          if indexed then
            image:drawPixel(x, y, useDark and darkIdx or baseIdx)
          else
            local col = useDark and darkCol or baseCol
            image:drawPixel(x, y, app.pixelColor.rgba(col.red, col.green, col.blue, pa))
          end
        end
      end
    end

    app.alert("Pixels scanned: " .. totalCount ..
      "\nMatched: " .. matchCount ..
      "\nFirst pixel RGBA: " .. sampleR .. "," .. sampleG .. "," .. sampleB .. "," .. sampleA ..
      "\nBase color RGB: " .. baseCol.red .. "," .. baseCol.green .. "," .. baseCol.blue)
  end)

  app.refresh()
end

-- ─── Dialog ────────────────────────────────────────────────────────────────
function showDialog()
  local sprite = app.sprite
  if not sprite then
    app.alert("Please open or create a sprite first.")
    return
  end

  local defaultBase = Color { r = 74, g = 124, b = 63 }
  local defaultNoise = closestDarkerPaletteColor(defaultBase)

  local dlg = Dialog("Noise Texture")

  dlg:label { text = "Base colour (flat fill to texture):" }
  dlg:color { id = "baseColor", color = defaultBase,
    onchange = function()
      dlg:modify { id = "noiseColor", color = closestDarkerPaletteColor(dlg.data.baseColor) }
    end
  }

  dlg:label { text = "Noise colour:" }
  dlg:color { id = "noiseColor", color = defaultNoise }

  dlg:separator { text = "Parameters" }
  dlg:slider { id = "density", label = "Density:", min = 1, max = 100, value = 35 }

  dlg:separator {}
  dlg:button { id = "apply", text = "Apply", onclick = function()
    applyTexture {
      baseColor  = dlg.data.baseColor,
      noiseColor = dlg.data.noiseColor,
      density    = dlg.data.density / 100.0,
      patternFn  = patternNoise,
    }
  end }
  dlg:button { id = "close", text = "Close", onclick = function() dlg:close() end }

  dlg:show { wait = false }
end

-- ─── Standalone execution (when run via File > Scripts, not as extension) ────

if not _PRAMPREM_INIT then
  showDialog()
end
