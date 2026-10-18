//
// NielloUI native backend helpers.
//

#ifndef NUI_UTIL_H
#define NUI_UTIL_H

#include <SDL3/SDL.h>

#include "gpu/graphite/dawn/DawnBackendContext.h"

wgpu::Surface CreateDawnSurface(wgpu::Instance instance, SDL_Window* window);

skgpu::graphite::DawnBackendContext GetDawnContext();

#endif //NUI_UTIL_H
