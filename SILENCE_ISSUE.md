# Audio Tap Silence Issue

## Summary

AudioTrace successfully creates process taps and receives audio callbacks, but all captured audio data contains only zeros (silence). The infrastructure is working correctly - callbacks fire, ring buffers transfer data, and the worker thread processes samples - but no actual audio is being captured.

## What We Learned (Dec 21–22)

- The realtime callback receives zeroes directly from CoreAudio (first samples are 0.0 in `audio_io_proc`), so the silence is upstream of our ring buffers/threads.
- The correct “audio process objects” must be used; helper PIDs aren’t tappable. Spotify’s actual audio PID appears as PID 707 (object 110) in `kAudioHardwarePropertyProcessObjectList`.
- Single-PID tap creation succeeds (tap 137, format 48k/2ch), but buffers remain all zeros.
- Global tap also returns zeros. So the problem is not mis-attribution across buffers.
- Default output device is 48 kHz, 2 channels (no multi-channel halving bug). Tap formats match.
- Screen Recording permission is required; lack of it can yield zeroed audio. Environment still returning zeros even with permission.
- `test_activity` CLI fails to see any audio process objects (likely because it isn’t a bundled app with the entitlement), so it’s not a valid probe.

## Current Implementation

### Architecture

1. **Process Discovery**: Discovers all audio-capable processes using `kAudioHardwarePropertyProcessObjectList`
2. **Tap Creation**: Creates individual process taps using `AudioHardwareCreateProcessTap()` with `CATapDescription`
3. **Aggregate Device**: Bundles all taps into a single aggregate device with `kAudioAggregateDeviceIsStackedKey = NO` (separate buffers)
4. **Audio Callbacks**: Registers IOProc on aggregate device to receive audio from all taps
5. **Ring Buffers**: Lock-free per-tap ring buffers transfer data from realtime callback to worker thread
6. **Worker Thread**: Processes audio data, analyzes for activity, and tracks per-process audio

### What's Working ✅

- Successfully creates 38+ process taps
- Aggregate device creation succeeds
- IOProc callbacks fire regularly (~100 times per second)
- Each callback receives 38 buffers (one per tap)
- Ring buffers successfully transfer data
- Worker thread processes thousands of buffers
- No crashes or errors

### What's NOT Working ❌

- All audio samples are `0.000000`
- No audio activity detected from any process
- RMS levels always `0.000000000`
- Applies to both per-process and global tap paths in current tests.

## Build Instructions

```bash
cd /Users/gabriel/ws/AudioTrace
./build.sh
```

Expected output:
```
✓ Build successful!
  App bundle: /Users/gabriel/ws/AudioTrace/build/AudioTrace.app
```

## Test/Reproduce

### 1. Run the Application

```bash
# Kill any existing instance
pkill AudioTrace

# Run and capture logs
/Users/gabriel/ws/AudioTrace/build/AudioTrace.app/Contents/MacOS/AudioTrace 2>&1 | tee /tmp/audiotrace.log
```

### 2. Expected Output

You should see:
```
Creating tap for PID 101
✓ Created tap 137 for PID 101
...
✅ Created aggregate device 175 with 38 taps
🧵 Worker thread started, taps=38
🎉 Started aggregate device with 38 taps
✓ Audio tap manager started successfully
```

### 3. Play Audio for Testing

While AudioTrace is running, play some audio:

```bash
# Text-to-speech
say "Testing audio capture"

# Or play music, YouTube, Spotify, etc.
```

### 4. Check for Activity

Monitor the logs for:
```
🔍 Sample 1000: PID 707, RMS=0.000000000 (threshold=0.005)
```

**Problem**: RMS is always 0.000000000, even when audio is playing

### 5. Debug Buffer Contents

Every 1000 callbacks, we log the first buffer's sample values:
```
🎤 Audio callback fired 1000 times, 38 buffers
  Buffer 0: channels=2, dataSize=2048 bytes
  First samples: 0.000000, 0.000000, 0.000000, 0.000000
```

**Problem**: All samples are 0.000000

## Investigation Done

### Verified Items

1. ✅ Tap objects created successfully (IDs 137-174)
2. ✅ Aggregate device created successfully (ID 175)
3. ✅ IOProc registered and firing
4. ✅ Buffers have correct structure (2 channels, 2048/4096 bytes)
5. ✅ Buffer data pointers are valid (not NULL)
6. ✅ Ring buffer push/pop working correctly
7. ✅ Worker thread processing data
8. ✅ Per-process tap association maintained (buffer index matches tap index)
9. ✅ Tap formats match default output: 48kHz, 2ch, 32-bit float

