//
//  GenericNetworking.m
//
//
//  Created by Lakr Aream on 2022/2/5.
//

#import "GenericNetworking.h"

#import <netinet/tcp.h>

/*
 waits for a non-blocking connect() to settle on a socket
 select is retried on EINTR against an absolute deadline so a signal
 can not stretch the wait past the requested timeout
 */
static BOOL NSRWaitForSocketWritable(int sock, double timeoutSeconds) {
    if (timeoutSeconds <= 0) { timeoutSeconds = GENERIC_SOCKET_CONNECT_TIMEOUT; }
    struct timeval deadline;
    gettimeofday(&deadline, NULL);
    deadline.tv_sec += (time_t)timeoutSeconds;
    deadline.tv_usec += (suseconds_t)((timeoutSeconds - (double)(time_t)timeoutSeconds) * 1000000);
    if (deadline.tv_usec >= 1000000) {
        deadline.tv_sec += 1;
        deadline.tv_usec -= 1000000;
    }
    while (true) {
        struct timeval now;
        gettimeofday(&now, NULL);
        struct timeval tv;
        tv.tv_sec = deadline.tv_sec - now.tv_sec;
        tv.tv_usec = deadline.tv_usec - now.tv_usec;
        if (tv.tv_usec < 0) {
            tv.tv_sec -= 1;
            tv.tv_usec += 1000000;
        }
        if (tv.tv_sec < 0) { return NO; }
        fd_set wset;
        FD_ZERO(&wset);
        FD_SET(sock, &wset);
        int rc = select(sock + 1, NULL, &wset, NULL, &tv);
        if (rc > 0) { break; }
        if (rc < 0 && errno == EINTR) { continue; }
        return NO;
    }
    int socketError = 0;
    socklen_t socketErrorLength = sizeof(socketError);
    if (getsockopt(sock, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) != 0) {
        return NO;
    }
    return socketError == 0;
}

@implementation GenericNetworking

+ (NSArray *)resolveIpAddressesFor:(NSString*)candidateHost
{
    if (!candidateHost) return [[NSArray alloc] init];
    NSArray<NSData*> *candidateHostData = [[NSArray alloc] init];
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = PF_UNSPEC;        // PF_INET if you want only IPv4 addresses
    hints.ai_protocol = IPPROTO_TCP;
    struct addrinfo *addrs = NULL, *addr;
    int rc = getaddrinfo([candidateHost UTF8String], NULL, &hints, &addrs);
    if (rc != 0) {
        NSRLog(@"resolving host %@ failed: %s", candidateHost, gai_strerror(rc));
        return [[NSArray alloc] init];
    }
    for (addr = addrs; addr; addr = addr->ai_next) {
        char host[NI_MAXHOST];
        getnameinfo(addr->ai_addr, addr->ai_addrlen, host, sizeof(host), NULL, 0, NI_NUMERICHOST);
        if (strlen(host) <= 0) { continue; }
        NSString *hostStr = [[NSString alloc] initWithUTF8String:host];
        NSRLog(@"resolving host %@ loading result: %@", candidateHost, hostStr);
        NSData *build = [[NSData alloc] initWithBytes:addr->ai_addr length: addr->ai_addrlen];
        candidateHostData = [candidateHostData arrayByAddingObject:build];
    }
    freeaddrinfo(addrs);
    return candidateHostData;
}

+ (BOOL)isValidateWithPort:(NSNumber*)port {
    int p = [port intValue];
    // we are treating 0 as a valid port and technically it should work!
    if (p >= 0 && p <= 65535) {
        return YES;
    }
    return NO;
}

