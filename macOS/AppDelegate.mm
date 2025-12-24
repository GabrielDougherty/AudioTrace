#import "AppDelegate.hpp"
#import "StatusItem.hpp"
#import "ProcessInfo.hpp"
#include "../AudioCore/AudioTapManager.hpp"
#include "../AudioCore/AudioAnalyzer.hpp"
#include "../AudioCore/ActivityTracker.hpp"
#include "../AudioCore/Logger.hpp"

@interface AppDelegate () {
    std::unique_ptr<AudioTrace::AudioTapManager> _tapManager;
}
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    AudioTrace::Logger::info("AudioTrace starting...");

    // Initialize audio capture
    [self setupAudioPipeline];

    // Create menu bar UI - pass the tap manager which has the tracker
    self.statusItem = [[StatusItem alloc] initWithTapManager:_tapManager.get()];
    [self.statusItem show];

    AudioTrace::Logger::info("AudioTrace menu bar app ready");
}

- (void)setupAudioPipeline {
    // Create tap manager (includes analyzer and tracker)
    AudioTrace::AudioTapManager::Config tap_config;
    tap_config.sample_rate = 48000;
    tap_config.buffer_frames = 512;
    _tapManager = std::make_unique<AudioTrace::AudioTapManager>(tap_config);

    // Start audio capture - will trigger permission prompt if needed
    bool started = _tapManager->start();
    if (!started) {
        AudioTrace::Logger::warn("Failed to start audio tap manager");
        AudioTrace::Logger::warn("Check System Settings > Privacy & Security > Screen Recording");
    } else {
        AudioTrace::Logger::info("Audio tap manager started successfully");
    }
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    AudioTrace::Logger::info("AudioTrace shutting down...");
    
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
