-- progress_bar_spec: pure-logic cases for the progress_bar plugin.
-- Run with /spec. Everything here goes through the _test seam, so no bar
-- is ever painted and no window opened.

local pb = require("progress_bar")
local t = pb._test
local apply = t.apply
local state = t.current_state
local key = { session = "spec-session", task = "spec" }

local function fresh(input)
  t.apply({ session = "spec-session", task = "spec" }, { action = "clear" })
  return apply(key, input)
end

local cases = {}

cases.create_needs_value_and_total = function(check)
  check.eq(fresh({ value = 5 }), "a new bar needs both value and total")
  check.eq(fresh({ total = 10 }), "a new bar needs both value and total")
  check.eq(fresh({ value = 5, total = 10 }), nil)
end

cases.total_zero_rejected = function(check)
  check.eq(fresh({ value = 0, total = 0 }), "total must be > 0")
end

cases.value_above_total_rejected = function(check)
  check.eq(fresh({ value = 11, total = 10 }), "value (11) is greater than total (10)")
end

cases.negative_and_nonnumeric_rejected = function(check)
  check.eq(fresh({ value = -1, total = 10 }), "value must be a number >= 0")
  check.eq(fresh({ value = "x", total = 10 }), "value must be a number >= 0")
  check.eq(fresh({ value = 1, total = "y" }), "total must be a number >= 0")
end

cases.label_and_note_validation = function(check)
  check.eq(fresh({ value = 1, total = 2, label = "" }), "label must be a non-empty string")
  check.eq(fresh({ value = 1, total = 2, note = " " }), "note must be a non-empty string")
  check.eq(fresh({ value = 1, total = 2, label = " ok ", note = " req " }), nil)
  local st = state(key)
  check.eq(st.label, "ok")
  check.eq(st.note, "req")
end

cases.floats_round_to_counts = function(check)
  fresh({ value = 2.4, total = 10 })
  check.eq(state(key).value, 2)
  t.apply(key, { value = 2.6 })
  check.eq(state(key).value, 3)
end

cases.update_only_value_after_create = function(check)
  fresh({ value = 1, total = 4, label = "t", note = "n" })
  check.eq(apply(key, { value = 3 }), nil)
  local st = state(key)
  check.eq(st.value, 3)
  check.eq(st.total, 4)
  check.eq(st.label, "t")
  check.eq(st.note, "n")
end

cases.restart_resets_timeline_not_total = function(check)
  fresh({ value = 4, total = 10, note = "old" })
  local t0 = state(key).start_time
  apply(key, { value = 1 })
  local st = state(key)
  check.eq(st.value, 1)
  check.eq(st.total, 10)
  check.is(st.start_time >= t0, true, "restart bumps start_time")
  check.eq(st.note, nil, "restart drops a stale note")
end

cases.clear_drops_state = function(check)
  fresh({ value = 1, total = 2 })
  check.eq(apply(key, { action = "clear" }), nil)
  check.eq(state(key), nil)
  check.eq(apply(key, { value = 1 }), "a new bar needs both value and total")
end

cases.subagent_task_keying = function(check)
  local k2 = { session = "spec-session", task = "other" }
  t.apply(k2, { action = "clear" })
  fresh({ value = 1, total = 2 })
  check.eq(t.current_state(k2), nil, "a different task has no bar")
  check.eq(apply(k2, { value = 1, total = 3 }), nil)
  check.eq(t.current_state(k2).total, 3)
  check.eq(state(key).total, 2, "the original task is untouched")
end

