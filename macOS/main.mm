#import <Cocoa/Cocoa.h>
#import "AppDelegate.hpp"
#include "../AudioCore/Logger.hpp"

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        // Initialize logging system
        AudioTrace::Logger::init();
        
        NSApplication* app = [NSApplication sharedApplication];
        
        AppDelegate* delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];
        
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        
        return NSApplicationMain(argc, argv);
    }
}
