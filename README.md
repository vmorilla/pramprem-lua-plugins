# Pramprem Lua Plugins

A collection of Aseprite Lua plugins by Pramprem.

## Plugins

### Color Swap

Replaces a family of colors in the active sprite with a target color, preserving relative brightness and saturation variations.

**Features:**
- Reference color picker with HSV-based tolerance sliders (hue, saturation, value)
- Live preview (non-destructive until you click Apply)
- "Add source color" button to auto-expand tolerances to cover an extra sample color
- Full undo support
- Session-persistent settings

**Usage:** Edit → Pramprem → Color Swap...

### Noise Texture

Applies a noise dithering pattern to a flat color in the active cel. Works with both RGB and Indexed sprites.

**Features:**
- Configurable base color and noise color (auto-suggests a darker palette color)
- Adjustable noise density

**Usage:** Edit → Pramprem → Noise Texture...

---

## Installation

### As an Aseprite extension (recommended)

1. Build the extension:
   ```sh
   make
   ```
   This produces `pramprem.aseprite-extension`.

2. In Aseprite, go to **Edit → Preferences → Extensions** and drag the `.aseprite-extension` file onto the window, or double-click the file.

3. Both commands will appear under **Edit → Pramprem** in the menu.

### As standalone scripts

Each `.lua` file can also be run directly via **File → Scripts** in Aseprite:

- `color-swap.lua` — opens the Color Swap dialog immediately
- `noise-texture.lua` — opens the Noise Texture dialog immediately

---

## Project Structure

```
pramprem-lua-plugins/
├── README.md
├── Makefile
├── package.json          # Extension manifest
├── pramprem.lua          # Extension entry point (registers the Pramprem menu)
├── color-swap.lua        # Color Swap plugin logic
└── noise-texture.lua     # Noise Texture plugin logic
```

## Building

Requires `zip` (standard on macOS/Linux).

```sh
make        # builds pramprem.aseprite-extension
make clean  # removes the built extension
```
