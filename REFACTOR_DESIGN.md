# AudioTrace Core Audio Taps Refactor - Design Document

**Date:** December 23, 2025  
**Status:** Design Phase  
**Author:** Analysis based on audioteejs repository findings

## Executive Summary

AudioTrace is currently experiencing a "silence issue" where all captured audio samples are zeros despite successful tap creation and callback execution. Analysis of the [audioteejs/audiotee](https://github.com/makeusabrew/audiotee) repository reveals that we are already using the correct Core Audio Taps API (`AudioHardwareCreateProcessTap`), but there may be configuration issues with our aggregate device setup or tap parameters.

**Key Finding:** We do NOT need to refactor to a different API - we're already using the correct one. The issue is in the implementation details.

## Current Architecture Analysis

### What We're Using (Correct API ✓)

```objc
// From AudioTapManager.mm:581
AudioObjectID tap_id = kAudioObjectUnknown;
OSStatus status = AudioHardwareCreateProcessTap(tapDesc, &tap_id);
```

We are correctly using:
- **Core Audio Taps API** (macOS 14.2+) via `AudioHardwareCreateProcessTap()`
- **`CATapDescription`** for tap configuration
- **Aggregate device** to bundle multiple taps
- **IOProc callbacks** to receive audio data

### What We're NOT Using (Good! ✓)

We are NOT using:
- `MTAudioProcessingTap` (older media processing tap API - wrong for system audio)
- `MTAudioProcessingTapCallbacks` (media-specific, not for system audio taps)

## The Actual Problem

Based on test harness output and comparison with AudioTee Swift implementation:

### Evidence of the Issue
```
2025-12-23 18:24:31.039 AudioTrace[90261:15146011]   First samples: 0.000000, 0.000000, 0.000000, 0.000000
2025-12-23 18:24:20.656 AudioTrace[90261:15146010] 🔍 Sample 1000: PID 486, RMS=0.000000000
```

All audio samples are zeros despite:
- ✅ Tap creation succeeds (39 taps created)
- ✅ Aggregate device created successfully (device 177)
- ✅ Device becomes ready (after 1 poll, 0.1s)
- ✅ IOProc callbacks fire regularly (~100 times/sec)
- ✅ Buffers received (4096 bytes, 2 channels)
- ✅ Permissions granted (System Audio Recording)

### Root Cause Hypotheses

Comparing with AudioTee Swift implementation, potential issues:

1. **Aggregate Device Configuration**
   - We use `kAudioAggregateDeviceIsStackedKey = 0` (separate buffers)
   - AudioTee uses same approach
   - But: Need to verify drift compensation and tap list configuration

2. **Tap Description Parameters**
   - We set `exclusive = NO`, `muteBehavior = CATapUnmuted`, `privateTap = YES`
   - AudioTee uses `exclusive = NO`, `muteBehavior = .unmuted`, `isPrivate = true`
   - Match appears correct, but need to verify all CATapDescription properties

3. **IOProc Registration Timing**
   - ✅ We now wait for device ready before starting IOProc (after recent fix)
   - This matches AudioTee's approach

4. **Sub-Device vs Tap-Only Configuration**
   - AudioTee comment: "it seems we only need the tap, not the actual device in there"
   - We don't include the main output device in our aggregate
   - Need to verify this is correct for our use case

## Comparison: AudioTrace vs AudioTee

### AudioTee Swift Implementation (Working)

```swift
// From AudioTee/Sources/Core/AudioTapManager.swift
let tapConfig = TapConfiguration(
    processes: processes,
    muteBehavior: mute ? .muted : .unmuted,
    isExclusive: isExclusive,
    isMono: !stereo
)

let description = CATapDescription()
description.name = "audiotee-tap"
description.processes = translatePIDsToProcessObjects(config.processes)
description.isPrivate = true
description.muteBehavior = config.muteBehavior.coreAudioValue
description.isMixdown = true
description.isMono = config.isMono
description.isExclusive = config.isExclusive
description.deviceUID = nil  // system default
description.stream = 0  // first stream of output device

var tapID = AudioObjectID(kAudioObjectUnknown)
let status = AudioHardwareCreateProcessTap(description, &tapID)
```

**Key Properties:**
- `isMixdown = true` (mixes all process audio into one stream)
- `deviceUID = nil` (uses system default)
- `stream = 0` (first stream)

### AudioTrace Implementation (Silent)

```objc
// From AudioTapManager.mm:560-582
CATapDescription* tapDesc = nil;
if (device_uid) {
    tapDesc = [[CATapDescription alloc] initWithProcesses:processes
                                             andDeviceUID:device_uid
                                               withStream:0];
} else {
    tapDesc = [[CATapDescription alloc] initStereoMixdownOfProcesses:processes];
}

tapDesc.exclusive = NO;
tapDesc.muteBehavior = CATapUnmuted;
tapDesc.privateTap = YES;

AudioObjectID tap_id = kAudioObjectUnknown;
OSStatus status = AudioHardwareCreateProcessTap(tapDesc, &tap_id);
```

**Differences Found:**
1. ❌ We specify `device_uid = "BuiltInSpeakerDevice"` - AudioTee uses `nil`
2. ⚠️  We use convenience initializer `initWithProcesses:andDeviceUID:withStream:` vs manual property setting
3. ⚠️  We don't explicitly set `isMixdown` property (might be implicit in convenience initializer)

## Proposed Solution: Configuration Audit

### Phase 1: Simplify Tap Creation (Match AudioTee Exactly)

**Change tap creation to match AudioTee's working implementation:**

```objc
// Current (potentially problematic):
if (device_uid) {
    tapDesc = [[CATapDescription alloc] initWithProcesses:processes
                                             andDeviceUID:device_uid
                                               withStream:0];
} else {
    tapDesc = [[CATapDescription alloc] initStereoMixdownOfProcesses:processes];
}

// Proposed (matching AudioTee):
tapDesc = [[CATapDescription alloc] init];
tapDesc.name = [NSString stringWithFormat:@"audiotrace-tap-pid-%d", pid];
tapDesc.processes = processes;
tapDesc.isPrivate = YES;
tapDesc.muteBehavior = CATapUnmuted;
tapDesc.isMixdown = YES;  // Explicit: mix process audio
tapDesc.isMono = NO;      // Stereo
tapDesc.isExclusive = NO;
tapDesc.deviceUID = nil;  // System default, not specific device
tapDesc.stream = 0;
```

**Rationale:**
- AudioTee doesn't specify a device UID - lets system choose
- Explicit property setting is clearer than convenience initializers
- Ensures `isMixdown` is set (critical for capturing audio)

### Phase 2: Verify Aggregate Device Configuration

**Current aggregate device setup:**

```objc
// AudioTapManager.mm:730-833
int is_stacked_value = 0;  // Separate buffers per tap
CFNumberRef is_stacked = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &is_stacked_value);
CFDictionarySetValue(device_dict, CFSTR(kAudioAggregateDeviceIsStackedKey), is_stacked);

int auto_start_value = 0;  // Don't auto-start
CFNumberRef auto_start = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &auto_start_value);
CFDictionarySetValue(device_dict, CFSTR(kAudioAggregateDeviceTapAutoStartKey), auto_start);
```

**Verify:**
1. ✓ `kAudioAggregateDeviceIsStackedKey = 0` - Correct (matches AudioTee)
2. ✓ `kAudioAggregateDeviceIsPrivateKey = 1` - Correct
3. ✓ `kAudioAggregateDeviceTapAutoStartKey = 0` - Correct
4. ✓ Drift compensation enabled per sub-tap - Correct

### Phase 3: IOProc Data Inspection

**Add detailed logging at IOProc level:**

```objc
// In audio_io_proc callback
static std::atomic<int> zero_count{0};
static std::atomic<int> nonzero_count{0};

for (UInt32 i = 0; i < inInputData->mNumberBuffers; ++i) {
    const AudioBuffer& buf = inInputData->mBuffers[i];
    if (buf.mData && buf.mDataByteSize >= sizeof(float) * 8) {
        const float* samples = static_cast<const float*>(buf.mData);
        
        bool has_audio = false;
        for (size_t j = 0; j < buf.mDataByteSize / sizeof(float); ++j) {
            if (std::abs(samples[j]) > 1e-7f) {
                has_audio = true;
                break;
            }
        }
        
        if (has_audio) {
            zero_count++;
            if (zero_count <= 5) {
                NSLog(@"🎵 Buffer %u HAS AUDIO! First non-zero at sample check", i);
            }
        } else {
            nonzero_count++;
        }
    }
}
```

### Phase 4: Test with Global System Tap

**Create a single tap for ALL system audio (not per-process):**

```objc
// Simpler test: tap entire system output
tapDesc = [[CATapDescription alloc] init];
tapDesc.name = @"audiotrace-global-tap";
tapDesc.processes = @[];  // Empty = all processes
tapDesc.isPrivate = YES;
tapDesc.muteBehavior = CATapUnmuted;
tapDesc.isMixdown = YES;
tapDesc.isMono = NO;
tapDesc.isExclusive = YES;  // Try exclusive first
tapDesc.deviceUID = nil;
tapDesc.stream = 0;
```

**Rationale:**
- Simpler case to debug
- AudioTee supports this: empty processes = all audio
- Eliminates per-process tap complexity

## Implementation Plan

### Step 1: Add Debug Mode for Tap Configuration
**File:** `AudioCore/AudioTapManager.mm`

```objc
// Add environment variable control
bool debug_use_nil_device_uid = std::getenv("AUDIO_TRACE_DEBUG_NIL_DEVICE_UID") != nullptr;
bool debug_explicit_mixdown = std::getenv("AUDIO_TRACE_DEBUG_EXPLICIT_MIXDOWN") != nullptr;
```

### Step 2: Create Tap Parameter Test Matrix

Test combinations:
1. ✅ Current: device_uid="BuiltInSpeakerDevice", convenience initializer
2. 🆕 Test A: device_uid=nil, convenience initializer  
3. 🆕 Test B: device_uid=nil, explicit property setting + isMixdown=YES
4. 🆕 Test C: Global tap (empty processes), device_uid=nil, isMixdown=YES

### Step 3: Enhanced Logging

Add to `create_tap_for_process()`:
```objc
NSLog(@"🔧 Tap Config: deviceUID=%@, isMixdown=%d, isMono=%d, isExclusive=%d, isPrivate=%d",
      tapDesc.deviceUID ?: @"<nil>",
      tapDesc.isMixdown,
      tapDesc.isMono,
      tapDesc.isExclusive,
      tapDesc.isPrivate);
```

### Step 4: Verify Format After Tap Creation

```objc
// After AudioHardwareCreateProcessTap
AudioStreamBasicDescription fmt{};
UInt32 size = sizeof(fmt);
AudioObjectPropertyAddress addr{kAudioTapPropertyFormat, ...};
if (AudioObjectGetPropertyData(tap_id, &addr, 0, nullptr, &size, &fmt) == noErr) {
    NSLog(@"📊 Tap format: rate=%.0f, channels=%u, bytesPerFrame=%u, formatFlags=0x%x",
          fmt.mSampleRate, fmt.mChannelsPerFrame, fmt.mBytesPerFrame, fmt.mFormatFlags);
    
    // CRITICAL: Verify this is NOT zero or invalid
    if (fmt.mSampleRate == 0 || fmt.mChannelsPerFrame == 0) {
        NSLog(@"❌ INVALID tap format detected!");
    }
}
```

## Testing Strategy

### Test 1: Single Process Tap with nil deviceUID
```bash
AUDIO_TRACE_DEBUG_NIL_DEVICE_UID=1 \
AUDIO_TRACE_DEBUG_SINGLE_PID=707 \
./build/AudioTrace.app/Contents/MacOS/AudioTrace
```

Expected: Either audio data OR specific error about tap configuration

### Test 2: Global System Tap
```bash
AUDIO_TRACE_DEBUG_GLOBAL_ONLY=1 \
AUDIO_TRACE_DEBUG_NIL_DEVICE_UID=1 \
./build/AudioTrace.app/Contents/MacOS/AudioTrace
```

Expected: System-wide audio from all processes

### Test 3: OCaml Test Harness with Each Configuration
```bash
cd test_harness
dune exec ./test_silence_issue.exe
```

Expected: Non-zero RMS values when audio is playing

## Success Criteria

1. **Primary:** RMS values > 0 when audio is playing
2. **Validation:** First samples in IOProc callback are non-zero floats
3. **Verification:** OCaml test harness shows audio activity
4. **Confirmation:** Menu bar updates with active process names

## Rollback Plan

If refactor causes issues:
- Keep current implementation in `AudioTapManager.mm.current`
- New implementation in `AudioTapManager.mm.refactor`
- CMake flag to switch: `AUDIO_TRACE_USE_REFACTOR_TAP=ON/OFF`

## Key Insights from AudioTee Analysis

### What AudioTee Does Right (That We Should Verify)

1. **Permission Handling:**
   - They document the silence issue when permissions aren't granted
   - Reference AudioCap's TCC probing for pre-emptive checks
   - We have permissions, but should add explicit verification

2. **Device Readiness:**
   - ✅ We now wait for device ready (recently added)
   - Polls `kAudioDevicePropertyDeviceIsAlive` before use

3. **Nil Device UID:**
   - AudioTee uses `deviceUID = nil` for system default
   - We explicitly set to "BuiltInSpeakerDevice"
   - **Hypothesis:** Explicit device UID might cause tap to miss audio routing

4. **Explicit Property Setting:**
   - AudioTee sets each CATapDescription property explicitly
   - We use convenience initializers
   - **Hypothesis:** Convenience initializers might not set all required properties

## Open Questions

1. **Why does explicit deviceUID cause silence?**
   - Does it lock tap to physical device even when audio routes elsewhere?
   - Should we always use nil for system audio tapping?

2. **Is isMixdown being set by convenience initializer?**
   - `initStereoMixdownOfProcesses:` should set it, but verify
   - May need explicit property setting instead

3. **Do we need to handle audio format conversion?**
   - AudioTee uses AudioFormatConverter for sample rate changes
   - We don't currently do this
   - Could format mismatch cause silent buffers?

4. **Could this be an entitlements issue?**
   - We have `com.apple.security.device.audio-input` ✓
   - AudioTee doesn't mention specific entitlements beyond permissions
   - Likely not the issue since taps are created successfully

## References

- [AudioTee Swift Implementation](https://github.com/makeusabrew/audiotee)
- [AudioTee.js Node Wrapper](https://github.com/makeusabrew/audioteejs)
- [Apple Core Audio Taps Documentation](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [AudioCap TCC Permission Checking](https://github.com/insidegui/AudioCap/blob/main/AudioCap/ProcessTap/AudioRecordingPermission.swift)

## Next Steps

1. ✅ Document current findings (this document)
2. ⏭️ Implement Phase 1: Nil deviceUID + explicit property setting
3. ⏭️ Test with single process tap
4. ⏭️ Test with global system tap
5. ⏭️ Verify with OCaml test harness
6. ⏭️ Compare buffer data byte-by-byte if still silent

## Conclusion

**We are using the correct API.** The issue is likely in tap configuration parameters, specifically:
- Using explicit `deviceUID` instead of `nil`
- Potentially missing `isMixdown` property setting
- Need to match AudioTee's exact configuration that is known to work

The fix should be a **configuration change**, not an API refactor.
