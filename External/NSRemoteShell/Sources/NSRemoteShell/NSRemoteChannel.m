//
//  NSRemoteChannel.m
//  
//
//  Created by Lakr Aream on 2022/2/6.
//

#import "NSRemoteChannel.h"

@interface NSRemoteChannel ()

@property (nonatomic, nullable, readwrite, assign) LIBSSH2_SESSION *representedSession;
@property (nonatomic, nullable, readwrite, assign) LIBSSH2_CHANNEL *representedChannel;

@property (nonatomic, nullable, strong) NSRemoteChannelRequestDataBlock requestDataBlock;
@property (nonatomic, nullable, strong) NSRemoteChannelReceiveDataBlock receiveDataBlock;
@property (nonatomic, nullable, strong) NSRemoteChannelContinuationBlock continuationDecisionBlock;
@property (nonatomic, nullable, strong) NSRemoteChannelTerminalSizeBlock requestTerminalSizeBlock;

@property (nonatomic) CGSize currentTerminalSize;
// what was typed and the channel has not taken yet
@property (nonatomic, nonnull, strong) NSMutableData *pendingWrite;

@property (nonatomic, nullable, strong) NSDate *scheduledTermination;
@property (nonatomic, nullable, strong) dispatch_block_t terminationBlock;

@property (nonatomic, readwrite) BOOL channelCompleted;
@property (nonatomic, readwrite, assign) int exitStatus;

@end

@implementation NSRemoteChannel

// MARK: - LIFE CYCLE

- (instancetype)initWithRepresentedSession:(LIBSSH2_SESSION *)representedSession
                     withRepresentedChanel:(LIBSSH2_CHANNEL *)representedChannel
{
    self = [super init];
    if (self) {
        _representedSession = representedSession;
        _representedChannel = representedChannel;
        _channelCompleted = NO;
        _currentTerminalSize = CGSizeMake(0, 0);
        _pendingWrite = [[NSMutableData alloc] init];
        _exitStatus = 0;
    }
    return self;
}

- (void)dealloc {
    NSRLog(@"channel object at %p deallocating", self);
    [self unsafeDisconnectAndPrepareForRelease];
}

// MARK: - SETUP

- (void)onTermination:(dispatch_block_t)terminationHandler {
    self.terminationBlock = terminationHandler;
}

- (void)setRequestDataChain:(NSRemoteChannelRequestDataBlock _Nonnull)requestData {
    self.requestDataBlock = requestData;
}

- (void)setReceivedDataChain:(NSRemoteChannelReceiveDataBlock _Nonnull)receiveData {
    self.receiveDataBlock = receiveData;
}

- (void)setContinuationChain:(NSRemoteChannelContinuationBlock _Nonnull)continuation {
    self.continuationDecisionBlock = continuation;
}

- (void)setTerminalSizeChain:(NSRemoteChannelTerminalSizeBlock _Nonnull)terminalSize {
    self.requestTerminalSizeBlock = terminalSize;
}

- (void)setChannelTimeoutWith:(double)timeoutValueFromNowInSecond {
    if (timeoutValueFromNowInSecond <= 0) {
#if DEBUG
        NSRLog(@"setChannelTimeoutWith was called with negative value or zero, setChannelTimeoutWithScheduled skipped");
#endif
    } else {
        NSDate *schedule = [[NSDate alloc] initWithTimeIntervalSinceNow:timeoutValueFromNowInSecond];
        [self setChannelTimeoutWithScheduled:schedule];
    }
}

- (void)setChannelTimeoutWithScheduled:(NSDate*)timeoutDate {
    self.scheduledTermination = timeoutDate;
}

- (void)setChannelCompleted:(BOOL)channelCompleted {
    if (_channelCompleted != channelCompleted) {
        _channelCompleted = channelCompleted;
        [self unsafeDisconnectAndPrepareForRelease];
    }
}

// MARK: - EXEC

