// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#define FML_USED_ON_EMBEDDER

#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterPlatformViews_Internal.h"
#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterViewController_Internal.h"

#include <memory>

#include "flutter/fml/memory/weak_ptr.h"
#include "flutter/fml/message_loop.h"
#include "flutter/fml/platform/darwin/platform_version.h"
#include "flutter/fml/platform/darwin/scoped_nsobject.h"
#include "flutter/runtime/ptrace_check.h"
#include "flutter/shell/common/thread_host.h"
#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterBinaryMessengerRelay.h"
#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterEngine_Internal.h"
#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterPlatformPlugin.h"
#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterTextInputDelegate.h"
#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterTextInputPlugin.h"
#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterView.h"
#import "flutter/shell/platform/darwin/ios/framework/Source/platform_message_response_darwin.h"
#import "flutter/shell/platform/darwin/ios/platform_view_ios.h"

static constexpr int kMicrosecondsPerSecond = 1000 * 1000;
static constexpr CGFloat kScrollViewContentSize = 2.0;

NSNotificationName const FlutterSemanticsUpdateNotification = @"FlutterSemanticsUpdate";
NSNotificationName const FlutterViewControllerWillDealloc = @"FlutterViewControllerWillDealloc";
NSNotificationName const FlutterViewControllerHideHomeIndicator =
    @"FlutterViewControllerHideHomeIndicator";
NSNotificationName const FlutterViewControllerShowHomeIndicator =
    @"FlutterViewControllerShowHomeIndicator";

// This is left a FlutterBinaryMessenger privately for now to give people a chance to notice the
// change. Unfortunately unless you have Werror turned on, incompatible pointers as arguments are
// just a warning.
@interface FlutterViewController () <FlutterBinaryMessenger, UIScrollViewDelegate>
@property(nonatomic, readwrite, getter=isDisplayingFlutterUI) BOOL displayingFlutterUI;
@property(nonatomic, assign) BOOL isHomeIndicatorHidden;
@property(nonatomic, assign) BOOL isPresentingViewControllerAnimating;
@end

// The following conditional compilation defines an API 13 concept on earlier API targets so that
// a compiler compiling against API 12 or below does not blow up due to non-existent members.
#if __IPHONE_OS_VERSION_MAX_ALLOWED < 130000
typedef enum UIAccessibilityContrast : NSInteger {
  UIAccessibilityContrastUnspecified = 0,
  UIAccessibilityContrastNormal = 1,
  UIAccessibilityContrastHigh = 2
} UIAccessibilityContrast;

@interface UITraitCollection (MethodsFromNewerSDK)
- (UIAccessibilityContrast)accessibilityContrast;
@end
#endif

@implementation FlutterViewController {
  std::unique_ptr<fml::WeakPtrFactory<FlutterViewController>> _weakFactory;
  fml::scoped_nsobject<FlutterEngine> _engine;

  // We keep a separate reference to this and create it ahead of time because we want to be able to
  // setup a shell along with its platform view before the view has to appear.
  fml::scoped_nsobject<FlutterView> _flutterView;
  fml::scoped_nsobject<UIView> _splashScreenView;
  fml::ScopedBlock<void (^)(void)> _flutterViewRenderedCallback;
  UIInterfaceOrientationMask _orientationPreferences;
  UIStatusBarStyle _statusBarStyle;
  flutter::ViewportMetrics _viewportMetrics;
  BOOL _initialized;
  BOOL _viewOpaque;
  BOOL _engineNeedsLaunch;
  fml::scoped_nsobject<NSMutableSet<NSNumber*>> _ongoingTouches;
  // This scroll view is a workaround to accomodate iOS 13 and higher.  There isn't a way to get
  // touches on the status bar to trigger scrolling to the top of a scroll view.  We place a
  // UIScrollView with height zero and a content offset so we can get those events. See also:
  // https://github.com/flutter/flutter/issues/35050
  fml::scoped_nsobject<UIScrollView> _scrollView;
}

@synthesize displayingFlutterUI = _displayingFlutterUI;

#pragma mark - Manage and override all designated initializers

- (instancetype)initWithEngine:(FlutterEngine*)engine
                       nibName:(nullable NSString*)nibName
                        bundle:(nullable NSBundle*)nibBundle {
  NSAssert(engine != nil, @"Engine is required");
  self = [super initWithNibName:nibName bundle:nibBundle];
  if (self) {
    _viewOpaque = YES;
    if (engine.viewController) {
      FML_LOG(ERROR) << "The supplied FlutterEngine " << [[engine description] UTF8String]
                     << " is already used with FlutterViewController instance "
                     << [[engine.viewController description] UTF8String]
                     << ". One instance of the FlutterEngine can only be attached to one "
                        "FlutterViewController at a time. Set FlutterEngine.viewController "
                        "to nil before attaching it to another FlutterViewController.";
    }
    _engine.reset([engine retain]);
    _engineNeedsLaunch = NO;
    _flutterView.reset([[FlutterView alloc] initWithDelegate:_engine opaque:self.isViewOpaque]);
    _weakFactory = std::make_unique<fml::WeakPtrFactory<FlutterViewController>>(self);
    _ongoingTouches.reset([[NSMutableSet alloc] init]);

    [self performCommonViewControllerInitialization];
    [engine setViewController:self];
  }

  return self;
}

- (instancetype)initWithProject:(FlutterDartProject*)project
                        nibName:(NSString*)nibName
                         bundle:(NSBundle*)nibBundle {
  self = [super initWithNibName:nibName bundle:nibBundle];
  if (self) {
    [self sharedSetupWithProject:project initialRoute:nil];
  }

  return self;
}

- (instancetype)initWithProject:(FlutterDartProject*)project
                   initialRoute:(NSString*)initialRoute
                        nibName:(NSString*)nibName
                         bundle:(NSBundle*)nibBundle {
  self = [super initWithNibName:nibName bundle:nibBundle];
  if (self) {
    [self sharedSetupWithProject:project initialRoute:initialRoute];
  }

  return self;
}

- (instancetype)initWithNibName:(NSString*)nibNameOrNil bundle:(NSBundle*)nibBundleOrNil {
  return [self initWithProject:nil nibName:nil bundle:nil];
}

- (instancetype)initWithCoder:(NSCoder*)aDecoder {
  self = [super initWithCoder:aDecoder];
  return self;
}

