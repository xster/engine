// Copyright 2016 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "flutter/shell/platform/darwin/ios/framework/Headers/FlutterViewController.h"

#include <memory>

#include "flutter/common/threads.h"
#include "flutter/fml/platform/darwin/scoped_block.h"
#include "flutter/fml/platform/darwin/scoped_nsobject.h"
#include "flutter/glue/trace_event.h"
#include "flutter/shell/platform/darwin/common/buffer_conversions.h"
#include "flutter/shell/platform/darwin/common/platform_mac.h"
#include "flutter/shell/platform/darwin/ios/framework/Headers/FlutterCodecs.h"
#include "flutter/shell/platform/darwin/ios/framework/Source/FlutterDartProject_Internal.h"
#include "flutter/shell/platform/darwin/ios/framework/Source/FlutterPlatformPlugin.h"
#include "flutter/shell/platform/darwin/ios/framework/Source/FlutterTextInputDelegate.h"
#include "flutter/shell/platform/darwin/ios/framework/Source/FlutterTextInputPlugin.h"
#include "flutter/shell/platform/darwin/ios/framework/Source/flutter_main_ios.h"
#include "flutter/shell/platform/darwin/ios/framework/Source/flutter_touch_mapper.h"
#include "flutter/shell/platform/darwin/ios/platform_view_ios.h"
#include "lib/ftl/functional/make_copyable.h"
#include "lib/ftl/logging.h"
#include "lib/ftl/time/time_delta.h"

namespace {

typedef void (^PlatformMessageResponseCallback)(NSData*);

class PlatformMessageResponseDarwin : public blink::PlatformMessageResponse {
  FRIEND_MAKE_REF_COUNTED(PlatformMessageResponseDarwin);

 public:
  void Complete(std::vector<uint8_t> data) override {
    ftl::RefPtr<PlatformMessageResponseDarwin> self(this);
    blink::Threads::Platform()->PostTask(
        ftl::MakeCopyable([ self, data = std::move(data) ]() mutable {
          self->callback_.get()(shell::GetNSDataFromVector(data));
        }));
  }

  void CompleteEmpty() override {
    ftl::RefPtr<PlatformMessageResponseDarwin> self(this);
    blink::Threads::Platform()->PostTask(
        ftl::MakeCopyable([self]() mutable { self->callback_.get()(nil); }));
  }

 private:
  explicit PlatformMessageResponseDarwin(PlatformMessageResponseCallback callback)
      : callback_(callback, fml::OwnershipPolicy::Retain) {}

  fml::ScopedBlock<PlatformMessageResponseCallback> callback_;
};

}  // namespace

@interface FlutterViewController ()<UIAlertViewDelegate, FlutterTextInputDelegate>
@end

@implementation FlutterViewController {
  fml::scoped_nsprotocol<FlutterDartProject*> _dartProject;
  UIInterfaceOrientationMask _orientationPreferences;
  UIStatusBarStyle _statusBarStyle;
  blink::ViewportMetrics _viewportMetrics;
  shell::TouchMapper _touchMapper;
  std::shared_ptr<shell::PlatformViewIOS> _platformView;
  fml::scoped_nsprotocol<FlutterPlatformPlugin*> _platformPlugin;
  fml::scoped_nsprotocol<FlutterTextInputPlugin*> _textInputPlugin;
  fml::scoped_nsprotocol<FlutterMethodChannel*> _localizationChannel;
  fml::scoped_nsprotocol<FlutterMethodChannel*> _navigationChannel;
  fml::scoped_nsprotocol<FlutterMethodChannel*> _platformChannel;
  fml::scoped_nsprotocol<FlutterMethodChannel*> _textInputChannel;
  fml::scoped_nsprotocol<FlutterBasicMessageChannel*> _lifecycleChannel;
  fml::scoped_nsprotocol<FlutterBasicMessageChannel*> _systemChannel;
  BOOL _initialized;
  BOOL _connected;
}

+ (void)initialize {
  if (self == [FlutterViewController class]) {
    shell::FlutterMain();
  }
}

#pragma mark - Manage and override all designated initializers

