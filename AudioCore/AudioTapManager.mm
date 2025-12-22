#include "AudioTapManager.hpp"
#include <thread>
#include <algorithm>
#include <CoreFoundation/CoreFoundation.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>

namespace AudioTrace {

AudioTapManager::AudioTapManager(Config config)
    : config_(config)
    , analyzer_(AudioAnalyzer::Config{
        .silence_threshold_rms = 0.001f,  // ~-60dB
        .active_threshold_rms = 0.005f,   // ~-46dB (hysteresis)
        .window_frames = 2048
      })
    , tracker_(ActivityTracker::Config{
        .current_threshold = std::chrono::milliseconds(500),
        .expiry_time = std::chrono::minutes(2)
      })
{}

AudioTapManager::~AudioTapManager() {
    stop();
}

bool AudioTapManager::start() {
    if (is_running_) {
        return false;
    }

    // Step 1: Discover and create process taps
    std::vector<AudioObjectID> process_objects = discover_audio_processes();
    
    if (process_objects.empty()) {
        NSLog(@"No audio processes found - creating tap for system audio");
        if (!create_tap_for_system()) {
            NSLog(@"Failed to create system audio tap");
            return false;
        }
    } else {
        // Create taps for discovered processes
        for (AudioObjectID obj_id : process_objects) {
            pid_t pid = get_pid_from_audio_object(obj_id);
            if (pid > 0) {
                NSLog(@"Creating tap for PID %d", pid);
                create_tap_for_process(pid);
            }
        }
        
        if (process_taps_.empty()) {
            NSLog(@"Failed to create any process taps, falling back to system audio");
            if (!create_tap_for_system()) {
                return false;
            }
        }
    }
    
    // Step 2: Collect tap UIDs for aggregate device
    std::vector<CFStringRef> tap_uids;
    for (const auto& tap : process_taps_) {
        CFStringRef tap_uid = nullptr;
        UInt32 data_size = sizeof(tap_uid);
        AudioObjectPropertyAddress prop_addr{
            kAudioTapPropertyUID,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        
        OSStatus status = AudioObjectGetPropertyData(
            tap->tap_id,
            &prop_addr,
            0,
            nullptr,
            &data_size,
            &tap_uid
        );
        
        if (status == noErr && tap_uid) {
            tap_uids.push_back(tap_uid);
        }
    }

    // Step 3: Create aggregate device with taps
    if (!create_aggregate_device(tap_uids)) {
        for (auto uid : tap_uids) {
            if (uid) CFRelease(uid);
        }
        return false;
    }
    
    for (auto uid : tap_uids) {
        if (uid) CFRelease(uid);
    }

    // Step 4: Start worker thread
    worker_should_stop_.store(false, std::memory_order_release);
    worker_thread_ = std::make_unique<std::thread>(
        &AudioTapManager::worker_thread_proc, this
    );

    // Step 5: Register IOProc callback for aggregate device
    OSStatus status = AudioDeviceCreateIOProcID(
        aggregate_device_id_,
        audio_io_proc,
        this,
        &io_proc_id_
    );
    
    if (status != noErr) {
        NSLog(@"❌ Failed to create IOProcID: %d", status);
        stop();
        return false;
    }

    // Step 6: Start the aggregate device
    status = AudioDeviceStart(aggregate_device_id_, io_proc_id_);
    if (status != noErr) {
        NSLog(@"❌ Failed to start aggregate device: %d", status);
        AudioDeviceDestroyIOProcID(aggregate_device_id_, io_proc_id_);
        io_proc_id_ = nullptr;
        stop();
        return false;
    }

    NSLog(@"🎉 Started aggregate device with %zu taps", process_taps_.size());
    is_running_ = true;
    return true;
}

void AudioTapManager::stop() {
    if (!is_running_) {
        return;
    }

    // Stop aggregate device
    if (aggregate_device_id_ != kAudioObjectUnknown && io_proc_id_ != nullptr) {
        AudioDeviceStop(aggregate_device_id_, io_proc_id_);
        AudioDeviceDestroyIOProcID(aggregate_device_id_, io_proc_id_);
        io_proc_id_ = nullptr;
    }

    // Signal worker thread to stop
    worker_should_stop_.store(true, std::memory_order_release);
    
    if (worker_thread_ && worker_thread_->joinable()) {
        worker_thread_->join();
    }
    worker_thread_.reset();

    // Destroy aggregate device and taps
    destroy_aggregate_device();

    process_taps_.clear();
    is_running_ = false;
}

void AudioTapManager::set_audio_callback(AudioCallback callback) {
    audio_callback_ = std::move(callback);
}

std::vector<pid_t> AudioTapManager::get_tapped_processes() const {
    std::vector<pid_t> result;
    result.reserve(process_taps_.size());
    
    for (const auto& tap : process_taps_) {
        result.push_back(tap->pid);
    }
    
    return result;
}

std::vector<ActivitySnapshot> AudioTapManager::get_activity_snapshot() const {
    return tracker_.snapshot();
}

void AudioTapManager::worker_thread_proc() {
    NSLog(@"🧵 Worker thread started, taps=%zu", process_taps_.size());
    int loop_count = 0;
    int total_pops = 0;
    int samples_checked = 0;
    
    while (!worker_should_stop_.load(std::memory_order_acquire)) {
        bool did_work = false;
        int pops_this_loop = 0;

        for (auto& tap : process_taps_) {
            AudioTapData data;
            while (tap->ring_buffer.pop(data)) {
                pops_this_loop++;
                total_pops++;
                samples_checked++;
                
                // Calculate RMS manually for debugging
                float sum = 0.0f;
                for (uint32_t i = 0; i < data.frame_count * data.channel_count; ++i) {
                    sum += data.samples[i] * data.samples[i];
                }
                float rms = std::sqrt(sum / (data.frame_count * data.channel_count));
                
                if (samples_checked % 1000 == 0) {
                    NSLog(@"🔍 Sample %d: PID %d, RMS=%.9f (threshold=0.005)", 
                          samples_checked, data.pid, rms);
                }
                
                // Analyze audio for activity
                auto event = analyzer_.analyze(
                    data.samples.data(),
                    data.frame_count,
                    data.channel_count,
                    data.pid,
                    std::chrono::steady_clock::now()
                );
                
                if (event) {
                    // Record activity
                    tracker_.record_activity(*event);
                    
                    NSLog(@"🎵 Activity! PID %d, RMS: %.6f", data.pid, event->rms_level);
                    
                    // Also call user callback if set
                    if (audio_callback_) {
                        audio_callback_(data);
                    }
                }
                
                did_work = true;
            }
        }
        
        if (pops_this_loop > 0 && loop_count % 50 == 0) {
            NSLog(@"📦 Loop %d: popped %d buffers (total=%d)", loop_count, pops_this_loop, total_pops);
        }
        
        loop_count++;

        if (!did_work) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        } else {
            // Periodically cleanup expired entries
            static int cleanup_counter = 0;
            if (++cleanup_counter > 100) {
                tracker_.cleanup_expired();
                cleanup_counter = 0;
            }
        }
    }
}

OSStatus AudioTapManager::audio_io_proc(
    AudioDeviceID,
    const AudioTimeStamp*,
    const AudioBufferList* inInputData,
    const AudioTimeStamp* inInputTime,
    AudioBufferList*,
    const AudioTimeStamp*,
    void* inClientData
) noexcept
{
    auto* manager = static_cast<AudioTapManager*>(inClientData);
    if (!manager || !inInputData) {
        return noErr;
    }

    static std::atomic<int> callback_count{0};
    int count = ++callback_count;
    if (count % 1000 == 0) {
        NSLog(@"🎤 Audio callback fired %d times, %u buffers", 
              count, inInputData->mNumberBuffers);
        
        // Debug: Check first buffer's data
        if (inInputData->mNumberBuffers > 0) {
            const AudioBuffer& buf = inInputData->mBuffers[0];
            NSLog(@"  Buffer 0: channels=%u, dataSize=%u bytes", 
                  buf.mNumberChannels, buf.mDataByteSize);
            
            if (buf.mData && buf.mDataByteSize >= sizeof(float) * 4) {
                const float* samples = static_cast<const float*>(buf.mData);
                NSLog(@"  First samples: %.6f, %.6f, %.6f, %.6f", 
                      samples[0], samples[1], samples[2], samples[3]);
            }
        }
    }

    manager->process_input_data(inInputData, inInputTime);
    
    return noErr;
}

void AudioTapManager::process_input_data(const AudioBufferList* buffer_list,
                                         const AudioTimeStamp* timestamp) noexcept
{
    if (!buffer_list || buffer_list->mNumberBuffers == 0) {
        return;
    }
    
    // Each buffer in the aggregate device corresponds to one tap
    const uint32_t num_buffers = std::min(
        static_cast<uint32_t>(buffer_list->mNumberBuffers),
        static_cast<uint32_t>(process_taps_.size())
    );
    
    for (uint32_t i = 0; i < num_buffers; ++i) {
        const AudioBuffer& buffer = buffer_list->mBuffers[i];
        
        if (buffer.mData == nullptr || buffer.mDataByteSize == 0) {
            continue;
        }

        const float* samples = static_cast<const float*>(buffer.mData);
        const uint32_t sample_count = buffer.mDataByteSize / sizeof(float);
        const uint32_t channel_count = buffer.mNumberChannels;
        const uint32_t frame_count = sample_count / channel_count;

        // Send this buffer to the corresponding tap
        auto& tap = process_taps_[i];
        AudioTapData data;
        data.pid = tap->pid;
        data.frame_count = frame_count;
        data.channel_count = channel_count;
        data.sample_time = timestamp ? timestamp->mSampleTime : 0;
        
        const size_t copy_size = std::min(static_cast<size_t>(sample_count), tap->temp_buffer.size());
        std::copy_n(samples, copy_size, tap->temp_buffer.begin());
        data.samples = tap->temp_buffer;
        
        if (!tap->ring_buffer.push(data)) {
            static std::atomic<int> drop_count{0};
            if (++drop_count % 100 == 0) {
                NSLog(@"⚠️ Dropped %d buffers (ring buffer full)", drop_count.load());
            }
        }
    }
}

AudioStreamBasicDescription AudioTapManager::get_stream_format() const {
    AudioStreamBasicDescription format{};
    format.mSampleRate = config_.sample_rate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mBitsPerChannel = 32;
    format.mChannelsPerFrame = 2;
    format.mBytesPerFrame = format.mChannelsPerFrame * sizeof(float);
    format.mFramesPerPacket = 1;
    format.mBytesPerPacket = format.mBytesPerFrame;
    return format;
}

bool AudioTapManager::create_tap_for_process(pid_t pid) {
    @autoreleasepool {
        // Translate PID to AudioObjectID first
        AudioObjectPropertyAddress prop_addr{
            kAudioHardwarePropertyTranslatePIDToProcessObject,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        
        AudioObjectID process_obj_id = kAudioObjectUnknown;
        UInt32 data_size = sizeof(process_obj_id);
        pid_t input_pid = pid;
        
        OSStatus status = AudioObjectGetPropertyData(
            kAudioObjectSystemObject,
            &prop_addr,
            sizeof(pid_t),
            &input_pid,
            &data_size,
            &process_obj_id
        );
        
        if (status != noErr || process_obj_id == kAudioObjectUnknown) {
            NSLog(@"Failed to translate PID %d to AudioObjectID, status: %d", pid, (int)status);
            return false;
        }
        
        // Create array of process AudioObjectIDs
        NSNumber* processID = @(process_obj_id);
        NSArray<NSNumber*>* processes = @[processID];
        
        // Create tap description (stereo mixdown of this process)
        CATapDescription* tapDesc = [[CATapDescription alloc] initStereoMixdownOfProcesses:processes];
        if (!tapDesc) {
            return false;
        }
        
        // Set mute behavior (don't mute original audio)
        tapDesc.muteBehavior = CATapUnmuted;
        
        // Create the tap - THIS WILL TRIGGER THE PERMISSION PROMPT!
        AudioObjectID tap_id = kAudioObjectUnknown;
        status = AudioHardwareCreateProcessTap(tapDesc, &tap_id);
        
        if (status != noErr || tap_id == kAudioObjectUnknown) {
            NSLog(@"AudioHardwareCreateProcessTap failed for PID %d with status %d", pid, (int)status);
            return false;
        }

        // Create ProcessTap structure
        size_t buffer_size = config_.buffer_frames * 2;
        auto process_tap = std::make_unique<ProcessTap>(
            pid,
            tap_id,
            config_.ringbuffer_capacity,
            buffer_size
        );
        
        process_taps_.push_back(std::move(process_tap));
        NSLog(@"✓ Created tap %u for PID %d", tap_id, pid);
        return true;
    }
}

std::vector<AudioObjectID> AudioTapManager::discover_audio_processes() {
    std::vector<AudioObjectID> result;
    
    AudioObjectPropertyAddress prop_addr{
        kAudioHardwarePropertyProcessObjectList,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    
    UInt32 data_size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(
        kAudioObjectSystemObject,
        &prop_addr,
        0,
        nullptr,
        &data_size
    );
    
    if (status != noErr || data_size == 0) {
        return result;
    }
    
    UInt32 count = data_size / sizeof(AudioObjectID);
    result.resize(count);
    
    status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &prop_addr,
        0,
        nullptr,
        &data_size,
        result.data()
    );
    
    if (status != noErr) {
        result.clear();
    }
    
    return result;
}

pid_t AudioTapManager::get_pid_from_audio_object(AudioObjectID obj_id) {
    AudioObjectPropertyAddress prop_addr{
        kAudioProcessPropertyPID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    
    pid_t pid = -1;
    UInt32 data_size = sizeof(pid);
    
    OSStatus status = AudioObjectGetPropertyData(
        obj_id,
        &prop_addr,
        0,
        nullptr,
        &data_size,
        &pid
    );
    
    return (status == noErr) ? pid : -1;
}

bool AudioTapManager::create_tap_for_system() {
    // For system-wide audio, create a stereo mixdown tap
    @autoreleasepool {
        // Create a stereo mixdown tap with empty process array for system-wide
        CATapDescription* tapDesc = [[CATapDescription alloc] initStereoMixdownOfProcesses:@[]];
        if (!tapDesc) {
            return false;
        }
        
        // Don't mute the system audio
        tapDesc.muteBehavior = CATapUnmuted;
        
        AudioObjectID tap_id = kAudioObjectUnknown;
        OSStatus status = AudioHardwareCreateProcessTap(tapDesc, &tap_id);
        
        if (status != noErr || tap_id == kAudioObjectUnknown) {
            NSLog(@"Failed to create system-wide tap, status: %d", (int)status);
            return false;
        }
        
        size_t buffer_size = config_.buffer_frames * 2;
        auto process_tap = std::make_unique<ProcessTap>(
            0,  // PID 0 = system-wide
            tap_id,
            config_.ringbuffer_capacity,
            buffer_size
        );
        
        process_taps_.push_back(std::move(process_tap));
        NSLog(@"✓ Created system-wide audio tap %u", tap_id);
        return true;
    }
}

bool AudioTapManager::create_aggregate_device(const std::vector<CFStringRef>& tap_uids) {
    CFMutableDictionaryRef device_dict = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    
    if (!device_dict) {
        return false;
    }

    // Generate unique UID for this aggregate device
    CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
    CFStringRef device_uid = CFUUIDCreateString(kCFAllocatorDefault, uuid);
    CFRelease(uuid);
    
    CFStringRef device_name = CFSTR("AudioTrace Tap Aggregate");
    CFDictionarySetValue(device_dict, CFSTR(kAudioAggregateDeviceNameKey), device_name);
    CFDictionarySetValue(device_dict, CFSTR(kAudioAggregateDeviceUIDKey), device_uid);
    
    // Make it private (not visible system-wide)
    int is_private_value = 1;
    CFNumberRef is_private = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &is_private_value);
    CFDictionarySetValue(device_dict, CFSTR(kAudioAggregateDeviceIsPrivateKey), is_private);
    CFRelease(is_private);
    
    // Disable stacking (we want taps as separate streams/buffers)
    int is_stacked_value = 0;
    CFNumberRef is_stacked = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &is_stacked_value);
    CFDictionarySetValue(device_dict, CFSTR(kAudioAggregateDeviceIsStackedKey), is_stacked);
    CFRelease(is_stacked);
    
    // Enable auto-start for taps
    int auto_start_value = 1;
    CFNumberRef auto_start = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &auto_start_value);
    CFDictionarySetValue(device_dict, CFSTR(kAudioAggregateDeviceTapAutoStartKey), auto_start);
    CFRelease(auto_start);
    