- (void)awakeFromNib {
  [super awakeFromNib];
  if (!_engine) {
    [self sharedSetupWithProject:nil initialRoute:nil];
  }
}

- (instancetype)init {
  return [self initWithProject:nil nibName:nil bundle:nil];
}

- (void)sharedSetupWithProject:(nullable FlutterDartProject*)project
                  initialRoute:(nullable NSString*)initialRoute {
  auto engine = fml::scoped_nsobject<FlutterEngine>{[[FlutterEngine alloc]
                initWithName:@"io.flutter"
                     project:project
      allowHeadlessExecution:self.engineAllowHeadlessExecution]};

  if (!engine) {
    return;
  }

  _viewOpaque = YES;
  _weakFactory = std::make_unique<fml::WeakPtrFactory<FlutterViewController>>(self);
  _engine = std::move(engine);
  _flutterView.reset([[FlutterView alloc] initWithDelegate:_engine opaque:self.isViewOpaque]);
  [_engine.get() createShell:nil libraryURI:nil initialRoute:initialRoute];
  _engineNeedsLaunch = YES;
  _ongoingTouches.reset([[NSMutableSet alloc] init]);
//  [self loadDefaultSplashScreenView];
  [self performCommonViewControllerInitialization];
}

- (BOOL)isViewOpaque {
  return _viewOpaque;
}

- (void)setViewOpaque:(BOOL)value {
  _viewOpaque = value;
  if (_flutterView.get().layer.opaque != value) {
    _flutterView.get().layer.opaque = value;
    [_flutterView.get().layer setNeedsLayout];
  }
}

#pragma mark - Common view controller initialization tasks

- (void)performCommonViewControllerInitialization {
  if (_initialized)
    return;

  _initialized = YES;

  _orientationPreferences = UIInterfaceOrientationMaskAll;
  _statusBarStyle = UIStatusBarStyleDefault;

  [self setupNotificationCenterObservers];
}

- (FlutterEngine*)engine {
  return _engine.get();
}

- (fml::WeakPtr<FlutterViewController>)getWeakPtr {
  return _weakFactory->GetWeakPtr();
}

- (void)setupNotificationCenterObservers {
  NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
  [center addObserver:self
             selector:@selector(onOrientationPreferencesUpdated:)
                 name:@(flutter::kOrientationUpdateNotificationName)
               object:nil];

  [center addObserver:self
             selector:@selector(onPreferredStatusBarStyleUpdated:)
                 name:@(flutter::kOverlayStyleUpdateNotificationName)
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
             selector:@selector(onAccessibilityStatusChanged:)
                 name:UIAccessibilityVoiceOverStatusChanged
               object:nil];

  [center addObserver:self
             selector:@selector(onAccessibilityStatusChanged:)
                 name:UIAccessibilitySwitchControlStatusDidChangeNotification
               object:nil];

  [center addObserver:self
             selector:@selector(onAccessibilityStatusChanged:)
                 name:UIAccessibilitySpeakScreenStatusDidChangeNotification
               object:nil];

  [center addObserver:self
             selector:@selector(onAccessibilityStatusChanged:)
                 name:UIAccessibilityInvertColorsStatusDidChangeNotification
               object:nil];

  [center addObserver:self
             selector:@selector(onAccessibilityStatusChanged:)
                 name:UIAccessibilityReduceMotionStatusDidChangeNotification
               object:nil];

  [center addObserver:self
             selector:@selector(onAccessibilityStatusChanged:)
                 name:UIAccessibilityBoldTextStatusDidChangeNotification
               object:nil];

  [center addObserver:self
             selector:@selector(onAccessibilityStatusChanged:)
                 name:UIAccessibilityDarkerSystemColorsStatusDidChangeNotification
               object:nil];

  [center addObserver:self
             selector:@selector(onUserSettingsChanged:)
                 name:UIContentSizeCategoryDidChangeNotification
               object:nil];

  [center addObserver:self
             selector:@selector(onHideHomeIndicatorNotification:)
                 name:FlutterViewControllerHideHomeIndicator
               object:nil];

  [center addObserver:self
             selector:@selector(onShowHomeIndicatorNotification:)
                 name:FlutterViewControllerShowHomeIndicator
               object:nil];
}

- (void)setInitialRoute:(NSString*)route {
  [[_engine.get() navigationChannel] invokeMethod:@"setInitialRoute" arguments:route];
}

- (void)popRoute {
  [[_engine.get() navigationChannel] invokeMethod:@"popRoute" arguments:nil];
}

- (void)pushRoute:(NSString*)route {
  [[_engine.get() navigationChannel] invokeMethod:@"pushRoute" arguments:route];
}

#pragma mark - Loading the view

static UIView* GetViewOrPlaceholder(UIView* existing_view) {
  if (existing_view) {
    return existing_view;
  }

  auto placeholder = [[[UIView alloc] init] autorelease];

  placeholder.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  if (@available(iOS 13.0, *)) {
    placeholder.backgroundColor = UIColor.systemBackgroundColor;
  } else {
    placeholder.backgroundColor = UIColor.whiteColor;
  }
  placeholder.autoresizesSubviews = YES;

  // Only add the label when we know we have failed to enable tracing (and it was necessary).
  // Otherwise, a spurious warning will be shown in cases where an engine cannot be initialized for
  // other reasons.
  if (flutter::GetTracingResult() == flutter::TracingResult::kDisabled) {
    auto messageLabel = [[[UILabel alloc] init] autorelease];
    messageLabel.numberOfLines = 0u;
    messageLabel.textAlignment = NSTextAlignmentCenter;
    messageLabel.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    messageLabel.text =
        @"In iOS 14+, debug mode Flutter apps can only be launched from Flutter tooling, "
        @"IDEs with Flutter plugins or from Xcode.\n\nAlternatively, build in profile or release "
        @"modes to enable launching from the home screen.";
    [placeholder addSubview:messageLabel];
  }

  return placeholder;
}

