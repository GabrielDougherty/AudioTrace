#include "ActivityTracker.hpp"
#include "Logger.hpp"
#include <algorithm>

namespace AudioTrace {

ActivityTracker::ActivityTracker(Config config)
    : config_(config)
{}

ActivityTracker::~ActivityTracker() = default;

void ActivityTracker::record_activity(const ActivityEvent& event) {
    std::scoped_lock lock(mutex_);
    
    // Check if this is a new process or update existing
    auto it = activities_.find(event.pid);
    if (it != activities_.end()) {
        // Update existing entry, keep cached window title
        it->second.last_heard = event.timestamp;
        it->second.last_rms_level = event.rms_level;
        it->second.last_peak_level = event.peak_level;
    } else {
        // New entry - will cache window title in snapshot()
        activities_[event.pid] = ProcessActivity{
            .last_heard = event.timestamp,
            .last_rms_level = event.rms_level,
            .last_peak_level = event.peak_level,
            .cached_window_title = ""
        };
    }
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
            .is_currently_playing = elapsed < config_.current_threshold,
            .cached_window_title = activity.cached_window_title
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

void ActivityTracker::cache_window_title(pid_t pid, const std::string& title) {
    std::scoped_lock lock(mutex_);
    
    auto it = activities_.find(pid);
    if (it != activities_.end() && it->second.cached_window_title.empty() && !title.empty()) {
        it->second.cached_window_title = title;
        Logger::debug("Cached window title '{}' for PID {}", title, pid);
    }
}

}  // namespace AudioTrace