- (instancetype)initWithProject:(FlutterDartProject*)project
                        nibName:(NSString*)nibNameOrNil
                         bundle:(NSBundle*)nibBundleOrNil {
  self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];

  if (self) {
    if (project == nil)
      _dartProject.reset([[FlutterDartProject alloc] initFromDefaultSourceForConfiguration]);
    else
      _dartProject.reset([project retain]);

    [self performCommonViewControllerInitialization];
  }

  return self;
}

- (instancetype)initWithNibName:(NSString*)nibNameOrNil bundle:(NSBundle*)nibBundleOrNil {
  return [self initWithProject:nil nibName:nil bundle:nil];
}

- (instancetype)initWithCoder:(NSCoder*)aDecoder {
  return [self initWithProject:nil nibName:nil bundle:nil];
}

#pragma mark - Common view controller initialization tasks

- (void)performCommonViewControllerInitialization {
  if (_initialized)
    return;

  _initialized = YES;

  _orientationPreferences = UIInterfaceOrientationMaskAll;
  _statusBarStyle = UIStatusBarStyleDefault;
  _platformView =
      std::make_shared<shell::PlatformViewIOS>(reinterpret_cast<CAEAGLLayer*>(self.view.layer));
  _platformView->Attach();
  _platformView->SetupResourceContextOnIOThread();

  _localizationChannel.reset([[FlutterMethodChannel alloc]
         initWithName:@"flutter/localization"
      binaryMessenger:self
                codec:[FlutterJSONMethodCodec sharedInstance]]);

  _navigationChannel.reset([[FlutterMethodChannel alloc]
         initWithName:@"flutter/navigation"
      binaryMessenger:self
                codec:[FlutterJSONMethodCodec sharedInstance]]);

  _platformChannel.reset([[FlutterMethodChannel alloc]
         initWithName:@"flutter/platform"
      binaryMessenger:self
                codec:[FlutterJSONMethodCodec sharedInstance]]);

  _textInputChannel.reset([[FlutterMethodChannel alloc]
         initWithName:@"flutter/textinput"
      binaryMessenger:self
                codec:[FlutterJSONMethodCodec sharedInstance]]);

  _lifecycleChannel.reset([[FlutterBasicMessageChannel alloc]
         initWithName:@"flutter/lifecycle"
      binaryMessenger:self
                codec:[FlutterStringCodec sharedInstance]]);

  _systemChannel.reset([[FlutterBasicMessageChannel alloc]
         initWithName:@"flutter/system"
      binaryMessenger:self
                codec:[FlutterJSONMessageCodec sharedInstance]]);

  _platformPlugin.reset([[FlutterPlatformPlugin alloc] init]);
  [_platformChannel.get() setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
    [_platformPlugin.get() handleMethodCall:call result:result];
  }];

  _textInputPlugin.reset([[FlutterTextInputPlugin alloc] init]);
  _textInputPlugin.get().textInputDelegate = self;
  [_textInputChannel.get() setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
    [_textInputPlugin.get() handleMethodCall:call result:result];
  }];

  [self setupNotificationCenterObservers];

}

- (void)setupNotificationCenterObservers {
  NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
  [center addObserver:self
             selector:@selector(onOrientationPreferencesUpdated:)
                 name:@(shell::kOrientationUpdateNotificationName)
               object:nil];

  [center addObserver:self
             selector:@selector(onPreferredStatusBarStyleUpdated:)
                 name:@(shell::kOverlayStyleUpdateNotificationName)
               object:nil];

  [center addObserver:self
             selector:@selector(applicationBecameActive:)
                 name:UIApplicationDidBecomeActiveNotification
               object:nil];

  [center addObserver:self
             selector:@selector(applicationWillResignActive:)
                 name:UIApplicationWillResignActiveNotification
               object:nil];

  [center addObserver:self
             selector:@selector(applicationDidEnterBackground:)
                 name:UIApplicationDidEnterBackgroundNotification
               object:nil];

  [center addObserver:self
             selector:@selector(applicationWillEnterForeground:)
                 name:UIApplicationWillEnterForegroundNotification
               object:nil];

  [center addObserver:self
             selector:@selector(keyboardWillChangeFrame:)
                 name:UIKeyboardWillChangeFrameNotification
               object:nil];

  [center addObserver:self
             selector:@selector(keyboardWillBeHidden:)
                 name:UIKeyboardWillHideNotification
               object:nil];

  [center addObserver:self
             selector:@selector(onLocaleUpdated:)
                 name:NSCurrentLocaleDidChangeNotification
               object:nil];

  [center addObserver:self
             selector:@selector(onVoiceOverChanged:)
                 name:UIAccessibilityVoiceOverStatusChanged
               object:nil];

  [center addObserver:self
             selector:@selector(onMemoryWarning:)
                 name:UIApplicationDidReceiveMemoryWarningNotification
               object:nil];
}