+ (int)createSocketNonblockingListenerWithLocalPort:(NSNumber*)localPort
{
    if (![GenericNetworking isValidateWithPort:localPort]) {
        NSRLog(@"invalid port %@", [localPort stringValue]);
        return 0;
    }
    
    int port = [localPort intValue];
    struct sockaddr_in server4;
    int socket_desc4 = socket(AF_INET, SOCK_STREAM, 0);
    if (socket_desc4 <= 0) {
        NSRLog(@"failed to create socket for ipv4 at port %d", port);
        return 0;
    }
    server4.sin_family = AF_INET;
    server4.sin_addr.s_addr = inet_addr("127.0.0.1"); // for security?
    server4.sin_port = htons(port);
    if (setsockopt(socket_desc4, SOL_SOCKET, SO_REUSEADDR, &(int){1}, sizeof(int)) == -1) {
        NSRLog(@"failed to setsockopt for ipv4 at port %d", port);
        close(socket_desc4);
        return 0;
    }
    if (bind(socket_desc4, (struct sockaddr*)&server4, sizeof(server4)) < 0) {
        NSRLog(@"failed to bind socket for ipv4 at port %d", port);
        close(socket_desc4);
        return 0;
    } else {
        NSRLog(@"bound listener v4 for port %d", port);
    }
    if (fcntl(socket_desc4, F_SETFL, fcntl(socket_desc4, F_GETFL, 0) | O_NONBLOCK) == -1) {
        NSRLog(@"failed to call fcntl for none-blocking ipv4 at port %d", port);
        close(socket_desc4);
        return 0;
    }
    if (listen(socket_desc4, SOCKET_QUEUE_MAXSIZE) == -1) {
        NSRLog(@"failed to call fcntl for none-blocking ipv6 at port %d", port);
        close(socket_desc4);
        return 0;
    }
    
    NSRLog(@"socket listener for port %d booted", port);
    return socket_desc4;
}

+ (int)createSocketWithTargetHost:(NSString *)targetHost
                   withTargetPort:(NSNumber *)targetPort
             requireNonblockingIO:(BOOL)useNonblocking
{
    return [self createSocketWithTargetHost:targetHost
                             withTargetPort:targetPort
                       requireNonblockingIO:useNonblocking
                         withConnectTimeout:@(GENERIC_SOCKET_CONNECT_TIMEOUT)];
}

+ (int)createSocketWithTargetHost:(NSString *)targetHost
                   withTargetPort:(NSNumber *)targetPort
             requireNonblockingIO:(BOOL)useNonblocking
               withConnectTimeout:(NSNumber *)connectTimeout
{
    if (![self isValidateWithPort:targetPort]) { return 0; }
    int candidatePort = [targetPort intValue];
    NSArray *addrData = [self resolveIpAddressesFor:targetHost];
    if (!addrData) { return 0; }
    for (id candidateHostData in addrData) {
        if ([candidateHostData length] == sizeof(struct sockaddr_in)) {
            struct sockaddr_in address4;
            [candidateHostData getBytes:&address4 length:sizeof(address4)];
            address4.sin_port = htons(candidatePort);
            char str[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &(address4.sin_addr), str, INET_ADDRSTRLEN);
            int forwardsock = socket(PF_INET, SOCK_STREAM, IPPROTO_TCP);
            if (forwardsock <= 0) {
                NSRLog(@"socket failed to create, trying next");
                continue;
            }
            setsockopt(forwardsock, SOL_SOCKET, SO_NOSIGPIPE, &(int){1}, sizeof(int));
            // connect() must run non-blocking even when the caller wants a
            // blocking socket, otherwise a dropped packet parks us for the
            // full kernel tcp timeout; blocking mode is restored afterwards
            if (fcntl(forwardsock, F_SETFL, fcntl(forwardsock, F_GETFL, 0) | O_NONBLOCK) == -1) {
                NSRLog(@"failed to call fcntl for none-blocking for socket %d", forwardsock);
                close(forwardsock);
                continue;
            }
            int rv = connect(forwardsock, (struct sockaddr*)&address4, sizeof(struct sockaddr_in));
            if (rv != 0) {
                if (errno != EINPROGRESS && errno != EINTR) {
                    NSRLog(@"socket failed to connect, trying next address");
                    close(forwardsock);
                    continue;
                }
                if (!NSRWaitForSocketWritable(forwardsock, [connectTimeout doubleValue])) {
                    NSRLog(@"socket failed to connect before deadline, trying next address");
                    close(forwardsock);
                    continue;
                }
            }
            if (!useNonblocking && fcntl(forwardsock, F_SETFL, fcntl(forwardsock, F_GETFL, 0) & ~O_NONBLOCK) == -1) {
                NSRLog(@"failed to restore blocking io for socket %d", forwardsock);
                close(forwardsock);
                continue;
            }
            NSRConfigureLiveness(forwardsock);
            NSRLog(@"created socket %d to address %s", forwardsock, str);
            return forwardsock;
        } else if ([candidateHostData length] == sizeof(struct sockaddr_in6)) {
            struct sockaddr_in6 address6;
            [candidateHostData getBytes:&address6 length:sizeof(address6)];
            address6.sin6_port = htons(candidatePort);
            char str[INET6_ADDRSTRLEN];
            inet_ntop(AF_INET6, &(address6.sin6_addr), str, INET6_ADDRSTRLEN);
            int forwardsock = socket(PF_INET6, SOCK_STREAM, IPPROTO_TCP);
            if (forwardsock <= 0) {
                NSRLog(@"socket failed to create, trying next");
                continue;
            }
            setsockopt(forwardsock, SOL_SOCKET, SO_NOSIGPIPE, &(int){1}, sizeof(int));
            if (fcntl(forwardsock, F_SETFL, fcntl(forwardsock, F_GETFL, 0) | O_NONBLOCK) == -1) {
                NSRLog(@"failed to call fcntl for none-blocking for socket %d", forwardsock);
                close(forwardsock);
                continue;
            }
            int rv = connect(forwardsock, (struct sockaddr*)&address6, sizeof(struct sockaddr_in6));
            if (rv != 0) {
                if (errno != EINPROGRESS && errno != EINTR) {
                    NSRLog(@"socket failed to connect, trying next address");
                    close(forwardsock);
                    continue;
                }
                if (!NSRWaitForSocketWritable(forwardsock, [connectTimeout doubleValue])) {
                    NSRLog(@"socket failed to connect before deadline, trying next address");
                    close(forwardsock);
                    continue;
                }
            }
            if (!useNonblocking && fcntl(forwardsock, F_SETFL, fcntl(forwardsock, F_GETFL, 0) & ~O_NONBLOCK) == -1) {
                NSRLog(@"failed to restore blocking io for socket %d", forwardsock);
                close(forwardsock);
                continue;
            }
            NSRConfigureLiveness(forwardsock);
            NSRLog(@"created socket %d to address %s", forwardsock, str);
            return forwardsock;
        } else {
            NSRLog(@"unrecognized address candidate size");
            continue;
        }
    }
    return 0;
}

