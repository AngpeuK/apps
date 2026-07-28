#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ServiceManagement/ServiceManagement.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

@interface AppsScreenRecorder : NSObject <SCStreamOutput, SCStreamDelegate>
@property SCStream *stream;
@property AVAssetWriter *writer;
@property AVAssetWriterInput *videoInput;
@property AVAssetWriterInput *audioInput;
@property AVAssetWriterInputPixelBufferAdaptor *pixelAdaptor;
@property dispatch_queue_t captureQueue;
@property NSURL *outputURL;
@property BOOL recording;
@property BOOL starting;
@property BOOL sessionStarted;
@property CMTime sessionStartTime;
@property (copy) void (^stateHandler)(BOOL recording, NSURL *fileURL, NSError *error);
- (void)start;
- (void)stop;
@end

@implementation AppsScreenRecorder

- (instancetype)init {
    if ((self = [super init])) {
        _captureQueue = dispatch_queue_create("ee.antero.apps.screen-recorder", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (NSURL *)newOutputURL {
    NSString *movies = NSSearchPathForDirectoriesInDomains(NSMoviesDirectory, NSUserDomainMask, YES).firstObject;
    [[NSFileManager defaultManager] createDirectoryAtPath:movies withIntermediateDirectories:YES attributes:nil error:nil];
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"yyyy-MM-dd HH.mm.ss";
    NSString *name = [NSString stringWithFormat:@"Запись apps %@.mp4", [formatter stringFromDate:NSDate.date]];
    return [NSURL fileURLWithPath:[movies stringByAppendingPathComponent:name]];
}

- (void)notifyRecording:(BOOL)recording file:(NSURL *)file error:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.stateHandler) self.stateHandler(recording, file, error);
    });
}

- (void)start {
    if (self.recording || self.starting) return;
    self.starting = YES;
    self.sessionStarted = NO;
    self.sessionStartTime = kCMTimeInvalid;
    if (!CGPreflightScreenCaptureAccess()) CGRequestScreenCaptureAccess();
    CGDirectDisplayID mainDisplayID = [NSScreen.mainScreen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];

    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *content, NSError *error) {
        if (error) {
            self.starting = NO;
            [self notifyRecording:NO file:nil error:error];
            return;
        }
        SCDisplay *display = nil;
        for (SCDisplay *candidate in content.displays) {
            if (candidate.displayID == mainDisplayID) { display = candidate; break; }
        }
        if (!display) display = content.displays.firstObject;
        if (!display) {
            self.starting = NO;
            NSError *missing = [NSError errorWithDomain:@"ee.antero.apps" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Основной дисплей недоступен для записи."}];
            [self notifyRecording:NO file:nil error:missing];
            return;
        }

        size_t width = display.width - (display.width % 2);
        size_t height = display.height - (display.height % 2);
        self.outputURL = [self newOutputURL];
        NSError *writerError = nil;
        self.writer = [AVAssetWriter assetWriterWithURL:self.outputURL fileType:AVFileTypeMPEG4 error:&writerError];
        if (writerError) {
            self.starting = NO;
            [self notifyRecording:NO file:nil error:writerError];
            return;
        }

        NSDictionary *videoSettings = @{
            AVVideoCodecKey: AVVideoCodecTypeH264,
            AVVideoWidthKey: @(width),
            AVVideoHeightKey: @(height),
            AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(12 * 1000 * 1000)}
        };
        self.videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
        self.videoInput.expectsMediaDataInRealTime = YES;
        NSDictionary *pixelAttributes = @{
            (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (NSString *)kCVPixelBufferWidthKey: @(width),
            (NSString *)kCVPixelBufferHeightKey: @(height),
            (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        self.pixelAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:self.videoInput sourcePixelBufferAttributes:pixelAttributes];
        NSDictionary *audioSettings = @{
            AVFormatIDKey: @(kAudioFormatMPEG4AAC),
            AVSampleRateKey: @48000,
            AVNumberOfChannelsKey: @2,
            AVEncoderBitRateKey: @192000
        };
        self.audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
        self.audioInput.expectsMediaDataInRealTime = YES;
        if ([self.writer canAddInput:self.videoInput]) [self.writer addInput:self.videoInput];
        if ([self.writer canAddInput:self.audioInput]) [self.writer addInput:self.audioInput];

        SCStreamConfiguration *configuration = [SCStreamConfiguration new];
        configuration.width = width;
        configuration.height = height;
        configuration.minimumFrameInterval = CMTimeMake(1, 30);
        configuration.queueDepth = 6;
        configuration.pixelFormat = kCVPixelFormatType_32BGRA;
        configuration.showsCursor = YES;
        configuration.capturesAudio = YES;
        configuration.sampleRate = 48000;
        configuration.channelCount = 2;
        configuration.excludesCurrentProcessAudio = NO;

        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
        self.stream = [[SCStream alloc] initWithFilter:filter configuration:configuration delegate:self];
        NSError *outputError = nil;
        BOOL videoAdded = [self.stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.captureQueue error:&outputError];
        BOOL audioAdded = [self.stream addStreamOutput:self type:SCStreamOutputTypeAudio sampleHandlerQueue:self.captureQueue error:&outputError];
        if (!videoAdded || !audioAdded) {
            self.starting = NO;
            [self notifyRecording:NO file:nil error:outputError];
            return;
        }
        [self.stream startCaptureWithCompletionHandler:^(NSError *startError) {
            self.starting = NO;
            if (startError) {
                [self notifyRecording:NO file:nil error:startError];
            } else {
                self.recording = YES;
                [self notifyRecording:YES file:self.outputURL error:nil];
            }
        }];
    }];
}

