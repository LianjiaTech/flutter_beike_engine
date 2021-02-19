// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#define FML_USED_ON_EMBEDDER

#include "flutter/shell/platform/darwin/ios/framework/Source/FlutterDartProject_Internal.h"

#include "flutter/common/task_runners.h"
#include "flutter/fml/mapping.h"
#include "flutter/fml/message_loop.h"
#include "flutter/fml/platform/darwin/scoped_nsobject.h"
#include "flutter/runtime/dart_vm.h"
#include "flutter/shell/common/shell.h"
#include "flutter/shell/common/switches.h"
#include "flutter/shell/platform/darwin/common/command_line.h"
#include "flutter/shell/platform/darwin/ios/framework/Headers/FlutterViewController.h"

extern "C" {
#if FLUTTER_RUNTIME_MODE == FLUTTER_RUNTIME_MODE_DEBUG
// Used for debugging dart:* sources.
extern const uint8_t kPlatformStrongDill[];
extern const intptr_t kPlatformStrongDillSize;
#endif
}

//static const char* kApplicationKernelSnapshotFileName = "kernel_blob.bin";

static flutter::Settings DefaultSettingsForProcess(NSBundle* bundle = nil) {
  auto command_line = flutter::CommandLineFromNSProcessInfo();

  // Precedence:
  // 1. Settings from the specified NSBundle.
  // 2. Settings passed explicitly via command-line arguments.
  // 3. Settings from the NSBundle with the default bundle ID.
  // 4. Settings from the main NSBundle and default values.

  NSBundle* mainBundle = [NSBundle mainBundle];
  NSBundle* engineBundle = [NSBundle bundleForClass:[FlutterViewController class]];

  bool hasExplicitBundle = bundle != nil;
  if (bundle == nil) {
    bundle = [NSBundle bundleWithIdentifier:[FlutterDartProject defaultBundleIdentifier]];
  }
  if (bundle == nil) {
    bundle = mainBundle;
  }

  auto settings = flutter::SettingsFromCommandLine(command_line);

  settings.task_observer_add = [](intptr_t key, fml::closure callback) {
    fml::MessageLoop::GetCurrent().AddTaskObserver(key, std::move(callback));
  };

  settings.task_observer_remove = [](intptr_t key) {
    fml::MessageLoop::GetCurrent().RemoveTaskObserver(key);
  };

  // The command line arguments may not always be complete. If they aren't, attempt to fill in
  // defaults.

  // Flutter ships the ICU data file in the bundle of the engine. Look for it there.
//  if (settings.icu_data_path.size() == 0) {
//    NSString* icuDataPath = [engineBundle pathForResource:@"icudtl" ofType:@"dat"];
//    if (icuDataPath.length > 0) {
//      settings.icu_data_path = icuDataPath.UTF8String;
//    }
//  }

  if (flutter::DartVM::IsRunningPrecompiledCode()) {
    if (hasExplicitBundle) {
      NSString* executablePath = bundle.executablePath;
      if ([[NSFileManager defaultManager] fileExistsAtPath:executablePath]) {
        settings.application_library_path.push_back(executablePath.UTF8String);
      }
    }

    // No application bundle specified.  Try a known location from the main bundle's Info.plist.
    if (settings.application_library_path.size() == 0) {
      NSString* libraryName = [mainBundle objectForInfoDictionaryKey:@"FLTLibraryPath"];
      NSString* libraryPath = [mainBundle pathForResource:libraryName ofType:@""];
      if (libraryPath.length > 0) {
        NSString* executablePath = [NSBundle bundleWithPath:libraryPath].executablePath;
        if (executablePath.length > 0) {
          settings.application_library_path.push_back(executablePath.UTF8String);
        }
      }
    }

    // In case the application bundle is still not specified, look for the App.framework in the
    // Frameworks directory.
    if (settings.application_library_path.size() == 0) {
      NSString* applicationFrameworkPath = [mainBundle pathForResource:@"Frameworks/App.framework"
                                                                ofType:@""];
      if (applicationFrameworkPath.length > 0) {
        NSString* executablePath =
            [NSBundle bundleWithPath:applicationFrameworkPath].executablePath;
        if (executablePath.length > 0) {
          settings.application_library_path.push_back(executablePath.UTF8String);
        }
      }
    }
  }

  // Checks to see if the flutter assets directory is already present.
//  if (settings.assets_path.size() == 0) {
//    NSString* assetsName = [FlutterDartProject flutterAssetsName:bundle];
//    NSString* assetsPath = [bundle pathForResource:assetsName ofType:@""];
//
//    if (assetsPath.length == 0) {
//      assetsPath = [mainBundle pathForResource:assetsName ofType:@""];
//    }
//
//    if (assetsPath.length == 0) {
//      NSLog(@"Failed to find assets path for \"%@\"", assetsName);
//    } else {
//      settings.assets_path = assetsPath.UTF8String;
//
//      // Check if there is an application kernel snapshot in the assets directory we could
//      // potentially use.  Looking for the snapshot makes sense only if we have a VM that can use
//      // it.
//      if (!flutter::DartVM::IsRunningPrecompiledCode()) {
//        NSURL* applicationKernelSnapshotURL =
//            [NSURL URLWithString:@(kApplicationKernelSnapshotFileName)
//                   relativeToURL:[NSURL fileURLWithPath:assetsPath]];
//        if ([[NSFileManager defaultManager] fileExistsAtPath:applicationKernelSnapshotURL.path]) {
//          settings.application_kernel_asset = applicationKernelSnapshotURL.path.UTF8String;
//        } else {
//          NSLog(@"Failed to find snapshot: %@", applicationKernelSnapshotURL.path);
//        }
//      }
//    }
//  }
    NSLog(@"开始设置路径");
    //设置沙盒路径
    NSArray * documentPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString * documentDirectory = [documentPaths objectAtIndex:0];
    //设置vm_snapshot_data路径
    NSString *vm_snapshot_data_path = [NSString stringWithFormat:@"%@/flutter_resource/Resource/vm_snapshot_data",documentDirectory];
    if ([[NSFileManager defaultManager] fileExistsAtPath:vm_snapshot_data_path]) {
        settings.vm_snapshot_data_path = vm_snapshot_data_path.UTF8String;
    }
    
    //设置isolate_snapshot_data路径
    NSString *isolate_snapshot_data_path = [NSString stringWithFormat:@"%@/flutter_resource/Resource/isolate_snapshot_data",documentDirectory];
    if ([[NSFileManager defaultManager] fileExistsAtPath:isolate_snapshot_data_path]) {
        settings.isolate_snapshot_data_path = isolate_snapshot_data_path.UTF8String;
    }
    
    //设置资源路径
    NSString *assets_path = [NSString stringWithFormat:@"%@/flutter_resource/Resource/flutter_assets",documentDirectory];
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:assets_path]) {
        settings.assets_path = assets_path.UTF8String;
    }
    else {
        NSString* assetsName = [FlutterDartProject flutterAssetsName:bundle];
        NSString* assetsPath = [bundle pathForResource:assetsName ofType:@""];
        
        if (assetsPath.length == 0) {
            assetsPath = [mainBundle pathForResource:assetsName ofType:@""];
        }
        
        if (assetsPath.length == 0) {
            NSLog(@"Failed to find assets path for \"%@\"", assetsName);
        } else {
            settings.assets_path = assetsPath.UTF8String;
        }
    }
    //    设置icu_data_path
    NSString *icu_data_path = [NSString stringWithFormat:@"%@/flutter_resource/Resource/icudtl.dat",documentDirectory];
    if ([[NSFileManager defaultManager] fileExistsAtPath:icu_data_path]) {
        settings.icu_data_path = icu_data_path.UTF8String;
    }
    else {
        NSString* icuDataPath = [engineBundle pathForResource:@"icudtl" ofType:@"dat"];
        if (icuDataPath.length > 0) {
            settings.icu_data_path = icuDataPath.UTF8String;
        }
    }
    
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:vm_snapshot_data_path] && [[NSFileManager defaultManager] fileExistsAtPath:isolate_snapshot_data_path] ) {
        NSLog(@"data存在");
    }
    else {
        NSLog(@"data不存在");
    }
    
    NSLog(@"路径设置完毕");

  // Domain network configuration
  NSDictionary* appTransportSecurity =
      [mainBundle objectForInfoDictionaryKey:@"NSAppTransportSecurity"];
  settings.may_insecurely_connect_to_all_domains =
      [FlutterDartProject allowsArbitraryLoads:appTransportSecurity];
  settings.domain_network_policy =
      [FlutterDartProject domainNetworkPolicy:appTransportSecurity].UTF8String;

