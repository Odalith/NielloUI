# API reference

One page per package, generated from the documentation comments in the
source. Every page starts with the package's overview and an index, then
lists its types, procedures, constants and variables. Each declaration is
shown as written, with the names it uses linked, and a link to its source
line.

| Package | Import | What it is |
|---|---|---|
| [niello](reference/niello.md) | `import niello "niello:."` | The core: units, declaring, layout, input, animation, groups. No OS code. |
| [niello/sdl](reference/sdl.md) | `import niello_sdl "niello:sdl"` | The desktop host: windows, the event loop, rendering through the native backend. |
| [niello/controls](reference/controls.md) | `import controls "niello:controls"` | The shipped controls, with theme, type and spacing roles. |
| [niello/virtual](reference/virtual.md) | `import virtual "niello:virtual"` | Virtual lists: fixed and estimated row heights. |
| [niello/inbox](reference/inbox.md) | `import inbox "niello:inbox"` | One queue for results from worker threads. |
| [niello/debugui](reference/debugui.md) | `import debugui "niello:debugui"` | The debugger window (debug builds). |

The packages other than `niello` are optional, and each is built on the
core's public API only.