- (void)setInitialRoute:(NSString*)route {
  [_navigationChannel.get() invokeMethod:@"setInitialRoute"
                               arguments:route];
}
#pragma mark - Initializing the engine

- (void)alertView:(UIAlertView*)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
  exit(0);
}

- (void)connectToEngineAndLoad {
  if (_connected)
    return;
  _connected = YES;

  TRACE_EVENT0("flutter", "connectToEngineAndLoad");

  // We ask the VM to check what it supports.
  const enum VMType type = Dart_IsPrecompiledRuntime() ? VMTypePrecompilation : VMTypeInterpreter;

  [_dartProject launchInEngine:&_platformView->engine()
                embedderVMType:type
                        result:^(BOOL success, NSString* message) {
                          if (!success) {
                            UIAlertView* alert = [[UIAlertView alloc] initWithTitle:@"Launch Error"
                                                                            message:message
                                                                           delegate:self
                                                                  cancelButtonTitle:@"OK"
                                                                  otherButtonTitles:nil];
                            [alert show];
                            [alert release];
                          }
                        }];
}

#pragma mark - Loading the view

- (void)loadView {
  FlutterView* view = [[FlutterView alloc] init];

  self.view = view;
  self.view.multipleTouchEnabled = YES;
  self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

  [view release];
}

#pragma mark - UIViewController lifecycle notifications

- (void)viewWillAppear:(BOOL)animated {
  FTL_DLOG(ERROR) << "viewWillAppear";
  TRACE_EVENT0("flutter", "VC:view will appear");
  [self connectToEngineAndLoad];
  [super viewWillAppear:animated];
}

- (void)viewDidDisappear:(BOOL)animated {
  FTL_DLOG(ERROR) << "viewDidDisappear";
  TRACE_EVENT0("flutter", "VC:view did disappear");
  [_lifecycleChannel.get() sendMessage:@"AppLifecycleState.paused"];

  [super viewDidDisappear:animated];
}

#pragma mark - Application lifecycle notifications

- (void)applicationBecameActive:(NSNotification*)notification {
  FTL_DLOG(ERROR) << "applicationBecameActive";
  TRACE_EVENT_INSTANT0("flutter", "AD:app became active");
  [_lifecycleChannel.get() sendMessage:@"AppLifecycleState.resumed"];
}

- (void)applicationWillResignActive:(NSNotification*)notification {
  FTL_DLOG(ERROR) << "applicationWillResignActive";
  TRACE_EVENT_INSTANT0("flutter", "AD:app will resign active");
  [_lifecycleChannel.get() sendMessage:@"AppLifecycleState.inactive"];
}

- (void)applicationDidEnterBackground:(NSNotification*)notification {
  FTL_DLOG(ERROR) << "applicationDidEnterBackground";
  TRACE_EVENT_INSTANT0("flutter", "AD:app did enter background");
  [_lifecycleChannel.get() sendMessage:@"AppLifecycleState.paused"];
}

- (void)applicationWillEnterForeground:(NSNotification*)notification {
  FTL_DLOG(ERROR) << "applicationWillEnterForeground";
  TRACE_EVENT_INSTANT0("flutter", "AD:app will enter foreground");
  [_lifecycleChannel.get() sendMessage:@"AppLifecycleState.inactive"];
}

#pragma mark - Touch event handling

enum MapperPhase {
  Accessed,
  Added,
  Removed,
};

