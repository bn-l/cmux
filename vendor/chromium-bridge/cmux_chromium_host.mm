// cmux Chromium host process.
//
// This is a thin wrapper around Content Shell that:
// 1. Starts Chromium's browser process
// 2. Listens on a Unix socket for commands from cmux
// 3. Creates WebContents and sends back the NSView pointer
//    (for in-process embedding via shared memory/mach port)
//
// For the MVP, this runs IN-PROCESS with cmux (loaded as a dylib).
// The Atlas/OWL approach runs it out-of-process for crash isolation,
// but in-process is simpler for the first version.

#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#include <stdio.h>
#include "chromium_bridge.h"

// Function pointer to ContentMain from the framework
typedef int (*ContentMainFn)(int argc, char** argv);

// Global state
static bool g_initialized = false;
static void* g_framework_handle = nullptr;

// Forward declarations for content API types we use
// These are defined in Chromium headers but we forward-declare
// to avoid including the full Chromium header tree.
namespace content {
class WebContents;
class BrowserContext;
}

// Stub implementations - to be replaced with real Chromium calls
// once we build our bridge against the Chromium headers.

int chromium_initialize(const char* framework_path,
                        const char* helper_path,
                        const char* cache_root) {
    if (g_initialized) return CHROMIUM_OK;
    if (!framework_path) return CHROMIUM_ERR_INVALID;

    // Load the Content Shell Framework
    NSString* fwPath = [NSString stringWithUTF8String:framework_path];
    NSString* fullPath = [fwPath stringByAppendingPathComponent:
        @"Content Shell Framework.framework/Content Shell Framework"];

    fprintf(stderr, "[Chromium] Loading framework: %s\n", [fullPath UTF8String]);
    fflush(stderr);

    g_framework_handle = dlopen([fullPath UTF8String], RTLD_NOW | RTLD_GLOBAL);
    if (!g_framework_handle) {
        fprintf(stderr, "[Chromium] dlopen failed: %s\n", dlerror());
        return CHROMIUM_ERR_FAILED;
    }

    // Find ContentMain
    ContentMainFn contentMain = (ContentMainFn)dlsym(g_framework_handle, "ContentMain");
    if (!contentMain) {
        fprintf(stderr, "[Chromium] ContentMain not found: %s\n", dlerror());
        return CHROMIUM_ERR_FAILED;
    }

    fprintf(stderr, "[Chromium] Framework loaded, ContentMain=%p\n", contentMain);
    fflush(stderr);

    // TODO: Initialize the browser process without blocking.
    // ContentMain takes over the main thread's run loop.
    // For in-process embedding, we need to use the content API
    // directly instead of ContentMain.
    //
    // The approach:
    // 1. Call ContentMainRunner::Create() + Initialize() + Run()
    //    on a background thread
    // 2. Or use BrowserMainRunner directly
    // 3. Create WebContents via content::WebContents::Create()
    //
    // For now, mark as initialized and return.
    // The actual initialization will be done when we build
    // against Chromium's content API headers.

    g_initialized = true;
    return CHROMIUM_OK;
}

void chromium_do_message_loop_work(void) {
    // TODO: pump Chromium's message loop
}

void chromium_shutdown(void) {
    if (g_framework_handle) {
        // Don't dlclose - Chromium doesn't support being unloaded
        g_framework_handle = nullptr;
    }
    g_initialized = false;
}

bool chromium_is_initialized(void) {
    return g_initialized;
}

// Browser stubs - will be implemented against content API
chromium_browser_t chromium_browser_create(
    const char* url, int w, int h,
    const chromium_client_callbacks* cbs) {
    if (!g_initialized) return nullptr;
    // TODO: Create WebContents, get NSView, return handle
    fprintf(stderr, "[Chromium] CreateBrowser %dx%d url=%s (stub)\n", w, h, url);
    return nullptr;
}

void chromium_browser_destroy(chromium_browser_t b) {}
int chromium_browser_load_url(chromium_browser_t b, const char* u) { return CHROMIUM_ERR_NOT_INIT; }
int chromium_browser_go_back(chromium_browser_t b) { return CHROMIUM_ERR_NOT_INIT; }
int chromium_browser_go_forward(chromium_browser_t b) { return CHROMIUM_ERR_NOT_INIT; }
int chromium_browser_reload(chromium_browser_t b) { return CHROMIUM_ERR_NOT_INIT; }
int chromium_browser_stop(chromium_browser_t b) { return CHROMIUM_ERR_NOT_INIT; }
void chromium_browser_resize(chromium_browser_t b, int w, int h) {}
void chromium_browser_set_visible(chromium_browser_t b, bool v) {}

void chromium_browser_send_mouse_click(chromium_browser_t b, int x, int y,
    int btn, bool up, int cc, uint32_t m) {}
void chromium_browser_send_mouse_move(chromium_browser_t b, int x, int y, uint32_t m) {}
void chromium_browser_send_mouse_wheel(chromium_browser_t b, int x, int y,
    float dx, float dy, uint32_t m) {}
void chromium_browser_send_key_event(chromium_browser_t b, int t, int wk,
    int nk, uint32_t m, uint16_t c) {}

const char* chromium_get_version(void) {
    return "chromium-content-shell-dev";
}