- (void)stop {
    if (!self.recording || !self.stream) return;
    self.recording = NO;
    [self.stream stopCaptureWithCompletionHandler:^(NSError *stopError) {
        dispatch_async(self.captureQueue, ^{
            [self.videoInput markAsFinished];
            [self.audioInput markAsFinished];
            if (self.writer.status == AVAssetWriterStatusWriting) {
                [self.writer finishWritingWithCompletionHandler:^{
                    NSError *error = self.writer.status == AVAssetWriterStatusFailed ? self.writer.error : stopError;
                    [self notifyRecording:NO file:self.outputURL error:error];
                }];
            } else {
                NSError *error = self.writer.error ?: stopError;
                [self notifyRecording:NO file:self.outputURL error:error];
            }
        });
    }];
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (!CMSampleBufferIsValid(sampleBuffer) || !CMSampleBufferDataIsReady(sampleBuffer)) return;
    if (type == SCStreamOutputTypeScreen) {
        CMTime time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        if (!self.sessionStarted) {
            if (![self.writer startWriting]) return;
            self.sessionStartTime = time;
            [self.writer startSessionAtSourceTime:time];
            self.sessionStarted = YES;
        }
        if (self.writer.status == AVAssetWriterStatusWriting && self.videoInput.readyForMoreMediaData) {
            CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (pixelBuffer) [self.pixelAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:time];
        }
    } else if (type == SCStreamOutputTypeAudio && self.sessionStarted) {
        CMTime time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        if (CMTIME_COMPARE_INLINE(time, >=, self.sessionStartTime) &&
            self.writer.status == AVAssetWriterStatusWriting && self.audioInput.readyForMoreMediaData) {
            [self.audioInput appendSampleBuffer:sampleBuffer];
        }
    }
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    if (self.recording) {
        self.recording = NO;
        [self notifyRecording:NO file:self.outputURL error:error];
    }
}
@end

typedef NS_ENUM(NSInteger, AppsWindowAction) {
    AppsMinimize, AppsRestore, AppsMaximize, AppsResize, AppsGridTwo, AppsGridFour, AppsGridEight, AppsGridTwoPanorama,
    AppsExpandTopTwo, AppsExpandBottomTwo, AppsExitFullscreen
};

typedef NS_ENUM(NSInteger, AppsLayoutMode) {
    AppsLayoutCenter, AppsLayoutTwoColumns, AppsLayoutFour, AppsLayoutEight, AppsLayoutTwoPanorama
};

@interface AppsDelegate : NSObject <NSApplicationDelegate>
@property NSStatusItem *statusItem;
@property NSMenuItem *loginItem;
@property NSMenuItem *recordingItem;
@property AppsScreenRecorder *screenRecorder;
@property dispatch_queue_t windowQueue;
@property BOOL showingTopStacks;
@property AppsLayoutMode currentLayout;
@end

@implementation AppsDelegate