#if FLUTTER_RUNTIME_MODE == FLUTTER_RUNTIME_MODE_DEBUG
  // There are no ownership concerns here as all mappings are owned by the
  // embedder and not the engine.
  auto make_mapping_callback = [](const uint8_t* mapping, size_t size) {
    return [mapping, size]() { return std::make_unique<fml::NonOwnedMapping>(mapping, size); };
  };

  settings.dart_library_sources_kernel =
      make_mapping_callback(kPlatformStrongDill, kPlatformStrongDillSize);
#endif  // FLUTTER_RUNTIME_MODE == FLUTTER_RUNTIME_MODE_DEBUG

  return settings;
}

@implementation FlutterDartProject {
  flutter::Settings _settings;
}

#pragma mark - Override base class designated initializers

- (instancetype)init {
  return [self initWithPrecompiledDartBundle:nil];
}

#pragma mark - Designated initializers

- (instancetype)initWithPrecompiledDartBundle:(nullable NSBundle*)bundle {
  self = [super init];

  if (self) {
    _settings = DefaultSettingsForProcess(bundle);
  }

  return self;
}

#pragma mark - PlatformData accessors

- (const flutter::PlatformData)defaultPlatformData {
  flutter::PlatformData PlatformData;
  PlatformData.lifecycle_state = std::string("AppLifecycleState.detached");
  return PlatformData;
}

