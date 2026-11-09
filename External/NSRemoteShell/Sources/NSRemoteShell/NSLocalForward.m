//
//  NSLocalForward.m
//  
//
//  Created by Lakr Aream on 2022/3/9.
//

#import "NSLocalForward.h"
#import <arpa/inet.h>

typedef NS_ENUM(NSInteger, NSSOCKSHandshakeStage) {
    NSSOCKSHandshakeStageGreeting = 0,
    NSSOCKSHandshakeStageRequest = 1,
};

@interface NSPendingSOCKSConnection : NSObject
@property (nonatomic, assign) int socket;
@property (nonatomic, assign) NSSOCKSHandshakeStage stage;
@property (nonatomic, strong) NSMutableData *buffer;
@property (nonatomic, strong) NSDate *deadline;
@end

@implementation NSPendingSOCKSConnection
- (instancetype)initWithSocket:(int)socket timeout:(NSTimeInterval)timeout {
    self = [super init];
    if (self) {
        _socket = socket;
        _stage = NSSOCKSHandshakeStageGreeting;
        _buffer = [[NSMutableData alloc] init];
        _deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(timeout, 10)];
    }
    return self;
}
@end

@interface NSLocalForward ()

@property (nonatomic, readwrite, strong) NSString *targetHost;
@property (nonatomic, readwrite, strong) NSNumber *targetPort;
@property (nonatomic, readwrite, strong) NSNumber *localPort;
@property (nonatomic, readwrite, strong) NSNumber *timeout;
@property (nonatomic, readwrite, assign) BOOL dynamicSOCKS;

@property (nonatomic, nullable, readwrite, assign) LIBSSH2_SESSION *representedSession;
@property (nonatomic, readwrite, assign) int representedSocket;
@property (nonatomic, nonnull, readwrite, strong) NSMutableArray *forwardSocketPair;
@property (nonatomic, nonnull, readwrite, strong) NSMutableArray<NSPendingSOCKSConnection *> *pendingSOCKSConnections;
@property (nonatomic, nullable, strong) dispatch_block_t terminationBlock;
@property (nonatomic, nullable, strong) NSRemoteChannelContinuationBlock continuationDecisionBlock;
@property (nonatomic, readwrite) BOOL forwardCompleted;

@end

@implementation NSLocalForward

- (instancetype)initWithRepresentedSession:(LIBSSH2_SESSION *)representedSession
                     withRepresentedSocket:(int)socketDescriptor
                            withTargetHost:(NSString*)withTargetHost
                            withTargetPort:(NSNumber*)withTargetPort
                             withLocalPort:(NSNumber*)withLocalPort
                               withTimeout:(NSNumber *)withTimeout
{
    self = [super init];
    if (self) {
        _targetHost = withTargetHost;
        _targetPort = withTargetPort;
        _localPort = withLocalPort;
        _timeout = withTimeout;
        _dynamicSOCKS = NO;
        _representedSession = representedSession;
        _representedSocket = socketDescriptor;
        _forwardSocketPair = [[NSMutableArray alloc] init];
        _pendingSOCKSConnections = [[NSMutableArray alloc] init];
        _forwardCompleted = NO;
    }
    return self;
}

- (instancetype)initDynamicSOCKSWithRepresentedSession:(LIBSSH2_SESSION *)representedSession
                                 withRepresentedSocket:(int)socketDescriptor
                                         withLocalPort:(NSNumber *)withLocalPort
                                           withTimeout:(NSNumber *)withTimeout
{
    self = [self initWithRepresentedSession:representedSession
                      withRepresentedSocket:socketDescriptor
                             withTargetHost:@""
                             withTargetPort:@(0)
                              withLocalPort:withLocalPort
                                withTimeout:withTimeout];
    if (self) {
        _dynamicSOCKS = YES;
    }
    return self;
}

- (void)onTermination:(dispatch_block_t)terminationHandler {
    self.terminationBlock = terminationHandler;
}

