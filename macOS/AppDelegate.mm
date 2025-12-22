#import "AppDelegate.hpp"
#import "StatusItem.hpp"
#import "ProcessInfo.hpp"
#include "../AudioCore/AudioTapManager.hpp"
#include "../AudioCore/AudioAnalyzer.hpp"
#include "../AudioCore/ActivityTracker.hpp"

@interface AppDelegate () {
    std::unique_ptr<AudioTrace::AudioTapManager> _tapManager;
    std::unique_ptr<AudioTrace::AudioAnalyzer> _analyzer;
    std::unique_ptr<AudioTrace::ActivityTracker> _tracker;
}
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    NSLog(@"AudioTrace starting...");

    // Initialize C++ components
    [self setupAudioPipeline];

    // Create menu bar UI
    self.statusItem = [[StatusItem alloc] initWithActivityTracker:_tracker.get()];
    [self.statusItem show];

    NSLog(@"AudioTrace menu bar app ready");
}

- (void)setupAudioPipeline {
    // Create activity tracker
    AudioTrace::ActivityTracker::Config tracker_config;
    tracker_config.current_threshold = std::chrono::milliseconds(500);
    tracker_config.expiry_time = std::chrono::minutes(2);
    _tracker = std::make_unique<AudioTrace::ActivityTracker>(tracker_config);

    // Create audio analyzer
    AudioTrace::AudioAnalyzer::Config analyzer_config;
    analyzer_config.silence_threshold_rms = 0.001f;  // ~-60dB
    analyzer_config.active_threshold_rms = 0.005f;   // ~-46dB
    _analyzer = std::make_unique<AudioTrace::AudioAnalyzer>(analyzer_config);

    // Create tap manager
    AudioTrace::AudioTapManager::Config tap_config;
    tap_config.sample_rate = 48000;
    tap_config.buffer_frames = 512;
    _tapManager = std::make_unique<AudioTrace::AudioTapManager>(tap_config);

    // Set up audio callback chain: TapManager -> Analyzer -> Tracker
    auto analyzer = _analyzer.get();
    auto tracker = _tracker.get();
    _tapManager->set_audio_callback([analyzer, tracker](const AudioTrace::AudioTapData& data) {
        // This runs on worker thread (not realtime)
        auto timestamp = std::chrono::steady_clock::now();
        
        auto event = analyzer->analyze(
            data.samples.data(),
            data.frame_count,
            data.channel_count,
            data.pid,
            timestamp
        );

        if (event.has_value()) {
            tracker->record_activity(*event);
        }
    });

    // Start audio capture
    // TODO: This will trigger audio permission prompt
    bool started = _tapManager->start();
    if (!started) {
        NSLog(@"Warning: Failed to start audio tap manager");
        NSLog(@"Audio capture may require permissions in System Settings > Privacy & Security > Microphone");
    }

    // Set up periodic cleanup
    [NSTimer scheduledTimerWithTimeInterval:30.0
                                     target:self
                                   selector:@selector(cleanupExpiredEntries)
                                   userInfo:nil
                                    repeats:YES];
}

- (void)cleanupExpiredEntries {
    if (_tracker) {
        _tracker->cleanup_expired();
    }
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    NSLog(@"AudioTrace shutting down...");
    
    // Stop audio capture
    if (_tapManager) {
        _tapManager->stop();
    }

    // Hide menu bar item
    [self.statusItem hide];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return NO;  // Menu bar app doesn't terminate when windows close
}

@end