- (BOOL)seatbeltCheckPassed {
    if (!self.representedSession) { self.channelCompleted = YES; return NO; }
    if (!self.representedChannel) { self.channelCompleted = YES; return NO; }
    return YES;
}

- (void)unsafeChannelRead {
    // two 128k frames do not belong on the event loop thread stack
    NSMutableData *bufferData = [[NSMutableData alloc] initWithLength:BUFFER_SIZE];
    NSMutableData *errorBufferData = [[NSMutableData alloc] initWithLength:BUFFER_SIZE];
    if (!bufferData || !errorBufferData) { return; }
    char *buffer = [bufferData mutableBytes];
    char *errorBuffer = [errorBufferData mutableBytes];

    long rcout = libssh2_channel_read(self.representedChannel, buffer, BUFFER_SIZE);
    long rcerr = libssh2_channel_read_stderr(self.representedChannel, errorBuffer, BUFFER_SIZE);

    if (rcout != LIBSSH2_ERROR_EAGAIN && rcout > 0) {
        NSString *read = [[NSString alloc] initWithBytes:buffer length:(NSUInteger)rcout encoding:NSUTF8StringEncoding];
        if (!read) {
            // a chunk holding invalid or split UTF-8 must not be dropped nor passed as nil
            read = [[NSString alloc] initWithBytes:buffer length:(NSUInteger)rcout encoding:NSISOLatin1StringEncoding];
        }
        if (read && self.receiveDataBlock) {
            self.receiveDataBlock(read);
        }
    }
    if (rcerr != LIBSSH2_ERROR_EAGAIN && rcerr > 0) {
        NSString *read = [[NSString alloc] initWithBytes:errorBuffer length:(NSUInteger)rcerr encoding:NSUTF8StringEncoding];
        if (!read) {
            read = [[NSString alloc] initWithBytes:errorBuffer length:(NSUInteger)rcerr encoding:NSISOLatin1StringEncoding];
        }
        if (read && self.receiveDataBlock) {
            self.receiveDataBlock(read);
        }
    }
}

/*
 Writes what the channel takes now and keeps the rest for the next tick.
 It must never wait here for the remote to take more: a remote whose
 input window is full may itself be waiting for us to read its output,
 and reading happens on this same tick; waiting would freeze both sides
 for good (pasting into a busy full-screen program did it). A partial
 write keeps the remainder instead of dropping it.
 */
- (void)unsafeChannelWrite {
    if (self.requestDataBlock) {
        NSString *requestedBuffer = self.requestDataBlock();
        if (requestedBuffer.length > 0) {
            NSData *data = [requestedBuffer dataUsingEncoding:NSUTF8StringEncoding];
            if (data.length > 0) { [self.pendingWrite appendData:data]; }
        }
    }
    while (self.pendingWrite.length > 0) {
        if ([self unsafeChannelShouldTerminate]) {
            [self.pendingWrite setLength:0];
            return;
        }
        // Actual number of bytes written or negative on failure.
        long rc = libssh2_channel_write(self.representedChannel, self.pendingWrite.bytes, self.pendingWrite.length);
        if (rc == LIBSSH2_ERROR_EAGAIN || rc == 0) {
            return; // the channel is full: the next tick, after reading
        }
        if (rc < 0) {
            NSRLog(@"error occurred during message write, consider terminated channel");
            [self.pendingWrite setLength:0];
            return;
        }
        [self.pendingWrite replaceBytesInRange:NSMakeRange(0, (NSUInteger)rc) withBytes:NULL length:0];
    }
}

- (BOOL)unsafeChannelShouldTerminate {
    do {
        if (self.scheduledTermination && [self.scheduledTermination timeIntervalSinceNow] < 0) {
            NSRLog(@"channel terminating due to timeout schedule");
            break;
        }
        if (self.continuationDecisionBlock && !self.continuationDecisionBlock()) {
            break;
        }
        long rc = libssh2_channel_eof(self.representedChannel);
        if (rc == 1) {
            break;
        }
        if (rc < 0 && rc != LIBSSH2_ERROR_EAGAIN) {
            break;
        }
        return NO;
    } while (0);
    self.channelCompleted = YES;
    return YES;
}