- (void)loadView {
  self.view = GetViewOrPlaceholder(_flutterView.get());
  self.view.multipleTouchEnabled = YES;
  self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

  [self installSplashScreenViewIfNecessary];
  UIScrollView* scrollView = [[UIScrollView alloc] init];
  scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  // The color shouldn't matter since it is offscreen.
  scrollView.backgroundColor = UIColor.whiteColor;
  scrollView.delegate = self;
  // This is an arbitrary small size.
  scrollView.contentSize = CGSizeMake(kScrollViewContentSize, kScrollViewContentSize);
  // This is an arbitrary offset that is not CGPointZero.
  scrollView.contentOffset = CGPointMake(kScrollViewContentSize, kScrollViewContentSize);
  [self.view addSubview:scrollView];
  _scrollView.reset(scrollView);
}

static void sendFakeTouchEvent(FlutterEngine* engine,
                               CGPoint location,
                               flutter::PointerData::Change change) {
  const CGFloat scale = [UIScreen mainScreen].scale;
  flutter::PointerData pointer_data;
  pointer_data.Clear();
  pointer_data.physical_x = location.x * scale;
  pointer_data.physical_y = location.y * scale;
  pointer_data.kind = flutter::PointerData::DeviceKind::kTouch;
  pointer_data.time_stamp = [[NSDate date] timeIntervalSince1970] * kMicrosecondsPerSecond;
  auto packet = std::make_unique<flutter::PointerDataPacket>(/*count=*/1);
  pointer_data.change = change;
  packet->SetPointerData(0, pointer_data);
  [engine dispatchPointerDataPacket:std::move(packet)];
}

- (BOOL)scrollViewShouldScrollToTop:(UIScrollView*)scrollView {
  if (!_engine) {
    return NO;
  }
  CGPoint statusBarPoint = CGPointZero;
  sendFakeTouchEvent(_engine.get(), statusBarPoint, flutter::PointerData::Change::kDown);
  sendFakeTouchEvent(_engine.get(), statusBarPoint, flutter::PointerData::Change::kUp);
  return NO;
}

#pragma mark - Managing launch views

- (void)installSplashScreenViewIfNecessary {
  // Show the launch screen view again on top of the FlutterView if available.
  // This launch screen view will be removed once the first Flutter frame is rendered.
  if (_splashScreenView && (self.isBeingPresented || self.isMovingToParentViewController)) {
    [_splashScreenView.get() removeFromSuperview];
    _splashScreenView.reset();
    return;
  }

  // Use the property getter to initialize the default value.
  UIView* splashScreenView = self.splashScreenView;
  if (splashScreenView == nil) {
    return;
  }
  splashScreenView.frame = self.view.bounds;
  [self.view addSubview:splashScreenView];
}

+ (BOOL)automaticallyNotifiesObserversOfDisplayingFlutterUI {
  return NO;
}

- (void)setDisplayingFlutterUI:(BOOL)displayingFlutterUI {
  if (_displayingFlutterUI != displayingFlutterUI) {
    if (displayingFlutterUI == YES) {
      if (!self.isViewLoaded || !self.view.window) {
        return;
      }
    }
    [self willChangeValueForKey:@"displayingFlutterUI"];
    _displayingFlutterUI = displayingFlutterUI;
    [self didChangeValueForKey:@"displayingFlutterUI"];
  }
}

- (void)callViewRenderedCallback {
  self.displayingFlutterUI = YES;
  if (_flutterViewRenderedCallback != nil) {
    _flutterViewRenderedCallback.get()();
    _flutterViewRenderedCallback.reset();
  }
}

- (void)removeSplashScreenView:(dispatch_block_t _Nullable)onComplete {
  NSAssert(_splashScreenView, @"The splash screen view must not be null");
  UIView* splashScreen = _splashScreenView.get();
  _splashScreenView.reset();
  [UIView animateWithDuration:0.2
      animations:^{
        splashScreen.alpha = 0;
      }
      completion:^(BOOL finished) {
        [splashScreen removeFromSuperview];
        if (onComplete) {
          onComplete();
        }
      }];
}

- (void)installFirstFrameCallback {
  if (!_engine) {
    return;
  }

  fml::WeakPtr<flutter::PlatformViewIOS> weakPlatformView = [_engine.get() platformView];
  if (!weakPlatformView) {
    return;
  }

  // Start on the platform thread.
  weakPlatformView->SetNextFrameCallback([weakSelf = [self getWeakPtr],
                                          platformTaskRunner = [_engine.get() platformTaskRunner],
                                          RasterTaskRunner = [_engine.get() RasterTaskRunner]]() {
    FML_DCHECK(RasterTaskRunner->RunsTasksOnCurrentThread());
    // Get callback on raster thread and jump back to platform thread.
    platformTaskRunner->PostTask([weakSelf]() {
      fml::scoped_nsobject<FlutterViewController> flutterViewController(
          [(FlutterViewController*)weakSelf.get() retain]);
      if (flutterViewController) {
        if (flutterViewController.get()->_splashScreenView) {
          [flutterViewController removeSplashScreenView:^{
            [flutterViewController callViewRenderedCallback];
          }];
        } else {
          [flutterViewController callViewRenderedCallback];
        }
      }
    });
  });
}

#pragma mark - Properties

- (UIView*)splashScreenView {
  if (!_splashScreenView) {
    return nil;
  }
  return _splashScreenView.get();
}

- (BOOL)loadDefaultSplashScreenView {
  NSString* launchscreenName =
      [[[NSBundle mainBundle] infoDictionary] objectForKey:@"UILaunchStoryboardName"];
  if (launchscreenName == nil) {
    return NO;
  }
  UIView* splashView = [self splashScreenFromStoryboard:launchscreenName];
  if (!splashView) {
    splashView = [self splashScreenFromXib:launchscreenName];
  }
  if (!splashView) {
    return NO;
  }
  self.splashScreenView = splashView;
  return YES;
}

- (UIView*)splashScreenFromStoryboard:(NSString*)name {
  UIStoryboard* storyboard = nil;
  @try {
    storyboard = [UIStoryboard storyboardWithName:name bundle:nil];
  } @catch (NSException* exception) {
    return nil;
  }
  if (storyboard) {
    UIViewController* splashScreenViewController = [storyboard instantiateInitialViewController];
    return splashScreenViewController.view;
  }
  return nil;
}

- (UIView*)splashScreenFromXib:(NSString*)name {
  NSArray* objects = nil;
  @try {
    objects = [[NSBundle mainBundle] loadNibNamed:name owner:self options:nil];
  } @catch (NSException* exception) {
    return nil;
  }
  if ([objects count] != 0) {
    UIView* view = [objects objectAtIndex:0];
    return view;
  }
  return nil;
}

