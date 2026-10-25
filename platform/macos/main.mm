#import <AppKit/AppKit.h>

#import "menu_app.h"

int main(int, const char*[]) {
    @autoreleasepool {
        NSApplication* application = [NSApplication sharedApplication];
        application.activationPolicy = NSApplicationActivationPolicyAccessory;

        // NSApplication holds its delegate weakly, so keep this one alive until run returns.
        AGMenuApp* delegate NS_VALID_UNTIL_END_OF_SCOPE = [[AGMenuApp alloc] init];
        application.delegate = delegate;

        [application run];
    }
    return 0;
}