- (void)unsafeChannelTerminalSizeUpdate {
    // may called from outside
    if (![self seatbeltCheckPassed]) { return; }
    if (!self.requestTerminalSizeBlock) {
        return;
    }
    CGSize targetSize = self.requestTerminalSizeBlock();
    if (CGSizeEqualToSize(targetSize, self.currentTerminalSize)) {
        return;
    }
    // a wedged channel must not stall the loop here; giving up leaves
    // currentTerminalSize stale so a later tick retries the resize
    NSDate *resizeDeadline = [[NSDate alloc] initWithTimeIntervalSinceNow:LIBSSH2_CHANNEL_EAGAIN_TIMEOUT];
    while (true) {
        if ([resizeDeadline timeIntervalSinceNow] < 0) { return; }
        long rc = libssh2_channel_request_pty_size(self.representedChannel,
                                                   targetSize.width,
                                                   targetSize.height);
        if (rc == LIBSSH2_ERROR_EAGAIN) {
            usleep(LIBSSH2_CONTINUE_EAGAIN_WAIT);
            continue;
        }
        // don't check error here?
        break;
    }
    self.currentTerminalSize = targetSize;
}

- (void)unsafeCallNonblockingOperations {
    if (self.channelCompleted) { return; }
    if (![self seatbeltCheckPassed]) { return; }
    [self unsafeChannelRead];
    [self unsafeChannelTerminalSizeUpdate];
    [self unsafeChannelWrite];
    [self unsafeChannelShouldTerminate];
}

- (BOOL)unsafeInsanityCheckAndReturnDidSuccess {
    do {
        if (self.channelCompleted) { break; }
        if (![self seatbeltCheckPassed]) { break; }
        return YES;
    } while (0);
    return NO;
}

- (void)unsafeDisconnectAndPrepareForRelease {
    if (!self.channelCompleted) { self.channelCompleted = YES; }
    if (!self.representedSession) { return; }
    if (!self.representedChannel) { return; }
    LIBSSH2_CHANNEL *channel = self.representedChannel;
    self.representedChannel = NULL;
    self.representedSession = NULL;
    NSDate *channelTeardownDeadline = [[NSDate alloc] initWithTimeIntervalSinceNow:LIBSSH2_CHANNEL_EAGAIN_TIMEOUT];
    while (libssh2_channel_send_eof(channel) == LIBSSH2_ERROR_EAGAIN) {
        if ([channelTeardownDeadline timeIntervalSinceNow] < 0) { break; }
        usleep(LIBSSH2_CONTINUE_EAGAIN_WAIT);
    }
    while (libssh2_channel_close(channel) == LIBSSH2_ERROR_EAGAIN) {
        if ([channelTeardownDeadline timeIntervalSinceNow] < 0) { break; }
        usleep(LIBSSH2_CONTINUE_EAGAIN_WAIT);
    }
    while (libssh2_channel_wait_closed(channel) == LIBSSH2_ERROR_EAGAIN) {
        if ([channelTeardownDeadline timeIntervalSinceNow] < 0) { break; }
        usleep(LIBSSH2_CONTINUE_EAGAIN_WAIT);
    }
    int es = libssh2_channel_get_exit_status(channel);
    NSRLog(@"channel get exit status returns: %d", es);
    self.exitStatus = es;
    while (libssh2_channel_free(channel) == LIBSSH2_ERROR_EAGAIN) {
        if ([channelTeardownDeadline timeIntervalSinceNow] < 0) { break; }
        usleep(LIBSSH2_CONTINUE_EAGAIN_WAIT);
    }
    if (self.terminationBlock) { self.terminationBlock(); }
    self.terminationBlock = NULL;
}

@end
