#pragma once

#import <Cocoa/Cocoa.h>
#include <memory>

// Forward declarations
namespace AudioTrace {
    class AudioTapManager;
    class AudioAnalyzer;
    class ActivityTracker;
}

@class StatusItem;

@interface AppDelegate : NSObject <NSApplicationDelegate>

@property (strong, nonatomic) StatusItem* statusItem;

@end
