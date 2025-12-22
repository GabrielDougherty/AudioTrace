#import "ProcessInfo.hpp"
#import <AppKit/AppKit.h>
#include <signal.h>

namespace AudioTrace {

#ifdef __OBJC__

NSRunningApplication* ProcessInfo::get_running_app(pid_t pid) {
    NSRunningApplication* app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    return app;
}

std::optional<ProcessInfo::AppInfo> ProcessInfo::get_app_info(pid_t pid) {
    @autoreleasepool {
        NSRunningApplication* app = get_running_app(pid);
        if (!app) {
            return std::nullopt;
        }

        AppInfo info;
        info.pid = pid;

        // Get app name
        if (app.localizedName) {
            info.name = [app.localizedName UTF8String];
        } else {
            info.name = "Unknown";
        }

        // Get bundle ID
        if (app.bundleIdentifier) {
            info.bundle_id = [app.bundleIdentifier UTF8String];
        }

        // Get app icon
        info.icon = app.icon;  // NSImage is reference counted

        return info;
    }
}

std::optional<std::string> ProcessInfo::get_app_name(pid_t pid) {
    @autoreleasepool {
        NSRunningApplication* app = get_running_app(pid);
        if (!app || !app.localizedName) {
            return std::nullopt;
        }

        return std::string([app.localizedName UTF8String]);
    }
}

bool ProcessInfo::is_process_alive(pid_t pid) {
    // Use kill with signal 0 to check if process exists
    // Returns 0 if process exists, -1 if not
    return kill(pid, 0) == 0;
}

#endif  // __OBJC__

}  // namespace AudioTrace