- (NSMenuItem *)item:(NSString *)title action:(SEL)action key:(NSString *)key {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    item.target = self;
    return item;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.windowQueue = dispatch_queue_create("ee.antero.apps.windows", DISPATCH_QUEUE_SERIAL);
    self.showingTopStacks = YES;
    self.currentLayout = AppsLayoutCenter;
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSString *iconPath = [NSBundle.mainBundle pathForResource:@"apps" ofType:@"icns"];
    NSImage *menuIcon = [[NSImage alloc] initWithContentsOfFile:iconPath];
    menuIcon.size = NSMakeSize(18, 18);
    menuIcon.template = NO;
    self.statusItem.button.image = menuIcon;
    self.statusItem.button.toolTip = @"apps — управление окнами";

    NSMenu *menu = [NSMenu new];
    [menu addItem:[self item:@"Развернуть все окна" action:@selector(maximizeAll:) key:@"1"]];
    [menu addItem:[self item:@"Уменьшить все окна" action:@selector(resizeAll:) key:@"2"]];
    [menu addItem:[self item:@"Расставить окна по 2" action:@selector(gridTwoAll:) key:@"t"]];
    [menu addItem:[self item:@"Расставить окна по 4" action:@selector(gridFourAll:) key:@"6"]];
    [menu addItem:[self item:@"Расставить окна по 8" action:@selector(gridEightAll:) key:@"0"]];
    [menu addItem:[self item:@"Расставить по 2 панорамы" action:@selector(gridTwoPanoramaAll:) key:@"p"]];
    [menu addItem:[self item:@"Верхние 2 стопки — развернуть вниз" action:@selector(expandTopTwo:) key:@"7"]];
    [menu addItem:[self item:@"Нижние 2 стопки — развернуть вверх" action:@selector(expandBottomTwo:) key:@"8"]];
    [menu addItem:[self item:@"Переключить верхние ↕ нижние стопки" action:@selector(toggleStackRows:) key:@"9"]];
    [menu addItem:[self item:@"Активное окно → следующая стопка" action:@selector(moveActiveWindowToNextStack:) key:@"n"]];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self item:@"Свернуть в Dock" action:@selector(minimizeAll:) key:@"3"]];
    [menu addItem:[self item:@"Восстановить из Dock" action:@selector(restoreAll:) key:@"4"]];
    [menu addItem:[self item:@"Выйти из полноэкранного режима" action:@selector(exitFullscreenAll:) key:@"5"]];
    [menu addItem:NSMenuItem.separatorItem];
    self.recordingItem = [self item:@"Начать запись экрана" action:@selector(toggleScreenRecording:) key:@""];
    [menu addItem:self.recordingItem];
    [menu addItem:NSMenuItem.separatorItem];
    self.loginItem = [self item:@"Запускать при входе" action:@selector(toggleLogin:) key:@""];
    [menu addItem:self.loginItem];
    [menu addItem:[self item:@"Открыть настройки доступа…" action:@selector(openSettings:) key:@""]];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self item:@"Перезапустить" action:@selector(restart:) key:@"r"]];
    [menu addItem:[self item:@"Завершить apps" action:@selector(quit:) key:@"q"]];
    self.statusItem.menu = menu;
    [self updateLoginState];

    self.screenRecorder = [AppsScreenRecorder new];
    __weak AppsDelegate *weakSelf = self;
    self.screenRecorder.stateHandler = ^(BOOL recording, NSURL *fileURL, NSError *error) {
        AppsDelegate *strongSelf = weakSelf;
        strongSelf.recordingItem.title = recording ? @"Остановить запись" : @"Начать запись экрана";
        if (error) {
            NSAlert *alert = [NSAlert alertWithError:error];
            alert.messageText = @"Не удалось записать экран";
            NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
            alert.informativeText = underlying ?
                [NSString stringWithFormat:@"%@\n%@", error.localizedDescription, underlying.localizedDescription] :
                error.localizedDescription;
            [alert runModal];
        } else if (!recording && fileURL) {
            NSAlert *alert = [NSAlert new];
            alert.messageText = @"Запись экрана сохранена";
            alert.informativeText = fileURL.path;
            [alert addButtonWithTitle:@"Показать в Finder"];
            [alert addButtonWithTitle:@"Закрыть"];
            if ([alert runModal] == NSAlertFirstButtonReturn) {
                [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[fileURL]];
            }
        }
    };

    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