- (void)setSplashScreenView:(UIView*)view {
  if (!view) {
    // Special case: user wants to remove the splash screen view.
    if (_splashScreenView) {
      [self removeSplashScreenView:nil];
    }
    return;
  }

  _splashScreenView.reset([view retain]);
  _splashScreenView.get().autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
}

- (void)setFlutterViewDidRenderCallback:(void (^)(void))callback {
  _flutterViewRenderedCallback.reset(callback, fml::OwnershipPolicy::Retain);
}

#pragma mark - Surface creation and teardown updates

- (void)surfaceUpdated:(BOOL)appeared {
  if (!_engine) {
    return;
  }

  // NotifyCreated/NotifyDestroyed are synchronous and require hops between the UI and raster
  // thread.
  if (appeared) {
    [self installFirstFrameCallback];
    [_engine.get() platformViewsController]->SetFlutterView(_flutterView.get());
    [_engine.get() platformViewsController]->SetFlutterViewController(self);
    [_engine.get() platformView]->NotifyCreated();
  } else {
    self.displayingFlutterUI = NO;
    [_engine.get() platformView]->NotifyDestroyed();
    [_engine.get() platformViewsController]->SetFlutterView(nullptr);
    [_engine.get() platformViewsController]->SetFlutterViewController(nullptr);
  }
}

#pragma mark - UIViewController lifecycle notifications

- (void)viewDidLoad {
  TRACE_EVENT0("flutter", "viewDidLoad");

  if (_engine && _engineNeedsLaunch) {
    [_engine.get() launchEngine:nil libraryURI:nil];
    [_engine.get() setViewController:self];
    _engineNeedsLaunch = NO;
  }

  [_engine.get() attachView];

  [super viewDidLoad];
}

- (void)viewWillAppear:(BOOL)animated {
  TRACE_EVENT0("flutter", "viewWillAppear");

  // Send platform settings to Flutter, e.g., platform brightness.
  [self onUserSettingsChanged:nil];

  // Only recreate surface on subsequent appearances when viewport metrics are known.
  // First time surface creation is done on viewDidLayoutSubviews.
  if (_viewportMetrics.physical_width) {
    [self surfaceUpdated:YES];
  }
  [[_engine.get() lifecycleChannel] sendMessage:@"AppLifecycleState.inactive"];

  [super viewWillAppear:animated];
}

- (void)viewDidAppear:(BOOL)animated {
  TRACE_EVENT0("flutter", "viewDidAppear");
  [self onUserSettingsChanged:nil];
  [self onAccessibilityStatusChanged:nil];
  [[_engine.get() lifecycleChannel] sendMessage:@"AppLifecycleState.resumed"];

  [super viewDidAppear:animated];
}

- (void)viewWillDisappear:(BOOL)animated {
  TRACE_EVENT0("flutter", "viewWillDisappear");
  [[_engine.get() lifecycleChannel] sendMessage:@"AppLifecycleState.inactive"];

  [super viewWillDisappear:animated];
}

- (void)viewDidDisappear:(BOOL)animated {
  TRACE_EVENT0("flutter", "viewDidDisappear");
  if ([_engine.get() viewController] == self) {
    [self surfaceUpdated:NO];
    [[_engine.get() lifecycleChannel] sendMessage:@"AppLifecycleState.paused"];
    [self flushOngoingTouches];
    [_engine.get() notifyLowMemory];
  }

  [super viewDidDisappear:animated];
}

- (void)flushOngoingTouches {
  if (_engine && _ongoingTouches.get().count > 0) {
    auto packet = std::make_unique<flutter::PointerDataPacket>(_ongoingTouches.get().count);
    size_t pointer_index = 0;
    // If the view controller is going away, we want to flush cancel all the ongoing
    // touches to the framework so nothing gets orphaned.
    for (NSNumber* device in _ongoingTouches.get()) {
      // Create fake PointerData to balance out each previously started one for the framework.
      flutter::PointerData pointer_data;
      pointer_data.Clear();

      // Use current time.
      pointer_data.time_stamp = [[NSDate date] timeIntervalSince1970] * kMicrosecondsPerSecond;

      pointer_data.change = flutter::PointerData::Change::kCancel;
      pointer_data.kind = flutter::PointerData::DeviceKind::kTouch;
      pointer_data.device = device.longLongValue;
      pointer_data.pointer_identifier = 0;

      // Anything we put here will be arbitrary since there are no touches.
      pointer_data.physical_x = 0;
      pointer_data.physical_y = 0;
      pointer_data.physical_delta_x = 0.0;
      pointer_data.physical_delta_y = 0.0;
      pointer_data.pressure = 1.0;
      pointer_data.pressure_max = 1.0;

      packet->SetPointerData(pointer_index++, pointer_data);
    }

    [_ongoingTouches removeAllObjects];
    [_engine.get() dispatchPointerDataPacket:std::move(packet)];
  }
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] postNotificationName:FlutterViewControllerWillDealloc
                                                      object:self
                                                    userInfo:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [super dealloc];
}

#pragma mark - Application lifecycle notifications

- (void)applicationBecameActive:(NSNotification*)notification {
  TRACE_EVENT0("flutter", "applicationBecameActive");
  if (_viewportMetrics.physical_width)
    [self surfaceUpdated:YES];
  [self goToApplicationLifecycle:@"AppLifecycleState.resumed"];
}

- (void)applicationWillResignActive:(NSNotification*)notification {
  TRACE_EVENT0("flutter", "applicationWillResignActive");
  [self surfaceUpdated:NO];
  [self goToApplicationLifecycle:@"AppLifecycleState.inactive"];
}

- (void)applicationDidEnterBackground:(NSNotification*)notification {
  TRACE_EVENT0("flutter", "applicationDidEnterBackground");
  [self goToApplicationLifecycle:@"AppLifecycleState.paused"];
}

- (void)applicationWillEnterForeground:(NSNotification*)notification {
  TRACE_EVENT0("flutter", "applicationWillEnterForeground");
  [self goToApplicationLifecycle:@"AppLifecycleState.inactive"];
}

