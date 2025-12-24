#import "ProcessInfo.hpp"
#import <AppKit/AppKit.h>
#include <signal.h>
#include <libproc.h>
#include <sys/sysctl.h>
#include <vector>
#include "../AudioCore/Logger.hpp"

namespace AudioTrace {

#ifdef __OBJC__

pid_t ProcessInfo::get_parent_pid(pid_t pid) {
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
        if (app && app.localizedName) {
            return std::string([app.localizedName UTF8String]);
        }
        
        // For helper processes, try to find the responsible application
        // using bundle ID matching
        if (app && app.bundleIdentifier) {
            NSString* bundleId = app.bundleIdentifier;
            Logger::debug("PID {} has bundle ID: {}", pid, [bundleId UTF8String]);
            
            // For Messages helpers (e.g., com.apple.imagent), look for the main app
            if ([bundleId containsString:@"message"] || [bundleId containsString:@"imessage"] || 
                [bundleId isEqualToString:@"com.apple.imagent"] || 
                [bundleId isEqualToString:@"com.apple.IMDPersistenceAgent"]) {
                NSArray<NSRunningApplication*>* messagesApps = 
                    [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.MobileSMS"];
                if (messagesApps.count > 0) {
                    Logger::debug("Found Messages app for helper PID {} (bundle: {})", 
                                 pid, [bundleId UTF8String]);
                    return std::string("Messages");
                }
            }
            
            // Generic fallback: try parent PID
            pid_t parent = get_parent_pid(pid);
            if (parent > 0 && parent != pid && parent != 1) {
                NSRunningApplication* parentApp = get_running_app(parent);
                if (parentApp && parentApp.localizedName) {
                    Logger::debug("Got app name '{}' from parent PID {} for helper PID {}", 
                                 [parentApp.localizedName UTF8String], parent, pid);
                    return std::string([parentApp.localizedName UTF8String]);
                }
            }
        } else {
            // No bundle ID - likely a system daemon
            // Try to get the process path using proc_pidpath
            char process_path[PROC_PIDPATHINFO_MAXSIZE];
            int ret = proc_pidpath(pid, process_path, sizeof(process_path));
            if (ret > 0) {
                // Extract just the process name from the path
                const char* process_name = strrchr(process_path, '/');
                process_name = process_name ? process_name + 1 : process_path;
                Logger::debug("PID {} has no bundle identifier, process name: {}", pid, process_name);
                
                // Special case: system audio daemons playing notification sounds
                // Heuristic: coreaudiod often plays notification sounds for Messages
                if (strcmp(process_name, "coreaudiod") == 0) {
                    // Check if Messages is running - if so, attribute to Messages
                    NSArray<NSRunningApplication*>* messagesApps = 
                        [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.MobileSMS"];
                    if (messagesApps.count > 0) {
                        Logger::debug("Attributing coreaudiod (PID {}) to Messages (heuristic)", pid);
                        return std::string("Messages (notifications)");
                    }
                    return std::string("System Audio");
                }
                
                // Return the process name
                return std::string(process_name);
            } else {
                Logger::debug("PID {} has no bundle identifier and proc_pidpath failed", pid);
                
                // Last resort heuristic: if Messages is running and we can't identify the process,
                // assume it's a notification sound
                NSArray<NSRunningApplication*>* messagesApps = 
                    [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.MobileSMS"];
                if (messagesApps.count > 0) {
                    Logger::debug("Unknown PID {} attributed to Messages (fallback heuristic)", pid);
                    return std::string("Messages (notifications)");
                }
            }
        }
        
        return std::nullopt;
    }
}

std::optional<std::string> ProcessInfo::get_window_title(pid_t pid) {
    @autoreleasepool {
        // Try the given PID first, then try parent if needed
        std::vector<pid_t> pids_to_try = {pid};
        
        // Add parent PID (helper processes might not have windows, but parent does)
        pid_t parent = ProcessInfo::get_parent_pid(pid);
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

NSRunningApplication* ProcessInfo::get_activatable_app(pid_t pid) {
    // Don't use @autoreleasepool here - we need the returned object to stay alive
    // Try the direct PID first
    NSRunningApplication* app = get_running_app(pid);
    if (app) {
        Logger::debug("Found running application for PID {}", pid);
        return app;
    }
    
    // If not found, try the parent PID (for helper processes)
    pid_t parent = ProcessInfo::get_parent_pid(pid);
    if (parent > 0 && parent != pid) {
        Logger::debug("PID {} not activatable, trying parent PID {}", pid, parent);
        app = get_running_app(parent);
        if (app) {
            Logger::debug("Found parent application for PID {} -> {}", pid, parent);
            return app;
        }
    }
    
    Logger::warn("Could not find activatable application for PID {} (parent: {})", pid, parent);
    return nil;
}

#endif  // __OBJC__

}  // namespace AudioTrace
