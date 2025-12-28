#include "AudioTapManager.hpp"
#include "Logger.hpp"
#include <mutex>
#include <thread>
#include <algorithm>
#include <unordered_set>
#include <array>
#include <CoreFoundation/CoreFoundation.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#include <libproc.h>
#include <sys/sysctl.h>

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
        AUDIOTRACE_LOG_WARN("Failed to query default output device: {}", (int)status);
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
        AUDIOTRACE_LOG_WARN("Failed to query output stream configuration");
        return;
    }

    std::vector<uint8_t> buffer(data_size);
    auto* buf_list = reinterpret_cast<AudioBufferList*>(buffer.data());
    if (AudioObjectGetPropertyData(device, &cfg_addr, 0, nullptr, &data_size, buf_list) != noErr) {
        AUDIOTRACE_LOG_WARN("Failed to read output stream configuration");
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
        AUDIOTRACE_LOG_WARN("Failed to read output sample rate");
        return;
    }

    AUDIOTRACE_LOG_INFO("Default output device {}: sample_rate={:.1f} Hz, channels={} (buffers={})",
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
        AUDIOTRACE_LOG_INFO("Tap {} (PID {}) format: {:.1f} Hz, channels={}, bytes/frame={}, flags=0x{:08x}",
              tap_id,
              pid,
              fmt.mSampleRate,
              fmt.mChannelsPerFrame,
              fmt.mBytesPerFrame,
              (unsigned int)fmt.mFormatFlags);
    } else {
        AUDIOTRACE_LOG_WARN("Failed to read format for tap {} (PID {})", tap_id, pid);
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
        AUDIOTRACE_LOG_WARN("Failed to read UID for default output device {}", device);
        return nil;
    }
    NSString* ns = [NSString stringWithString:(__bridge NSString*)uid_string];
    CFRelease(uid_string);
    return ns;
}

}  // namespace

std::string AudioTapManager::osstatus_to_string(OSStatus status) {
    char fourcc[5] = {0};
    *reinterpret_cast<OSStatus*>(fourcc) = status;
    bool printable = true;
    for (int i = 0; i < 4; ++i) {
        if (fourcc[i] < 32 || fourcc[i] > 126) {
            printable = false;
            break;
        }
    }
    if (printable) {
        return std::string(fourcc, 4);
    }
    return std::to_string(status);
}

std::string AudioTapManager::pid_path(pid_t pid) {
    std::array<char, PROC_PIDPATHINFO_MAXSIZE> buf{};
    int ret = proc_pidpath(pid, buf.data(), buf.size());
    if (ret > 0) {
        return std::string(buf.data());
    }
    return "<unknown>";
}

pid_t AudioTapManager::get_parent_pid(pid_t pid) {
    struct kinfo_proc info{};
    size_t length = sizeof(info);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    
    if (sysctl(mib, 4, &info, &length, NULL, 0) == 0) {
        return info.kp_eproc.e_ppid;
    }
    return -1;
}

