#pragma once

#include "AudioAnalyzer.hpp"
#include <chrono>
#include <vector>
#include <unordered_map>
#include <mutex>
#include <sys/types.h>

namespace AudioTrace {

/// Snapshot of a single process's audio activity
struct ActivitySnapshot {
    pid_t pid;
    std::chrono::steady_clock::time_point last_heard;
    float last_rms_level;
    float last_peak_level;
    bool is_currently_playing;  // Heard within last 500ms
};

/// Tracks audio activity per process
/// Thread-safe for concurrent reads and writes
class ActivityTracker {
public:
    struct Config {
        std::chrono::milliseconds current_threshold{500};    // "currently playing" window
        std::chrono::minutes expiry_time{2};                 // Remove entries after this
    };

    explicit ActivityTracker(Config config);
    ~ActivityTracker();

    ActivityTracker(const ActivityTracker&) = delete;
    ActivityTracker& operator=(const ActivityTracker&) = delete;

    /// Record an activity event (called from audio analysis thread)
    void record_activity(const ActivityEvent& event);

    /// Get snapshot of all tracked processes (called from UI thread)
    /// Returns processes sorted by most recent activity first
    std::vector<ActivitySnapshot> snapshot() const;

    /// Remove entries older than expiry_time
    void cleanup_expired();

    /// Get number of tracked processes
    size_t process_count() const;

private:
    Config config_;
    
    struct ProcessActivity {
        std::chrono::steady_clock::time_point last_heard;
        float last_rms_level;
        float last_peak_level;
    };

    mutable std::mutex mutex_;
    std::unordered_map<pid_t, ProcessActivity> activities_;
};

}  // namespace AudioTrace
