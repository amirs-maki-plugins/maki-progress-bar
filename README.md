# maki-progress-bar

Live progress bars for [maki](https://github.com/tontinton/maki), shown above
the input box separator and updated from inside `code_execution` polling
loops: load runs, backfills, installs, test suites that log running counts.

```
build   ████████░░░░░░░░░░  412/1000 requests  41%  2m03s
```

## Install

Declare it in your global `init.lua` (`~/.config/maki/init.lua`), then
restart maki and accept the install prompt:

```lua
maki.pack.add({
  { src = "https://github.com/amirs-maki-plugins/maki-progress-bar", version = "v1.0.0" },
})
```

Requires maki 0.5.3 or newer. Update with `/packupdate maki-progress-bar`.

## Use

Call the `progress_bar` tool once per polling-loop iteration with the counts
you just read. A fresh bar needs `value` and `total`; later calls pass only
what changed. Several bars run at once, one per `name`:

```python
await progress_bar(label='load-test', value=0, total=1000, note='requests')
for snap in poll():
    await progress_bar(value=snap.done)
```

Bars outlive each `code_execution` script and clear when the turn ends.

## Colors

`color` takes a name from a built-in swatch list (`red`, `cyan`, ...). On
maki builds that expose `maki.ui.get_theme_palette`, the running theme's
palette is offered first. The list (`swatches`) is bundled with this
package.
