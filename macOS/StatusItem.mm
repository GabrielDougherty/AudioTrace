#import "StatusItem.hpp"
#import "ProcessInfo.hpp"
#include "../AudioCore/AudioTapManager.hpp"
#include <chrono>

@interface StatusItem ()
@property (strong, nonatomic) NSStatusItem* statusItem;
@property (strong, nonatomic) NSMenu* menu;
@property (strong, nonatomic) NSTimer* updateTimer;
@property (assign, nonatomic) AudioTrace::AudioTapManager* tapManager;
@end

@implementation StatusItem

- (instancetype)initWithTapManager:(AudioTrace::AudioTapManager*)tapManager {
    self = [super init];
    if (self) {
        _tapManager = tapManager;
        _menu = [[NSMenu alloc] init];
        _menu.autoenablesItems = NO;
    }
    return self;
}

- (void)show {
    if (!self.statusItem) {
        self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
        self.statusItem.button.title = @"🔊";
        self.statusItem.menu = self.menu;
        
        // Update menu every 500ms
        self.updateTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                           target:self
                                                         selector:@selector(updateMenu)
                                                         userInfo:nil
                                                          repeats:YES];
        
        [self updateMenu];
    }
}

- (void)hide {
    if (self.statusItem) {
        [[NSStatusBar systemStatusBar] removeStatusItem:self.statusItem];
        self.statusItem = nil;
    }
    
    if (self.updateTimer) {
        [self.updateTimer invalidate];
        self.updateTimer = nil;
    }
}

- (void)updateMenu {
    if (!self.tapManager) {
        NSLog(@"⚠️ updateMenu: tapManager is NULL!");
        return;
    }

    [self.menu removeAllItems];

    // Get activity snapshot from tap manager
    auto snapshots = self.tapManager->get_activity_snapshot();
    
    NSLog(@"📊 updateMenu: Got %lu snapshots", (unsigned long)snapshots.size());

    if (snapshots.empty()) {
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:@"No recent audio activity"
                                                      action:nil
                                               keyEquivalent:@""];
        item.enabled = NO;
        [self.menu addItem:item];
    } else {
        for (const auto& snapshot : snapshots) {
            // Get process info
            auto app_info = AudioTrace::ProcessInfo::get_app_name(snapshot.pid);
            NSString* appName = app_info.has_value() 
                ? [NSString stringWithUTF8String:app_info->c_str()]
                : [NSString stringWithFormat:@"PID %d", snapshot.pid];

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

            NSString* title = [NSString stringWithFormat:@"%@ — %@", appName, timeStr];
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

- (void)dealloc {
    [self hide];
}

@end