- (BOOL)ensurePermission {
    if (AXIsProcessTrusted()) return YES;
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Нужно разрешение на управление окнами";
    alert.informativeText = @"Добавьте apps в «Системные настройки → Конфиденциальность и безопасность → Универсальный доступ», затем повторите команду.";
    [alert addButtonWithTitle:@"Открыть настройки"];
    [alert addButtonWithTitle:@"Отмена"];
    if ([alert runModal] == NSAlertFirstButtonReturn) [self openSettings:nil];
    return NO;
}

- (NSArray *)windowsIncludingHidden:(BOOL)includeHidden {
    NSMutableArray *result = [NSMutableArray array];
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        if (app.processIdentifier == NSProcessInfo.processInfo.processIdentifier ||
            app.activationPolicy != NSApplicationActivationPolicyRegular ||
            (!includeHidden && app.hidden)) continue;
        if (includeHidden && app.hidden) [app unhide];
        AXUIElementRef appElement = AXUIElementCreateApplication(app.processIdentifier);
        AXUIElementSetMessagingTimeout(appElement, includeHidden ? 1.0 : 0.25);
        CFTypeRef value = NULL;
        if (AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute, &value) == kAXErrorSuccess && value) {
            for (id window in (__bridge NSArray *)value) {
                AXUIElementRef element = (__bridge AXUIElementRef)window;
                CFTypeRef role = NULL;
                CFTypeRef subrole = NULL;
                BOOL hasRole = AXUIElementCopyAttributeValue(element, kAXRoleAttribute, &role) == kAXErrorSuccess;
                BOOL hasSubrole = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute, &subrole) == kAXErrorSuccess;
                BOOL isWindow = hasRole && CFEqual(role, kAXWindowRole);
                BOOL isStandard = hasSubrole && CFEqual(subrole, kAXStandardWindowSubrole);
                if (role) CFRelease(role);
                if (subrole) CFRelease(subrole);
                if (isWindow && (includeHidden || isStandard)) [result addObject:window];
            }
            CFRelease(value);
        }
        CFRelease(appElement);
    }
    return result;
}

- (void)setBoolean:(BOOL)value attribute:(CFStringRef)attribute window:(AXUIElementRef)window {
    AXUIElementSetAttributeValue(window, attribute, value ? kCFBooleanTrue : kCFBooleanFalse);
}

- (void)setPosition:(CGPoint)position size:(CGSize)size window:(AXUIElementRef)window {
    AXValueRef p = AXValueCreate(kAXValueCGPointType, &position);
    AXValueRef s = AXValueCreate(kAXValueCGSizeType, &size);
    AXUIElementSetAttributeValue(window, kAXSizeAttribute, s);
    AXUIElementSetAttributeValue(window, kAXPositionAttribute, p);
    AXUIElementSetAttributeValue(window, kAXSizeAttribute, s);
    CFRelease(p); CFRelease(s);
}

- (CGSize)actualSizeOfWindow:(AXUIElementRef)window fallback:(CGSize)fallback {
    CFTypeRef value = NULL;
    CGSize size = fallback;
    if (AXUIElementCopyAttributeValue(window, kAXSizeAttribute, &value) == kAXErrorSuccess && value) {
        if (CFGetTypeID(value) == AXValueGetTypeID() &&
            AXValueGetType((AXValueRef)value) == kAXValueCGSizeType) {
            AXValueGetValue((AXValueRef)value, kAXValueCGSizeType, &size);
        }
        CFRelease(value);
    }
    return size;
}

- (CGPoint)positionOfWindow:(AXUIElementRef)window {
    CFTypeRef value = NULL;
    CGPoint point = CGPointZero;
    if (AXUIElementCopyAttributeValue(window, kAXPositionAttribute, &value) == kAXErrorSuccess && value) {
        if (CFGetTypeID(value) == AXValueGetTypeID() &&
            AXValueGetType((AXValueRef)value) == kAXValueCGPointType) {
            AXValueGetValue((AXValueRef)value, kAXValueCGPointType, &point);
        }
        CFRelease(value);
    }
    return point;
}

