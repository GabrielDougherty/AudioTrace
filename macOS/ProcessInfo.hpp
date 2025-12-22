#pragma once

#import <Foundation/Foundation.h>
#include <string>
#include <optional>
#include <sys/types.h>

#ifdef __OBJC__
@class NSImage;
@class NSRunningApplication;
#endif

namespace AudioTrace {

/// Process metadata retrieval (Obj-C++ bridge to macOS APIs)
class ProcessInfo {
public:
    struct AppInfo {
        std::string name;
        std::string bundle_id;
        pid_t pid;
        #ifdef __OBJC__
        NSImage* __strong icon;  // Retained
        #else
        void* icon;
        #endif
    };

    ProcessInfo() = default;
    ~ProcessInfo() = default;

    /// Get application info for a process ID
    /// Returns nullopt if PID is invalid or not accessible
    static std::optional<AppInfo> get_app_info(pid_t pid);

    /// Get just the application name (lighter weight)
    static std::optional<std::string> get_app_name(pid_t pid);

    /// Check if process is still running
    static bool is_process_alive(pid_t pid);

private:
    #ifdef __OBJC__
    static NSRunningApplication* get_running_app(pid_t pid);
    #endif
};

}  // namespace AudioTrace
