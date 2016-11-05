//
//  iTermWebSocketConnection.m
//  iTerm2
//
//  Created by George Nachman on 11/4/16.
//
//

#import "iTermWebSocketConnection.h"
#import "DebugLogging.h"
#import "iTermHTTPConnection.h"
#import "iTermWebSocketFrame.h"
#import "iTermWebSocketFrameBuilder.h"
#import "NSData+iTerm.h"

#import <CommonCrypto/CommonDigest.h>

#if DEBUG
#define ENABLE_WEBSOCKET_TESTING 1
#else
#define ENABLE_WEBSOCKET_TESTING 0
#endif

#define ILog ELog

static NSString *const kProtocolName = @"api.iterm2.com";
static const NSInteger kWebSocketVersion = 13;

typedef NS_ENUM(NSUInteger, iTermWebSocketConnectionState) {
    iTermWebSocketConnectionStateConnecting,
    iTermWebSocketConnectionStateOpen,
    iTermWebSocketConnectionStateClosing,
    iTermWebSocketConnectionStateClosed
};

@implementation iTermWebSocketConnection {
    iTermHTTPConnection *_connection;
    iTermWebSocketConnectionState _state;
    iTermWebSocketFrame *_fragment;
    dispatch_queue_t _queue;
    iTermWebSocketFrameBuilder *_frameBuilder;
    dispatch_io_t _channel;
}

+ (BOOL)validateRequest:(NSURLRequest *)request {
    if (![request.HTTPMethod isEqualToString:@"GET"]) {
        ILog(@"Method not GET");
        return NO;
    }
    if (request.URL.path.length == 0) {
        ILog(@"Empty path");
        return NO;
    }
    NSDictionary<NSString *, NSString *> *headers = request.allHTTPHeaderFields;
    NSDictionary<NSString *, NSString *> *requiredValues =
        @{ @"upgrade": @"websocket",
           @"connection": @"Upgrade",
           @"sec-websocket-protocol": kProtocolName,
#if !ENABLE_WEBSOCKET_TESTING
           @"host": @"localhost",
           @"origin": @"localhost"
#endif
         };
    for (NSString *key in requiredValues) {
        if (![headers[key] isEqualToString:requiredValues[key]]) {
            ILog(@"Header %@ has value <%@> but I require <%@>", key, headers[key], requiredValues[key]);
            return NO;
        }
    }

    NSArray<NSString *> *requiredKeys =
        @[ @"sec-websocket-key",
           @"sec-websocket-version",
           @"origin" ];
    for (NSString *key in requiredKeys) {
        if ([headers[key] length] == 0) {
            ILog(@"Empty or missing value for header %@", key);
            return NO;
        }
    }

    NSString *version = headers[@"sec-websocket-version"];
    if ([version integerValue] < kWebSocketVersion) {
        ILog(@"websocket version too old");
        return NO;
    }

    ILog(@"Request validates as websocket upgrade request");
    return YES;
}

- (instancetype)initWithConnection:(iTermHTTPConnection *)connection {
    self = [super init];
    if (self) {
        _connection = connection;
    }
    return self;
}

- (void)handleRequest:(NSURLRequest *)request {
    ILog(@"Handling websocket request %@", request);
    NSAssert(_state == iTermWebSocketConnectionStateConnecting, @"Request already handled");

    if (![self sendUpgradeResponseWithKey:request.allHTTPHeaderFields[@"sec-websocket-key"]
                                  version:[request.allHTTPHeaderFields[@"sec-websocket-version"] integerValue]]) {
        [_connection badRequest];
        _state = iTermWebSocketConnectionStateClosed;
        [_delegate webSocketConnectionDidTerminate:self];
        return;
    }

    _state = iTermWebSocketConnectionStateOpen;

    _frameBuilder = [[iTermWebSocketFrameBuilder alloc] init];
    _queue = dispatch_get_global_queue(0, 0); //dispatch_queue_create("com.iterm2.api-io", NULL);
    _channel = [_connection newChannelOnQueue:_queue];

    static int dotest=0;
    if (dotest) {
        [_connection nextByte];
    }
    __weak __typeof(self) weakSelf = self;
    dispatch_io_set_low_water(_channel, 1);
    dispatch_io_read(_channel, 0, SIZE_MAX, _queue, ^(bool done, dispatch_data_t data, int error) {
        if (data) {
            dispatch_data_apply(data, ^bool(dispatch_data_t  _Nonnull region, size_t offset, const void * _Nonnull buffer, size_t size) {
                return [weakSelf didReceiveData:[NSMutableData dataWithBytes:buffer length:size]];
            });
        }
        if (error || done) {
            ILog(@"File descriptor closed. error=%d done=%d", error, (int)done);
            [self abort];
        }
    });
}

- (BOOL)didReceiveData:(NSMutableData *)data {
    ILog(@"Read %@ bytes of data", @(data.length));
    __weak __typeof(self) weakSelf = self;
    [_frameBuilder addData:data
                     frame:^(iTermWebSocketFrame *frame, BOOL *stop) {
                         if (!stop) {
                             [weakSelf abort];
                         }
                         *stop = [weakSelf didReceiveFrame:frame];
                     }];
    return _state != iTermWebSocketConnectionStateClosed;
}

- (BOOL)didReceiveFrame:(iTermWebSocketFrame *)frame {
    if (_state != iTermWebSocketConnectionStateClosed) {
        [self handleFrame:frame];
    }
    return (_state == iTermWebSocketConnectionStateClosed);
}