// Make this transition only while this current view controller is visible.
- (void)goToApplicationLifecycle:(nonnull NSString*)state {
  // Accessing self.view will create the view. Check whether the view is organically loaded
  // first before checking whether the view is attached to window.
  if (self.isViewLoaded && self.view.window) {
    [[_engine.get() lifecycleChannel] sendMessage:state];
  }
}

#pragma mark - Touch event handling

static flutter::PointerData::Change PointerDataChangeFromUITouchPhase(UITouchPhase phase) {
  switch (phase) {
    case UITouchPhaseBegan:
      return flutter::PointerData::Change::kDown;
    case UITouchPhaseMoved:
    case UITouchPhaseStationary:
      // There is no EVENT_TYPE_POINTER_STATIONARY. So we just pass a move type
      // with the same coordinates
      return flutter::PointerData::Change::kMove;
    case UITouchPhaseEnded:
      return flutter::PointerData::Change::kUp;
    case UITouchPhaseCancelled:
      return flutter::PointerData::Change::kCancel;
    default:
      // TODO(53695): Handle the `UITouchPhaseRegion`... enum values.
      FML_DLOG(INFO) << "Unhandled touch phase: " << phase;
      break;
  }

  return flutter::PointerData::Change::kCancel;
}

static flutter::PointerData::DeviceKind DeviceKindFromTouchType(UITouch* touch) {
  if (@available(iOS 9, *)) {
    switch (touch.type) {
      case UITouchTypeDirect:
      case UITouchTypeIndirect:
        return flutter::PointerData::DeviceKind::kTouch;
      case UITouchTypeStylus:
        return flutter::PointerData::DeviceKind::kStylus;
      default:
        // TODO(53696): Handle the UITouchTypeIndirectPointer enum value.
        FML_DLOG(INFO) << "Unhandled touch type: " << touch.type;
        break;
    }
  }

  return flutter::PointerData::DeviceKind::kTouch;
}

// Dispatches the UITouches to the engine. Usually, the type of change of the touch is determined
// from the UITouch's phase. However, FlutterAppDelegate fakes touches to ensure that touch events
// in the status bar area are available to framework code. The change type (optional) of the faked
// touch is specified in the second argument.
- (void)dispatchTouches:(NSSet*)touches
    pointerDataChangeOverride:(flutter::PointerData::Change*)overridden_change {
  if (!_engine) {
    return;
  }

  const CGFloat scale = [UIScreen mainScreen].scale;
  auto packet = std::make_unique<flutter::PointerDataPacket>(touches.count);

  size_t pointer_index = 0;

  for (UITouch* touch in touches) {
    CGPoint windowCoordinates = [touch locationInView:self.view];

    flutter::PointerData pointer_data;
    pointer_data.Clear();

    constexpr int kMicrosecondsPerSecond = 1000 * 1000;
    pointer_data.time_stamp = touch.timestamp * kMicrosecondsPerSecond;

    pointer_data.change = overridden_change != nullptr
                              ? *overridden_change
                              : PointerDataChangeFromUITouchPhase(touch.phase);

    pointer_data.kind = DeviceKindFromTouchType(touch);

    pointer_data.device = reinterpret_cast<int64_t>(touch);

    // Pointer will be generated in pointer_data_packet_converter.cc.
    pointer_data.pointer_identifier = 0;

    pointer_data.physical_x = windowCoordinates.x * scale;
    pointer_data.physical_y = windowCoordinates.y * scale;

    // Delta will be generated in pointer_data_packet_converter.cc.
    pointer_data.physical_delta_x = 0.0;
    pointer_data.physical_delta_y = 0.0;

    NSNumber* deviceKey = [NSNumber numberWithLongLong:pointer_data.device];
    // Track touches that began and not yet stopped so we can flush them
    // if the view controller goes away.
    switch (pointer_data.change) {
      case flutter::PointerData::Change::kDown:
        [_ongoingTouches addObject:deviceKey];
        break;
      case flutter::PointerData::Change::kCancel:
      case flutter::PointerData::Change::kUp:
        [_ongoingTouches removeObject:deviceKey];
        break;
      case flutter::PointerData::Change::kHover:
      case flutter::PointerData::Change::kMove:
        // We're only tracking starts and stops.
        break;
      case flutter::PointerData::Change::kAdd:
      case flutter::PointerData::Change::kRemove:
        // We don't use kAdd/kRemove.
        break;
    }

    // pressure_min is always 0.0
    if (@available(iOS 9, *)) {
      // These properties were introduced in iOS 9.0.
      pointer_data.pressure = touch.force;
      pointer_data.pressure_max = touch.maximumPossibleForce;
    } else {
      pointer_data.pressure = 1.0;
      pointer_data.pressure_max = 1.0;
    }

    // These properties were introduced in iOS 8.0
    pointer_data.radius_major = touch.majorRadius;
    pointer_data.radius_min = touch.majorRadius - touch.majorRadiusTolerance;
    pointer_data.radius_max = touch.majorRadius + touch.majorRadiusTolerance;

    // These properties were introduced in iOS 9.1
    if (@available(iOS 9.1, *)) {
      // iOS Documentation: altitudeAngle
      // A value of 0 radians indicates that the stylus is parallel to the surface. The value of
      // this property is Pi/2 when the stylus is perpendicular to the surface.
      //
      // PointerData Documentation: tilt
      // The angle of the stylus, in radians in the range:
      //    0 <= tilt <= pi/2
      // giving the angle of the axis of the stylus, relative to the axis perpendicular to the input
      // surface (thus 0.0 indicates the stylus is orthogonal to the plane of the input surface,
      // while pi/2 indicates that the stylus is flat on that surface).
      //
      // Discussion:
      // The ranges are the same. Origins are swapped.
      pointer_data.tilt = M_PI_2 - touch.altitudeAngle;

      // iOS Documentation: azimuthAngleInView:
      // With the tip of the stylus touching the screen, the value of this property is 0 radians
      // when the cap end of the stylus (that is, the end opposite of the tip) points along the
      // positive x axis of the device's screen. The azimuth angle increases as the user swings the
      // cap end of the stylus in a clockwise direction around the tip.
      //
      // PointerData Documentation: orientation
      // The angle of the stylus, in radians in the range:
      //    -pi < orientation <= pi
      // giving the angle of the axis of the stylus projected onto the input surface, relative to
      // the positive y-axis of that surface (thus 0.0 indicates the stylus, if projected onto that
      // surface, would go from the contact point vertically up in the positive y-axis direction, pi
      // would indicate that the stylus would go down in the negative y-axis direction; pi/4 would
      // indicate that the stylus goes up and to the right, -pi/2 would indicate that the stylus
      // goes to the left, etc).
      //
      // Discussion:
      // Sweep direction is the same. Phase of M_PI_2.
      pointer_data.orientation = [touch azimuthAngleInView:nil] - M_PI_2;
    }

    packet->SetPointerData(pointer_index++, pointer_data);
  }

  [_engine.get() dispatchPointerDataPacket:std::move(packet)];
}