AudioTapManager::AudioTapManager(Config config)
    : config_(config)
    , analyzer_(AudioAnalyzer::Config{
        .silence_threshold_rms = 0.001f,  // ~-60dB
        .active_threshold_rms = 0.005f,   // ~-46dB (hysteresis)
        .window_frames = 2048
      })
    , tracker_(ActivityTracker::Config{
        .current_threshold = std::chrono::milliseconds(500),
        .expiry_time = std::chrono::minutes(10)
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
    
    AUDIOTRACE_LOG_INFO("Process list changed - checking for new audio processes");
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
        AUDIOTRACE_LOG_INFO("Registered listener for new audio processes");
    } else {
        AUDIOTRACE_LOG_WARN("Failed to register process list listener: {}", (int)status);
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
    AUDIOTRACE_LOG_DEBUG("Unregistered process list listener");
}

void AudioTapManager::check_for_new_processes() {
    if (!is_running_ || debug_single_pid_ > 0) {
        return;
    }
    
    // If a rebuild is already running, skip; the poller will recheck shortly.
    if (rebuild_in_progress_.load(std::memory_order_acquire)) {
        return;
    }
    
    auto current_processes = discover_audio_processes();
    if (current_processes.empty()) {
        return;
    }
    
    // Get PIDs we're already monitoring
    std::unordered_set<pid_t> monitored_pids;
    {
        std::scoped_lock lock(process_taps_mutex_);
        for (const auto& tap : process_taps_) {
            monitored_pids.insert(tap->pid);
        }
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
        AUDIOTRACE_LOG_INFO("Found {} new audio process(es)", new_pids.size());
        for (pid_t pid : new_pids) {
            AUDIOTRACE_LOG_INFO("  New PID: {}", pid);
        }
        // Always record that a rebuild is needed; caller will coalesce requests.
        rebuild_requested_.store(true, std::memory_order_release);
        full_reset_requested_.store(true, std::memory_order_release);
        rebuild_taps_if_needed();
    }
}

bool AudioTapManager::rebuild_taps_if_needed() {
    bool any_rebuild = false;
    bool last_result = false;
    
    while (true) {
        // Set flag to prevent concurrent rebuilds
        bool expected = false;
        if (!rebuild_in_progress_.compare_exchange_strong(expected, true, std::memory_order_acquire)) {
            // Another rebuild is in flight; coalesce this request.
            rebuild_requested_.store(true, std::memory_order_release);
            return any_rebuild ? last_result : false;
        }
        
        // We own the rebuild now; clear the request flag for this iteration.
        rebuild_requested_.store(false, std::memory_order_release);
        any_rebuild = true;
        
        AUDIOTRACE_LOG_INFO("Rebuilding audio taps to include new processes");
        
        // Unregister listener to prevent recursive triggers during rebuild
        unregister_process_list_listener();
        
        // Stop the IOProc, but keep existing taps alive
        AudioDeviceID old_device_id = aggregate_device_id_;
        if (io_proc_id_ != nullptr) {
            AudioDeviceStop(old_device_id, io_proc_id_);
            AudioDeviceDestroyIOProcID(old_device_id, io_proc_id_);
            io_proc_id_ = nullptr;
            
            AUDIOTRACE_LOG_DEBUG("Waiting for device to stop...");
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
        }
        
        // Rediscover all audio processes
        auto process_objects = discover_audio_processes();
        if (process_objects.empty()) {
            AUDIOTRACE_LOG_WARN("No audio processes found during rebuild");
            register_process_list_listener();
            last_result = false;
            rebuild_in_progress_.store(false, std::memory_order_release);
            if (rebuild_requested_.exchange(false, std::memory_order_acq_rel)) {
                continue;
            }
            return last_result;
        }

        // Create taps for missing PIDs (keep existing taps)
        std::unordered_set<pid_t> seen;
        int failed_tap_count = 0;
        for (AudioObjectID obj_id : process_objects) {
            pid_t pid = get_pid_from_audio_object(obj_id);
            if (pid <= 0 || seen.count(pid)) continue;
            seen.insert(pid);
            
            auto already_tapped = [&](pid_t test_pid) {
                std::scoped_lock lock(process_taps_mutex_);
                for (const auto& tap : process_taps_) {
                    if (tap->pid == test_pid) {
                        return true;
                    }
                }
                return false;
            };
            
            if (already_tapped(pid)) {
                continue;
            }
            
            AUDIOTRACE_LOG_INFO("Creating tap for PID {} during rebuild (full reset)", pid);
            if (!create_tap_for_process(pid)) {
                failed_tap_count++;
            }
        }
        
        if (failed_tap_count > 0) {
            AUDIOTRACE_LOG_INFO("Tap creation failed for {} process(es) during rebuild", failed_tap_count);
        }
        
        // Collect tap UIDs from taps (existing + new)
        std::vector<CFStringRef> tap_uids;
        {
            std::scoped_lock lock(process_taps_mutex_);
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
        }
        
        if (tap_uids.empty()) {
            register_process_list_listener();
            AUDIOTRACE_LOG_WARN("No tap UIDs collected after rebuild");
            last_result = false;
            rebuild_in_progress_.store(false, std::memory_order_release);
            if (rebuild_requested_.exchange(false, std::memory_order_acq_rel)) {
                continue;
            }
            return last_result;
        }
            
        // Create new aggregate device
        if (!create_aggregate_device(tap_uids)) {
            for (auto uid : tap_uids) {
                if (uid) CFRelease(uid);
            }
            last_result = false;
            register_process_list_listener();
            rebuild_in_progress_.store(false, std::memory_order_release);
            if (rebuild_requested_.exchange(false, std::memory_order_acq_rel)) {
                continue;
            }
            return last_result;
        }
        
        for (auto uid : tap_uids) {
            if (uid) CFRelease(uid);
        }
        
        // Wait for device to be ready
        if (!wait_for_device_ready(aggregate_device_id_, 2.0)) {
            AUDIOTRACE_LOG_WARN("Aggregate device did not become ready after rebuild");
        }
        
        // Register IOProc callback
        OSStatus status = AudioDeviceCreateIOProcID(
            aggregate_device_id_,
            audio_io_proc,
            this,
            &io_proc_id_
        );
        
        if (status != noErr) {
            AUDIOTRACE_LOG_ERROR("Failed to create IOProcID after rebuild: {}", status);
            last_result = false;
            rebuild_in_progress_.store(false, std::memory_order_release);
            if (rebuild_requested_.exchange(false, std::memory_order_acq_rel)) {
                continue;
            }
            return last_result;
        }
        
        // Start the device
        status = AudioDeviceStart(aggregate_device_id_, io_proc_id_);
        if (status != noErr) {
            AUDIOTRACE_LOG_ERROR("Failed to start aggregate device after rebuild: {}", status);
            last_result = false;
            rebuild_in_progress_.store(false, std::memory_order_release);
            if (rebuild_requested_.exchange(false, std::memory_order_acq_rel)) {
                continue;
            }
            return last_result;
        }
        
        // Destroy the previous aggregate device now that the new one is running
        if (old_device_id != kAudioObjectUnknown && old_device_id != aggregate_device_id_) {
            AudioHardwareDestroyAggregateDevice(old_device_id);
        }
        
        // Re-register listener for future changes
        register_process_list_listener();
        
        {
            std::scoped_lock lock(process_taps_mutex_);
            AUDIOTRACE_LOG_INFO("Successfully rebuilt taps - now monitoring {} processes", process_taps_.size());
        }
        last_result = true;
        rebuild_in_progress_.store(false, std::memory_order_release);
        
        // If another rebuild was requested during this run, loop again immediately
        if (rebuild_requested_.exchange(false, std::memory_order_acq_rel)) {
            continue;
        }
        
        return last_result;
    }
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
        AUDIOTRACE_LOG_DEBUG("Debug logging for buffers is enabled (AUDIO_TRACE_DEBUG_LOG_BUFFERS=1)");
    }
    if (debug_single_pid_ > 0) {
        AUDIOTRACE_LOG_DEBUG("Debug mode: single PID tap = {} (AUDIO_TRACE_DEBUG_SINGLE_PID)", debug_single_pid_);
    }

    log_default_output_format();
    if (debug_log_buffers_) {
        log_available_audio_processes();
    }

    // Step 1: Discover and create process taps
    std::vector<AudioObjectID> process_objects;

    if (debug_single_pid_ > 0) {
        if (!create_tap_for_process(debug_single_pid_)) {
            AUDIOTRACE_LOG_ERROR("Failed to create tap for debug PID {}", debug_single_pid_);
            return false;
        }
    } else {
        process_objects = discover_audio_processes();
    }

    // Create taps for discovered processes (don't hold lock during creation)
    if (!process_objects.empty()) {
        bool should_create_taps = false;
        {
            std::scoped_lock lock(process_taps_mutex_);
            should_create_taps = process_taps_.empty();
        }
        
        if (should_create_taps) {
            std::unordered_set<pid_t> seen;
            for (AudioObjectID obj_id : process_objects) {
                pid_t pid = get_pid_from_audio_object(obj_id);
                if (pid > 0 && !seen.count(pid)) {
                    seen.insert(pid);
                    AUDIOTRACE_LOG_INFO("Creating tap for PID {}", pid);
                    create_tap_for_process(pid);
                }
            }
        }
    }
    
    {
        std::scoped_lock lock(process_taps_mutex_);
        if (process_taps_.empty() && debug_single_pid_ <= 0) {
            AUDIOTRACE_LOG_ERROR("Failed to create any process taps");
            return false;
        }
    }

    if (debug_log_buffers_) {
        std::scoped_lock lock(process_taps_mutex_);
        for (size_t i = 0; i < process_taps_.size(); ++i) {
            AUDIOTRACE_LOG_DEBUG("Tap map: buffer index {} -> PID {} (tap {})",
                  i, process_taps_[i]->pid, process_taps_[i]->tap_id);
        }
    }
    
    // Step 2: Collect tap UIDs for aggregate device
    std::vector<CFStringRef> tap_uids;
    {
        std::scoped_lock lock(process_taps_mutex_);
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
        AUDIOTRACE_LOG_WARN("Aggregate device did not become ready, proceeding anyway...");
    }

    // Step 4: Start worker thread
    worker_should_stop_.store(false, std::memory_order_release);
    worker_thread_ = std::make_unique<std::thread>(
        &AudioTapManager::worker_thread_proc, this
    );
    
    // Start monitor thread to poll for late process objects
    monitor_should_stop_.store(false, std::memory_order_release);
    monitor_thread_ = std::make_unique<std::thread>(
        &AudioTapManager::poller_thread_proc, this
    );

    // Step 5: Register IOProc callback for aggregate device
    OSStatus status = AudioDeviceCreateIOProcID(
        aggregate_device_id_,
        audio_io_proc,
        this,
        &io_proc_id_
    );
    
    if (status != noErr) {
        AUDIOTRACE_LOG_ERROR("Failed to create IOProcID: {}", status);
        stop();
        return false;
    }

    // Step 6: Start the aggregate device
    status = AudioDeviceStart(aggregate_device_id_, io_proc_id_);
    if (status != noErr) {
        AUDIOTRACE_LOG_ERROR("Failed to start aggregate device: {}", status);
        AudioDeviceDestroyIOProcID(aggregate_device_id_, io_proc_id_);
        io_proc_id_ = nullptr;
        stop();
        return false;
    }

    {
        std::scoped_lock lock(process_taps_mutex_);
        AUDIOTRACE_LOG_INFO("Started aggregate device with {} taps", process_taps_.size());
    }
    is_running_ = true;
    
    // Register listener for new audio processes
    register_process_list_listener();
    
    return true;
}