- (void)sendBinary:(NSData *)binaryData {
    if (_state == iTermWebSocketConnectionStateOpen) {
        ILog(@"Sending binary frame");
        [self sendFrame:[iTermWebSocketFrame binaryFrameWithData:binaryData]];
    } else {
        ILog(@"Not sending binary frame because not open");
    }
}

- (void)sendText:(NSString *)text {
    if (_state == iTermWebSocketConnectionStateOpen) {
        ILog(@"Sending text frame");
        [self sendFrame:[iTermWebSocketFrame textFrameWithString:text]];
    } else {
        ILog(@"Not sending text frame because not open");
    }
}

- (void)sendFrame:(iTermWebSocketFrame *)frame {
    ILog(@"Send frame %@", frame);
    [self sendData:frame.data];
}

- (void)sendData:(NSData *)data {
    dispatch_data_t dispatchData = dispatch_data_create(data.bytes, data.length, _queue, ^{
        ILog(@"Disposing of data %p", data);
        [data length];  // Keep a reference to data
    });

    __weak __typeof(self) weakSelf = self;
    dispatch_io_write(_channel, 0, dispatchData, _queue, ^(bool done, dispatch_data_t  _Nullable data, int error) {
        ILog(@"Write progress: done=%d error=%d", (int)done, (int)error);
        if (error) {
            [weakSelf abort];
        }
    });
}

- (void)abort {
    if (_state != iTermWebSocketConnectionStateClosed) {
        ILog(@"Aborting connection");
        _state = iTermWebSocketConnectionStateClosed;
        [_delegate webSocketConnectionDidTerminate:self];
        [_connection close];
    }
}

- (void)handleFrame:(iTermWebSocketFrame *)frame {
    ILog(@"Handle frame %@", frame);
    switch (frame.opcode) {
        case iTermWebSocketOpcodeBinary:
        case iTermWebSocketOpcodeText:
            if (_state == iTermWebSocketConnectionStateOpen) {
                if (frame.fin) {
                    ILog(@"Pass finished frame to delegate");
                    [_delegate webSocketConnection:self didReadFrame:frame];
                } else if (_fragment == nil) {
                    ILog(@"Begin fragmented frame");
                    _fragment = frame;
                } else {
                    ILog(@"Already have a fragmented frame started. Opcode should have been Continuation");
                    [self abort];
                }
            } else {
                [self abort];
            }
            break;

        case iTermWebSocketOpcodePing:
            if (_state == iTermWebSocketConnectionStateOpen) {
                ILog(@"Sending pong");
                [self sendFrame:[iTermWebSocketFrame pongFrameForPingFrame:frame]];
            } else {
                [self abort];
            }
            break;

        case iTermWebSocketOpcodePong:
            ILog(@"Got pong");
            break;

        case iTermWebSocketOpcodeContinuation:
            if (_state == iTermWebSocketConnectionStateOpen) {
                if (!_fragment) {
                    ILog(@"Continuation without fragment");
                    [self abort];
                    break;
                }
                ILog(@"Append fragment");
                [_fragment appendFragment:frame];
                if (frame.fin) {
                    ILog(@"Fragmented frame finished. Sending to delegate");
                    [_delegate webSocketConnection:self didReadFrame:_fragment];
                    _fragment = nil;
                }
            } else {
                [self abort];
            }
            break;

        case iTermWebSocketOpcodeConnectionClose:
            if (_state == iTermWebSocketConnectionStateOpen) {
                ILog(@"open->closing");
                _state = iTermWebSocketConnectionStateClosing;
                [self sendFrame:[iTermWebSocketFrame closeFrame]];

                _state = iTermWebSocketConnectionStateClosed;
                [_delegate webSocketConnectionDidTerminate:self];
                [_connection close];
            } else if (_state == iTermWebSocketConnectionStateClosing) {
                ILog(@"closing->closed");
                _state = iTermWebSocketConnectionStateClosed;
                [_delegate webSocketConnectionDidTerminate:self];
                [_connection close];
            }
            break;
    }
}

- (void)close {
    ILog(@"Client initiated close");
    if (_state == iTermWebSocketConnectionStateOpen) {
        ILog(@"Send close frame");
        _state = iTermWebSocketConnectionStateClosing;
        [self sendFrame:[iTermWebSocketFrame closeFrame]];
    }
}

- (BOOL)sendUpgradeResponseWithKey:(NSString *)key version:(NSInteger)version {
    ILog(@"Upgrading with key %@", key);
    key = [key stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"];

    NSData *data = [key dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char hash[CC_SHA1_DIGEST_LENGTH];
    if (CC_SHA1([data bytes], [data length], hash) ) {
        NSData *sha1 = [NSData dataWithBytes:hash length:CC_SHA1_DIGEST_LENGTH];
        NSDictionary<NSString *, NSString *> *headers =
            @{
               @"Upgrade": @"websocket",
               @"Connection": @"Upgrade",
               @"Sec-WebSocket-Accept": [sha1 stringWithBase64EncodingWithLineBreak:@""],
               @"Sec-WebSocket-Protocol": kProtocolName
             };
        if (version > kWebSocketVersion) {
            NSMutableDictionary *temp = [headers mutableCopy];
            temp[@"Sec-Websocket-Version"] = [@(kWebSocketVersion) stringValue];
            headers = temp;
        }
        ILog(@"Send headers %@", headers);
        return [_connection sendResponseWithCode:101
                                          reason:@"Switching Protocols"
                                         headers:headers];
    } else {
        return NO;
    }
}

@end