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
            // Try to get app info first
            auto app_info = AudioTrace::ProcessInfo::get_app_info(snapshot.pid);
            
            // Even if app info fails, try to get window title directly
            auto window_title = AudioTrace::ProcessInfo::get_window_title(snapshot.pid);
            
            NSString* displayName;
            if (app_info.has_value()) {
                // We have app name
                if (!app_info->window_title.empty()) {
                    NSString* windowTitle = [NSString stringWithUTF8String:app_info->window_title.c_str()];
                    NSString* appName = [NSString stringWithUTF8String:app_info->name.c_str()];
                    displayName = [NSString stringWithFormat:@"%@: %@", appName, windowTitle];
                } else {
                    displayName = [NSString stringWithUTF8String:app_info->name.c_str()];
                }
            } else if (window_title.has_value()) {
                // No app info but we have window title
                displayName = [NSString stringWithUTF8String:window_title->c_str()];
            } else {
                // Fallback to PID
                displayName = [NSString stringWithFormat:@"PID %d", snapshot.pid];
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
                                                          action:nil
                                                   keyEquivalent:@""];
            
            // TODO: Set app icon as item.image if available
            
            item.enabled = NO;
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

#pragma mark - NSMenuDelegate

- (void)menuWillOpen:(NSMenu *)menu {
    [self updateMenu];
}

- (void)dealloc {
    [self hide];
}

@end
