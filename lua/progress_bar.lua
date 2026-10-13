-- progress_bar: live status bars above the input box separator that a
-- long-running script can update from inside code_execution.
--
-- Layout (one line per bar):
--   build   ████████░░░░░░░░░░  412/1000 requests  41%  2m03s
--   check   ██░░░░░░░░░░░░░░░░   18/200   files    9%  0m41s
--
-- In code_execution:
--   await progress_bar(label='build', value=0, total=1000, note='requests')
--   await progress_bar(value=650)                        -- unnamed bar
--   await progress_bar(name='check', value=18, total=200) -- a second bar
--   await progress_bar(name='check', value=200)          -- update it
--   await progress_bar(action='clear')                   -- every bar
--   await progress_bar(name='check', action='clear')     -- one bar
--
-- The bars outlive the script: state persists across code_execution runs in
-- the same turn, so a later script resumes a bar with `value` alone. The
-- turn's end is the destructor — it clears every bar the turn left, so the
-- agent must keep polling inside the turn while the user watches the bars.
--
-- The Lua side holds state only. Every call goes through the same apply()
-- path, so repeated calls with the same value are cheap and a script
-- restart (a value that went backwards) resets the timeline, not grows it.

local PLUGIN = "progress_bar"
local FILL, EMPTY = "█", "░"
local MAIN_TASK = "main"
local DEFAULT_NAME = ""
local MAX_BARS = 6
local DEFAULT_COLOR = "todo_in_progress"
local swatches = require("swatches")

-- A color is a name from the shared swatch list (the same colors /color
-- offers). resolve() answers the hex, so the bar never depends on the
-- theme resolving the name — it works on upstream maki too. A name the
-- list does not offer falls back to the theme's in-progress style, with a
-- note in the tool reply rather than an error.
local function to_color(v)
  return swatches.resolve(v)
end