- (void)setPositionOnly:(CGPoint)position window:(AXUIElementRef)window {
    AXValueRef value = AXValueCreate(kAXValueCGPointType, &position);
    AXUIElementSetAttributeValue(window, kAXPositionAttribute, value);
    CFRelease(value);
}

- (void)perform:(AppsWindowAction)action {
    NSArray *windows = [self windowsIncludingHidden:action == AppsRestore];
    NSScreen *screen = NSScreen.mainScreen;
    NSRect visible = screen.visibleFrame;
    NSMutableArray *gridWindowsToRaise = [NSMutableArray array];

    if (action == AppsExpandTopTwo || action == AppsExpandBottomTwo) {
        CGFloat layoutScale = MIN(NSWidth(visible) / 1792.0, NSHeight(visible) / 1095.0);
        CGFloat spacing = MIN(18, MAX(8, round(12 * layoutScale)));
        CGFloat width = (NSWidth(visible) - spacing * 3) / 2;
        CGFloat height = NSHeight(visible) - spacing * 2;
        CGFloat visibleTop = NSMaxY(screen.frame) - NSMaxY(visible);
        CGFloat leftSlotX = NSMinX(visible) + spacing;
        CGFloat rightSlotX = leftSlotX + width + spacing;
        for (NSUInteger index = 0; index < windows.count; index++) {
            NSUInteger gridPosition = index % 4;
            BOOL belongsToTopStacks = gridPosition < 2;
            if ((action == AppsExpandTopTwo && !belongsToTopStacks) ||
                (action == AppsExpandBottomTwo && belongsToTopStacks)) continue;
            id object = windows[index];
            AXUIElementRef window = (__bridge AXUIElementRef)object;
            BOOL rightColumn = gridPosition % 2 == 1;
            CGPoint point = CGPointMake(rightColumn ? rightSlotX : leftSlotX, visibleTop + spacing);
            [self setPosition:point size:CGSizeMake(width, height) window:window];
            AXUIElementPerformAction(window, kAXRaiseAction);
        }
        return;
    }

    for (NSUInteger index = 0; index < windows.count; index++) {
        id object = windows[index];
        AXUIElementRef window = (__bridge AXUIElementRef)object;
        if (action == AppsMinimize) {
            [self setBoolean:YES attribute:kAXMinimizedAttribute window:window];
        } else if (action == AppsRestore) {
            [self setBoolean:NO attribute:kAXMinimizedAttribute window:window];
        } else if (action == AppsExitFullscreen) {
            [self setBoolean:NO attribute:CFSTR("AXFullScreen") window:window];
        } else if (action == AppsMaximize) {
            CGPoint point = CGPointMake(NSMinX(visible), NSMaxY(screen.frame) - NSMaxY(visible));
            [self setPosition:point size:visible.size window:window];
        } else if (action == AppsGridTwo) {
            CGFloat layoutScale = MIN(NSWidth(visible) / 1792.0, NSHeight(visible) / 1095.0);
            CGFloat spacing = MIN(18, MAX(8, round(12 * layoutScale)));
            CGFloat width = (NSWidth(visible) - spacing * 3) / 2;
            CGFloat height = NSHeight(visible) - spacing * 2;
            NSUInteger column = index % 2;
            CGFloat x = NSMinX(visible) + spacing + column * (width + spacing);
            CGFloat visibleTop = NSMaxY(screen.frame) - NSMaxY(visible);
            CGFloat y = visibleTop + spacing;
            [self setPosition:CGPointMake(x, y) size:CGSizeMake(width, height) window:window];
            CGSize actual = [self actualSizeOfWindow:window fallback:CGSizeMake(width, height)];
            CGFloat maxX = NSMaxX(visible) - spacing - actual.width;
            CGFloat maxY = visibleTop + NSHeight(visible) - spacing - actual.height;
            CGPoint safePoint = CGPointMake(MAX(NSMinX(visible) + spacing, MIN(x, maxX)),
                                            MAX(visibleTop + spacing, MIN(y, maxY)));
            [self setPositionOnly:safePoint window:window];
        } else if (action == AppsGridFour) {
            CGFloat layoutScale = MIN(NSWidth(visible) / 1792.0, NSHeight(visible) / 1095.0);
            CGFloat spacing = MIN(18, MAX(8, round(12 * layoutScale)));
            CGFloat width = (NSWidth(visible) - spacing * 3) / 2;
            CGFloat height = (NSHeight(visible) - spacing * 3) / 2;
            NSUInteger position = index % 4;
            NSUInteger column = position % 2;
            NSUInteger row = position / 2;
            CGFloat x = NSMinX(visible) + spacing + column * (width + spacing);
            CGFloat visibleTop = NSMaxY(screen.frame) - NSMaxY(visible);
            CGFloat y = visibleTop + spacing + row * (height + spacing);
            [self setPosition:CGPointMake(x, y) size:CGSizeMake(width, height) window:window];
            CGSize actual = [self actualSizeOfWindow:window fallback:CGSizeMake(width, height)];
            CGFloat minX = NSMinX(visible) + spacing;
            CGFloat maxX = NSMaxX(visible) - spacing - actual.width;
            CGFloat minY = visibleTop + spacing;
            CGFloat maxY = visibleTop + NSHeight(visible) - spacing - actual.height;
            BOOL oversized = actual.width > width + 1 || actual.height > height + 1;
            CGPoint safePoint;
            if (oversized) {
                safePoint = CGPointMake(MAX(minX, maxX), minY);
            } else {
                safePoint = CGPointMake(MAX(minX, MIN(x, maxX)),
                                        MAX(minY, MIN(y, maxY)));
                [gridWindowsToRaise addObject:object];
            }
            [self setPositionOnly:safePoint window:window];
        } else if (action == AppsGridEight) {
            CGFloat layoutScale = MIN(NSWidth(visible) / 1792.0, NSHeight(visible) / 1095.0);
            CGFloat spacing = MIN(18, MAX(8, round(12 * layoutScale)));
            CGFloat width = (NSWidth(visible) - spacing * 5) / 4;
            CGFloat height = (NSHeight(visible) - spacing * 3) / 2;
            NSUInteger position = index % 8;
            NSUInteger column = position % 4;
            NSUInteger row = position / 4;
            CGFloat x = NSMinX(visible) + spacing + column * (width + spacing);
            CGFloat visibleTop = NSMaxY(screen.frame) - NSMaxY(visible);
            CGFloat y = visibleTop + spacing + row * (height + spacing);
            [self setPosition:CGPointMake(x, y) size:CGSizeMake(width, height) window:window];
            CGSize actual = [self actualSizeOfWindow:window fallback:CGSizeMake(width, height)];
            CGFloat maxX = NSMaxX(visible) - spacing - actual.width;
            CGFloat maxY = visibleTop + NSHeight(visible) - spacing - actual.height;
            CGPoint safePoint = CGPointMake(MAX(NSMinX(visible) + spacing, MIN(x, maxX)),
                                            MAX(visibleTop + spacing, MIN(y, maxY)));
            [self setPositionOnly:safePoint window:window];
        } else if (action == AppsGridTwoPanorama) {
            CGFloat layoutScale = MIN(NSWidth(visible) / 1792.0, NSHeight(visible) / 1095.0);
            CGFloat spacing = MIN(18, MAX(8, round(12 * layoutScale)));
            CGFloat width = NSWidth(visible) - spacing * 2;
            CGFloat height = (NSHeight(visible) - spacing * 3) / 2;
            NSUInteger row = index % 2;
            CGFloat x = NSMinX(visible) + spacing;
            CGFloat visibleTop = NSMaxY(screen.frame) - NSMaxY(visible);
            CGFloat y = visibleTop + spacing + row * (height + spacing);
            [self setPosition:CGPointMake(x, y) size:CGSizeMake(width, height) window:window];
            CGSize actual = [self actualSizeOfWindow:window fallback:CGSizeMake(width, height)];
            CGFloat maxX = NSMaxX(visible) - spacing - actual.width;
            CGFloat maxY = visibleTop + NSHeight(visible) - spacing - actual.height;
            CGPoint safePoint = CGPointMake(MAX(NSMinX(visible) + spacing, MIN(x, maxX)),
                                            MAX(visibleTop + spacing, MIN(y, maxY)));
            [self setPositionOnly:safePoint window:window];
        } else {
            CGFloat layoutScale = MIN(NSWidth(visible) / 1792.0, NSHeight(visible) / 1095.0);
            CGFloat width = MIN(round(1000 * layoutScale), NSWidth(visible));
            CGFloat height = MIN(round(700 * layoutScale), NSHeight(visible));
            CGFloat x = NSMinX(visible) + (NSWidth(visible) - width) / 2;
            CGFloat visibleTop = NSMaxY(screen.frame) - NSMaxY(visible);
            CGFloat y = visibleTop + (NSHeight(visible) - height) / 2;
            CGPoint point = CGPointMake(x, y);
            [self setPosition:point size:CGSizeMake(width, height) window:window];
        }
    }
    if (action == AppsGridFour) {
        for (id object in gridWindowsToRaise) {
            AXUIElementPerformAction((__bridge AXUIElementRef)object, kAXRaiseAction);
        }
    }
}

