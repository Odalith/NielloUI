# niello/sdl

SDL3 app glue + FFI bindings to the native render backend (`nui_*`, see
`skiasdl/nui.h`).

`ffi.odin` declares the whole C surface and pins the ABI: `niello.Draw_Cmd`
must stay exactly 64 bytes or the compile fails. The backend replays those
commands onto a Skia Graphite canvas.

Linking needs the prebuilt backend for your platform —
`tools/fetch-native.sh`, then build with
`-extra-linker-flags:"-Lthird_party/native/<platform>/lib"`.