- (void)touchesBegan:(NSSet*)touches withEvent:(UIEvent*)event {
  [self dispatchTouches:touches pointerDataChangeOverride:nullptr];
}

- (void)touchesMoved:(NSSet*)touches withEvent:(UIEvent*)event {
  [self dispatchTouches:touches pointerDataChangeOverride:nullptr];
}

- (void)touchesEnded:(NSSet*)touches withEvent:(UIEvent*)event {
  [self dispatchTouches:touches pointerDataChangeOverride:nullptr];
}

- (void)touchesCancelled:(NSSet*)touches withEvent:(UIEvent*)event {
  [self dispatchTouches:touches pointerDataChangeOverride:nullptr];
}

#pragma mark - Handle view resizing

- (void)updateViewportMetrics {
  [_engine.get() updateViewportMetrics:_viewportMetrics];
}

- (CGFloat)statusBarPadding {
  UIScreen* screen = self.view.window.screen;
  CGRect statusFrame = [UIApplication sharedApplication].statusBarFrame;
  CGRect viewFrame = [self.view convertRect:self.view.bounds
                          toCoordinateSpace:screen.coordinateSpace];
  CGRect intersection = CGRectIntersection(statusFrame, viewFrame);
  return CGRectIsNull(intersection) ? 0.0 : intersection.size.height;
}

- (void)viewDidLayoutSubviews {
  CGSize viewSize = self.view.bounds.size;
  CGFloat scale = [UIScreen mainScreen].scale;

  // Purposefully place this not visible.
  _scrollView.get().frame = CGRectMake(0.0, 0.0, viewSize.width, 0.0);
  _scrollView.get().contentOffset = CGPointMake(kScrollViewContentSize, kScrollViewContentSize);

  // First time since creation that the dimensions of its view is known.
  bool firstViewBoundsUpdate = !_viewportMetrics.physical_width;
  _viewportMetrics.device_pixel_ratio = scale;
  _viewportMetrics.physical_width = viewSize.width * scale;
  _viewportMetrics.physical_height = viewSize.height * scale;

  [self updateViewportPadding];
  [self updateViewportMetrics];

  // There is no guarantee that UIKit will layout subviews when the application is active. Creating
  // the surface when inactive will cause GPU accesses from the background. Only wait for the first
  // frame to render when the application is actually active.
  bool applicationIsActive =
      [UIApplication sharedApplication].applicationState == UIApplicationStateActive;

  // This must run after updateViewportMetrics so that the surface creation tasks are queued after
  // the viewport metrics update tasks.
  if (firstViewBoundsUpdate && applicationIsActive && _engine) {
    [self surfaceUpdated:YES];

    flutter::Shell& shell = [_engine.get() shell];
    fml::TimeDelta waitTime =
#if FLUTTER_RUNTIME_MODE == FLUTTER_RUNTIME_MODE_DEBUG
        fml::TimeDelta::FromMilliseconds(200);
#else
        fml::TimeDelta::FromMilliseconds(100);
#endif
    if (shell.WaitForFirstFrame(waitTime).code() == fml::StatusCode::kDeadlineExceeded) {
      FML_LOG(INFO) << "Timeout waiting for the first frame to render.  This may happen in "
                    << "unoptimized builds.  If this is a release build, you should load a less "
                    << "complex frame to avoid the timeout.";
    }
  }
}

- (void)viewSafeAreaInsetsDidChange {
  [self updateViewportPadding];
  [self updateViewportMetrics];
  [super viewSafeAreaInsetsDidChange];
}

// Updates _viewportMetrics physical padding.
//
// Viewport padding represents the iOS safe area insets.
- (void)updateViewportPadding {
  CGFloat scale = [UIScreen mainScreen].scale;
  if (@available(iOS 11, *)) {
    _viewportMetrics.physical_padding_top = self.view.safeAreaInsets.top * scale;
    _viewportMetrics.physical_padding_left = self.view.safeAreaInsets.left * scale;
    _viewportMetrics.physical_padding_right = self.view.safeAreaInsets.right * scale;
    _viewportMetrics.physical_padding_bottom = self.view.safeAreaInsets.bottom * scale;
  } else {
    _viewportMetrics.physical_padding_top = [self statusBarPadding] * scale;
  }
}

#pragma mark - Keyboard events