- (void)schedule:(AppsWindowAction)action {
    if (![self ensurePermission]) return;
    dispatch_async(self.windowQueue, ^{ [self perform:action]; });
}

- (void)showMessage:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"apps";
        alert.informativeText = message;
        [alert runModal];
    });
}

- (void)moveFocusedWindowToNextSlot:(AppsLayoutMode)layout {
    NSUInteger columns = 1, rows = 1;
    if (layout == AppsLayoutTwoColumns) columns = 2;
    else if (layout == AppsLayoutFour) { columns = 2; rows = 2; }
    else if (layout == AppsLayoutEight) { columns = 4; rows = 2; }
    else if (layout == AppsLayoutTwoPanorama) rows = 2;
    else { [self showMessage:@"В центральном режиме только одна стопка."]; return; }

    AXUIElementRef system = AXUIElementCreateSystemWide();
    CFTypeRef appValue = NULL;
    CFTypeRef windowValue = NULL;
    AXError appError = AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute, &appValue);
    if (appError == kAXErrorSuccess && appValue) {
        AXUIElementSetMessagingTimeout((AXUIElementRef)appValue, 0.75);
        AXUIElementCopyAttributeValue((AXUIElementRef)appValue, kAXFocusedWindowAttribute, &windowValue);
    }
    CFRelease(system);
    if (appValue) CFRelease(appValue);
    if (!windowValue) { [self showMessage:@"Не удалось определить активное окно."]; return; }

    AXUIElementRef window = (AXUIElementRef)windowValue;
    NSScreen *screen = NSScreen.mainScreen;
    NSRect visible = screen.visibleFrame;
    CGFloat scale = MIN(NSWidth(visible) / 1792.0, NSHeight(visible) / 1095.0);
    CGFloat spacing = MIN(18, MAX(8, round(12 * scale)));
    CGFloat width = (NSWidth(visible) - spacing * (columns + 1)) / columns;
    CGFloat height = (NSHeight(visible) - spacing * (rows + 1)) / rows;
    CGFloat visibleTop = NSMaxY(screen.frame) - NSMaxY(visible);
    CGPoint current = [self positionOfWindow:window];
    NSUInteger count = columns * rows;
    NSUInteger nearest = 0;
    CGFloat nearestDistance = CGFLOAT_MAX;
    for (NSUInteger index = 0; index < count; index++) {
        NSUInteger column = index % columns;
        NSUInteger row = index / columns;
        CGPoint slot = CGPointMake(NSMinX(visible) + spacing + column * (width + spacing),
                                   visibleTop + spacing + row * (height + spacing));
        CGFloat distance = hypot(current.x - slot.x, current.y - slot.y);
        if (distance < nearestDistance) { nearestDistance = distance; nearest = index; }
    }
    NSUInteger next = (nearest + 1) % count;
    NSUInteger nextColumn = next % columns;
    NSUInteger nextRow = next / columns;
    CGPoint point = CGPointMake(NSMinX(visible) + spacing + nextColumn * (width + spacing),
                                visibleTop + spacing + nextRow * (height + spacing));
    [self setBoolean:NO attribute:CFSTR("AXFullScreen") window:window];
    [self setBoolean:NO attribute:kAXMinimizedAttribute window:window];
    [self setPosition:point size:CGSizeMake(width, height) window:window];
    AXUIElementPerformAction(window, kAXRaiseAction);
    CFRelease(windowValue);
}

