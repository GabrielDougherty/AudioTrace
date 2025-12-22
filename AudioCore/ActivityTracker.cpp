#include "ActivityTracker.hpp"
#include <algorithm>

namespace AudioTrace {

ActivityTracker::ActivityTracker(Config config)
    : config_(config)
{}

ActivityTracker::~ActivityTracker() = default;

void ActivityTracker::record_activity(const ActivityEvent& event) {
    std::scoped_lock lock(mutex_);
    
    activities_[event.pid] = ProcessActivity{
        .last_heard = event.timestamp,
        .last_rms_level = event.rms_level,
        .last_peak_level = event.peak_level
    };
}

std::vector<ActivitySnapshot> ActivityTracker::snapshot() const {
    std::scoped_lock lock(mutex_);
    
    const auto now = std::chrono::steady_clock::now();
    std::vector<ActivitySnapshot> result;
    result.reserve(activities_.size());

    for (const auto& [pid, activity] : activities_) {
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            now - activity.last_heard
        );
        
        result.push_back(ActivitySnapshot{
            .pid = pid,
            .last_heard = activity.last_heard,
            .last_rms_level = activity.last_rms_level,
            .last_peak_level = activity.last_peak_level,
            .is_currently_playing = elapsed < config_.current_threshold
        });
    }

    // Sort by most recent first
    std::sort(result.begin(), result.end(), [](const auto& a, const auto& b) {
        return a.last_heard > b.last_heard;
    });

    return result;
}

void ActivityTracker::cleanup_expired() {
    std::scoped_lock lock(mutex_);
    
    const auto now = std::chrono::steady_clock::now();
    const auto expiry_threshold = now - config_.expiry_time;

    // Remove entries older than expiry time
    for (auto it = activities_.begin(); it != activities_.end();) {
        if (it->second.last_heard < expiry_threshold) {
            it = activities_.erase(it);
        } else {
            ++it;
        }
    }
}

size_t ActivityTracker::process_count() const {
    std::scoped_lock lock(mutex_);
    return activities_.size();
}

}  // namespace AudioTrace
