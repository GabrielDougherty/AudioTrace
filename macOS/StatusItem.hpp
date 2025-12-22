#pragma once

#import <Cocoa/Cocoa.h>
#include "../AudioCore/AudioTapManager.hpp"
#include "../AudioCore/AudioAnalyzer.hpp"
#include "../AudioCore/ActivityTracker.hpp"
#include <memory>

/// Main menu bar status item controller
@interface StatusItem : NSObject

- (instancetype)initWithActivityTracker:(AudioTrace::ActivityTracker*)tracker;
- (void)show;
- (void)hide;
- (void)updateMenu;

@end
