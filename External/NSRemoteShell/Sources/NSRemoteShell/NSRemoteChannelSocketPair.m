//
//  NSRemoteChannelSocketPair.m
//  
//
//  Created by Lakr Aream on 2022/3/9.
//

#import "NSRemoteChannelSocketPair.h"

@interface NSRemoteChannelSocketPair ()

@property (nonatomic, nonnull, strong) NSMutableData *bufferData;

@end

@implementation NSRemoteChannelSocketPair

- (instancetype)initWithSocket:(int)socket
                   withChannel:(LIBSSH2_CHANNEL*)channel
{
    self = [super init];
    if (self) {
        _socket = socket;
        _channel = channel;
        _completed = NO;
        _bufferData = [[NSMutableData alloc] initWithLength:BUFFER_SIZE];
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &(int){1}, sizeof(int));
    }
    return self;
}

- (void)unsafeCallNonblockingOperations {
    if (self.completed) { return; }
    if (![self seatbeltCheckPassed]) { return; }
    [self unsafeProcessReadWrite];
}

- (void)unsafeProcessReadWrite {
    char *buf = [self.bufferData mutableBytes];
    if (!buf) { return; }

    long len = recv(self.socket, buf, BUFFER_SIZE, 0);
    if (len > 0) {
        long wr = 0;
        while (wr < len) {
            long i = libssh2_channel_write(self.channel, buf + wr, len - wr);
            if (LIBSSH2_ERROR_EAGAIN == i) { usleep(LIBSSH2_CONTINUE_EAGAIN_WAIT); continue; }
            if (i <= 0) {
                NSRLog(@"libssh2_channel_write returns failure %ld", len);
                self.completed = YES;
                return;
            }
            wr += i;
        }
    }

    len = libssh2_channel_read(self.channel, buf, BUFFER_SIZE);
    if (len > 0) {
        long wr = 0;
        while (wr < len) {
            long i = send(self.socket, buf + wr, len - wr, 0);
            if (i <= 0) { self.completed = YES; return; }
            wr += i;
        }
    } else if (len != LIBSSH2_ERROR_EAGAIN) {
        NSRLog(@"libssh2_channel_read returns failure %ld", len);
        self.completed = YES;
        return;
    }
}

- (void)setCompleted:(BOOL)completed {
    if (_completed != completed) {
        _completed = completed;
        [self unsafeDisconnectAndPrepareForRelease];
    }
}

- (BOOL)seatbeltCheckPassed {
    if (!self.channel) { self.completed = YES; return NO; }
    if (!self.socket) { self.completed = YES; return NO; }
    return YES;
}

- (BOOL)unsafeInsanityCheckAndReturnDidSuccess {
    if (self.completed) { return NO; }
    if (![self seatbeltCheckPassed]) { return NO; }
    if (libssh2_channel_eof(self.channel)) { return NO; }
    return YES;
}

- (void)unsafeDisconnectAndPrepareForRelease {
    if (!self.completed) { self.completed = YES; }
    if (!self.channel) { return; }
    if (!self.socket) { return; }
    LIBSSH2_CHANNEL *channel = self.channel;
    [GenericNetworking destroyNativeSocket:self.socket];
    self.channel = NULL;
    self.socket = 0;
    LIBSSH2_CHANNEL_SHUTDOWN(channel);
}

@end
