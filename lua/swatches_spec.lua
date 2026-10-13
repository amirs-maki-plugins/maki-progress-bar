-- swatches_spec: cases for the shared swatch module.
-- Run with /spec.

local swatches = require("swatches")

local cases = {}

cases.resolve_known_names = function(check)
  for _, name in ipairs({ "red", "cyan", "blue", "green", "slate" }) do
    local hex = swatches.resolve(name)
    check.is(hex ~= nil, true, name .. " resolves")
    check.is(hex:match("^#%x%x%x%x%x%x$") ~= nil, true, name .. " answers #rrggbb")
  end
end

cases.resolve_merged_label_alias = function(check)
  -- gruvbox maps purple and pink to the same hex, so on that theme the
  -- merged row is "pink/purple": both names must resolve. On upstream
  -- builds (no palette API) the SWATCHES carry the names separately, and
  -- each still resolves. Either way both names answer a hex.
  local p = swatches.resolve("purple")
  local k = swatches.resolve("pink")
  check.is(p ~= nil, true, "purple resolves")
  check.is(k ~= nil, true, "pink resolves")
end

cases.resolve_rejects_garbage = function(check)
  check.eq(swatches.resolve(""), nil)
  check.eq(swatches.resolve("mauve"), nil)
  check.eq(swatches.resolve(nil), nil)
  check.eq(swatches.resolve(7), nil)
end

cases.hex_is_never_an_input = function(check)
  check.eq(swatches.resolve("#ff0000"), nil, "hex input is not a swatch name")
end

cases.swatch_list_shape = function(check)
  local list = swatches.swatch_list()
  check.is(#list > 0, true, "the list is not empty")
  local seen = {}
  for _, sw in ipairs(list) do
    check.is(type(sw.label) == "string", true, "row has a label")
    check.is(sw.hex:match("^#%x%x%x%x%x%x$") ~= nil, true, "row has #rrggbb: " .. tostring(sw.label))
    check.eq(seen[sw.hex], nil, "no duplicate hex rows: " .. sw.hex)
    seen[sw.hex] = true
  end
end

cases.every_list_name_resolves = function(check)
  for _, sw in ipairs(swatches.swatch_list()) do
    for part in sw.label:gmatch("[^/]+") do
      check.eq(swatches.resolve(part), sw.hex, "label part resolves: " .. part)
    end
  end
end

return { cases = cases, name = "swatches" }
