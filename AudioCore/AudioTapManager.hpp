#pragma once

#include "RingBuffer.hpp"
#include "AudioAnalyzer.hpp"
#include "ActivityTracker.hpp"
#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioToolbox.h>
#include <memory>
#include <vector>
#include <functional>
#include <thread>
#include <atomic>
#include <sys/types.h>
#include <cstdlib>

namespace AudioTrace {

/// Raw audio data from a process tap
struct AudioTapData {
    pid_t pid;
    std::vector<float> samples;  // Interleaved samples
    uint32_t frame_count;
    uint32_t channel_count;
    uint64_t sample_time;
};

/// Manages Core Audio process taps for system audio capture
/// Realtime-safe audio callbacks write to lock-free ring buffers
class AudioTapManager {
public:
    using AudioCallback = std::function<void(const AudioTapData&)>;

    struct Config {
        uint32_t sample_rate = 48000;
        uint32_t buffer_frames = 512;
        size_t ringbuffer_capacity = 64;  // Number of buffers to queue
    };

    explicit AudioTapManager(Config config);
    ~AudioTapManager();

    AudioTapManager(const AudioTapManager&) = delete;
    AudioTapManager& operator=(const AudioTapManager&) = delete;

    /// Start capturing system audio
    /// TODO: Implement Core Audio tap setup
    bool start();

    /// Stop capturing
    void stop();

    /// Set callback for audio data (called from worker thread, not realtime)
    void set_audio_callback(AudioCallback callback);

    
    /// Get activity snapshot for UI
    std::vector<ActivitySnapshot> get_activity_snapshot() const;
    /// Get list of currently tapped process IDs
    std::vector<pid_t> get_tapped_processes() const;

private:
    AudioObjectID find_process_object_for_pid(pid_t pid);
    void log_available_audio_processes();

    // Debug controls (set via environment variables)
    bool debug_log_buffers_ = false;
    bool debug_global_only_ = false;
    pid_t debug_single_pid_ = -1;

    Config config_;
    
    // Audio analysis components
    AudioAnalyzer analyzer_;
    ActivityTracker tracker_;
    bool is_running_ = false;
    AudioCallback audio_callback_;

    // Core Audio aggregate device for taps
    AudioObjectID aggregate_device_id_ = kAudioObjectUnknown;
    AudioDeviceIOProcID io_proc_id_ = nullptr;
    
    // Ring buffers for each tapped process (realtime -> worker)
    struct ProcessTap {
        pid_t pid;
        AudioObjectID tap_id;
        RingBuffer<AudioTapData> ring_buffer;
        std::vector<float> temp_buffer;  // Pre-allocated for realtime use
        
        ProcessTap(pid_t p, AudioObjectID tap, size_t capacity, size_t buffer_size)
            : pid(p)
            , tap_id(tap)
            , ring_buffer(capacity)
            , temp_buffer(buffer_size)
        {}
    };
    
    std::vector<std::unique_ptr<ProcessTap>> process_taps_;

    // Worker thread that drains ring buffers
    void worker_thread_proc();
    std::unique_ptr<std::thread> worker_thread_;
    std::atomic<bool> worker_should_stop_{false};

    // Helper methods
    bool create_aggregate_device(const std::vector<CFStringRef>& tap_uids);
    void destroy_aggregate_device();
    bool create_tap_for_process(pid_t pid);
    bool create_tap_for_system();
    std::vector<AudioObjectID> discover_audio_processes();
    pid_t get_pid_from_audio_object(AudioObjectID obj_id);
    AudioStreamBasicDescription get_stream_format() const;

    // Core Audio callback (REALTIME SAFE) - for aggregate device
    static OSStatus audio_io_proc(
        AudioDeviceID inDevice,
        const AudioTimeStamp* inNow,
        const AudioBufferList* inInputData,
        const AudioTimeStamp* inInputTime,
        AudioBufferList* outOutputData,
        const AudioTimeStamp* inOutputTime,
        void* inClientData
    ) noexcept;
    
    // Process buffers from aggregate device
    void process_input_data(const AudioBufferList* buffer_list,
                           const AudioTimeStamp* timestamp) noexcept;
};

}  // namespace AudioTrace
