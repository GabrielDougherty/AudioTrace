# AudioTrace

macOS menu bar application that tracks which applications have produced audible sound recently using Core Audio process taps.

I made this app to answer the question, "where did that sound come from?" when hearing an intermittent beep or something

## Features

- Real-time audio activity detection
- Menu bar interface showing recent audio sources

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

On first launch, you'll be prompted to grant audio input permissions in System Settings > Privacy & Security. And to grant Accessibility features (for window titles)

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
3. **Main thread** - UI updates on open

## License

ISC