-- A random swatch hex no other bar of the task uses, taken from the theme
-- colors first and from the rest of the swatches once those are all used, for a bar created
-- without a color while other bars are already on screen. Nil when every
-- swatch is taken: the bar falls back to the default fill.
local function auto_color(task_bars)
  local used = {}
  for _, other in pairs(task_bars or {}) do
    if other.color then
      used[other.color] = true
    end
  end
  local themed, rest = {}, {}
  for _, sw in ipairs(swatches.swatch_list()) do
    if not used[sw.hex] then
      local group = sw.theme and themed or rest
      group[#group + 1] = sw.hex
    end
  end
  local pool = #themed > 0 and themed or rest
  if #pool == 0 then
    return nil
  end
  return pool[math.random(#pool)]
end

-- [session_id][task_id] = { [bar_name] = state, ... }. A subagent shares
-- its session id with the parent, only the task id tells them apart (same
-- keying as todo_write). Within a task, the bar name tells bars apart; the
-- unnamed bar keeps the old single-bar call shape working.
local states = {}
local focused = { session = "", task = MAIN_TASK }
-- The task last updated in the focused session, shown while the user
-- watches a chat whose own bars are idle (a subagent running the test).
local fallback = {}
local buf, win
local seq = 0

local function sanitize(s)
  if type(s) ~= "string" then
    return nil
  end
  s = s:gsub("%c", ""):gsub("^%s+", ""):gsub("%s+$", "")
  return s ~= "" and s or nil
end

local function to_count(v)
  local n = tonumber(v)
  if n and n >= 0 and n <= 1e15 then
    return math.floor(n + 0.5)
  end
  return nil
end

-- The states of one task's bars, in creation order.
local function bars_of(key)
  local task_bars = states[key.session] and states[key.session][key.task]
  if not task_bars then
    return nil
  end
  local list = {}
  for _, st in pairs(task_bars) do
    list[#list + 1] = st
  end
  if #list == 0 then
    return nil
  end
  table.sort(list, function(a, b)
    return a.seq < b.seq
  end)
  return list
end

local function dw(s)
  return maki.ui.display_width(s)
end

-- The text of each column for one state; nil when the state has none.
local function columns(st, now)
  local value = st.value or 0
  local total = st.total or value
  local ratio = total > 0 and math.min(value / total, 1) or 0
  return {
    label = sanitize(st.label),
    count = value .. "/" .. total,
    note = sanitize(st.note),
    pct = math.floor(ratio * 100 + 0.5) .. "%",
    time = st.start_time and maki.ui.humantime(math.max(now - st.start_time, 0)) or nil,
  }
end

-- Widest cell of each column across a set of states. Bars share these, so
-- every column lines up and a new bar re-aligns the rest on the next render.
local function column_widths(list, now)
  local w = { label = 0, count = 0, note = 0, pct = 0, time = 0 }
  for _, st in ipairs(list) do
    for key, text in pairs(columns(st, now)) do
      w[key] = math.max(w[key], dw(text))
    end
  end
  return w
end

-- Fixed width around the bar cells: label, count, note, pct, time, plus the
-- gaps between them. `w` is the shared column widths (own widths if nil).
local function fixed_width(st, now, w)
  w = w or column_widths({ st }, now)
  local n = 0
  if w.label > 0 then
    n = n + w.label + 2
  end
  n = n + 1 + w.count
  if w.note > 0 then
    n = n + 1 + w.note
  end
  n = n + 1 + w.pct
  if w.time > 0 then
    n = n + 2 + w.time
  end
  return n
end

local function pad_right(text, width)
  return text .. string.rep(" ", width - dw(text))
end

local function pad_left(text, width)
  return string.rep(" ", width - dw(text)) .. text
end

-- `wait` without `stalled`: the bar repaints on every call, and a script
-- that polls pushes a call per iteration, so no timer is needed on the Lua
-- side to keep it current. `w` is the shared column widths from render();
-- without it the bar aligns to itself.
local function render_state(st, now, w)
  local value = st.value or 0
  local total = st.total or value
  local ratio = total > 0 and math.min(value / total, 1) or 0

  local c = columns(st, now)
  w = w or column_widths({ st }, now)
  local cols = maki.ui.terminal_size().cols
  local width = math.max(math.min(cols - fixed_width(st, now, w), math.floor(cols / 2)), 10)
  local filled = math.floor(ratio * width + 0.5)

  local spans = {}
  if w.label > 0 then
    spans[#spans + 1] = { pad_right(c.label or "", w.label), "bold" }
    spans[#spans + 1] = { "  ", {} }
  end
  local fill_style = st.color and { fg = st.color } or DEFAULT_COLOR
  spans[#spans + 1] = { string.rep(FILL, filled), fill_style }
  if width - filled > 0 then
    spans[#spans + 1] = { string.rep(EMPTY, width - filled), "dim" }
  end
  spans[#spans + 1] = { " " .. pad_left(c.count, w.count), "bold" }
  if w.note > 0 then
    spans[#spans + 1] = { " " .. pad_right(c.note or "", w.note), "dim" }
  end
  spans[#spans + 1] = { " " .. pad_left(c.pct, w.pct), "dim" }
  if w.time > 0 then
    spans[#spans + 1] = { "  " .. pad_left(c.time or "", w.time), "dim" }
  end
  return { spans }
end

-- Rebuilt from the focused states (fallback included) on every change: one
-- line per bar, in creation order, all bars at the same width so the
-- columns line up. set_lines repaints the panel through its waker,
-- set_config rows it to the line count.
local function render()
  local sid = focused.session
  local list = bars_of(focused)
  if not list then
    local fb = fallback[sid]
    if fb then
      list = bars_of({ session = sid, task = fb.task })
    end
  end
  if not list then
    if win and win:is_open() then
      win:hide()
    end
    return
  end

  if not (buf and win and win:is_open()) then
    buf = maki.ui.buf({ scratch = true })
    -- A panel row sits directly above the queue panel and the input box
    -- separator, and the layout engine keeps it there as the box grows,
    -- which a fixed SW float cannot.
    win = maki.ui.open_win(buf, {
      split = "panel",
      height = 1,
      order = 20,
      border = "none",
      focus = false,
      visible = false,
    })
  end

  local now = os.time()
  local widths = column_widths(list, now)
  local lines = {}
  for i, st in ipairs(list) do
    lines[i] = render_state(st, now, widths)[1]
  end
  buf:set_lines(lines)
  win:set_config({ height = #lines })
  win:show()
end

local function sync()
  local ok, err = pcall(render)
  if not ok then
    maki.log.error(PLUGIN .. ": render failed: " .. tostring(err))
  end
end

local function current_state(key, name)
  name = name or DEFAULT_NAME
  local task_bars = states[key.session] and states[key.session][key.task]
  return task_bars and task_bars[name] or nil
end

local function clear_state(key, name)
  local task_bars = states[key.session] and states[key.session][key.task]
  if not task_bars then
    return
  end
  if name then
    task_bars[name] = nil
  else
    states[key.session][key.task] = nil
  end
  local fb = fallback[key.session]
  if fb and fb.task == key.task and not bars_of(key) then
    -- The fallback only dies with the last bar of its task: another bar
    -- left in it still wants the screen.
    fallback[key.session] = nil
  end
end

-- One path for every caller (handler, restore, forward). Returns an error
-- string or nil.
local function apply(key, input)
  if type(input) ~= "table" then
    return "input must be a table"
  end

  local action = sanitize(input.action)
  local name = sanitize(input.name)
  if input.name ~= nil and not name then
    return "name must be a non-empty string"
  end
  name = name or DEFAULT_NAME
  if action == "clear" or action == "hide" then
    -- A named clear drops one bar; a bare clear drops every bar the task
    -- owns, so the common end-of-work call needs no bookkeeping.
    clear_state(key, name ~= DEFAULT_NAME and name or nil)
    return nil
  end
  if action and action ~= "update" and action ~= "set" and action ~= "new" then
    return "unknown action '" .. action .. "'"
  end

  local label = sanitize(input.label)
  if input.label ~= nil and not label then
    return "label must be a non-empty string"
  end
  local note = sanitize(input.note)
  if input.note ~= nil and not note then
    return "note must be a non-empty string"
  end
  local color = to_color(input.color)
  local total = to_count(input.total)
  if input.total ~= nil and not total then
    return "total must be a number >= 0"
  end
  if total == 0 then
    return "total must be > 0"
  end
  local value = to_count(input.value)
  if input.value ~= nil and not value then
    return "value must be a number >= 0"
  end
  if value and total and value > total then
    return "value (" .. value .. ") is greater than total (" .. total .. ")"
  end

  local st = current_state(key, name)
  if not st and (value == nil or total == nil) then
    return "a new bar needs both value and total"
  end
  -- A value that went backwards is a new run over a bar left mid-way (a
  -- restarted script, a second pass): reset the timeline it measures.
  local restart = st and value ~= nil and value < (st.value or 0)

  if not st then
    local task_bars = states[key.session] and states[key.session][key.task]
    local n = 0
    for _ in pairs(task_bars or {}) do
      n = n + 1
    end
    if n >= MAX_BARS then
      return "too many bars: at most " .. MAX_BARS .. " per task, clear one first"
    end
    seq = seq + 1
    st = { name = name, seq = seq, value = 0, total = total, start_time = os.time() }
    -- A bar beyond the first that asked for no color takes a random unused
    -- swatch, so a stack of default bars stays readable. A requested color
    -- that did not resolve does not trigger a pick — it keeps the plain
    -- fallback and its reply note.
    if input.color == nil and n > 0 then
      st.color = auto_color(task_bars)
    end
    states[key.session] = states[key.session] or {}
    states[key.session][key.task] = states[key.session][key.task] or {}
    states[key.session][key.task][name] = st
  end
  fallback[key.session] = { task = key.task }
  if restart then
    st.start_time = os.time()
    st.note = nil
  end
  if total then
    st.total = total
  end
  if value then
    st.value = value
  end
  if label then
    st.label = label
  end
  if note then
    st.note = note
  end
  if color then
    st.color = color
  end
  return nil
end

-- Percent for the tool reply. Computed from the stored state so a call that
-- only updates the label still reports where the bar stands.
local function percent(st)
  if not st or not st.total or st.total == 0 then
    return 0
  end
  return math.floor((st.value or 0) / st.total * 100 + 0.5)
end

local function key_of(ctx)
  return { session = ctx:session_id() or "", task = ctx:task_id() or MAIN_TASK }
end

local DESCRIPTION = [[Update live progress bars shown above the input box separator.

Use them for long-running work you poll in a loop, typically inside code_execution: a test whose snapshots log how many requests went through, a load run, a backfill, an install. Call once per loop iteration with the counts you just read.

Example — one bar for a whole turn, fresh once, then updates only:

    # first call of the turn: a fresh bar needs value AND total
    await progress_bar(label='load-test', value=0, total=1000, note='requests')
    for snap in poll():                          # a real loop, spaced by waits
        await progress_bar(value=snap.done)      # later calls: only what changed
    # a later code_execution script in the same turn resumes the same bar:
    await progress_bar(value=650)

Several bars at once (parallel work; one line each, stacked in creation order):

    await progress_bar(name='build', label='build', value=0, total=500)
    await progress_bar(name='check', label='check', value=0, total=200)
    await progress_bar(name='build', value=412)   # updates the build bar only

Rules:
- A fresh bar needs `value` and `total` together. On later calls pass only what changed.
- `name` identifies a bar: the same name updates the same bar, a new name opens another (at most 6 per task). Omit it for the unnamed default bar — the shape of every single-bar example above. A named bar is only ever touched by calls that repeat its `name`.
- The bars outlive the script: they stay on screen after code_execution ends and their state persists, so the next script in the same turn resumes them with `value` alone (plus `name` for a named bar). Keep updating them while work continues across scripts. Do not re-send `value` and `total` to resume: a value below a bar's current count reads as a restarted run and resets its elapsed time and note.
- The turn's end clears every bar automatically, so ending your turn (sending a final reply) removes the bars even though the work is still running. If the user wants to watch the bars, do not end the turn: keep polling with consecutive code_execution calls (each loop at most a few minutes, a bash sleep between rounds) until the work is done, then reply. A bar cleared this way needs value and total again on its next call. Within a turn, `action='clear'` removes bars early: with `name`, that one bar; without, every bar the task owns. A finished bar left at 100% is also fine.
- The bars are visible to the user immediately. Do NOT call more often than your polling loop already runs, and make sure the loop actually waits between iterations — calls from a delay-free loop churn the bar for nothing.
- `color` sets the fill color: a name from the shared swatch list (the same names /color offers, e.g. 'red', 'cyan'; hex is not accepted). A name not in the list falls back to the theme's in-progress style. A bar created without a color while other bars exist picks a random unused theme color first, then a random unused swatch from the rest, so a stack of bars stays distinguishable.
- Panel stacking verified: the bars (order=20) sit below the todo panel (order=10), both above the input separator.
- `todo_write` has no "interpreter" audience, so scripts cannot update todos — only the bars. Todo updates happen as direct calls between scripts.

In code_execution call it as an async function, e.g. `await progress_bar(label='t', value=n, total=100)`.]]

local SCHEMA = {
  type = "object",
  additionalProperties = false,
  properties = {
    name = {
      type = "string",
      description = "Bar id: the same name updates the same bar, a new name opens another bar (max 6 per task). Omit for the unnamed default bar.",
    },
    label = { type = "string", description = "Short name shown before the bar. Optional after the first call." },
    value = { type = "integer", description = "Current count, 0..total. A value below the bar's current count restarts the run: elapsed time and note reset." },
    total = { type = "integer", description = "Count at completion, > 0." },
    note = { type = "string", description = "Short text after the count, e.g. 'requests'. Optional." },
    color = {
      type = "string",
      description = "Fill color: a name from the shared swatch list (same as the /color picker, e.g. 'red', 'cyan'; no hex). Falls back to the theme in-progress style when the name is not a swatch. Omitted on a bar beyond the first: a random unused theme color is picked first, then a random unused swatch.",
    },
    action = {
      type = "string",
      enum = { "clear" },
      description = "'clear' removes the bar: the one named by `name`, or every bar this task owns when `name` is omitted.",
    },
  },
}

maki.api.register_tool({
  name = "progress_bar",
  description = DESCRIPTION,
  schema = SCHEMA,
  kind = "status",
  audiences = { "main", "research_sub", "general_sub", "interpreter" },

  header = function(input)
    input = input or {}
    local prefix = input.name and input.name .. " " or ""
    if input.action == "clear" then
      return prefix .. "clear"
    end
    if input.value ~= nil and input.total ~= nil then
      return prefix .. tostring(input.value) .. "/" .. tostring(input.total)
    end
    return prefix .. "update"
  end,

  handler = function(input, ctx)
    local key = key_of(ctx)
    local err = apply(key, input)
    if err then
      return { llm_output = "error: " .. err, is_error = true }
    end
    -- Before the early return: a clear must repaint (hide) too, or the bars
    -- keep their last frame until the turn ends.
    if key.session == focused.session then
      sync()
    end
    local name = sanitize(type(input) == "table" and input.name or nil) or DEFAULT_NAME
    local st = current_state(key, name)
    if not st then
      local remaining = bars_of(key)
      return remaining and ("bar cleared (" .. #remaining .. " left)") or "bar cleared"
    end
    local tag = name ~= DEFAULT_NAME and "'" .. name .. "': " or ""
    -- A requested color that did not stick (not a swatch name) is reported,
    -- not raised: the bar still renders with the default fill.
    local fallback_note = ""
    if type(input) == "table" and input.color ~= nil and st.color ~= to_color(input.color) then
      fallback_note = " (color '" .. tostring(input.color) .. "' not in the swatch list, using default)"
    end
    return tag .. string.format("%d/%d (%d%%)%s", st.value or 0, st.total or 0, percent(st), fallback_note)
  end,

  -- No restore hook on purpose: the bar is turn-scoped state. A session
  -- load or a transcript click replaying old calls would resurrect a bar
  -- from a dead turn with no TurnEnd left to clear it.
})

maki.api.create_autocmd("TurnStart", {
  callback = function(ev)
    -- A session that loads mid-turn (reload during a run) gets no TurnEnd
    -- for the turn that was live before it, so drop anything a restored
    -- state table left behind when the next turn starts.
    if states[ev.data.session_id] then
      states[ev.data.session_id], fallback[ev.data.session_id] = nil, nil
    end
  end,
})

-- Subagents run inside the parent's turn, so its end clears their bars too.
maki.api.create_autocmd({ "TurnEnd", "SessionReset", "SessionEnd" }, {
  callback = function(ev)
    local sid = ev.data and ev.data.session_id or ""
    if states[sid] or fallback[sid] then
      states[sid], fallback[sid] = nil, nil
    end
    if sid == focused.session then
      sync()
    end
  end,
})

-- Fires on a session switch too, so this is the one focus event the bar
-- needs to follow. Startup fires it for the focused session as well.
maki.api.create_autocmd("TaskFocusChanged", {
  callback = function(ev)
    focused = { session = ev.data.session_id, task = ev.data.id or MAIN_TASK }
    sync()
  end,
})

-- Test seam: the pure internals, for progress_bar_spec (run via /spec).
-- apply mutates the module-local state tables, so specs key their cases
-- with throwaway session ids.
return {
  _test = {
    apply = apply,
    current_state = current_state,
    bars_of = bars_of,
    MAX_BARS = MAX_BARS,
    sanitize = sanitize,
    to_count = to_count,
    auto_color = auto_color,
    percent = percent,
    render_state = render_state,
    fixed_width = fixed_width,
    column_widths = column_widths,
  },
}
