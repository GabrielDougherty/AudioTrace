# AudioTrace Logging

AudioTrace uses [spdlog](https://github.com/gabime/spdlog) for structured logging with different log levels.

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
AudioTrace::Logger::info("Application started");
AudioTrace::Logger::warn("Low memory warning");
AudioTrace::Logger::error("Failed to connect");

// Formatted messages (uses fmt/spdlog formatting)
AudioTrace::Logger::debug("Processing PID {} with {} samples", pid, count);
AudioTrace::Logger::info("Window title: '{}'", title);
```

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

To migrate existing NSLog calls to spdlog:

```objc
// Old
NSLog(@"⚠️ Failed to process PID %d", pid);

// New
AudioTrace::Logger::warn("Failed to process PID {}", pid);
```

Note: spdlog uses `{}` for format placeholders (like Python/Rust), not `%d`/`%@` like NSLog.
