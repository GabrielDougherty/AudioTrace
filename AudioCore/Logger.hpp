#pragma once

#include <quill/Backend.h>
#include <quill/Frontend.h>
#include <quill/LogMacros.h>
#include <quill/Logger.h>
#include <quill/sinks/ConsoleSink.h>
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
        if (!initialized_) {
            // Start the backend thread
            quill::Backend::start();
            
            // Create console sink with color support
            auto console_sink = quill::Frontend::create_or_get_sink<quill::ConsoleSink>("sink_id_1");
            
            // Create logger
            logger_ = quill::Frontend::create_or_get_logger(
                "AudioTrace",
                std::move(console_sink)
            );
            
            // Default to info level, can be changed via environment variable
            const char* log_level = std::getenv("AUDIOTRACE_LOG_LEVEL");
            quill::LogLevel level = quill::LogLevel::Info;
            
            if (log_level) {
                std::string level_str(log_level);
                if (level_str == "debug" || level_str == "DEBUG") {
                    level = quill::LogLevel::Debug;
                } else if (level_str == "trace" || level_str == "TRACE") {
                    level = quill::LogLevel::TraceL3;
                } else if (level_str == "warn" || level_str == "WARN") {
                    level = quill::LogLevel::Warning;
                } else if (level_str == "error" || level_str == "ERROR") {
                    level = quill::LogLevel::Error;
                }
            } else {
                // Default to info level in release, debug in debug builds
                #ifdef NDEBUG
                level = quill::LogLevel::Info;
                #else
                level = quill::LogLevel::Debug;
                #endif
            }
            
            logger_->set_log_level(level);
            initialized_ = true;
        }
    }
    
    static quill::Logger* get() {
        if (!initialized_) {
            init();
        }
        return logger_;
    }
    
private:
    static quill::Logger* logger_;
    static bool initialized_;
};

}  // namespace AudioTrace

// Define logging macros that match the old API
// These macros provide compile-time format string checking required by Quill
#define AUDIOTRACE_LOG_TRACE(fmt, ...) LOG_TRACE_L3(::AudioTrace::Logger::get(), fmt, ##__VA_ARGS__)
#define AUDIOTRACE_LOG_DEBUG(fmt, ...) LOG_DEBUG(::AudioTrace::Logger::get(), fmt, ##__VA_ARGS__)
#define AUDIOTRACE_LOG_INFO(fmt, ...) LOG_INFO(::AudioTrace::Logger::get(), fmt, ##__VA_ARGS__)
#define AUDIOTRACE_LOG_WARN(fmt, ...) LOG_WARNING(::AudioTrace::Logger::get(), fmt, ##__VA_ARGS__)
#define AUDIOTRACE_LOG_ERROR(fmt, ...) LOG_ERROR(::AudioTrace::Logger::get(), fmt, ##__VA_ARGS__)
