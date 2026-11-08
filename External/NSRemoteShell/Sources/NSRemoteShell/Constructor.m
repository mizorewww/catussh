//
//  Constructor.m
//  
//
//  Created by Lakr Aream on 2022/2/5.
//

#import "Constructor.h"
#import "GenericHeaders.h"
#import "TSEventLoop.h"

#import <Foundation/Foundation.h>
#import <os/lock.h>

int kLIBSSH2_CONSTRUCTOR_SUCCESS = 0;

#if TARGET_OS_OSX
static id<NSObject> activityToken = nil;
static NSInteger activityRefCount = 0;
static os_unfair_lock activityLock = OS_UNFAIR_LOCK_INIT;
#endif

void libssh2_retain_activity(void) {
#if TARGET_OS_OSX
    os_unfair_lock_lock(&activityLock);
    activityRefCount += 1;
    if (activityRefCount == 1 && !activityToken) {
        activityToken = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep | NSActivityLatencyCritical
                                                                       reason:@"NSRemoteShell active SSH session"];
    }
    os_unfair_lock_unlock(&activityLock);
#endif
}

void libssh2_release_activity(void) {
#if TARGET_OS_OSX
    os_unfair_lock_lock(&activityLock);
    if (activityRefCount > 0) {
        activityRefCount -= 1;
    }
    if (activityRefCount == 0 && activityToken) {
        [[NSProcessInfo processInfo] endActivity:activityToken];
        activityToken = nil;
    }
    os_unfair_lock_unlock(&activityLock);
#endif
}

__attribute__((constructor)) void libssh2_constructor(void) {
    int ret = libssh2_init(0); // flag 1 == no crypto
    if (ret == 0) {
        kLIBSSH2_CONSTRUCTOR_SUCCESS = 1;
        NSRLog(@"libssh2 init success");
    }
}

__attribute__((destructor)) void libssh2_destructor(void) {
    if (kLIBSSH2_CONSTRUCTOR_SUCCESS) {
        libssh2_exit();
    }
#if TARGET_OS_OSX
    os_unfair_lock_lock(&activityLock);
    if (activityToken) {
        [[NSProcessInfo processInfo] endActivity:activityToken];
        activityToken = nil;
        activityRefCount = 0;
    }
    os_unfair_lock_unlock(&activityLock);
#endif
}

int libssh2_init_check() {
    return kLIBSSH2_CONSTRUCTOR_SUCCESS;
}

/*
 used for our CI machine, don't remove this if making contribute
 */
NSString *NSRemoteShellVersion = @"k.S-BrGcrAzymeD6jQ7FdFw6stCZW";