- (void)setContinuationChain:(NSRemoteChannelContinuationBlock _Nonnull)continuation {
    self.continuationDecisionBlock = continuation;
}

- (void)setForwardCompleted:(BOOL)channelCompleted {
    if (_forwardCompleted != channelCompleted) {
        _forwardCompleted = channelCompleted;
        [self unsafeDisconnectAndPrepareForRelease];
    }
}

- (BOOL)seatbeltCheckPassed {
    if (!self.representedSession) { self.forwardCompleted = YES; return NO; }
    if (!self.representedSocket) { self.forwardCompleted = YES; return NO; }
    return YES;
}

- (void)unsafeCallNonblockingOperations {
    if (self.forwardCompleted) { return; }
    if (![self seatbeltCheckPassed]) { return; }
    [self unsafeChannelMainSocketAccept];
    if (self.dynamicSOCKS) {
        [self unsafeProcessPendingSOCKSConnections];
    }
    [self unsafeProcessAllSocket];
    [self unsafeChannelShouldTerminate];
}

- (void)unsafeProcessAllSocket {
    NSMutableArray *newArray = [[NSMutableArray alloc] init];
    for (NSRemoteChannelSocketPair *pair in self.forwardSocketPair) {
        if (![pair unsafeInsanityCheckAndReturnDidSuccess]) {
            [pair unsafeDisconnectAndPrepareForRelease];
            continue;
        }
        [pair unsafeCallNonblockingOperations];
        if (![pair unsafeInsanityCheckAndReturnDidSuccess]) {
            [pair unsafeDisconnectAndPrepareForRelease];
            continue;
        }
        [newArray addObject:pair];
    }
    self.forwardSocketPair = newArray;
}

- (void)unsafeChannelMainSocketAccept {
    while (1) {
        struct sockaddr_in peeraddr;
        socklen_t peeraddrlen = sizeof(peeraddr);
        int forwardsock = accept(self.representedSocket, (struct sockaddr *)&peeraddr, &peeraddrlen);
        if (forwardsock <= 0) { return; }
        setsockopt(forwardsock, SOL_SOCKET, SO_NOSIGPIPE, &(int){1}, sizeof(int));
        int flags = fcntl(forwardsock, F_GETFL, 0);
        if (flags >= 0) {
            fcntl(forwardsock, F_SETFL, flags | O_NONBLOCK);
        }
        if (self.dynamicSOCKS) {
            NSPendingSOCKSConnection *pending = [[NSPendingSOCKSConnection alloc] initWithSocket:forwardsock
                                                                                         timeout:[self.timeout doubleValue]];
            [self.pendingSOCKSConnections addObject:pending];
            continue;
        }
        NSRLog(@"accept is returning child socket %d", forwardsock);
        NSDate *date = [[NSDate alloc] initWithTimeIntervalSinceNow:[self.timeout intValue]];
        LIBSSH2_CHANNEL *channel = NULL;
        while (true) {
            if ([date timeIntervalSinceNow] < 0) {
                libssh2_session_set_last_error(self.representedSession, LIBSSH2_ERROR_TIMEOUT, NULL);
                break;
            }
            LIBSSH2_CHANNEL *channelBuilder = libssh2_channel_direct_tcpip_ex(self.representedSession,
                                                                              [self.targetHost UTF8String],
                                                                              [self.targetPort intValue],
                                                                              "127.0.0.1",
                                                                              [self.localPort intValue]);
            if (channelBuilder) {
                channel = channelBuilder;
                break;
            }
            long rc = libssh2_session_last_errno(self.representedSession);
            if (rc == LIBSSH2_ERROR_EAGAIN) {
                usleep(LIBSSH2_CONTINUE_EAGAIN_WAIT);
                continue;
            }
            break;
        }
        if (!channel) {
            NSRLog(@"accepted connection failed to open channel");
            close(forwardsock);
            continue;
        }
        NSRLog(@"created channel for forward socket %d %p", forwardsock, channel);
        NSRemoteChannelSocketPair *pair = [[NSRemoteChannelSocketPair alloc] initWithSocket:forwardsock
                                                                                withChannel:channel];
        [self.forwardSocketPair addObject:pair];
    }
}