void AudioTapManager::stop() {
    if (!is_running_) {
        return;
    }

    monitor_should_stop_.store(true, std::memory_order_release);

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
    
    if (monitor_thread_ && monitor_thread_->joinable()) {
        monitor_thread_->join();
    }
    monitor_thread_.reset();

    // Destroy aggregate device and taps
    {
        std::scoped_lock lock(process_taps_mutex_);
        destroy_aggregate_device();
        process_taps_.clear();
    }
    is_running_ = false;
}

void AudioTapManager::set_audio_callback(AudioCallback callback) {
    audio_callback_ = std::move(callback);
}

std::vector<pid_t> AudioTapManager::get_tapped_processes() const {
    std::scoped_lock lock(process_taps_mutex_);
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
    {
        std::scoped_lock lock(process_taps_mutex_);
        AUDIOTRACE_LOG_DEBUG("Worker thread started, taps={}", process_taps_.size());
    }
    int loop_count = 0;
    int total_pops = 0;
    int samples_checked = 0;
    
    while (!worker_should_stop_.load(std::memory_order_acquire)) {
        bool did_work = false;
        int pops_this_loop = 0;

        // Lock briefly to get tap pointers, then process without holding lock
        std::vector<ProcessTap*> taps_snapshot;
        {
            std::scoped_lock lock(process_taps_mutex_);
            taps_snapshot.reserve(process_taps_.size());
            for (const auto& tap : process_taps_) {
                taps_snapshot.push_back(tap.get());
            }
        }
        
        for (auto* tap : taps_snapshot) {
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
                    AUDIOTRACE_LOG_TRACE("Sample {}: PID {}, RMS={:.9f} (threshold=0.005)", 
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
                    
                    AUDIOTRACE_LOG_TRACE("Activity! PID {}, RMS: {:.6f}", data.pid, event->rms_level);
                    
                    // Also call user callback if set
                    if (audio_callback_) {
                        audio_callback_(data);
                    }
                }
                
                did_work = true;
            }
        }
        
        if (pops_this_loop > 0 && loop_count % 50 == 0) {
            AUDIOTRACE_LOG_TRACE("Loop {}: popped {} buffers (total={})", loop_count, pops_this_loop, total_pops);
        }
        
        loop_count++;

        if (!did_work) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        // Periodically cleanup expired entries
        static int cleanup_counter = 0;
        if (++cleanup_counter > 100) {
            tracker_.cleanup_expired();
            cleanup_counter = 0;
        }
    }
}

