//
// NielloUI native backend helpers.
//

#ifndef NUI_UTIL_H
#define NUI_UTIL_H

#include "gpu/graphite/dawn/DawnBackendContext.h"
#include "nui.h"

wgpu::Surface CreateDawnSurface(const wgpu::Instance& instance, const UiNativeHandles* handles);

skgpu::graphite::DawnBackendContext GetDawnContext();

#endif //NUI_UTIL_H
