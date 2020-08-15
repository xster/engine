// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <TargetConditionals.h>
#include "flutter/fml/logging.h"
#include "flutter/fml/platform/darwin/platform_version.h"
#include "txt/platform.h"

#if TARGET_OS_EMBEDDED || TARGET_OS_SIMULATOR
#include <UIKit/UIKit.h>
#include <CoreText/CoreText.h>
#include "third_party/skia/include/ports/SkTypeface_mac.h"
#define FONT_CLASS UIFont
#else  // TARGET_OS_EMBEDDED
#include <AppKit/AppKit.h>
#define FONT_CLASS NSFont
#endif  // TARGET_OS_EMBEDDED

namespace txt {

std::vector<std::string> GetDefaultFontFamilies() {
  if (fml::IsPlatformVersionAtLeast(9)) {
    #if TARGET_OS_EMBEDDED || TARGET_OS_SIMULATOR
      FML_LOG(ERROR) << "System font size 14 family name is " << [FONT_CLASS systemFontOfSize:14].familyName.UTF8String << " font name " << [FONT_CLASS systemFontOfSize:14].fontName.UTF8String;
      FML_LOG(ERROR) << "System preferred body family name is " << [FONT_CLASS preferredFontForTextStyle:UIFontTextStyleBody].familyName.UTF8String << " font name " << [FONT_CLASS preferredFontForTextStyle:UIFontTextStyleBody].fontName.UTF8String;
      return {[FONT_CLASS preferredFontForTextStyle:UIFontTextStyleBody].familyName.UTF8String};
    #else
      return {[FONT_CLASS systemFontOfSize:14].familyName.UTF8String};
    #endif
  } else {
    return {"Helvetica"};
  }
}

sk_sp<SkFontMgr> GetDefaultFontManager() {
  return SkFontMgr::RefDefault();
}

void CheckSkTypeface(sk_sp<SkTypeface> typeface) {
  #if TARGET_OS_EMBEDDED || TARGET_OS_SIMULATOR
  CTFontRef ctfont = SkTypeface_GetCTFontRef(typeface.get());
  CFShow(ctfont);
  #endif
}

sk_sp<SkTypeface> MakeApplePreferredSkTypeface() {
  #if TARGET_OS_EMBEDDED || TARGET_OS_SIMULATOR
  [FONT_CLASS preferredFontForTextStyle:UIFontTextStyleBody];
  return SkMakeTypefaceFromCTFont(CTFontCreateWithName(kCTFontUIFontSystem, 30, nil));//[FONT_CLASS preferredFontForTextStyle:UIFontTextStyleBody]);
  return SkMakeTypefaceFromCTFont(CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 12, nil));//[FONT_CLASS preferredFontForTextStyle:UIFontTextStyleBody]);
  #else
  return NULL;
  #endif
}

}  // namespace txt