/*
 A connection whose network went away (sleep, a new Wi-Fi, a NAT that
 forgot it) must end rather than hang: probe an idle link after 30 s, and
 drop one that stops acknowledging for 30 s, instead of the minutes TCP
 would otherwise retransmit for.
 */
static void NSRConfigureLiveness(int socketDescriptor) {
    setsockopt(socketDescriptor, SOL_SOCKET, SO_KEEPALIVE, &(int){1}, sizeof(int));
    setsockopt(socketDescriptor, IPPROTO_TCP, TCP_KEEPALIVE, &(int){30}, sizeof(int));
    setsockopt(socketDescriptor, IPPROTO_TCP, TCP_KEEPINTVL, &(int){10}, sizeof(int));
    setsockopt(socketDescriptor, IPPROTO_TCP, TCP_KEEPCNT, &(int){3}, sizeof(int));
#ifdef TCP_RXT_CONNDROPTIME
    setsockopt(socketDescriptor, IPPROTO_TCP, TCP_RXT_CONNDROPTIME, &(int){30}, sizeof(int));
#endif
}

+ (void)destroyNativeSocket:(int)socketDescriptor {
    if (socketDescriptor > 0) {
        NSRLog(@"closing socket fd %d", socketDescriptor);
        close(socketDescriptor);
    }
}

+ (NSString*)getResolvedIpAddressWith:(int)socket {
    if (!socket) { return @""; }
    struct sockaddr_storage sin;
    socklen_t len = sizeof(sin);
    getpeername(socket, (struct sockaddr*)&sin, &len);
    char buf[255];
    memset(buf, 0, sizeof(buf));
    switch(sin.ss_family) {
        case AF_INET: {
            struct sockaddr_in *addr_in = (struct sockaddr_in *)&sin;
            inet_ntop(AF_INET, &(addr_in->sin_addr), buf, INET_ADDRSTRLEN);
            break;
        }
        case AF_INET6: {
            struct sockaddr_in6 *addr_in6 = (struct sockaddr_in6 *)&sin;
            inet_ntop(AF_INET6, &(addr_in6->sin6_addr), buf, INET6_ADDRSTRLEN);
            break;
        }
        default:
            break;
    }
    return [[NSString alloc] initWithUTF8String:buf];
}

@end