using PointerChangeMapperPhase = std::pair<blink::PointerData::Change, MapperPhase>;
static inline PointerChangeMapperPhase PointerChangePhaseFromUITouchPhase(UITouchPhase phase) {
  switch (phase) {
    case UITouchPhaseBegan:
      return PointerChangeMapperPhase(blink::PointerData::Change::kDown, MapperPhase::Added);
    case UITouchPhaseMoved:
    case UITouchPhaseStationary:
      // There is no EVENT_TYPE_POINTER_STATIONARY. So we just pass a move type
      // with the same coordinates
      return PointerChangeMapperPhase(blink::PointerData::Change::kMove, MapperPhase::Accessed);
    case UITouchPhaseEnded:
      return PointerChangeMapperPhase(blink::PointerData::Change::kUp, MapperPhase::Removed);
    case UITouchPhaseCancelled:
      return PointerChangeMapperPhase(blink::PointerData::Change::kCancel, MapperPhase::Removed);
  }

  return PointerChangeMapperPhase(blink::PointerData::Change::kCancel, MapperPhase::Accessed);
}

- (void)dispatchTouches:(NSSet*)touches phase:(UITouchPhase)phase {
  // Note: we cannot rely on touch.phase, since in some cases, e.g.,
  // handleStatusBarTouches, we synthesize touches from existing events.
  //
  // TODO(cbracken) consider creating out own class with the touch fields we
  // need.
  auto eventTypePhase = PointerChangePhaseFromUITouchPhase(phase);
  const CGFloat scale = [UIScreen mainScreen].scale;
  auto packet = std::make_unique<blink::PointerDataPacket>(touches.count);

  int i = 0;
  for (UITouch* touch in touches) {
    int device_id = 0;

    switch (eventTypePhase.second) {
      case Accessed:
        device_id = _touchMapper.identifierOf(touch);
        break;
      case Added:
        device_id = _touchMapper.registerTouch(touch);
        break;
      case Removed:
        device_id = _touchMapper.unregisterTouch(touch);
        break;
    }

    FTL_DCHECK(device_id != 0);
    CGPoint windowCoordinates = [touch locationInView:nil];

    blink::PointerData pointer_data;
    pointer_data.Clear();

    constexpr int kMicrosecondsPerSecond = 1000 * 1000;
    pointer_data.time_stamp = touch.timestamp * kMicrosecondsPerSecond;
    pointer_data.change = eventTypePhase.first;
    pointer_data.kind = blink::PointerData::DeviceKind::kTouch;
    pointer_data.device = device_id;
    pointer_data.physical_x = windowCoordinates.x * scale;
    pointer_data.physical_y = windowCoordinates.y * scale;
    pointer_data.pressure = 1.0;
    pointer_data.pressure_max = 1.0;

    packet->SetPointerData(i++, pointer_data);
  }

  blink::Threads::UI()->PostTask(ftl::MakeCopyable(
      [ engine = _platformView->engine().GetWeakPtr(), packet = std::move(packet) ] {
        if (engine.get())
          engine->DispatchPointerDataPacket(*packet);
      }));
}

- (void)touchesBegan:(NSSet*)touches withEvent:(UIEvent*)event {
  [self dispatchTouches:touches phase:UITouchPhaseBegan];
}

- (void)touchesMoved:(NSSet*)touches withEvent:(UIEvent*)event {
  [self dispatchTouches:touches phase:UITouchPhaseMoved];
}

- (void)touchesEnded:(NSSet*)touches withEvent:(UIEvent*)event {
  [self dispatchTouches:touches phase:UITouchPhaseEnded];
}

- (void)touchesCancelled:(NSSet*)touches withEvent:(UIEvent*)event {
  [self dispatchTouches:touches phase:UITouchPhaseCancelled];
}

#pragma mark - Handle view resizing

- (void)updateViewportMetrics {
  blink::Threads::UI()->PostTask(
      [ weak_platform_view = _platformView->GetWeakPtr(), metrics = _viewportMetrics ] {
        if (!weak_platform_view) {
          return;
        }
        weak_platform_view->UpdateSurfaceSize();
        weak_platform_view->engine().SetViewportMetrics(metrics);
      });
}

