#pragma once

#import <Cocoa/Cocoa.h>

// Forward declare C++ classes
namespace AudioTrace {
    class AudioTapManager;
}

@interface StatusItem : NSObject <NSMenuDelegate>

- (instancetype)initWithTapManager:(AudioTrace::AudioTapManager*)tapManager;
- (void)show;
- (void)hide;
- (void)updateMenu;

@end
