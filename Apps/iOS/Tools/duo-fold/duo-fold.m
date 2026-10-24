// Folds and unfolds the iPhone Duo *simulator* (iOS 27.1) from the command line.
//
// Simulator-only test tool. It calls SpringBoard's private display tool service
// (SBSDisplayToolServiceConnection, Mach service com.apple.springboard.sbdisplay), which needs the
// com.apple.springboard.sbdisplay.service entitlement embedded as an __entitlements section. It is
// private SPI and may stop working with any runtime update; never ship it or use it on a device.
// Run it through duo-fold.sh, which builds it and spawns it inside a simulator.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) {
            printf("usage: duo-fold <hinge position 0.0-1.0> [duration seconds]\n");
            return 2;
        }
        if (!dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW)) {
            printf("SpringBoardServices is unavailable\n");
            return 1;
        }
        double position = atof(argv[1]);
        double duration = argc > 2 ? atof(argv[2]) : 0.4;
        id connection = [[NSClassFromString(@"SBSDisplayToolServiceConnection") alloc] init];
        Ivar ivar = class_getInstanceVariable([connection class], "_connection");
        id service = ivar ? object_getIvar(connection, ivar) : nil;
        id target = service ? ((id (*)(id, SEL))objc_msgSend)(service, NSSelectorFromString(@"remoteTarget")) : nil;
        if (!target) {
            printf("SpringBoard's display tool service isn't reachable\n");
            return 1;
        }
        // targetMode 1 is an absolute hinge position: 0 closed, 1 fully open (180 degrees).
        NSDictionary *options = @{@"targetMode": @1, @"targetHingePosition": @(position),
                                  @"duration": @(MAX(duration, 0.05)), @"waitForCompletion": @YES};
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block int status = 0;
        ((void (*)(id, SEL, id, id))objc_msgSend)(target, NSSelectorFromString(@"swapDisplayWithOptions:completion:"), options,
            ^(NSError *error) {
                if (error) { printf("failed: %s\n", error.description.UTF8String); status = 1; }
                dispatch_semaphore_signal(done);
            });
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
        while (dispatch_semaphore_wait(done, DISPATCH_TIME_NOW) != 0) {
            if (deadline.timeIntervalSinceNow < 0) { printf("timed out\n"); return 1; }
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        return status;
    }
}