- (void)moveActiveWindowToNextStack:(id)sender {
    if (![self ensurePermission]) return;
    AppsLayoutMode layout = self.currentLayout;
    dispatch_async(self.windowQueue, ^{ [self moveFocusedWindowToNextSlot:layout]; });
}

- (void)maximizeAll:(id)sender { [self schedule:AppsMaximize]; }
- (void)resizeAll:(id)sender {
    self.currentLayout = AppsLayoutCenter;
    if (![self ensurePermission]) return;
    dispatch_async(self.windowQueue, ^{
        [self perform:AppsExitFullscreen];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), self.windowQueue, ^{
            [self perform:AppsResize];
        });
    });
}
- (void)gridFourAll:(id)sender {
    self.currentLayout = AppsLayoutFour;
    if (![self ensurePermission]) return;
    dispatch_async(self.windowQueue, ^{
        [self perform:AppsExitFullscreen];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), self.windowQueue, ^{
            [self perform:AppsGridFour];
        });
    });
}
- (void)gridTwoAll:(id)sender {
    self.currentLayout = AppsLayoutTwoColumns;
    if (![self ensurePermission]) return;
    dispatch_async(self.windowQueue, ^{
        [self perform:AppsExitFullscreen];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), self.windowQueue, ^{
            [self perform:AppsGridTwo];
        });
    });
}
- (void)gridEightAll:(id)sender {
    self.currentLayout = AppsLayoutEight;
    if (![self ensurePermission]) return;
    dispatch_async(self.windowQueue, ^{
        [self perform:AppsExitFullscreen];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), self.windowQueue, ^{
            [self perform:AppsGridEight];
        });
    });
}
- (void)gridTwoPanoramaAll:(id)sender {
    self.currentLayout = AppsLayoutTwoPanorama;
    if (![self ensurePermission]) return;
    dispatch_async(self.windowQueue, ^{
        [self perform:AppsExitFullscreen];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), self.windowQueue, ^{
            [self perform:AppsGridTwoPanorama];
        });
    });
}
- (void)expandTopTwo:(id)sender {
    self.currentLayout = AppsLayoutTwoColumns;
    self.showingTopStacks = YES;
    [self schedule:AppsExpandTopTwo];
}
- (void)expandBottomTwo:(id)sender {
    self.currentLayout = AppsLayoutTwoColumns;
    self.showingTopStacks = NO;
    [self schedule:AppsExpandBottomTwo];
}
- (void)toggleStackRows:(id)sender {
    if (self.showingTopStacks) {
        [self expandBottomTwo:sender];
    } else {
        [self expandTopTwo:sender];
    }
}
- (void)minimizeAll:(id)sender { [self schedule:AppsMinimize]; }
- (void)restoreAll:(id)sender { [self schedule:AppsRestore]; }
- (void)exitFullscreenAll:(id)sender { [self schedule:AppsExitFullscreen]; }