    // Add taps to aggregate device if we have any
    if (!tap_uids.empty()) {
        CFMutableArrayRef tap_list = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
        
        for (CFStringRef tap_uid : tap_uids) {
            // Create sub-tap dictionary with drift compensation enabled
            CFMutableDictionaryRef sub_tap = CFDictionaryCreateMutable(
                kCFAllocatorDefault,
                0,
                &kCFTypeDictionaryKeyCallBacks,
                &kCFTypeDictionaryValueCallBacks
            );
            
            CFDictionarySetValue(sub_tap, CFSTR(kAudioSubTapUIDKey), tap_uid);
            
            // Enable drift compensation
            int drift_comp_value = 1;
            CFNumberRef drift_comp = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &drift_comp_value);
            CFDictionarySetValue(sub_tap, CFSTR(kAudioSubTapDriftCompensationKey), drift_comp);
            CFRelease(drift_comp);
            
            CFArrayAppendValue(tap_list, sub_tap);
            CFRelease(sub_tap);
        }
        
        CFDictionarySetValue(device_dict, CFSTR(kAudioAggregateDeviceTapListKey), tap_list);
        CFRelease(tap_list);
    }

    OSStatus status = AudioHardwareCreateAggregateDevice(device_dict, &aggregate_device_id_);
    
    CFRelease(device_uid);
    CFRelease(device_dict);
    
    if (status != noErr) {
        NSLog(@"AudioHardwareCreateAggregateDevice failed with status %d", (int)status);
        return false;
    }
    
    NSLog(@"✅ Created aggregate device %u with %zu taps", aggregate_device_id_, tap_uids.size());
    
    return aggregate_device_id_ != kAudioObjectUnknown;
}

void AudioTapManager::destroy_aggregate_device() {
    if (aggregate_device_id_ != kAudioObjectUnknown) {
        // Destroy all taps first
        for (auto& tap : process_taps_) {
            if (tap->tap_id != kAudioObjectUnknown) {
                AudioHardwareDestroyProcessTap(tap->tap_id);
                tap->tap_id = kAudioObjectUnknown;
            }
        }
        
        // Then destroy the aggregate device
        AudioHardwareDestroyAggregateDevice(aggregate_device_id_);
        aggregate_device_id_ = kAudioObjectUnknown;
    }
}

}  // namespace AudioTrace