cases.named_bars_are_independent = function(check)
  fresh({ value = 1, total = 10 })
  check.eq(apply(key, { name = "build", value = 2, total = 5 }), nil)
  check.eq(apply(key, { name = "check", value = 3, total = 6 }), nil)
  check.eq(apply(key, { name = "build", value = 4 }), nil)
  check.eq(state(key, "build").value, 4)
  check.eq(state(key, "build").total, 5)
  check.eq(state(key, "check").value, 3, "check bar untouched by build update")
  check.eq(state(key).value, 1, "unnamed bar untouched by named updates")
  local bars = t.bars_of(key)
  check.eq(#bars, 3, "three bars in the task")
  check.eq(bars[1].name, "", "creation order: unnamed first")
  check.eq(bars[2].name, "build")
  check.eq(bars[3].name, "check")
end

cases.new_named_bar_still_needs_value_and_total = function(check)
  fresh({ value = 1, total = 2 })
  check.eq(apply(key, { name = "x", value = 1 }), "a new bar needs both value and total")
  check.eq(apply(key, { name = "x", total = 2 }), "a new bar needs both value and total")
end

cases.name_validation = function(check)
  check.eq(fresh({ name = "  ", value = 1, total = 2 }), "name must be a non-empty string")
  check.eq(fresh({ name = " ok ", value = 1, total = 2 }), nil)
  check.eq(state(key, "ok").value, 1, "name is sanitized like label")
end

cases.clear_named_keeps_the_rest = function(check)
  fresh({ value = 1, total = 2 })
  apply(key, { name = "build", value = 1, total = 2 })
  apply(key, { name = "check", value = 1, total = 2 })
  check.eq(apply(key, { name = "build", action = "clear" }), nil)
  check.eq(state(key, "build"), nil)
  check.is(state(key, "check") ~= nil, true, "check survives")
  check.is(state(key) ~= nil, true, "unnamed survives")
  check.eq(#t.bars_of(key), 2)
  check.eq(apply(key, { action = "clear" }), nil)
  check.eq(t.bars_of(key), nil, "bare clear drops every bar")
  check.eq(apply(key, { value = 5 }), "a new bar needs both value and total")
end

cases.max_bars_enforced = function(check)
  fresh({ value = 1, total = 2 })
  for i = 1, t.MAX_BARS - 1 do
    check.eq(apply(key, { name = "bar" .. i, value = 0, total = 1 }), nil)
  end
  check.eq(#t.bars_of(key), t.MAX_BARS)
  check.eq(apply(key, { name = "one-too-many", value = 0, total = 1 }),
    "too many bars: at most " .. t.MAX_BARS .. " per task, clear one first")
  check.eq(apply(key, { name = "bar1", value = 1 }), nil, "updates still pass at the cap")
end

cases.percent_math = function(check)
  check.eq(t.percent({ value = 0, total = 4 }), 0)
  check.eq(t.percent({ value = 1, total = 3 }), 33)
  check.eq(t.percent({ value = 2, total = 3 }), 67)
  check.eq(t.percent({ value = 3, total = 3 }), 100)
  check.eq(t.percent(nil), 0)
  check.eq(t.percent({ value = 1 }), 0, "no total -> 0, no division by zero")
end

cases.sanitize_strips_control_and_space = function(check)
  check.eq(t.sanitize("  a b\t\n"), "a b")
  check.eq(t.sanitize(""), nil)
  check.eq(t.sanitize("   "), nil)
  check.eq(t.sanitize(42), nil)
end

cases.color_resolves_via_swatches = function(check)
  fresh({ value = 1, total = 2, color = "red" })
  local st = state(key)
  check.is(st.color ~= nil and st.color:match("^#%x%x%x%x%x%x$") ~= nil, true,
    "a swatch name stores its hex")
  fresh({ value = 1, total = 2, color = "not-a-swatch" })
  check.eq(state(key).color, nil, "a non-swatch falls back to no color")
end

cases.auto_color_only_beyond_the_first_bar = function(check)
  fresh({ value = 1, total = 2 })
  check.eq(state(key).color, nil, "a lone colorless bar keeps the default fill")
  check.eq(apply(key, { name = "second", value = 1, total = 2 }), nil)
  check.is(state(key, "second").color ~= nil, true,
    "the second colorless bar picks a swatch hex")
  fresh({ value = 1, total = 2, color = "not-a-swatch" })
  apply(key, { name = "second", value = 1, total = 2 })
  check.eq(state(key).color, nil, "an unresolvable requested color never auto-picks")
end

cases.auto_colors_are_distinct_per_task = function(check)
  fresh({ value = 1, total = 2 })
  for i = 1, 4 do
    apply(key, { name = "b" .. i, value = 1, total = 2 })
  end
  local seen = {}
  local bars = t.bars_of(key)
  check.eq(#bars, 5)
  for _, st in ipairs(bars) do
    if st.color then
      check.is(seen[st.color] ~= true, true, "no two bars share a color")
      seen[st.color] = true
    end
  end
  check.is(next(seen) ~= nil, true, "at least the later bars carry a color")
end

cases.auto_color_excludes_used_and_returns_nil_when_pool_empty = function(check)
  local bars = {}
  for i = 1, 3 do
    bars["taken" .. i] = { color = "#00000" .. i }
  end
  local pool_hexes = {}
  for _, sw in ipairs(require("swatches").swatch_list()) do
    pool_hexes[#pool_hexes + 1] = sw.hex
  end
  for _, hex in ipairs(pool_hexes) do
    bars["taken" .. hex] = { color = hex }
  end
  check.eq(t.auto_color(bars), nil, "every swatch used -> nil")
  check.is(t.auto_color(nil) ~= nil, true, "no other bars -> any swatch (never called, but safe)")
  local picked = t.auto_color({ x = { color = pool_hexes[1] } })
  check.is(picked ~= nil and picked ~= pool_hexes[1], true, "picks an unused hex")
end

cases.render_state_spans = function(check)
  local line = t.render_state({ value = 1, total = 2, label = "L", note = "N" }, os.time())
  check.is(type(line) == "table" and type(line[1]) == "table", true, "one line of spans")
  local text = ""
  for _, sp in ipairs(line[1]) do
    text = text .. sp[1]
  end
  check.has(text, "L", "label present")
  check.has(text, "1/2", "count present")
  check.has(text, "N", "note present")
  check.has(text, "50%", "percent present")
end

cases.columns_align_across_bars = function(check)
  local now = os.time()
  local a = { value = 5, total = 100, label = "build", note = "requests", start_time = now }
  local b = { value = 100, total = 100, label = "x", note = "f", start_time = now }
  local w = t.column_widths({ a, b }, now)
  check.eq(w.label, 5, "label column is the widest label")
  check.eq(w.count, #"100/100", "count column is the widest count")
  check.eq(w.note, 8, "note column is the widest note")
  local function width(st)
    local n = 0
    for _, sp in ipairs(t.render_state(st, now, w)[1]) do
      n = n + maki.ui.display_width(sp[1])
    end
    return n
  end
  check.eq(width(a), width(b), "every bar renders to the same width")
end

cases.new_bar_realigns_existing = function(check)
  local now = os.time()
  local a = { value = 1, total = 2, label = "a", start_time = now }
  local before = t.column_widths({ a }, now)
  local b = { value = 1, total = 2, label = "longer", start_time = now }
  local after = t.column_widths({ a, b }, now)
  check.eq(before.label, 1)
  check.eq(after.label, 6, "adding a bar widens the shared label column")
end

cases.auto_color_prefers_theme = function(check)
  local swatches = require("swatches")
  local themed, rest = {}, {}
  for _, sw in ipairs(swatches.swatch_list()) do
    if sw.theme then
      themed[sw.hex] = true
    else
      rest[#rest + 1] = sw.hex
    end
  end
  if next(themed) == nil then
    for _ = 1, 20 do
      check.is(t.auto_color({}) ~= nil, true, "no theme palette -> canonical swatches")
    end
    return
  end
  for _ = 1, 50 do
    check.is(themed[t.auto_color({})], true, "theme color while one is unused")
  end
  local bars = {}
  for hex in pairs(themed) do
    bars[#bars + 1] = { color = hex }
  end
  for _ = 1, 50 do
    local picked = t.auto_color(bars)
    check.is(picked == nil or not themed[picked], true, "non-theme swatch once the theme colors are used")
  end
end

return { cases = cases, name = "progress_bar" }
