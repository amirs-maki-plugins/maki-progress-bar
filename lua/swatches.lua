-- swatches: the shared color list plugins offer for user-facing color
-- picks — the /color picker in session_bar and the progress_bar tool's
-- `color` option. One list, so both always offer the same colors.
--
-- The list is the canonical SWATCHES below; the running theme's palette
-- (maki.ui.get_theme_palette) is layered on top when the build has it —
-- it is an unmerged feature, so on upstream maki the SWATCHES alone are
-- the list. Entries that share one hex merge into one row labeled with
-- every name. resolve() maps any name — merged labels included — to its
-- hex, so a caller paints with the hex directly and never depends on the
-- theme resolving the name.

local SWATCHES = {
  { name = "blue",    default = "#1e6bb8" },
  { name = "cyan",    default = "#0e7490" },
  { name = "teal",    default = "#0f766e" },
  { name = "green",   default = "#15803d" },
  { name = "yellow",  default = "#a16207" },
  { name = "orange",  default = "#c2410c" },
  { name = "red",     default = "#b91c1c" },
  { name = "pink",    default = "#ec4899" },
  { name = "purple",  default = "#7c3aed" },
  { name = "violet",  default = "#8b5cf6" },
  { name = "magenta", default = "#a21caf" },
  { name = "sky",     default = "#0ea5e9" },
  { name = "slate",   default = "#334155" },
}

-- Palette entries that are UI roles, not colors a user picks: maki paints
-- backgrounds and selection bars from them, and they would only clutter a
-- picker.
local HIDDEN_PALETTE_NAMES = {
  background = true,
  background_2 = true,
  foreground = true,
  current_line = true,
  selection = true,
  highlight_high = true,
  highlight_med = true,
  highlight_low = true,
  comment = true,
  comment_lighter = true,
  mode_build = true,
  mode_plan = true,
  mode_bash = true,
}

local function hidden_name(name)
  return HIDDEN_PALETTE_NAMES[name] or name:match("^comment")
end

-- The merged list, theme colors first (alphabetical), then the canonical
-- SWATCHES for names the theme does not name. Entries that share one hex
-- merge into a single row labeled with every name, so the same color never
-- shows twice.
local function swatch_list()
  local pal = maki.ui.get_theme_palette and maki.ui.get_theme_palette() or {}
  local raw = {}
  local themed = {}
  for name, hex in pairs(pal) do
    if not hidden_name(name)
      and type(hex) == "string"
      and hex:match("^#%x%x%x%x%x%x$")
    then
      themed[#themed + 1] = name
    end
  end
  table.sort(themed)
  for _, name in ipairs(themed) do
    raw[#raw + 1] = { name = name, hex = pal[name], theme = true }
  end
  local themed_set = {}
  for _, name in ipairs(themed) do
    themed_set[name] = true
  end
  for _, sw in ipairs(SWATCHES) do
    if not themed_set[sw.name] then
      raw[#raw + 1] = { name = sw.name, hex = sw.default }
    end
  end

  local list, by_hex = {}, {}
  for _, sw in ipairs(raw) do
    local entry = by_hex[sw.hex]
    if entry then
      entry.label = entry.label .. "/" .. sw.name
    else
      entry = { label = sw.name, hex = sw.hex, theme = sw.theme or false }
      by_hex[sw.hex] = entry
      list[#list + 1] = entry
    end
  end
  return list
end

-- Name to hex: any name a swatch_list row carries, merged labels included
-- ("magenta" matches "violet/magenta"). Nil for a name the list does not
-- offer. Hex is never an input — callers paint with the hex this returns.
local function resolve(name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  for _, sw in ipairs(swatch_list()) do
    for part in sw.label:gmatch("[^/]+") do
      if part == name then
        return sw.hex
      end
    end
  end
  return nil
end

return {
  swatch_list = swatch_list,
  resolve = resolve,
}
