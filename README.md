# AudioTrace

macOS menu bar application that tracks which applications have produced audible sound recently using Core Audio process taps.

## Features

- Real-time audio activity detection
- Menu bar interface showing recent audio sources
- Low-latency, realtime-safe audio processing
- C++23 core with minimal Objective-C++ glue

## Requirements

- macOS 14.4+
- Apple Silicon (arm64)
- CMake 3.25+
- Xcode Command Line Tools

## Building

Using the build script (recommended):
```bash
./build.sh
```

Or manually:
```bash
mkdir -p build
cd build
CC=/usr/bin/clang CXX=/usr/bin/clang++ cmake -G Ninja ..
ninja
```

The application bundle will be created at `build/AudioTrace.app`.

## Running

```bash
open build/AudioTrace.app
```

On first launch, you'll be prompted to grant audio input permissions in System Settings > Privacy & Security.

## Architecture

### AudioCore/ (Pure C++23)
- **RingBuffer.hpp** - Lock-free SPSC ring buffer for realtime audio data
- **AudioTapManager** - Core Audio process tap management
- **AudioAnalyzer** - RMS/peak analysis with hysteresis
- **ActivityTracker** - Per-process activity tracking with timestamps

### macOS/ (Objective-C++ Integration)
- **AppDelegate** - Application lifecycle and audio pipeline setup
- **StatusItem** - Menu bar UI controller
- **ProcessInfo** - Process metadata (name, icon, bundle ID)

## Threading Model

1. **Core Audio callback** (realtime) - Writes to lock-free ring buffers
2. **Worker thread** - Drains buffers, analyzes audio
3. **Main thread** - UI updates every 500ms

## Current Status

This is a skeleton implementation with the following **TODO** items:

- [ ] Implement actual Core Audio process tap setup in AudioTapManager
- [ ] Add proper audio device enumeration
- [ ] Implement IOProc callback for real audio capture
- [ ] Add app icons to menu items
- [ ] Handle permission errors gracefully
- [ ] Add user preferences (allowlist/blocklist)
- [ ] Persist activity across app restarts

## License

TBD