- (void)keyboardWillChangeFrame:(NSNotification*)notification {
  NSDictionary* info = [notification userInfo];

  if (@available(iOS 9, *)) {
    // Ignore keyboard notifications related to other apps.
    id isLocal = info[UIKeyboardIsLocalUserInfoKey];
    if (isLocal && ![isLocal boolValue]) {
      return;
    }
  }

  CGRect keyboardFrame = [[info objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
  CGRect screenRect = [[UIScreen mainScreen] bounds];

  // Considering the iPad's split keyboard, Flutter needs to check if the keyboard frame is present
  // in the screen to see if the keyboard is visible.
  if (CGRectIntersectsRect(keyboardFrame, screenRect)) {
    CGFloat bottom = CGRectGetHeight(keyboardFrame);
    CGFloat scale = [UIScreen mainScreen].scale;

    // The keyboard is treated as an inset since we want to effectively reduce the window size by
    // the keyboard height. The Dart side will compute a value accounting for the keyboard-consuming
    // bottom padding.
    _viewportMetrics.physical_view_inset_bottom = bottom * scale;
  } else {
    _viewportMetrics.physical_view_inset_bottom = 0;
  }

  [self updateViewportMetrics];
}

- (void)keyboardWillBeHidden:(NSNotification*)notification {
  _viewportMetrics.physical_view_inset_bottom = 0;
  [self updateViewportMetrics];
}

#pragma mark - Orientation updates

- (void)onOrientationPreferencesUpdated:(NSNotification*)notification {
  // Notifications may not be on the iOS UI thread
  dispatch_async(dispatch_get_main_queue(), ^{
    NSDictionary* info = notification.userInfo;

    NSNumber* update = info[@(flutter::kOrientationUpdateNotificationKey)];

    if (update == nil) {
      return;
    }
    [self performOrientationUpdate:update.unsignedIntegerValue];
  });
}

- (void)performOrientationUpdate:(UIInterfaceOrientationMask)new_preferences {
  if (new_preferences != _orientationPreferences) {
    _orientationPreferences = new_preferences;
    [UIViewController attemptRotationToDeviceOrientation];

    UIInterfaceOrientationMask currentInterfaceOrientation =
        1 << [[UIApplication sharedApplication] statusBarOrientation];
    if (!(_orientationPreferences & currentInterfaceOrientation)) {
      // Force orientation switch if the current orientation is not allowed
      if (_orientationPreferences & UIInterfaceOrientationMaskPortrait) {
        // This is no official API but more like a workaround / hack (using
        // key-value coding on a read-only property). This might break in
        // the future, but currently it´s the only way to force an orientation change
        [[UIDevice currentDevice] setValue:@(UIInterfaceOrientationPortrait) forKey:@"orientation"];
      } else if (_orientationPreferences & UIInterfaceOrientationMaskPortraitUpsideDown) {
        [[UIDevice currentDevice] setValue:@(UIInterfaceOrientationPortraitUpsideDown)
                                    forKey:@"orientation"];
      } else if (_orientationPreferences & UIInterfaceOrientationMaskLandscapeLeft) {
        [[UIDevice currentDevice] setValue:@(UIInterfaceOrientationLandscapeLeft)
                                    forKey:@"orientation"];
      } else if (_orientationPreferences & UIInterfaceOrientationMaskLandscapeRight) {
        [[UIDevice currentDevice] setValue:@(UIInterfaceOrientationLandscapeRight)
                                    forKey:@"orientation"];
      }
    }
  }
}

- (void)onHideHomeIndicatorNotification:(NSNotification*)notification {
  self.isHomeIndicatorHidden = YES;
}

- (void)onShowHomeIndicatorNotification:(NSNotification*)notification {
  self.isHomeIndicatorHidden = NO;
}

- (void)setIsHomeIndicatorHidden:(BOOL)hideHomeIndicator {
  if (hideHomeIndicator != _isHomeIndicatorHidden) {
    _isHomeIndicatorHidden = hideHomeIndicator;
    if (@available(iOS 11, *)) {
      [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
  }
}

- (BOOL)prefersHomeIndicatorAutoHidden {
  return self.isHomeIndicatorHidden;
}

- (BOOL)shouldAutorotate {
  return YES;
}

- (NSUInteger)supportedInterfaceOrientations {
  return _orientationPreferences;
}

#pragma mark - Accessibility

- (void)onAccessibilityStatusChanged:(NSNotification*)notification {
  if (!_engine) {
    return;
  }
  auto platformView = [_engine.get() platformView];
  int32_t flags = 0;
  if (UIAccessibilityIsInvertColorsEnabled())
    flags |= static_cast<int32_t>(flutter::AccessibilityFeatureFlag::kInvertColors);
  if (UIAccessibilityIsReduceMotionEnabled())
    flags |= static_cast<int32_t>(flutter::AccessibilityFeatureFlag::kReduceMotion);
  if (UIAccessibilityIsBoldTextEnabled())
    flags |= static_cast<int32_t>(flutter::AccessibilityFeatureFlag::kBoldText);
  if (UIAccessibilityDarkerSystemColorsEnabled())
    flags |= static_cast<int32_t>(flutter::AccessibilityFeatureFlag::kHighContrast);
#if TARGET_OS_SIMULATOR
  // There doesn't appear to be any way to determine whether the accessibility
  // inspector is enabled on the simulator. We conservatively always turn on the
  // accessibility bridge in the simulator, but never assistive technology.
  platformView->SetSemanticsEnabled(true);
  platformView->SetAccessibilityFeatures(flags);
#else
  bool enabled = UIAccessibilityIsVoiceOverRunning() || UIAccessibilityIsSwitchControlRunning();
  if (enabled)
    flags |= static_cast<int32_t>(flutter::AccessibilityFeatureFlag::kAccessibleNavigation);
  platformView->SetSemanticsEnabled(enabled || UIAccessibilityIsSpeakScreenEnabled());
  platformView->SetAccessibilityFeatures(flags);
#endif
}

#pragma mark - Set user settings

- (void)traitCollectionDidChange:(UITraitCollection*)previousTraitCollection {
  [super traitCollectionDidChange:previousTraitCollection];
  [self onUserSettingsChanged:nil];
}

- (void)onUserSettingsChanged:(NSNotification*)notification {
  [[_engine.get() settingsChannel] sendMessage:@{
    @"textScaleFactor" : @([self textScaleFactor]),
    @"alwaysUse24HourFormat" : @([self isAlwaysUse24HourFormat]),
    @"platformBrightness" : [self brightnessMode],
    @"platformContrast" : [self contrastMode]
  }];
}

- (CGFloat)textScaleFactor {
  UIContentSizeCategory category = [UIApplication sharedApplication].preferredContentSizeCategory;
  // The delta is computed by approximating Apple's typography guidelines:
  // https://developer.apple.com/ios/human-interface-guidelines/visual-design/typography/
  //
  // Specifically:
  // Non-accessibility sizes for "body" text are:
  const CGFloat xs = 14;
  const CGFloat s = 15;
  const CGFloat m = 16;
  const CGFloat l = 17;
  const CGFloat xl = 19;
  const CGFloat xxl = 21;
  const CGFloat xxxl = 23;

  // Accessibility sizes for "body" text are:
  const CGFloat ax1 = 28;
  const CGFloat ax2 = 33;
  const CGFloat ax3 = 40;
  const CGFloat ax4 = 47;
  const CGFloat ax5 = 53;

  // We compute the scale as relative difference from size L (large, the default size), where
  // L is assumed to have scale 1.0.
  if ([category isEqualToString:UIContentSizeCategoryExtraSmall])
    return xs / l;
  else if ([category isEqualToString:UIContentSizeCategorySmall])
    return s / l;
  else if ([category isEqualToString:UIContentSizeCategoryMedium])
    return m / l;
  else if ([category isEqualToString:UIContentSizeCategoryLarge])
    return 1.0;
  else if ([category isEqualToString:UIContentSizeCategoryExtraLarge])
    return xl / l;
  else if ([category isEqualToString:UIContentSizeCategoryExtraExtraLarge])
    return xxl / l;
  else if ([category isEqualToString:UIContentSizeCategoryExtraExtraExtraLarge])
    return xxxl / l;
  else if ([category isEqualToString:UIContentSizeCategoryAccessibilityMedium])
    return ax1 / l;
  else if ([category isEqualToString:UIContentSizeCategoryAccessibilityLarge])
    return ax2 / l;
  else if ([category isEqualToString:UIContentSizeCategoryAccessibilityExtraLarge])
    return ax3 / l;
  else if ([category isEqualToString:UIContentSizeCategoryAccessibilityExtraExtraLarge])
    return ax4 / l;
  else if ([category isEqualToString:UIContentSizeCategoryAccessibilityExtraExtraExtraLarge])
    return ax5 / l;
  else
    return 1.0;
}

- (BOOL)isAlwaysUse24HourFormat {
  // iOS does not report its "24-Hour Time" user setting in the API. Instead, it applies
  // it automatically to NSDateFormatter when used with [NSLocale currentLocale]. It is
  // essential that [NSLocale currentLocale] is used. Any custom locale, even the one
  // that's the same as [NSLocale currentLocale] will ignore the 24-hour option (there
  // must be some internal field that's not exposed to developers).
  //
  // Therefore this option behaves differently across Android and iOS. On Android this
  // setting is exposed standalone, and can therefore be applied to all locales, whether
  // the "current system locale" or a custom one. On iOS it only applies to the current
  // system locale. Widget implementors must take this into account in order to provide
  // platform-idiomatic behavior in their widgets.
  NSString* dateFormat = [NSDateFormatter dateFormatFromTemplate:@"j"
                                                         options:0
                                                          locale:[NSLocale currentLocale]];
  return [dateFormat rangeOfString:@"a"].location == NSNotFound;
}

// The brightness mode of the platform, e.g., light or dark, expressed as a string that
// is understood by the Flutter framework. See the settings system channel for more
// information.
- (NSString*)brightnessMode {
  if (@available(iOS 13, *)) {
    UIUserInterfaceStyle style = self.traitCollection.userInterfaceStyle;

    if (style == UIUserInterfaceStyleDark) {
      return @"dark";
    } else {
      return @"light";
    }
  } else {
    return @"light";
  }
}

// The contrast mode of the platform, e.g., normal or high, expressed as a string that is
// understood by the Flutter framework. See the settings system channel for more
// information.
- (NSString*)contrastMode {
  if (@available(iOS 13, *)) {
    UIAccessibilityContrast contrast = self.traitCollection.accessibilityContrast;

    if (contrast == UIAccessibilityContrastHigh) {
      return @"high";
    } else {
      return @"normal";
    }
  } else {
    return @"normal";
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

    NSNumber* update = info[@(flutter::kOverlayStyleUpdateNotificationKey)];

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

#pragma mark - Platform views

- (flutter::FlutterPlatformViewsController*)platformViewsController {
  return [_engine.get() platformViewsController];
}

- (NSObject<FlutterBinaryMessenger>*)binaryMessenger {
  return _engine.get().binaryMessenger;
}

#pragma mark - FlutterBinaryMessenger

- (void)sendOnChannel:(NSString*)channel message:(NSData*)message {
  [_engine.get().binaryMessenger sendOnChannel:channel message:message];
}

- (void)sendOnChannel:(NSString*)channel
              message:(NSData*)message
          binaryReply:(FlutterBinaryReply)callback {
  NSAssert(channel, @"The channel must not be null");
  [_engine.get().binaryMessenger sendOnChannel:channel message:message binaryReply:callback];
}

- (FlutterBinaryMessengerConnection)setMessageHandlerOnChannel:(NSString*)channel
                                          binaryMessageHandler:
                                              (FlutterBinaryMessageHandler)handler {
  NSAssert(channel, @"The channel must not be null");
  return [_engine.get().binaryMessenger setMessageHandlerOnChannel:channel
                                              binaryMessageHandler:handler];
}

- (void)cleanupConnection:(FlutterBinaryMessengerConnection)connection {
  [_engine.get().binaryMessenger cleanupConnection:connection];
}

#pragma mark - FlutterTextureRegistry

- (int64_t)registerTexture:(NSObject<FlutterTexture>*)texture {
  return [_engine.get() registerTexture:texture];
}

- (void)unregisterTexture:(int64_t)textureId {
  [_engine.get() unregisterTexture:textureId];
}

- (void)textureFrameAvailable:(int64_t)textureId {
  [_engine.get() textureFrameAvailable:textureId];
}

- (NSString*)lookupKeyForAsset:(NSString*)asset {
  return [FlutterDartProject lookupKeyForAsset:asset];
}

- (NSString*)lookupKeyForAsset:(NSString*)asset fromPackage:(NSString*)package {
  return [FlutterDartProject lookupKeyForAsset:asset fromPackage:package];
}

- (id<FlutterPluginRegistry>)pluginRegistry {
  return _engine;
}

#pragma mark - FlutterPluginRegistry

- (NSObject<FlutterPluginRegistrar>*)registrarForPlugin:(NSString*)pluginKey {
  return [_engine.get() registrarForPlugin:pluginKey];
}

- (BOOL)hasPlugin:(NSString*)pluginKey {
  return [_engine.get() hasPlugin:pluginKey];
}

- (NSObject*)valuePublishedByPlugin:(NSString*)pluginKey {
  return [_engine.get() valuePublishedByPlugin:pluginKey];
}

- (void)presentViewController:(UIViewController*)viewControllerToPresent
                     animated:(BOOL)flag
                   completion:(void (^)(void))completion {
  self.isPresentingViewControllerAnimating = YES;
  [super presentViewController:viewControllerToPresent
                      animated:flag
                    completion:^{
                      self.isPresentingViewControllerAnimating = NO;
                      if (completion) {
                        completion();
                      }
                    }];
}

- (BOOL)isPresentingViewController {
  return self.presentedViewController != nil || self.isPresentingViewControllerAnimating;
}

@end