- (CGFloat)statusBarPadding {
  UIScreen* screen = self.view.window.screen;
  CGRect statusFrame = [UIApplication sharedApplication].statusBarFrame;
  CGRect viewFrame =
      [self.view convertRect:self.view.bounds toCoordinateSpace:screen.coordinateSpace];
  CGRect intersection = CGRectIntersection(statusFrame, viewFrame);
  return CGRectIsNull(intersection) ? 0.0 : intersection.size.height;
}

- (void)viewDidLayoutSubviews {
  CGSize viewSize = self.view.bounds.size;
  CGFloat scale = [UIScreen mainScreen].scale;

  _viewportMetrics.device_pixel_ratio = scale;
  _viewportMetrics.physical_width = viewSize.width * scale;
  _viewportMetrics.physical_height = viewSize.height * scale;
  _viewportMetrics.physical_padding_top = [self statusBarPadding] * scale;
  [self updateViewportMetrics];
}

#pragma mark - Keyboard events

- (void)keyboardWillChangeFrame:(NSNotification*)notification {
  NSDictionary* info = [notification userInfo];
  CGFloat bottom =
      CGRectGetHeight([[info objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue]);
  CGFloat scale = [UIScreen mainScreen].scale;
  _viewportMetrics.physical_padding_bottom = bottom * scale;
  [self updateViewportMetrics];
}

- (void)keyboardWillBeHidden:(NSNotification*)notification {
  _viewportMetrics.physical_padding_bottom = 0;
  [self updateViewportMetrics];
}

#pragma mark - Text input delegate

- (void)updateEditingClient:(int)client withState:(NSDictionary*)state {
  [_textInputChannel.get() invokeMethod:@"TextInputClient.updateEditingState"
                              arguments:@[ @(client), state ]];
}

- (void)performAction:(FlutterTextInputAction)action withClient:(int)client {
  NSString* actionString;
  switch (action) {
    case FlutterTextInputActionDone:
      actionString = @"TextInputAction.done";
      break;
  }
  [_textInputChannel.get() invokeMethod:@"TextInputClient.performAction"
                              arguments:@[ @(client), actionString ]];
}

#pragma mark - Orientation updates

- (void)onOrientationPreferencesUpdated:(NSNotification*)notification {
  // Notifications may not be on the iOS UI thread
  dispatch_async(dispatch_get_main_queue(), ^{
    NSDictionary* info = notification.userInfo;

    NSNumber* update = info[@(shell::kOrientationUpdateNotificationKey)];

    if (update == nil) {
      return;
    }

    NSUInteger new_preferences = update.unsignedIntegerValue;

    if (new_preferences != _orientationPreferences) {
      _orientationPreferences = new_preferences;
      [UIViewController attemptRotationToDeviceOrientation];
    }
  });
}

- (BOOL)shouldAutorotate {
  return YES;
}

- (NSUInteger)supportedInterfaceOrientations {
  return _orientationPreferences;
}

#pragma mark - Accessibility

- (void)onVoiceOverChanged:(NSNotification*)notification {
#if TARGET_OS_SIMULATOR
  // There doesn't appear to be any way to determine whether the accessibility
  // inspector is enabled on the simulator. We conservatively always turn on the
  // accessibility bridge in the simulator.
  bool enabled = true;
#else
  bool enabled = UIAccessibilityIsVoiceOverRunning();
#endif
  _platformView->ToggleAccessibility(self.view, enabled);
}

#pragma mark - Memory Notifications

- (void)onMemoryWarning:(NSNotification*)notification {
  [_systemChannel.get() sendMessage:@{ @"type" : @"memoryPressure" }];
}

#pragma mark - Locale updates

- (void)onLocaleUpdated:(NSNotification*)notification {
  NSLocale* currentLocale = [NSLocale currentLocale];
  NSString* languageCode = [currentLocale objectForKey:NSLocaleLanguageCode];
  NSString* countryCode = [currentLocale objectForKey:NSLocaleCountryCode];
  [_localizationChannel.get() invokeMethod:@"setLocale" arguments:@[ languageCode, countryCode ]];
}

#pragma mark - Surface creation and teardown updates

- (void)surfaceUpdated:(BOOL)appeared {
  FTL_CHECK(_platformView != nullptr);

  if (appeared) {
    _platformView->NotifyCreated();
  } else {
    _platformView->NotifyDestroyed();
  }
}

- (void)viewDidAppear:(BOOL)animated {
  TRACE_EVENT0("flutter", "VC:view did appear");
  [self surfaceUpdated:YES];
  [self onLocaleUpdated:nil];
  [self onVoiceOverChanged:nil];
  [_lifecycleChannel.get() sendMessage:@"AppLifecycleState.resumed"];

  [super viewDidAppear:animated];
}

- (void)viewWillDisappear:(BOOL)animated {
  TRACE_EVENT0("flutter", "VC:view will disappear");
  [self surfaceUpdated:NO];

  [super viewWillDisappear:animated];
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [super dealloc];
}

#pragma mark - Status Bar touch event handling

// Standard iOS status bar height in pixels.
constexpr CGFloat kStandardStatusBarHeight = 20.0;

- (void)handleStatusBarTouches:(UIEvent*)event {
  // If the status bar is double-height, don't handle status bar taps. iOS
  // should open the app associated with the status bar.
  CGRect statusBarFrame = [UIApplication sharedApplication].statusBarFrame;
  if (statusBarFrame.size.height != kStandardStatusBarHeight) {
    return;
  }

  // If we detect a touch in the status bar, synthesize a fake touch begin/end.
  for (UITouch* touch in event.allTouches) {
    if (touch.phase == UITouchPhaseBegan && touch.tapCount > 0) {
      CGPoint windowLoc = [touch locationInView:nil];
      CGPoint screenLoc = [touch.window convertPoint:windowLoc toWindow:nil];
      if (CGRectContainsPoint(statusBarFrame, screenLoc)) {
        NSSet* statusbarTouches = [NSSet setWithObject:touch];
        [self dispatchTouches:statusbarTouches phase:UITouchPhaseBegan];
        [self dispatchTouches:statusbarTouches phase:UITouchPhaseEnded];
        return;
      }
    }
  }
}

#pragma mark - Status bar style

- (UIStatusBarStyle)preferredStatusBarStyle {
  return _statusBarStyle;
}

- (void)onPreferredStatusBarStyleUpdated:(NSNotification*)notification {
  // Notifications may not be on the iOS UI thread
  dispatch_async(dispatch_get_main_queue(), ^{
    NSDictionary* info = notification.userInfo;

    NSNumber* update = info[@(shell::kOverlayStyleUpdateNotificationKey)];

    if (update == nil) {
      return;
    }

    NSInteger style = update.integerValue;

    if (style != _statusBarStyle) {
      _statusBarStyle = static_cast<UIStatusBarStyle>(style);
      [self setNeedsStatusBarAppearanceUpdate];
    }
  });
}

#pragma mark - FlutterBinaryMessenger

- (void)sendOnChannel:(NSString*)channel message:(NSData*)message {
  [self sendOnChannel:channel message:message binaryReply:nil];
}

- (void)sendOnChannel:(NSString*)channel
              message:(NSData*)message
          binaryReply:(FlutterBinaryReply)callback {
  NSAssert(channel, @"The channel must not be null");
  ftl::RefPtr<PlatformMessageResponseDarwin> response =
      (callback == nil) ? nullptr
                        : ftl::MakeRefCounted<PlatformMessageResponseDarwin>(^(NSData* reply) {
                            callback(reply);
                          });
  ftl::RefPtr<blink::PlatformMessage> platformMessage =
      (message == nil) ? ftl::MakeRefCounted<blink::PlatformMessage>(channel.UTF8String, response)
                       : ftl::MakeRefCounted<blink::PlatformMessage>(
                             channel.UTF8String, shell::GetVectorFromNSData(message), response);
  _platformView->DispatchPlatformMessage(platformMessage);
}

- (void)setMessageHandlerOnChannel:(NSString*)channel
              binaryMessageHandler:(FlutterBinaryMessageHandler)handler {
  NSAssert(channel, @"The channel must not be null");
  _platformView->platform_message_router().SetMessageHandler(channel.UTF8String, handler);
}
@end
