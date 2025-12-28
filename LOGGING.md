# AudioTrace Logging

AudioTrace uses [Quill](https://github.com/odygrd/quill) for high-performance asynchronous logging with different log levels. Quill provides ultra-low latency logging with minimal overhead in the hot path.

## Log Levels

- **trace**: Very detailed diagnostic information
- **debug**: Debugging information (default in debug builds)
- **info**: General informational messages (default in release builds)
- **warn**: Warning messages
- **error**: Error messages

## Usage in C++ Code

```cpp
#include "AudioCore/Logger.hpp"

// Simple messages
AUDIOTRACE_LOG_INFO("Application started");
AUDIOTRACE_LOG_WARN("Low memory warning");
AUDIOTRACE_LOG_ERROR("Failed to connect");

// Formatted messages (uses std::format/Python-style formatting)
AUDIOTRACE_LOG_DEBUG("Processing PID {} with {} samples", pid, count);
AUDIOTRACE_LOG_INFO("Window title: '{}'", title);
```

**Note:** Logging uses compile-time macros for zero-cost abstraction. The format strings must be compile-time constants.

## Controlling Log Level

Set the `AUDIOTRACE_LOG_LEVEL` environment variable:

```bash
# Debug logging
AUDIOTRACE_LOG_LEVEL=debug ./AudioTrace.app/Contents/MacOS/AudioTrace

# Info only (less verbose)
AUDIOTRACE_LOG_LEVEL=info ./AudioTrace.app/Contents/MacOS/AudioTrace

# Trace (most verbose)
AUDIOTRACE_LOG_LEVEL=trace ./AudioTrace.app/Contents/MacOS/AudioTrace

# Warnings and errors only
AUDIOTRACE_LOG_LEVEL=warn ./AudioTrace.app/Contents/MacOS/AudioTrace
```

When running as a normal app bundle (via `open`), logs go to Console.app.

## Default Levels

- **Debug builds** (`-DCMAKE_BUILD_TYPE=Debug`): `debug` level
- **Release builds** (default): `info` level

## Migration from NSLog

To migrate existing NSLog calls to Quill:

```objc
// Old
NSLog(@"⚠️ Failed to process PID %d", pid);

// New
AUDIOTRACE_LOG_WARN("Failed to process PID {}", pid);
```

Note: Quill uses `{}` for format placeholders (like Python/Rust), not `%d`/`%@` like NSLog.

## Available Logging Macros

- `AUDIOTRACE_LOG_TRACE(fmt, ...)` - Most verbose, detailed diagnostic information
- `AUDIOTRACE_LOG_DEBUG(fmt, ...)` - Debug-level information
- `AUDIOTRACE_LOG_INFO(fmt, ...)` - General informational messages
- `AUDIOTRACE_LOG_WARN(fmt, ...)` - Warning messages
- `AUDIOTRACE_LOG_ERROR(fmt, ...)` - Error messages

## Performance Benefits

Quill provides:
- **Asynchronous logging**: Log calls return immediately, actual I/O happens on a background thread
- **Low latency**: Hot path is optimized for minimal overhead (~10-20ns per log call)
- **Zero-cost abstraction**: Disabled log levels have zero runtime cost
- **Type-safe formatting**: Compile-time format string validation
