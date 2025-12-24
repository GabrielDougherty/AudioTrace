#pragma once

#include <spdlog/spdlog.h>
#include <spdlog/sinks/stdout_color_sinks.h>
#include <memory>
#include <string>

namespace AudioTrace {

/// Central logging utility for AudioTrace
/// Usage:
///   Logger::debug("Message with {}", value);
///   Logger::info("Info message");
///   Logger::warn("Warning!");
///   Logger::error("Error: {}", error_msg);
class Logger {
public:
    static void init() {
        if (!logger_) {
            logger_ = spdlog::stdout_color_mt("AudioTrace");
            
            // Default to info level, can be changed via environment variable
            const char* log_level = std::getenv("AUDIOTRACE_LOG_LEVEL");
            if (log_level) {
                std::string level(log_level);
                if (level == "debug" || level == "DEBUG") {
                    logger_->set_level(spdlog::level::debug);
                } else if (level == "trace" || level == "TRACE") {
                    logger_->set_level(spdlog::level::trace);
                } else if (level == "warn" || level == "WARN") {
                    logger_->set_level(spdlog::level::warn);
                } else if (level == "error" || level == "ERROR") {
                    logger_->set_level(spdlog::level::err);
                }
            } else {
                // Default to info level in release, debug in debug builds
                #ifdef NDEBUG
                logger_->set_level(spdlog::level::info);
                #else
                logger_->set_level(spdlog::level::debug);
                #endif
            }
            
            // Use a clean pattern: [timestamp] [level] message
            logger_->set_pattern("[%H:%M:%S.%e] [%^%l%$] %v");
        }
    }
    
    static std::shared_ptr<spdlog::logger>& get() {
        if (!logger_) {
            init();
        }
        return logger_;
    }
    
    template<typename... Args>
    static void trace(spdlog::format_string_t<Args...> fmt, Args&&... args) {
        get()->trace(fmt, std::forward<Args>(args)...);
    }
    
    template<typename... Args>
    static void debug(spdlog::format_string_t<Args...> fmt, Args&&... args) {
        get()->debug(fmt, std::forward<Args>(args)...);
    }
    
    template<typename... Args>
    static void info(spdlog::format_string_t<Args...> fmt, Args&&... args) {
        get()->info(fmt, std::forward<Args>(args)...);
    }
    
    template<typename... Args>
    static void warn(spdlog::format_string_t<Args...> fmt, Args&&... args) {
        get()->warn(fmt, std::forward<Args>(args)...);
    }
    
    template<typename... Args>
    static void error(spdlog::format_string_t<Args...> fmt, Args&&... args) {
        get()->error(fmt, std::forward<Args>(args)...);
    }
    
private:
    static std::shared_ptr<spdlog::logger> logger_;
};

}  // namespace AudioTrace
