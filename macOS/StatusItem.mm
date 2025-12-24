#import "StatusItem.hpp"
#import "ProcessInfo.hpp"
#include "../AudioCore/AudioTapManager.hpp"
#include "../AudioCore/Logger.hpp"
#include <chrono>

@interface StatusItem ()
@property (strong, nonatomic) NSStatusItem* statusItem;
@property (strong, nonatomic) NSMenu* menu;
@property (assign, nonatomic) AudioTrace::AudioTapManager* tapManager;
@end

@implementation StatusItem

- (instancetype)initWithTapManager:(AudioTrace::AudioTapManager*)tapManager {
    self = [super init];
    if (self) {
        _tapManager = tapManager;
        _menu = [[NSMenu alloc] init];
        _menu.autoenablesItems = NO;
        _menu.delegate = self;
    }
    return self;
}

- (void)show {
    if (!self.statusItem) {
        self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
        self.statusItem.button.title = @"🔊";
        self.statusItem.menu = self.menu;
        [self updateMenu];
    }
}

- (void)hide {
    if (self.statusItem) {
        [[NSStatusBar systemStatusBar] removeStatusItem:self.statusItem];
        self.statusItem = nil;
    }
}

- (void)updateMenu {
    if (!self.tapManager) {
        AudioTrace::Logger::warn("updateMenu called but tapManager is NULL");
        return;
    }

    [self.menu removeAllItems];

    // Get activity snapshot from tap manager
    auto snapshots = self.tapManager->get_activity_snapshot();
    
    AudioTrace::Logger::debug("updateMenu: Got {} snapshots", snapshots.size());

    if (snapshots.empty()) {
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:@"No recent audio activity"
                                                      action:nil
                                               keyEquivalent:@""];
        item.enabled = NO;
        [self.menu addItem:item];
    } else {
        for (const auto& snapshot : snapshots) {
            NSString* displayName = nil;
            
            // First, always try to get the app name (lightweight and reliable)
            auto app_name = AudioTrace::ProcessInfo::get_app_name(snapshot.pid);
            NSString* appName = app_name.has_value() 
                ? [NSString stringWithUTF8String:app_name->c_str()]
                : nil;
            
            // Check if we have a cached window title from the snapshot
            if (!snapshot.cached_window_title.empty()) {
                NSString* windowTitle = [NSString stringWithUTF8String:snapshot.cached_window_title.c_str()];
                if (appName) {
                    displayName = [NSString stringWithFormat:@"%@: %@", appName, windowTitle];
                } else {
                    displayName = windowTitle;
                }
            } else {
                // No cached title - try to get window title and cache it if available
                auto window_title = AudioTrace::ProcessInfo::get_window_title(snapshot.pid);
                
                if (window_title.has_value() && !window_title->empty()) {
                    NSString* windowTitle = [NSString stringWithUTF8String:window_title->c_str()];
                    if (appName) {
                        displayName = [NSString stringWithFormat:@"%@: %@", appName, windowTitle];
                    } else {
                        displayName = windowTitle;
                    }
                    // Cache this title for future use
                    self.tapManager->cache_window_title(snapshot.pid, *window_title);
                } else {
                    // No window title available - just show app name
                    if (appName) {
                        displayName = appName;
                    } else {
                        // Last resort fallback to PID
                        displayName = [NSString stringWithFormat:@"PID %d", snapshot.pid];
                    }
                }
            }

            // Format time ago
            NSString* timeStr;
            if (snapshot.is_currently_playing) {
                timeStr = @"currently playing";
            } else {
                auto now = std::chrono::steady_clock::now();
                auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                    now - snapshot.last_heard
                );
                
                if (elapsed.count() < 60) {
                    timeStr = [NSString stringWithFormat:@"%llds ago", elapsed.count()];
                } else {
                    auto minutes = elapsed.count() / 60;
                    timeStr = [NSString stringWithFormat:@"%lldm ago", minutes];
                }
            }

            NSString* title = [NSString stringWithFormat:@"%@ — %@", displayName, timeStr];
            NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title
                                                          action:@selector(raiseWindow:)
                                                   keyEquivalent:@""];
            
            // Store the PID in the menu item's tag
            item.tag = snapshot.pid;
            
            // TODO: Set app icon as item.image if available
            
            item.target = self;
            item.enabled = YES;
            [self.menu addItem:item];
        }
    }

    // Add separator and quit option
    [self.menu addItem:[NSMenuItem separatorItem]];
    
    NSMenuItem* quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit AudioTrace"
                                                      action:@selector(terminate:)
                                               keyEquivalent:@"q"];
    quitItem.target = NSApp;
    [self.menu addItem:quitItem];
}

- (void)raiseWindow:(NSMenuItem*)sender {
    pid_t pid = sender.tag;
    
    AudioTrace::Logger::debug("Attempting to raise window for PID {}", pid);
    
    // Get the activatable application for this PID (handles helper processes)
    NSRunningApplication* app = AudioTrace::ProcessInfo::get_activatable_app(pid);
    if (!app) {
        // Warning already logged in get_activatable_app
        return;
    }
    
    // Activate the application (bring it to front)
    [app activateWithOptions:NSApplicationActivateAllWindows];
    
    AudioTrace::Logger::debug("Activated application successfully");
}

#pragma mark - NSMenuDelegate

- (void)menuWillOpen:(NSMenu *)menu {
    [self updateMenu];
}

- (void)dealloc {
    [self hide];
    [super dealloc];
}

@end