- (void)unsafeProcessPendingSOCKSConnections {
    if ([self.pendingSOCKSConnections count] == 0) { return; }
    NSMutableArray<NSPendingSOCKSConnection *> *kept = [[NSMutableArray alloc] init];
    uint8_t temp[512];
    for (NSPendingSOCKSConnection *conn in self.pendingSOCKSConnections) {
        if ([conn.deadline timeIntervalSinceNow] < 0) {
            close(conn.socket);
            continue;
        }
        ssize_t n = recv(conn.socket, temp, sizeof(temp), 0);
        if (n > 0) {
            [conn.buffer appendBytes:temp length:(NSUInteger)n];
        } else if (n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
            close(conn.socket);
            continue;
        }

        const uint8_t *bytes = [conn.buffer bytes];
        NSUInteger len = [conn.buffer length];

        if (conn.stage == NSSOCKSHandshakeStageGreeting) {
            if (len < 2) {
                [kept addObject:conn];
                continue;
            }
            if (bytes[0] != 0x05) {
                close(conn.socket);
                continue;
            }
            uint8_t nmethods = bytes[1];
            if (len < (NSUInteger)(2 + nmethods)) {
                [kept addObject:conn];
                continue;
            }
            uint8_t reply[2] = {0x05, 0x00};
            if (send(conn.socket, reply, 2, 0) != 2) {
                close(conn.socket);
                continue;
            }
            [conn.buffer replaceBytesInRange:NSMakeRange(0, 2 + nmethods) withBytes:NULL length:0];
            conn.stage = NSSOCKSHandshakeStageRequest;
            bytes = [conn.buffer bytes];
            len = [conn.buffer length];
        }

        if (conn.stage == NSSOCKSHandshakeStageRequest) {
            if (len < 4) {
                [kept addObject:conn];
                continue;
            }
            if (bytes[0] != 0x05 || bytes[1] != 0x01) {
                uint8_t errReply[10] = {0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0};
                send(conn.socket, errReply, sizeof(errReply), 0);
                close(conn.socket);
                continue;
            }
            uint8_t atyp = bytes[3];
            NSString *destHost = nil;
            NSUInteger headerLen = 0;
            if (atyp == 0x01) {
                if (len < 10) { [kept addObject:conn]; continue; }
                char ipStr[INET_ADDRSTRLEN] = {0};
                inet_ntop(AF_INET, bytes + 4, ipStr, sizeof(ipStr));
                destHost = [NSString stringWithUTF8String:ipStr];
                headerLen = 10;
            } else if (atyp == 0x03) {
                if (len < 5) { [kept addObject:conn]; continue; }
                uint8_t dlen = bytes[4];
                if (len < (NSUInteger)(5 + dlen + 2)) { [kept addObject:conn]; continue; }
                destHost = [[NSString alloc] initWithBytes:(bytes + 5) length:dlen encoding:NSUTF8StringEncoding];
                headerLen = 5 + dlen + 2;
            } else if (atyp == 0x04) {
                if (len < 22) { [kept addObject:conn]; continue; }
                char ip6Str[INET6_ADDRSTRLEN] = {0};
                inet_ntop(AF_INET6, bytes + 4, ip6Str, sizeof(ip6Str));
                destHost = [NSString stringWithUTF8String:ip6Str];
                headerLen = 22;
            } else {
                close(conn.socket);
                continue;
            }
            if (!destHost || [destHost length] == 0) {
                close(conn.socket);
                continue;
            }
            uint16_t destPort = ((uint16_t)bytes[headerLen - 2] << 8) | (uint16_t)bytes[headerLen - 1];
            [conn.buffer replaceBytesInRange:NSMakeRange(0, headerLen) withBytes:NULL length:0];

            NSDate *date = [[NSDate alloc] initWithTimeIntervalSinceNow:[self.timeout intValue]];
            LIBSSH2_CHANNEL *channel = NULL;
            while (true) {
                if ([date timeIntervalSinceNow] < 0) {
                    libssh2_session_set_last_error(self.representedSession, LIBSSH2_ERROR_TIMEOUT, NULL);
                    break;
                }
                LIBSSH2_CHANNEL *ch = libssh2_channel_direct_tcpip_ex(self.representedSession,
                                                                      [destHost UTF8String],
                                                                      (int)destPort,
                                                                      "127.0.0.1",
                                                                      [self.localPort intValue]);
                if (ch) {
                    channel = ch;
                    break;
                }
                long rc = libssh2_session_last_errno(self.representedSession);
                if (rc == LIBSSH2_ERROR_EAGAIN) {
                    usleep(LIBSSH2_CONTINUE_EAGAIN_WAIT);
                    continue;
                }
                break;
            }
            if (!channel) {
                uint8_t failReply[10] = {0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0};
                send(conn.socket, failReply, sizeof(failReply), 0);
                close(conn.socket);
                continue;
            }
            uint8_t okReply[10] = {0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0};
            if (send(conn.socket, okReply, sizeof(okReply), 0) != sizeof(okReply)) {
                LIBSSH2_CHANNEL_SHUTDOWN(channel);
                close(conn.socket);
                continue;
            }
            if ([conn.buffer length] > 0) {
                const char *rem = [conn.buffer bytes];
                NSUInteger remLen = [conn.buffer length];
                NSUInteger wr = 0;
                while (wr < remLen) {
                    ssize_t w = libssh2_channel_write(channel, rem + wr, remLen - wr);
                    if (w == LIBSSH2_ERROR_EAGAIN) { usleep(LIBSSH2_CONTINUE_EAGAIN_WAIT); continue; }
                    if (w <= 0) { break; }
                    wr += (NSUInteger)w;
                }
            }
            NSRemoteChannelSocketPair *pair = [[NSRemoteChannelSocketPair alloc] initWithSocket:conn.socket
                                                                                    withChannel:channel];
            [self.forwardSocketPair addObject:pair];
        }
    }
    self.pendingSOCKSConnections = kept;
}

