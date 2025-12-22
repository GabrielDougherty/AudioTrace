#include "AudioAnalyzer.hpp"
#include <cmath>
#include <algorithm>
#include <unordered_map>
#include <optional>

namespace AudioTrace {

AudioAnalyzer::AudioAnalyzer(Config config)
    : config_(config)
{}

AudioAnalyzer::~AudioAnalyzer() = default;

auto AudioAnalyzer::analyze(const float* buffer,
                            uint32_t frame_count,
                            uint32_t channel_count,
                            pid_t pid,
                            std::chrono::steady_clock::time_point timestamp)
    -> std::optional<ActivityEvent>
{
    if (!buffer || frame_count == 0 || channel_count == 0) {
        return std::nullopt;
    }

    auto levels = compute_levels(buffer, frame_count, channel_count);
    
    // Get or create process state
    auto& state = process_states_[pid];
    state.last_update = timestamp;

    // Hysteresis logic
    bool is_audible = false;
    if (state.is_active) {
        // Already active - use lower threshold to avoid flickering
        is_audible = levels.rms >= config_.silence_threshold_rms;
    } else {
        // Inactive - use higher threshold to activate
        is_audible = levels.rms >= config_.active_threshold_rms;
    }

    state.is_active = is_audible;

    if (is_audible) {
        return ActivityEvent{
            .pid = pid,
            .rms_level = levels.rms,
            .peak_level = levels.peak,
            .timestamp = timestamp
        };
    }

    return std::nullopt;
}

auto AudioAnalyzer::compute_levels(const float* buffer,
                                   uint32_t frame_count,
                                   uint32_t channel_count) const noexcept
    -> AudioLevels
{
    float sum_squares = 0.0f;
    float peak = 0.0f;

    const uint32_t sample_count = frame_count * channel_count;
    
    for (uint32_t i = 0; i < sample_count; ++i) {
        const float sample = buffer[i];
        sum_squares += sample * sample;
        peak = std::max(peak, std::abs(sample));
    }

    const float rms = std::sqrt(sum_squares / sample_count);
    
    return AudioLevels{
        .rms = rms,
        .peak = peak
    };
}

}  // namespace AudioTrace