#pragma mark - Settings accessors

- (const flutter::Settings&)settings {
  return _settings;
}

- (flutter::RunConfiguration)runConfiguration {
  return [self runConfigurationForEntrypoint:nil];
}

- (flutter::RunConfiguration)runConfigurationForEntrypoint:(nullable NSString*)entrypointOrNil {
  return [self runConfigurationForEntrypoint:entrypointOrNil libraryOrNil:nil];
}

- (flutter::RunConfiguration)runConfigurationForEntrypoint:(nullable NSString*)entrypointOrNil
                                              libraryOrNil:(nullable NSString*)dartLibraryOrNil {
  auto config = flutter::RunConfiguration::InferFromSettings(_settings);
  if (dartLibraryOrNil && entrypointOrNil) {
    config.SetEntrypointAndLibrary(std::string([entrypointOrNil UTF8String]),
                                   std::string([dartLibraryOrNil UTF8String]));

  } else if (entrypointOrNil) {
    config.SetEntrypoint(std::string([entrypointOrNil UTF8String]));
  }
  return config;
}

#pragma mark - Assets-related utilities

+ (NSString*)flutterAssetsName:(NSBundle*)bundle {
  if (bundle == nil) {
    bundle = [NSBundle bundleWithIdentifier:[FlutterDartProject defaultBundleIdentifier]];
  }
  if (bundle == nil) {
    bundle = [NSBundle mainBundle];
  }
  NSString* flutterAssetsName = [bundle objectForInfoDictionaryKey:@"FLTAssetsPath"];
  if (flutterAssetsName == nil) {
    flutterAssetsName = @"Frameworks/App.framework/flutter_assets";
  }
  return flutterAssetsName;
}

+ (NSString*)domainNetworkPolicy:(NSDictionary*)appTransportSecurity {
  // https://developer.apple.com/documentation/bundleresources/information_property_list/nsapptransportsecurity/nsexceptiondomains
  NSDictionary* exceptionDomains = [appTransportSecurity objectForKey:@"NSExceptionDomains"];
  if (exceptionDomains == nil) {
    return @"";
  }
  NSMutableArray* networkConfigArray = [[NSMutableArray alloc] init];
  for (NSString* domain in exceptionDomains) {
    NSDictionary* domainConfiguration = [exceptionDomains objectForKey:domain];
    // Default value is false.
    bool includesSubDomains =
        [[domainConfiguration objectForKey:@"NSIncludesSubdomains"] boolValue];
    bool allowsCleartextCommunication =
        [[domainConfiguration objectForKey:@"NSExceptionAllowsInsecureHTTPLoads"] boolValue];
    [networkConfigArray addObject:@[
      domain, includesSubDomains ? @YES : @NO, allowsCleartextCommunication ? @YES : @NO
    ]];
  }
  NSData* jsonData = [NSJSONSerialization dataWithJSONObject:networkConfigArray
                                                     options:0
                                                       error:NULL];
  return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

+ (bool)allowsArbitraryLoads:(NSDictionary*)appTransportSecurity {
  return [[appTransportSecurity objectForKey:@"NSAllowsArbitraryLoads"] boolValue];
}

+ (NSString*)lookupKeyForAsset:(NSString*)asset {
  return [self lookupKeyForAsset:asset fromBundle:nil];
}

+ (NSString*)lookupKeyForAsset:(NSString*)asset fromBundle:(nullable NSBundle*)bundle {
  NSString* flutterAssetsName = [FlutterDartProject flutterAssetsName:bundle];
  return [NSString stringWithFormat:@"%@/%@", flutterAssetsName, asset];
}

+ (NSString*)lookupKeyForAsset:(NSString*)asset fromPackage:(NSString*)package {
  return [self lookupKeyForAsset:asset fromPackage:package fromBundle:nil];
}

+ (NSString*)lookupKeyForAsset:(NSString*)asset
                   fromPackage:(NSString*)package
                    fromBundle:(nullable NSBundle*)bundle {
  return [self lookupKeyForAsset:[NSString stringWithFormat:@"packages/%@/%@", package, asset]
                      fromBundle:bundle];
}

+ (NSString*)defaultBundleIdentifier {
  return @"io.flutter.flutter.app";
}

#pragma mark - Settings utilities

- (void)setPersistentIsolateData:(NSData*)data {
  if (data == nil) {
    return;
  }

  NSData* persistent_isolate_data = [data copy];
  fml::NonOwnedMapping::ReleaseProc data_release_proc = [persistent_isolate_data](auto, auto) {
    [persistent_isolate_data release];
  };
  _settings.persistent_isolate_data = std::make_shared<fml::NonOwnedMapping>(
      static_cast<const uint8_t*>(persistent_isolate_data.bytes),  // bytes
      persistent_isolate_data.length,                              // byte length
      data_release_proc                                            // release proc
  );
}

#pragma mark - PlatformData utilities

@end
