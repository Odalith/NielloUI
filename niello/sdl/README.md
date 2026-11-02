# niello/sdl

SDL3 app glue + FFI bindings to the native render backend (`nui_*`, see
`../../native/nui.h`).

`ffi.odin` declares the whole C surface and pins the ABI: `niello.Draw_Cmd`
must stay exactly 96 bytes or the compile fails. The backend replays those
commands onto a Skia Graphite canvas.

Linking needs the prebuilt backend for your platform —
`tools/fetch-native.sh` fetches it, and `ffi.odin` names the fat archive
by path, so a plain `odin run` links with no extra flags.