- (BOOL)unsafeChannelShouldTerminate {
    do {
        if (self.continuationDecisionBlock && !self.continuationDecisionBlock()) {
            break;
        }
        return NO;
    } while (0);
    self.forwardCompleted = YES;
    return YES;
}

- (BOOL)unsafeInsanityCheckAndReturnDidSuccess {
    do {
        if (self.forwardCompleted) { break; }
        if (![self seatbeltCheckPassed]) { break; }
        return YES;
    } while (0);
    return NO;
}

- (void)unsafeDisconnectAndPrepareForRelease {
    if (!self.forwardCompleted) { self.forwardCompleted = YES; }
    if (!self.representedSession) { return; }
    if (!self.representedSocket) { return; }
    int socket = self.representedSocket;
    [GenericNetworking destroyNativeSocket:socket];
    self.representedSession = NULL;
    self.representedSocket = 0;
    for (NSPendingSOCKSConnection *conn in self.pendingSOCKSConnections) {
        close(conn.socket);
    }
    self.pendingSOCKSConnections = [[NSMutableArray alloc] init];
    for (NSRemoteChannelSocketPair *pair in self.forwardSocketPair) {
        [pair unsafeDisconnectAndPrepareForRelease];
    }
    self.forwardSocketPair = [[NSMutableArray alloc] init];
    if (self.terminationBlock) { self.terminationBlock(); }
    self.terminationBlock = NULL;
}

@end
