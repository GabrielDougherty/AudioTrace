#import "ProcessInfo.hpp"
#import <AppKit/AppKit.h>
#include <signal.h>
#include <libproc.h>
#include <sys/sysctl.h>
#include <vector>
#include "../AudioCore/Logger.hpp"

namespace AudioTrace {

#ifdef __OBJC__

// Helper to get parent PID
static pid_t get_parent_pid(pid_t pid) {
    struct kinfo_proc info;
    size_t length = sizeof(struct kinfo_proc);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    
    if (sysctl(mib, 4, &info, &length, NULL, 0) == 0) {
        return info.kp_eproc.e_ppid;
    }
    return -1;
}

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

        // Get window title
        auto window_title = get_window_title(pid);
        if (window_title.has_value()) {
            info.window_title = *window_title;
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

std::optional<std::string> ProcessInfo::get_window_title(pid_t pid) {
    @autoreleasepool {
        // Try the given PID first, then try parent if needed
        std::vector<pid_t> pids_to_try = {pid};
        
        // Add parent PID (helper processes might not have windows, but parent does)
        pid_t parent = get_parent_pid(pid);
        if (parent > 0 && parent != pid) {
            pids_to_try.push_back(parent);
        }
        
        for (pid_t try_pid : pids_to_try) {
            // Use Accessibility API to get window title
            AXUIElementRef app = AXUIElementCreateApplication(try_pid);
            if (!app) {
                Logger::debug("Failed to create AXUIElement for PID {}", try_pid);
                continue;
            }
            
            // Try to get the focused window
            AXUIElementRef window = nullptr;
            AXError err = AXUIElementCopyAttributeValue(
                app,
                kAXFocusedWindowAttribute,
                (CFTypeRef*)&window
            );
            
            CFStringRef title = nullptr;
            if (err == kAXErrorSuccess && window) {
                // Got focused window, try to get its title
                err = AXUIElementCopyAttributeValue(
                    window,
                    kAXTitleAttribute,
                    (CFTypeRef*)&title
                );
                CFRelease(window);
            } else {
                // No focused window, try to get any window's title
                CFArrayRef windows = nullptr;
                err = AXUIElementCopyAttributeValue(
                    app,
                    kAXWindowsAttribute,
                    (CFTypeRef*)&windows
                );
                
                if (err == kAXErrorSuccess && windows) {
                    CFIndex count = CFArrayGetCount(windows);
                    for (CFIndex i = 0; i < count && !title; i++) {
                        AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
                        AXUIElementCopyAttributeValue(win, kAXTitleAttribute, (CFTypeRef*)&title);
                        if (title) break;
                    }
                    CFRelease(windows);
                }
            }
            
            CFRelease(app);
            
            if (title) {
                NSString* titleStr = (__bridge NSString*)title;
                if (titleStr.length > 0) {
                    std::string result = [titleStr UTF8String];
                    if (try_pid != pid) {
                        Logger::debug("Found window title '{}' for PID {} via parent {}", result, pid, try_pid);
                    } else {
                        Logger::debug("Found window title '{}' for PID {}", result, pid);
                    }
                    CFRelease(title);
                    return result;
                }
                CFRelease(title);
            } else {
                Logger::debug("No window title found for PID {}", try_pid);
            }
        }
        
        return std::nullopt;
    }
}

bool ProcessInfo::is_process_alive(pid_t pid) {
    // Use kill with signal 0 to check if process exists
    // Returns 0 if process exists, -1 if not
    return kill(pid, 0) == 0;
}

#endif  // __OBJC__

}  // namespace AudioTrace