void AudioTapManager::poller_thread_proc() {
    while (!monitor_should_stop_.load(std::memory_order_acquire)) {
        std::this_thread::sleep_for(std::chrono::seconds(1));
        if (monitor_should_stop_.load(std::memory_order_acquire)) {
            break;
        }
        // Poll for new processes in case CoreAudio didn't fire a listener event
        check_for_new_processes();
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
        AUDIOTRACE_LOG_TRACE("Audio callback fired {} times, {} buffers", 
              count, inInputData->mNumberBuffers);
        
        // Debug: Check first buffer's data
        if (inInputData->mNumberBuffers > 0) {
            const AudioBuffer& buf = inInputData->mBuffers[0];
            AUDIOTRACE_LOG_TRACE("  Buffer 0: channels={}, dataSize={} bytes", 
                  buf.mNumberChannels, buf.mDataByteSize);
            
            if (buf.mData && buf.mDataByteSize >= sizeof(float) * 4) {
                const float* samples = static_cast<const float*>(buf.mData);
                AUDIOTRACE_LOG_TRACE("  First samples: {:.6f}, {:.6f}, {:.6f}, {:.6f}", 
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
                AUDIOTRACE_LOG_TRACE("  [buf {}] ch={} size={} first4={:.6f}, {:.6f}, {:.6f}, {:.6f}",
                      (unsigned)i,
                      buf.mNumberChannels,
                      buf.mDataByteSize,
                      samples[0], samples[1], samples[2], samples[3]);
            } else {
                AUDIOTRACE_LOG_TRACE("  [buf {}] ch={} size={} (no data)", (unsigned)i, buf.mNumberChannels, buf.mDataByteSize);
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
    
    // Lock briefly to get tap pointers, then process without holding lock
    std::vector<ProcessTap*> taps_snapshot;
    {
        std::scoped_lock lock(process_taps_mutex_);
        taps_snapshot.reserve(process_taps_.size());
        for (const auto& tap : process_taps_) {
            taps_snapshot.push_back(tap.get());
        }
    }
    
    // Each buffer in the aggregate device corresponds to one tap
    const uint32_t num_buffers = std::min(
        static_cast<uint32_t>(buffer_list->mNumberBuffers),
        static_cast<uint32_t>(taps_snapshot.size())
    );

    static int map_log_counter = 0;
    if (debug_log_buffers_ && map_log_counter < 5) {
        AUDIOTRACE_LOG_TRACE("Mapping {} buffers to {} taps", num_buffers, taps_snapshot.size());
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
        auto* tap = taps_snapshot[i];

        if (debug_log_buffers_ && map_log_counter < 5) {
            float first = (buffer.mDataByteSize >= sizeof(float)) ? samples[0] : 0.0f;
            AUDIOTRACE_LOG_TRACE("    [map] buf {} -> PID {}, ch={} frames={} first={:.6f}",
                  i, tap->pid, channel_count, frame_count, first);
        }
        
        AudioTapData data;
        data.pid = tap->pid;
        data.channel_count = channel_count;
        data.sample_time = timestamp ? timestamp->mSampleTime : 0;
        
        const size_t copy_size = std::min(static_cast<size_t>(sample_count), tap->temp_buffer.size());
        std::copy_n(samples, copy_size, tap->temp_buffer.begin());
        data.samples = tap->temp_buffer;
        
        if (!channel_count) {
            continue;
        }
        // Clamp frame_count to what we actually copied
        const uint32_t copied_frames = copy_size / channel_count;
        data.frame_count = copied_frames;
        
        if (!tap->ring_buffer.push(data)) {
            static std::atomic<int> drop_count{0};
            if (++drop_count % 100 == 0) {
                AUDIOTRACE_LOG_WARN("Dropped {} buffers (ring buffer full)", drop_count.load());
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
        auto is_already_tapped = [&](pid_t test_pid) {
            std::scoped_lock lock(process_taps_mutex_);
            for (const auto& tap : process_taps_) {
                if (tap->pid == test_pid) {
                    return true;
                }
            }
            return false;
        };
        
        std::unordered_set<pid_t> tried;
        pid_t current_pid = pid;
        int fallback_depth = 0;
        
        while (true) {
            if (current_pid <= 0 || tried.count(current_pid)) {
                return false;
            }
            tried.insert(current_pid);
            
            if (is_already_tapped(current_pid)) {
                AUDIOTRACE_LOG_INFO("PID {} already tapped, skipping creation", current_pid);
                return true;
            }
            
            // Create the tap - THIS WILL TRIGGER THE PERMISSION PROMPT!
            AudioObjectID tap_id = kAudioObjectUnknown;
            OSStatus status = noErr;
            
            // Single attempt per PID to avoid long stalls during rebuild
            const int max_retries = 1;
            for (int attempt = 0; attempt < max_retries; ++attempt) {
                AudioObjectID process_obj_id = find_process_object_for_pid(current_pid);
                if (process_obj_id == kAudioObjectUnknown) {
                    AUDIOTRACE_LOG_WARN("Process object for PID {} is stale/gone - aborting tap creation (path={})", current_pid, pid_path(current_pid));
                    break;
                }
                const std::string process_path = pid_path(current_pid);
                
                // Create array of process AudioObjectIDs
                NSNumber* processID = @(process_obj_id);
                NSArray<NSNumber*>* processes = @[processID];

                // Use stereo mixdown for single-process taps
                AUDIOTRACE_LOG_DEBUG("Creating stereo mixdown tap (attempt {} / {}) PID {} obj {} path={}",
                      attempt + 1,
                      max_retries,
                      current_pid,
                      process_obj_id,
                      process_path);
                CATapDescription* tapDesc = [[CATapDescription alloc] initStereoMixdownOfProcesses:processes];
                
                if (!tapDesc) {
                    AUDIOTRACE_LOG_ERROR("Failed to create tap descriptor for PID {} (path={})", current_pid, process_path);
                    break;
                }
                
                // These properties should already be set by the initializer, but set them explicitly to be safe
                tapDesc.exclusive = NO;
                tapDesc.muteBehavior = CATapUnmuted;
                tapDesc.privateTap = YES;
                
                status = AudioHardwareCreateProcessTap(tapDesc, &tap_id);
                
                if (status == noErr && tap_id != kAudioObjectUnknown) {
                    break; // Success!
                }
                
                AUDIOTRACE_LOG_DEBUG("Tap creation returned status={} ({}) tap_id={} (PID {} obj {} path={})", 
                                     (int)status,
                                     osstatus_to_string(status),
                                     tap_id,
                                     current_pid,
                                     process_obj_id,
                                     process_path);
            }
            
            if (status == noErr && tap_id != kAudioObjectUnknown) {
                // Verify tap format (Step 4 from design doc)
                AudioStreamBasicDescription fmt{};
                UInt32 size = sizeof(fmt);
                AudioObjectPropertyAddress fmt_addr{
                    kAudioTapPropertyFormat,
                    kAudioObjectPropertyScopeGlobal,
                    kAudioObjectPropertyElementMain
                };
                if (AudioObjectGetPropertyData(tap_id, &fmt_addr, 0, nullptr, &size, &fmt) == noErr) {
                    AUDIOTRACE_LOG_DEBUG("Tap format: rate={:.0f}, channels={}, bytesPerFrame={}, formatFlags=0x{:x}",
                          fmt.mSampleRate, fmt.mChannelsPerFrame, fmt.mBytesPerFrame, fmt.mFormatFlags);
                    
                    // CRITICAL: Verify this is NOT zero or invalid
                    if (fmt.mSampleRate == 0 || fmt.mChannelsPerFrame == 0) {
                        AUDIOTRACE_LOG_ERROR("INVALID tap format detected! rate={:.0f} channels={}",
                              fmt.mSampleRate, fmt.mChannelsPerFrame);
                    }
                } else {
                    AUDIOTRACE_LOG_WARN("Could not get tap format for verification");
                }

                // Create ProcessTap structure
                size_t buffer_size = config_.buffer_frames * 2;
                auto process_tap = std::make_unique<ProcessTap>(
                    current_pid,
                    tap_id,
                    config_.ringbuffer_capacity,
                    buffer_size
                );
                
                {
                    std::scoped_lock lock(process_taps_mutex_);
                    process_taps_.push_back(std::move(process_tap));
                }
                AUDIOTRACE_LOG_INFO("Created tap {} for PID {}", tap_id, current_pid);
                log_tap_format(tap_id, current_pid);
                return true;
            }
            
            // Failed to create; try parent fallback once or twice
            pid_t parent = get_parent_pid(current_pid);
            if (parent > 1 && parent != current_pid && fallback_depth < 2 && !tried.count(parent)) {
                AUDIOTRACE_LOG_INFO("Tap creation failed for PID {} - trying parent PID {}", current_pid, parent);
                current_pid = parent;
                ++fallback_depth;
                continue;
            }
            
            // Final failure
            AUDIOTRACE_LOG_ERROR("AudioHardwareCreateProcessTap failed for PID {} after {} attempts (status={} / {}) path={} tap_id={}", 
                                 current_pid,
                                 max_retries,
                                 (int)status,
                                 osstatus_to_string(status),
                                 pid_path(current_pid),
                                 tap_id);
            return false;
        }
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
        AUDIOTRACE_LOG_INFO("No audio process objects found");
        return;
    }

    AUDIOTRACE_LOG_INFO("Audio process objects:");
    for (AudioObjectID obj_id : process_objects) {
        pid_t pid = get_pid_from_audio_object(obj_id);
        AUDIOTRACE_LOG_INFO("    - obj={} pid={}", obj_id, pid);
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
        AUDIOTRACE_LOG_ERROR("AudioHardwareCreateAggregateDevice failed with status {}", (int)status);
        return false;
    }
    
    AUDIOTRACE_LOG_INFO("Created aggregate device {} with {} taps", aggregate_device_id_, tap_uids.size());
    
    return aggregate_device_id_ != kAudioObjectUnknown;
}

void AudioTapManager::destroy_aggregate_device() {
    if (aggregate_device_id_ != kAudioObjectUnknown) {
        // Destroy all taps first (caller must hold process_taps_mutex_)
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

void AudioTapManager::destroy_aggregate_device_only() {
    // Destroy only the aggregate device, keep taps alive
    if (aggregate_device_id_ != kAudioObjectUnknown) {
        AudioHardwareDestroyAggregateDevice(aggregate_device_id_);
        aggregate_device_id_ = kAudioObjectUnknown;
    }
}

bool AudioTapManager::wait_for_device_ready(AudioObjectID device_id, double timeout_seconds) {
    // Based on AudioTee Swift implementation
    // Poll device readiness with 100ms intervals
    const double poll_interval = 0.1;  // 100ms
    const int max_polls = static_cast<int>(timeout_seconds / poll_interval);
    
    AUDIOTRACE_LOG_DEBUG("Waiting for device {} to become ready...", device_id);
    
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
            AUDIOTRACE_LOG_DEBUG("Device {} ready after {} polls ({:.1f}s)", 
                  device_id, poll, poll * poll_interval);
            return true;
        }
        
        if (poll < max_polls) {
            std::this_thread::sleep_for(
                std::chrono::milliseconds(static_cast<int>(poll_interval * 1000))
            );
        }
    }
    
    AUDIOTRACE_LOG_WARN("Device {} did not become ready within {:.1f}s", device_id, timeout_seconds);
    return false;
}

}  // namespace AudioTrace
