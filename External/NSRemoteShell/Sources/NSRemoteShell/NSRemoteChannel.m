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
// reusable buffers and incomplete UTF-8 tail caches for stdout and stderr
@property (nonatomic, nonnull, strong) NSMutableData *readBufferData;
@property (nonatomic, nonnull, strong) NSMutableData *errorBufferData;
@property (nonatomic, nonnull, strong) NSMutableData *pendingStdoutUTF8;
@property (nonatomic, nonnull, strong) NSMutableData *pendingStderrUTF8;

@property (nonatomic, nullable, strong) NSDate *scheduledTermination;
@property (nonatomic, nullable, strong) dispatch_block_t terminationBlock;

@property (nonatomic, readwrite) BOOL channelCompleted;
@property (nonatomic, readwrite, assign) int exitStatus;

@end

@implementation NSRemoteChannel

static NSUInteger NSRemoteUTF8CompletePrefixLength(const uint8_t *bytes, NSUInteger length) {
    if (length == 0) { return 0; }
    NSUInteger idx = length;
    NSUInteger trailingContinuations = 0;
    while (idx > 0 && trailingContinuations < 3) {
        uint8_t b = bytes[idx - 1];
        if ((b & 0xC0) == 0x80) {
            trailingContinuations += 1;
            idx -= 1;
        } else {
            break;
        }
    }
    if (idx == 0) {
        return length;
    }
    uint8_t lead = bytes[idx - 1];
    NSUInteger expectedLen = 1;
    if ((lead & 0x80) == 0x00) {
        return length;
    } else if ((lead & 0xE0) == 0xC0) {
        expectedLen = 2;
    } else if ((lead & 0xF0) == 0xE0) {
        expectedLen = 3;
    } else if ((lead & 0xF8) == 0xF0) {
        expectedLen = 4;
    } else {
        return length;
    }
    NSUInteger actualLen = 1 + trailingContinuations;
    if (actualLen < expectedLen) {
        return idx - 1;
    }
    return length;
}

static NSString * _Nullable NSRemoteDecodeUTF8StreamChunk(NSMutableData *accumulator, const char *bytes, NSUInteger length, BOOL flushAll) {
    if (length > 0 && bytes != NULL) {
        [accumulator appendBytes:bytes length:length];
    }
    if (accumulator.length == 0) {
        return nil;
    }
    NSUInteger decodeLen = flushAll
        ? accumulator.length
        : NSRemoteUTF8CompletePrefixLength((const uint8_t *)accumulator.bytes, accumulator.length);
    if (decodeLen == 0) {
        return nil;
    }
    NSString *decoded = [[NSString alloc] initWithBytes:accumulator.bytes length:decodeLen encoding:NSUTF8StringEncoding];
    if (!decoded) {
        decoded = [[NSString alloc] initWithBytes:accumulator.bytes length:decodeLen encoding:NSISOLatin1StringEncoding];
    }
    [accumulator replaceBytesInRange:NSMakeRange(0, decodeLen) withBytes:NULL length:0];
    return decoded;
}

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
        _readBufferData = [[NSMutableData alloc] initWithLength:BUFFER_SIZE];
        _errorBufferData = [[NSMutableData alloc] initWithLength:BUFFER_SIZE];
        _pendingStdoutUTF8 = [[NSMutableData alloc] init];
        _pendingStderrUTF8 = [[NSMutableData alloc] init];
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
    char *buffer = [self.readBufferData mutableBytes];
    char *errorBuffer = [self.errorBufferData mutableBytes];
    if (!buffer || !errorBuffer) { return; }

    while (true) {
        long rcout = libssh2_channel_read(self.representedChannel, buffer, BUFFER_SIZE);
        if (rcout > 0) {
            NSString *read = NSRemoteDecodeUTF8StreamChunk(self.pendingStdoutUTF8, buffer, (NSUInteger)rcout, NO);
            if (read && self.receiveDataBlock) {
                self.receiveDataBlock(read);
            }
            if (rcout == BUFFER_SIZE) {
                continue;
            }
        }
        break;
    }

    while (true) {
        long rcerr = libssh2_channel_read_stderr(self.representedChannel, errorBuffer, BUFFER_SIZE);
        if (rcerr > 0) {
            NSString *read = NSRemoteDecodeUTF8StreamChunk(self.pendingStderrUTF8, errorBuffer, (NSUInteger)rcerr, NO);
            if (read && self.receiveDataBlock) {
                self.receiveDataBlock(read);
            }
            if (rcerr == BUFFER_SIZE) {
                continue;
            }
        }
        break;
    }
}

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
        long rc = libssh2_channel_write(self.representedChannel, self.pendingWrite.bytes, self.pendingWrite.length);
        if (rc == LIBSSH2_ERROR_EAGAIN || rc == 0) {
            return;
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
    if (self.scheduledTermination && [self.scheduledTermination timeIntervalSinceNow] < 0) {
        NSRLog(@"channel terminating due to timeout schedule");
        self.channelCompleted = YES;
        return YES;
    }
    if (self.continuationDecisionBlock && !self.continuationDecisionBlock()) {
        self.channelCompleted = YES;
        return YES;
    }
    long rc = libssh2_channel_eof(self.representedChannel);
    if (rc == 1 || (rc < 0 && rc != LIBSSH2_ERROR_EAGAIN)) {
        self.channelCompleted = YES;
        return YES;
    }
    return NO;
}

- (void)unsafeChannelTerminalSizeUpdate {
    if (![self seatbeltCheckPassed]) { return; }
    if (!self.requestTerminalSizeBlock) {
        return;
    }
    CGSize targetSize = self.requestTerminalSizeBlock();
    if (CGSizeEqualToSize(targetSize, self.currentTerminalSize)) {
        return;
    }
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
    if (self.channelCompleted) { return NO; }
    if (![self seatbeltCheckPassed]) { return NO; }
    return YES;
}

- (void)unsafeDisconnectAndPrepareForRelease {
    if (!self.channelCompleted) { self.channelCompleted = YES; }
    if (!self.representedSession) { return; }
    if (!self.representedChannel) { return; }
    if (self.pendingStdoutUTF8.length > 0 && self.receiveDataBlock) {
        NSString *tail = NSRemoteDecodeUTF8StreamChunk(self.pendingStdoutUTF8, NULL, 0, YES);
        if (tail) { self.receiveDataBlock(tail); }
    }
    if (self.pendingStderrUTF8.length > 0 && self.receiveDataBlock) {
        NSString *tail = NSRemoteDecodeUTF8StreamChunk(self.pendingStderrUTF8, NULL, 0, YES);
        if (tail) { self.receiveDataBlock(tail); }
    }
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
