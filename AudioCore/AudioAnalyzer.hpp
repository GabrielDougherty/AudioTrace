#pragma once

#include <chrono>
#include <cstdint>
#include <unordered_map>
#include <optional>
#include <sys/types.h>

namespace AudioTrace {

/// Event emitted when audible activity is detected
struct ActivityEvent {
    pid_t pid;
    float rms_level;
    float peak_level;
    std::chrono::steady_clock::time_point timestamp;
};

/// Analyzes audio buffers to detect audible activity
/// NOT realtime-safe - runs on background thread
class AudioAnalyzer {
public:
    struct Config {
        float silence_threshold_rms = 0.001f;   // ~-60dB
        float active_threshold_rms = 0.005f;    // ~-46dB (hysteresis)
        uint32_t window_frames = 2048;          // ~42ms @ 48kHz
    };

    explicit AudioAnalyzer(Config config);
    ~AudioAnalyzer();

    AudioAnalyzer(const AudioAnalyzer&) = delete;
    AudioAnalyzer& operator=(const AudioAnalyzer&) = delete;

    /// Analyze audio buffer and return event if audible activity detected
    /// buffer: interleaved float samples
    /// frame_count: number of frames (samples / channels)
    /// channel_count: number of channels
    /// pid: process that produced this audio
    /// Returns ActivityEvent if audible, std::nullopt otherwise
    auto analyze(const float* buffer, 
                 uint32_t frame_count,
                 uint32_t channel_count,
                 pid_t pid,
                 std::chrono::steady_clock::time_point timestamp)
        -> std::optional<ActivityEvent>;

private:
    Config config_;
    
    // Per-PID state for hysteresis
    struct ProcessState {
        bool is_active = false;
        std::chrono::steady_clock::time_point last_update;
    };
    
    std::unordered_map<pid_t, ProcessState> process_states_;

    // Compute RMS and peak from buffer
    struct AudioLevels {
        float rms;
        float peak;
    };
    AudioLevels compute_levels(const float* buffer, 
                               uint32_t frame_count,
                               uint32_t channel_count) const noexcept;
};

}  // namespace AudioTrace