- (void)openSettings:(id)sender {
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
    [NSWorkspace.sharedWorkspace openURL:url];
}

- (void)updateLoginState API_AVAILABLE(macos(13.0)) {
    self.loginItem.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)toggleLogin:(id)sender API_AVAILABLE(macos(13.0)) {
    NSError *error = nil;
    if (SMAppService.mainAppService.status == SMAppServiceStatusEnabled)
        [SMAppService.mainAppService unregisterAndReturnError:&error];
    else
        [SMAppService.mainAppService registerAndReturnError:&error];
    if (error) [[NSAlert alertWithError:error] runModal];
    [self updateLoginState];
}

- (void)quit:(id)sender { [NSApp terminate:nil]; }

- (void)toggleScreenRecording:(id)sender {
    if (self.screenRecorder.recording) {
        self.recordingItem.title = @"Завершение записи…";
        self.recordingItem.enabled = NO;
        [self.screenRecorder stop];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.recordingItem.enabled = YES;
        });
    } else {
        self.recordingItem.title = @"Подготовка записи…";
        [self.screenRecorder start];
    }
}

- (void)restart:(id)sender {
    NSURL *appURL = NSBundle.mainBundle.bundleURL;
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.createsNewApplicationInstance = YES;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:appURL
                                        configuration:configuration
                                    completionHandler:^(NSRunningApplication *application, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                [[NSAlert alertWithError:error] runModal];
            } else {
                [NSApp terminate:nil];
            }
        });
    }];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        AppsDelegate *delegate = [AppsDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
