#include "AudioTapManager.hpp"
#include "Logger.hpp"
#include <thread>
#include <algorithm>
#include <unordered_set>
#include <CoreFoundation/CoreFoundation.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>

namespace AudioTrace {

namespace {

// Debug mode environment variables
static bool debug_use_nil_device_uid() {
    static bool value = std::getenv("AUDIO_TRACE_DEBUG_NIL_DEVICE_UID") != nullptr;
    return value;
}

static bool debug_explicit_mixdown() {
    static bool value = std::getenv("AUDIO_TRACE_DEBUG_EXPLICIT_MIXDOWN") != nullptr;
    return value;
}

AudioObjectID default_output_device() {
    AudioObjectID device_id = kAudioObjectUnknown;
    UInt32 data_size = sizeof(device_id);
    AudioObjectPropertyAddress addr{
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    OSStatus status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &addr,
        0,
        nullptr,
        &data_size,
        &device_id
    );

    if (status != noErr) {
        Logger::warn("Failed to query default output device: {}", (int)status);
        return kAudioObjectUnknown;
    }
    return device_id;
}

void log_default_output_format() {
    AudioObjectID device = default_output_device();
    if (device == kAudioObjectUnknown) {
        return;
    }

    // Channel count
    AudioObjectPropertyAddress cfg_addr{
        kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    UInt32 data_size = 0;
    if (AudioObjectGetPropertyDataSize(device, &cfg_addr, 0, nullptr, &data_size) != noErr ||
        data_size == 0) {
        Logger::warn("Failed to query output stream configuration");
        return;
    }

    std::vector<uint8_t> buffer(data_size);
    auto* buf_list = reinterpret_cast<AudioBufferList*>(buffer.data());
    if (AudioObjectGetPropertyData(device, &cfg_addr, 0, nullptr, &data_size, buf_list) != noErr) {
        Logger::warn("Failed to read output stream configuration");
        return;
    }

    uint32_t channels = 0;
    for (UInt32 i = 0; i < buf_list->mNumberBuffers; ++i) {
        channels += buf_list->mBuffers[i].mNumberChannels;
    }

    // Sample rate
    Float64 sample_rate = 0;
    data_size = sizeof(sample_rate);
    AudioObjectPropertyAddress rate_addr{
        kAudioDevicePropertyNominalSampleRate,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(device, &rate_addr, 0, nullptr, &data_size, &sample_rate) != noErr) {
        Logger::warn("Failed to read output sample rate");
        return;
    }

    Logger::info("Default output device {}: sample_rate={:.1f} Hz, channels={} (buffers={})",
          device, sample_rate, channels, buf_list->mNumberBuffers);
}

void log_tap_format(AudioObjectID tap_id, pid_t pid) {
    AudioStreamBasicDescription fmt{};
    UInt32 size = sizeof(fmt);
    AudioObjectPropertyAddress addr{
        kAudioTapPropertyFormat,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    if (AudioObjectGetPropertyData(tap_id, &addr, 0, nullptr, &size, &fmt) == noErr) {
        Logger::info("Tap {} (PID {}) format: {:.1f} Hz, channels={}, bytes/frame={}, flags=0x{:08x}",
              tap_id,
              pid,
              fmt.mSampleRate,
              fmt.mChannelsPerFrame,
              fmt.mBytesPerFrame,
              (unsigned int)fmt.mFormatFlags);
    } else {
        Logger::warn("Failed to read format for tap {} (PID {})", tap_id, pid);
    }
}

NSString* default_output_device_uid_string() {
    AudioObjectID device = default_output_device();
    if (device == kAudioObjectUnknown) {
        return nil;
    }
    
    CFStringRef uid_string = nullptr;
    UInt32 data_size = sizeof(uid_string);
    AudioObjectPropertyAddress addr{
        kAudioDevicePropertyDeviceUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    
    if (AudioObjectGetPropertyData(device, &addr, 0, nullptr, &data_size, &uid_string) != noErr || !uid_string) {
        Logger::warn("Failed to read UID for default output device {}", device);
        return nil;
    }
    NSString* ns = [NSString stringWithString:(__bridge NSString*)uid_string];
    CFRelease(uid_string);
    return ns;
}

}  // namespace

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

OSStatus AudioTapManager::process_list_listener(
    AudioObjectID inObjectID,
    UInt32 inNumberAddresses,
    const AudioObjectPropertyAddress inAddresses[],
    void* inClientData)
{
    auto* manager = static_cast<AudioTapManager*>(inClientData);
    if (!manager) {
        return noErr;
    }
    
    Logger::info("Process list changed - checking for new audio processes");
    manager->check_for_new_processes();
    
    return noErr;
}

void AudioTapManager::register_process_list_listener() {
    if (process_list_listener_registered_) {
        return;
    }
    
    AudioObjectPropertyAddress addr{
        kAudioHardwarePropertyProcessObjectList,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    
    OSStatus status = AudioObjectAddPropertyListener(
        kAudioObjectSystemObject,
        &addr,
        process_list_listener,
        this
    );
    
    if (status == noErr) {
        process_list_listener_registered_ = true;
        Logger::info("Registered listener for new audio processes");
    } else {
        Logger::warn("Failed to register process list listener: {}", (int)status);
    }
}

void AudioTapManager::unregister_process_list_listener() {
    if (!process_list_listener_registered_) {
        return;
    }
    
    AudioObjectPropertyAddress addr{
        kAudioHardwarePropertyProcessObjectList,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    
    AudioObjectRemovePropertyListener(
        kAudioObjectSystemObject,
        &addr,
        process_list_listener,
        this
    );
    
    process_list_listener_registered_ = false;
    Logger::debug("Unregistered process list listener");
}

void AudioTapManager::check_for_new_processes() {
    if (!is_running_ || debug_single_pid_ > 0) {
        return;
    }
    
    // Prevent concurrent rebuilds
    if (rebuild_in_progress_.load(std::memory_order_acquire)) {
        Logger::debug("Rebuild already in progress, ignoring process list change");
        return;
    }
    
    auto current_processes = discover_audio_processes();
    if (current_processes.empty()) {
        return;
    }
    
    // Get PIDs we're already monitoring
    std::unordered_set<pid_t> monitored_pids;
    for (const auto& tap : process_taps_) {
        monitored_pids.insert(tap->pid);
    }
    
    // Find new processes
    std::vector<pid_t> new_pids;
    for (AudioObjectID obj_id : current_processes) {
        pid_t pid = get_pid_from_audio_object(obj_id);
        if (pid > 0 && !monitored_pids.count(pid)) {
            new_pids.push_back(pid);
        }
    }
    
    if (!new_pids.empty()) {
        Logger::info("Found {} new audio process(es)", new_pids.size());
        for (pid_t pid : new_pids) {
            Logger::info("  New PID: {}", pid);
        }
        
        rebuild_taps_if_needed();
    }
}

bool AudioTapManager::rebuild_taps_if_needed() {
    // Set flag to prevent concurrent rebuilds
    bool expected = false;
    if (!rebuild_in_progress_.compare_exchange_strong(expected, true, std::memory_order_acquire)) {
        Logger::warn("Rebuild already in progress, skipping");
        return false;
    }
    
    Logger::info("Rebuilding audio taps to include new processes");
    
    // Unregister listener to prevent recursive triggers during rebuild
    unregister_process_list_listener();
    
    // Stop the current setup
    if (io_proc_id_ != nullptr) {
        AudioDeviceStop(aggregate_device_id_, io_proc_id_);
        AudioDeviceDestroyIOProcID(aggregate_device_id_, io_proc_id_);
        io_proc_id_ = nullptr;
    }
    
    destroy_aggregate_device();
    process_taps_.clear();
    
    // Wait for Core Audio to fully clean up the old taps
    // The system needs time to release resources before creating new taps
    Logger::debug("Waiting for tap cleanup...");
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    
    // Rediscover and create taps for all current processes
    auto process_objects = discover_audio_processes();
    if (process_objects.empty()) {
        Logger::warn("No audio processes found during rebuild");
        rebuild_in_progress_.store(false, std::memory_order_release);
        return false;
    }
    
    std::unordered_set<pid_t> seen;
    for (AudioObjectID obj_id : process_objects) {
        pid_t pid = get_pid_from_audio_object(obj_id);
        if (pid > 0 && !seen.count(pid)) {
            seen.insert(pid);
            Logger::info("Creating tap for PID {} during rebuild", pid);
            create_tap_for_process(pid);
        }
    }
    
    if (process_taps_.empty()) {
        Logger::error("Failed to create any process taps during rebuild");
        rebuild_in_progress_.store(false, std::memory_order_release);
        return false;
    }
    
    // Collect tap UIDs
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
    
    // Create new aggregate device
    if (!create_aggregate_device(tap_uids)) {
        for (auto uid : tap_uids) {
            if (uid) CFRelease(uid);
        }
        rebuild_in_progress_.store(false, std::memory_order_release);
        return false;
    }
    
    for (auto uid : tap_uids) {
        if (uid) CFRelease(uid);
    }
    
    // Wait for device to be ready
    if (!wait_for_device_ready(aggregate_device_id_, 2.0)) {
        Logger::warn("Aggregate device did not become ready after rebuild");
    }
    
    // Register IOProc callback
    OSStatus status = AudioDeviceCreateIOProcID(
        aggregate_device_id_,
        audio_io_proc,
        this,
        &io_proc_id_
    );
    
    if (status != noErr) {
        Logger::error("Failed to create IOProcID after rebuild: {}", status);
        rebuild_in_progress_.store(false, std::memory_order_release);
        return false;
    }
    
    // Start the device
    status = AudioDeviceStart(aggregate_device_id_, io_proc_id_);
    if (status != noErr) {
        Logger::error("Failed to start aggregate device after rebuild: {}", status);
        rebuild_in_progress_.store(false, std::memory_order_release);
        return false;
    }
    
    // Re-register listener for future changes
    register_process_list_listener();
    
    Logger::info("Successfully rebuilt taps - now monitoring {} processes", process_taps_.size());
    rebuild_in_progress_.store(false, std::memory_order_release);
    return true;
}


bool AudioTapManager::start() {
    if (is_running_) {
        return false;
    }

    // Debug controls from environment
    debug_log_buffers_ = std::getenv("AUDIO_TRACE_DEBUG_LOG_BUFFERS") != nullptr;
    if (const char* pid_str = std::getenv("AUDIO_TRACE_DEBUG_SINGLE_PID")) {
        debug_single_pid_ = static_cast<pid_t>(std::atoi(pid_str));
    } else {
        debug_single_pid_ = -1;
    }

    if (debug_log_buffers_) {
        Logger::debug("Debug logging for buffers is enabled (AUDIO_TRACE_DEBUG_LOG_BUFFERS=1)");
    }
    if (debug_single_pid_ > 0) {
        Logger::debug("Debug mode: single PID tap = {} (AUDIO_TRACE_DEBUG_SINGLE_PID)", debug_single_pid_);
    }

    log_default_output_format();
    if (debug_log_buffers_) {
        log_available_audio_processes();
    }

    // Step 1: Discover and create process taps
    std::vector<AudioObjectID> process_objects;

    if (debug_single_pid_ > 0) {
        if (!create_tap_for_process(debug_single_pid_)) {
            Logger::error("Failed to create tap for debug PID {}", debug_single_pid_);
            return false;
        }
    } else {
        process_objects = discover_audio_processes();
    }

    if (!process_objects.empty() && process_taps_.empty()) {
        // Create taps for discovered processes
        std::unordered_set<pid_t> seen;
        for (AudioObjectID obj_id : process_objects) {
            pid_t pid = get_pid_from_audio_object(obj_id);
            if (pid > 0 && !seen.count(pid)) {
                seen.insert(pid);
                Logger::info("Creating tap for PID {}", pid);
                create_tap_for_process(pid);
            }
        }
    }
    
    if (process_taps_.empty() && debug_single_pid_ <= 0) {
        Logger::error("Failed to create any process taps");
        return false;
    }

    if (debug_log_buffers_) {
        for (size_t i = 0; i < process_taps_.size(); ++i) {
            Logger::debug("Tap map: buffer index {} -> PID {} (tap {})",
                  i, process_taps_[i]->pid, process_taps_[i]->tap_id);
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

    // Step 3.5: Wait for aggregate device to become ready
    // Based on AudioTee Swift implementation - device needs time to initialize
    if (!wait_for_device_ready(aggregate_device_id_, 2.0)) {
        Logger::warn("Aggregate device did not become ready, proceeding anyway...");
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
        Logger::error("Failed to create IOProcID: {}", status);
        stop();
        return false;
    }

    // Step 6: Start the aggregate device
    status = AudioDeviceStart(aggregate_device_id_, io_proc_id_);
    if (status != noErr) {
        Logger::error("Failed to start aggregate device: {}", status);
        AudioDeviceDestroyIOProcID(aggregate_device_id_, io_proc_id_);
        io_proc_id_ = nullptr;
        stop();
        return false;
    }

    Logger::info("Started aggregate device with {} taps", process_taps_.size());
    is_running_ = true;
    
    // Register listener for new audio processes
    register_process_list_listener();
    
    return true;
}

void AudioTapManager::stop() {
    if (!is_running_) {
        return;
    }

    // Unregister process list listener
    unregister_process_list_listener();

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

void AudioTapManager::cache_window_title(pid_t pid, const std::string& title) {
    tracker_.cache_window_title(pid, title);
}

void AudioTapManager::worker_thread_proc() {
    Logger::debug("Worker thread started, taps={}", process_taps_.size());
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
                    Logger::trace("Sample {}: PID {}, RMS={:.9f} (threshold=0.005)", 
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
                    
                    Logger::trace("Activity! PID {}, RMS: {:.6f}", data.pid, event->rms_level);
                    
                    // Also call user callback if set
                    if (audio_callback_) {
                        audio_callback_(data);
                    }
                }
                
                did_work = true;
            }
        }
        
        if (pops_this_loop > 0 && loop_count % 50 == 0) {
            Logger::trace("Loop {}: popped {} buffers (total={})", loop_count, pops_this_loop, total_pops);
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
        Logger::trace("Audio callback fired {} times, {} buffers", 
              count, inInputData->mNumberBuffers);
        
        // Debug: Check first buffer's data
        if (inInputData->mNumberBuffers > 0) {
            const AudioBuffer& buf = inInputData->mBuffers[0];
            Logger::trace("  Buffer 0: channels={}, dataSize={} bytes", 
                  buf.mNumberChannels, buf.mDataByteSize);
            
            if (buf.mData && buf.mDataByteSize >= sizeof(float) * 4) {
                const float* samples = static_cast<const float*>(buf.mData);
                Logger::trace("  First samples: {:.6f}, {:.6f}, {:.6f}, {:.6f}", 
                      samples[0], samples[1], samples[2], samples[3]);
            }
        }
    }

    // Optional verbose debug: log first samples of every buffer for first few callbacks
    if (manager->debug_log_buffers_ && count <= 20) {
        for (UInt32 i = 0; i < inInputData->mNumberBuffers; ++i) {
            const AudioBuffer& buf = inInputData->mBuffers[i];
            if (buf.mData && buf.mDataByteSize >= sizeof(float) * 4) {
                const float* samples = static_cast<const float*>(buf.mData);
                Logger::trace("  [buf {}] ch={} size={} first4={:.6f}, {:.6f}, {:.6f}, {:.6f}",
                      (unsigned)i,
                      buf.mNumberChannels,
                      buf.mDataByteSize,
                      samples[0], samples[1], samples[2], samples[3]);
            } else {
                Logger::trace("  [buf {}] ch={} size={} (no data)", (unsigned)i, buf.mNumberChannels, buf.mDataByteSize);
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

    static int map_log_counter = 0;
    if (debug_log_buffers_ && map_log_counter < 5) {
        Logger::trace("Mapping {} buffers to {} taps", num_buffers, process_taps_.size());
    }
    
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

        if (debug_log_buffers_ && map_log_counter < 5) {
            float first = (buffer.mDataByteSize >= sizeof(float)) ? samples[0] : 0.0f;
            Logger::trace("    [map] buf {} -> PID {}, ch={} frames={} first={:.6f}",
                  i, tap->pid, channel_count, frame_count, first);
        }
        
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
                Logger::warn("Dropped {} buffers (ring buffer full)", drop_count.load());
            }
        }
    }
    if (debug_log_buffers_ && map_log_counter < 5) {
        map_log_counter++;
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
        AudioObjectID process_obj_id = find_process_object_for_pid(pid);
        if (process_obj_id == kAudioObjectUnknown) {
            Logger::error("Failed to find audio process object for PID {}", pid);
            return false;
        }
        
        // Create array of process AudioObjectIDs
        NSNumber* processID = @(process_obj_id);
        NSArray<NSNumber*>* processes = @[processID];

        // OPTION 1 TEST: Always use initStereoMixdownOfProcesses
        // This is the key - use the mixdown initializer for single-process taps
        Logger::debug("Creating stereo mixdown tap for single process (PID {}, obj {})", pid, process_obj_id);
        CATapDescription* tapDesc = [[CATapDescription alloc] initStereoMixdownOfProcesses:processes];
        
        if (!tapDesc) {
            Logger::error("Failed to create tap descriptor for PID {}", pid);
            return false;
        }
        
        // These properties should already be set by the initializer, but set them explicitly to be safe
        tapDesc.exclusive = NO;
        tapDesc.muteBehavior = CATapUnmuted;
        tapDesc.privateTap = YES;
        
        // Create the tap - THIS WILL TRIGGER THE PERMISSION PROMPT!
        AudioObjectID tap_id = kAudioObjectUnknown;
        OSStatus status = noErr;
        
        // Retry, Core Audio may not be ready immediately after cleanup
        const int max_retries = 3;
        for (int attempt = 0; attempt < max_retries; ++attempt) {
            if (attempt > 0) {
                std::this_thread::sleep_for(std::chrono::milliseconds(200));
            }
            
            status = AudioHardwareCreateProcessTap(tapDesc, &tap_id);
            
            if (status == noErr && tap_id != kAudioObjectUnknown) {
                break; // Success!
            }
            
            if (attempt < max_retries - 1) {
                Logger::debug("Tap creation returned status={} tap_id={}, retrying...", 
                             (int)status, tap_id);
            }
        }
        
        if (status != noErr || tap_id == kAudioObjectUnknown) {
            Logger::error("AudioHardwareCreateProcessTap failed for PID {} after {} attempts (status={})", 
                         pid, max_retries, (int)status);
            return false;
        }
        
        // Verify tap format (Step 4 from design doc)
        AudioStreamBasicDescription fmt{};
        UInt32 size = sizeof(fmt);
        AudioObjectPropertyAddress fmt_addr{
            kAudioTapPropertyFormat,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        if (AudioObjectGetPropertyData(tap_id, &fmt_addr, 0, nullptr, &size, &fmt) == noErr) {
            Logger::debug("Tap format: rate={:.0f}, channels={}, bytesPerFrame={}, formatFlags=0x{:x}",
                  fmt.mSampleRate, fmt.mChannelsPerFrame, fmt.mBytesPerFrame, fmt.mFormatFlags);
            
            // CRITICAL: Verify this is NOT zero or invalid
            if (fmt.mSampleRate == 0 || fmt.mChannelsPerFrame == 0) {
                Logger::error("INVALID tap format detected! rate={:.0f} channels={}",
                      fmt.mSampleRate, fmt.mChannelsPerFrame);
            }
        } else {
            Logger::warn("Could not get tap format for verification");
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
        Logger::info("Created tap {} for PID {}", tap_id, pid);
        log_tap_format(tap_id, pid);
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

AudioObjectID AudioTapManager::find_process_object_for_pid(pid_t pid) {
    auto process_objects = discover_audio_processes();
    for (AudioObjectID obj_id : process_objects) {
        if (get_pid_from_audio_object(obj_id) == pid) {
            return obj_id;
        }
    }
    return kAudioObjectUnknown;
}

void AudioTapManager::log_available_audio_processes() {
    auto process_objects = discover_audio_processes();
    if (process_objects.empty()) {
        Logger::info("No audio process objects found");
        return;
    }

    Logger::info("Audio process objects:");
    for (AudioObjectID obj_id : process_objects) {
        pid_t pid = get_pid_from_audio_object(obj_id);
        Logger::info("    - obj={} pid={}", obj_id, pid);
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
    
    // SoundPusher comment: "it seems we only need the tap, not the actual device in there"
    // Try without main sub-device or sub-device list for macOS 15+
    
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
    
    // Disable auto-start for taps (we start via IOProc)
    int auto_start_value = 0;
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
        Logger::error("AudioHardwareCreateAggregateDevice failed with status {}", (int)status);
        return false;
    }
    
    Logger::info("Created aggregate device {} with {} taps", aggregate_device_id_, tap_uids.size());
    
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

bool AudioTapManager::wait_for_device_ready(AudioObjectID device_id, double timeout_seconds) {
    // Based on AudioTee Swift implementation
    // Poll device readiness with 100ms intervals
    const double poll_interval = 0.1;  // 100ms
    const int max_polls = static_cast<int>(timeout_seconds / poll_interval);
    
    Logger::debug("Waiting for device {} to become ready...", device_id);
    
    AudioObjectPropertyAddress addr{
        kAudioDevicePropertyDeviceIsAlive,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    
    for (int poll = 1; poll <= max_polls; ++poll) {
        UInt32 is_alive = 0;
        UInt32 size = sizeof(is_alive);
        OSStatus status = AudioObjectGetPropertyData(
            device_id,
            &addr,
            0,
            nullptr,
            &size,
            &is_alive
        );
        
        if (status == noErr && is_alive == 1) {
            Logger::debug("Device {} ready after {} polls ({:.1f}s)", 
                  device_id, poll, poll * poll_interval);
            return true;
        }
        
        if (poll < max_polls) {
            std::this_thread::sleep_for(
                std::chrono::milliseconds(static_cast<int>(poll_interval * 1000))
            );
        }
    }
    
    Logger::warn("Device {} did not become ready within {:.1f}s", device_id, timeout_seconds);
    return false;
}

}  // namespace AudioTrace
