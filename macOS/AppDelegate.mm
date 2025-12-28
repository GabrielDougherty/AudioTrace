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
    AUDIOTRACE_LOG_INFO("AudioTrace starting...");

    // Request accessibility permissions for window title reading
    [self checkAccessibilityPermissions];

    // Initialize audio capture
    [self setupAudioPipeline];

    // Create menu bar UI - pass the tap manager which has the tracker
    self.statusItem = [[StatusItem alloc] initWithTapManager:_tapManager.get()];
    [self.statusItem show];

    AUDIOTRACE_LOG_INFO("AudioTrace menu bar app ready");
}

- (void)checkAccessibilityPermissions {
    NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
    BOOL accessibilityEnabled = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    
    if (!accessibilityEnabled) {
        AUDIOTRACE_LOG_WARN("Accessibility permissions not granted - window titles will not be available");
        AUDIOTRACE_LOG_WARN("Please grant access in System Settings > Privacy & Security > Accessibility");
    } else {
        AUDIOTRACE_LOG_INFO("Accessibility permissions granted");
    }
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
        AUDIOTRACE_LOG_WARN("Failed to start audio tap manager");
        AUDIOTRACE_LOG_WARN("Check System Settings > Privacy & Security > Screen Recording");
    } else {
        AUDIOTRACE_LOG_INFO("Audio tap manager started successfully");
    }
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    AUDIOTRACE_LOG_INFO("AudioTrace shutting down...");
    
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
