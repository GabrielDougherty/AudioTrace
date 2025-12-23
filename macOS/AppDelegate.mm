#import "AppDelegate.hpp"
#import "StatusItem.hpp"
#import "ProcessInfo.hpp"
#include "../AudioCore/AudioTapManager.hpp"
#include "../AudioCore/AudioAnalyzer.hpp"
#include "../AudioCore/ActivityTracker.hpp"

@interface AppDelegate () {
    std::unique_ptr<AudioTrace::AudioTapManager> _tapManager;
}
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    NSLog(@"AudioTrace starting...");

    // Initialize audio capture
    [self setupAudioPipeline];

    // Create menu bar UI - pass the tap manager which has the tracker
    self.statusItem = [[StatusItem alloc] initWithTapManager:_tapManager.get()];
    [self.statusItem show];

    NSLog(@"AudioTrace menu bar app ready");
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
        NSLog(@"⚠️  Failed to start audio tap manager");
        NSLog(@"Check System Settings > Privacy & Security > Screen Recording");
    } else {
        NSLog(@"✓ Audio tap manager started successfully");
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