### Tested Configurations

1. **Per-process taps**: now created from the CoreAudio process object list (no helpers), targeting default output device/stream when available (`initWithProcesses:andDeviceUID:withStream:0`, else stereo mixdown). `exclusive=NO`, `muteBehavior=Unmuted`, `privateTap=YES`.  
   - Result: Silence (buffers zero).
2. **System-wide/global tap**: `initStereoGlobalTapButExcludeProcesses:@[]`, `exclusive=NO`, `muteBehavior=Unmuted`, `privateTap=YES`.  
   - Result: Silence (buffers zero).
3. **Aggregate device settings**:
   - `kAudioAggregateDeviceIsStackedKey = NO` (separate buffers)
   - `kAudioAggregateDeviceIsPrivateKey = YES`
   - `kAudioAggregateDeviceTapAutoStartKey = YES` (not yet flipped to match sample)
   - `kAudioSubTapDriftCompensationKey = YES`

## Potential Causes

### 1. Permissions / CoreAudio state
If Screen Recording is off or coreaudiod hasn’t refreshed after granting, taps can return zeroed audio. (Global tap also zero suggests this.)

### 2. Tap inclusion/exclusion mismatch
We now set `exclusive=NO` for per-process and global taps. If CoreAudio treats global differently, try `exclusive=YES` on global path to mirror Apple sample.

### 3. Auto-start vs manual start
We set `kAudioAggregateDeviceTapAutoStartKey=YES`; Apple’s sample sets `NO` and relies on the IOProc start. Could flip to `NO` to match sample (low probability fix).

### 4. Environment-wide failure
If Apple’s sample also delivers zeros, it indicates an environment/permission issue rather than our code.

## Code Locations

### Tap Creation
[AudioCore/AudioTapManager.mm:398-455](AudioCore/AudioTapManager.mm#L398-L455) - `create_tap_for_process()`

### Aggregate Device Creation
[AudioCore/AudioTapManager.mm:495-591](AudioCore/AudioTapManager.mm#L495-L591) - `create_aggregate_device()`

### Audio Callback
[AudioCore/AudioTapManager.mm:249-279](AudioCore/AudioTapManager.mm#L249-L279) - `audio_io_proc()`

### Buffer Processing
[AudioCore/AudioTapManager.mm:281-318](AudioCore/AudioTapManager.mm#L281-L318) - `process_input_data()`

## Next Steps

1. **Permissions/state reset**
   - Confirm AudioTrace is enabled under System Settings → Privacy & Security → Screen Recording; toggle if needed.
   - Restart `coreaudiod` (log out/in or `sudo launchctl kickstart -k system/com.apple.audio.coreaudiod`) and retest.
2. **Flip auto-start and exclusivity on global tap**
   - Set `kAudioAggregateDeviceTapAutoStartKey = NO`.
   - Set `exclusive=YES` on the global tap to mirror the sample.
3. **Run Apple sample**
   - Build/run `context/example-usage-from-github.txt` to confirm the environment delivers non-zero samples. If it also returns zeros, issue is environmental.
4. **Console logs**
   - `log show --predicate 'subsystem == "com.apple.audio"' --last 5m` during a run to catch permission/denial errors.

## Reference Implementation

Apple's working example (`tapping.m`) uses the exact same approach but reports working audio capture. Key differences to investigate:

1. They use `initStereoGlobalTapButExcludeProcesses` with `exclusive=YES` for global capture.
2. They note the multi-channel volume bug and apply compensation.
3. They set `kAudioAggregateDeviceTapAutoStartKey = NO` and start via IOProc.
4. They use a simpler callback that doesn't distribute to ring buffers.

## Environment

- macOS: 14.2+
- Xcode: Latest
- Permission: Screen Recording (granted)
- Build: Ninja + CMake
- Language: Objective-C++

## Debugging Commands

```bash
# Check audio processes
log show --predicate 'subsystem == "com.apple.audio.CoreAudio"' --last 5m

# Monitor Core Audio
sudo log stream --predicate 'process == "coreaudiod"'

# Check tap objects
# (Add logging to enumerate tap properties)
```
