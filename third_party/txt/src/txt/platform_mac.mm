// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <TargetConditionals.h>
#include "flutter/fml/logging.h"
#include "flutter/fml/platform/darwin/platform_version.h"
#include "txt/platform.h"

#if TARGET_OS_EMBEDDED || TARGET_OS_SIMULATOR
#include <CoreText/CoreText.h>
#include <UIKit/UIKit.h>
#include "third_party/skia/include/core/SkData.h"
#include "third_party/skia/include/core/SkFontMgr.h"
#include "third_party/skia/include/core/SkStream.h"
#include "third_party/skia/include/ports/SkTypeface_mac.h"
#define FONT_CLASS UIFont
#else  // TARGET_OS_EMBEDDED
#include <AppKit/AppKit.h>
#define FONT_CLASS NSFont
#endif  // TARGET_OS_EMBEDDED

namespace txt {

void DisplayFont(CTFontRef font) {
  CFShow(CTFontCopyFontDescriptor(font));
  CFShow(CTFontCopyTraits(font));
  CFShow(CTFontCopyAttribute(font, kCTFontURLAttribute));
  CFShow(CTFontCopyAttribute(font, kCTFontStyleNameAttribute));
  CFShow(CTFontCopyAttribute(font, kCTFontFeaturesAttribute));
  CFShow(CTFontCopyAttribute(font, kCTFontFormatAttribute));
  CFShow(CTFontCopyPostScriptName(font));
  CFShow(CTFontCopyFamilyName(font));
  CFShow(CTFontCopyFullName(font));
  CFShow(CTFontCopyDisplayName(font));
  FML_LOG(ERROR) << "Leading is " << CTFontGetLeading(font);
  CFShow(CTFontCopyVariation(font));
}

std::vector<std::string> GetDefaultFontFamilies() {
  if (fml::IsPlatformVersionAtLeast(9)) {
#if TARGET_OS_EMBEDDED || TARGET_OS_SIMULATOR
    FML_LOG(ERROR) << "System font size 14 family name is " <<
        [FONT_CLASS systemFontOfSize:14].familyName.UTF8String << " font name "
                   << [FONT_CLASS systemFontOfSize:14].fontName.UTF8String;
    FML_LOG(ERROR) << "System preferred body family name is "
                   << [FONT_CLASS preferredFontForTextStyle:UIFontTextStyleBody]
                          .familyName.UTF8String
                   << " font name "
                   << [FONT_CLASS preferredFontForTextStyle:UIFontTextStyleBody]
                          .fontName.UTF8String;
    // DisplayFont(CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 12, nil));
    return {[FONT_CLASS preferredFontForTextStyle:UIFontTextStyleBody]
                .familyName.UTF8String};
#else
    return {[FONT_CLASS systemFontOfSize:14].familyName.UTF8String};
#endif
  } else {
    return {"Helvetica"};
  }
}

void CheckSkTypeface(sk_sp<SkTypeface> typeface) {
#if TARGET_OS_EMBEDDED || TARGET_OS_SIMULATOR
  CTFontRef ctfont = SkTypeface_GetCTFontRef(typeface.get());
  CFShow(ctfont);
  // DisplayFont(ctfont);
#endif
}

sk_sp<SkTypeface> MakeApplePreferredSkTypeface() {
#if TARGET_OS_EMBEDDED || TARGET_OS_SIMULATOR
  [FONT_CLASS preferredFontForTextStyle:UIFontTextStyleBody];
  return SkMakeTypefaceFromCTFont(CTFontCreateWithName(
      (CFStringRef) @".SFUI-Regular", 30,
      nil));  //[FONT_CLASS preferredFontForTextStyle:UIFontTextStyleBody]);
// return
// SkMakeTypefaceFromCTFont(CTFontCreateUIFontForLanguage(kCTFontUIFontSystem,
// 12, nil));//[FONT_CLASS preferredFontForTextStyle:UIFontTextStyleBody]);
#else
  return NULL;
#endif
}

#if TARGET_OS_EMBEDDED || TARGET_OS_SIMULATOR
// Just an implementation detail for iOS
namespace {

// An SkFontStyleSet like SkFontStyleSet_Mac but that has an exactly single match since it's
// initialized with a specific CTFont rather than fuzzier descriptors.
class SkFontStyleSet_MacSystem : public SkFontStyleSet {

private:
CTFontRef ctFont;

 public:
  SkFontStyleSet_MacSystem(CTFontRef font)
      : ctFont(font) {
    FML_DCHECK(font != nullptr);
  }

  int count() override { return 1; }

  void getStyle(int index, SkFontStyle* style, SkString* name) override {
    FML_NOTIMPLEMENTED();
  }

  SkTypeface* createTypeface(int index) override {
    return SkMakeTypefaceFromCTFont(ctFont).get();
  }

  SkTypeface* matchStyle(const SkFontStyle& pattern) override {
    FML_NOTIMPLEMENTED();
    return nullptr;
  }
};

// A SkFontMgr that's like the default SkFontMgr provided by Skia for iOS
// (SkFontMgr_Mac) except when we heuristically determine that we're trying to
// match a font family that's a system font (via a family name prefixed with
// "."), we use the appropriate, semantic API instead of the default behavior of
// looking up via the font name string through kCTFontFamilyNameAttribute. This
// produces the correct behavior on iOS since name lookups are deprecated in iOS
// 13 and broken in iOS 14.
class SkFontMgr_MacSystem : public SkFontMgr {
 private:
  sk_sp<SkFontMgr> delegate_mac_font_manager_;

 public:
  SkFontMgr_MacSystem(sk_sp<SkFontMgr> delegate_font_manager)
      : delegate_mac_font_manager_(delegate_font_manager) {
    FML_DCHECK(delegate_font_manager != nullptr);
  }

  ~SkFontMgr_MacSystem() = default;

 protected:
  // This is the only one we care about overriding.
  SkFontStyleSet* onMatchFamily(const char familyName[]) const override {
    if (!familyName) {
      return nullptr;
    }
    // This is asking for a system font. Since iOS 13, asking for a system font
    // by its string name will produce an undefined result. Until we expose the
    // proper semantics up to Flutter's APIs, we can only try to guess at what
    // the string->CoreText API mapping should be.
    if (familyName[0] == '.') {
      // See https://developer.apple.com/videos/play/wwdc2020/10175. There are
      // really 2 fonts families packed in SFPro.ttf. Below size 20, it's the
      // SFProText family. At and above 20, it's the SFProDisplay family. They
      // have different optical sizing, traking, etc, properties.
      std::string searchName(familyName);
      if (searchName.find("SF") != std::string::npos &&
          searchName.find("Display") != std::string::npos) {
        return new SkFontStyleSet_MacSystem(CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 17, nil));
      } else {
        // Otherwise, map various string forms of SF Pro Text or anything else
        // to the default font.
        return new SkFontStyleSet_MacSystem(CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 21, nil));
      }
    } else {
      return delegate_mac_font_manager_->matchFamily(familyName);
    }
  }

  // Just delegate the rest to the Skia SkFontMgr_Mac.
  int onCountFamilies() const override {
    return delegate_mac_font_manager_->countFamilies();
  }
  void onGetFamilyName(int index, SkString* familyName) const override {
    return delegate_mac_font_manager_->getFamilyName(index, familyName);
  }
  SkFontStyleSet* onCreateStyleSet(int index) const override {
    return delegate_mac_font_manager_->createStyleSet(index);
  }

  SkTypeface* onMatchFamilyStyle(const char familyName[],
                                 const SkFontStyle& style) const override {
    return delegate_mac_font_manager_->matchFamilyStyle(familyName, style);
  }
  SkTypeface* onMatchFamilyStyleCharacter(const char familyName[],
                                          const SkFontStyle& style,
                                          const char* bcp47[],
                                          int bcp47Count,
                                          SkUnichar character) const override {
    return delegate_mac_font_manager_->matchFamilyStyleCharacter(
        familyName, style, bcp47, bcp47Count, character);
  }
  SkTypeface* onMatchFaceStyle(const SkTypeface*,
                               const SkFontStyle&) const override {
    // SkFontMgr has no API for this for some reason to compose this. But
    // SkFontMgr_Mac doesn't implement this anyway.
    return nullptr;
  }

  sk_sp<SkTypeface> onMakeFromData(sk_sp<SkData> data,
                                   int ttcIndex) const override {
    return delegate_mac_font_manager_->makeFromData(std::move(data), ttcIndex);
  }
  sk_sp<SkTypeface> onMakeFromStreamIndex(
      std::unique_ptr<SkStreamAsset> streamAsset,
      int ttcIndex) const override {
    return delegate_mac_font_manager_->makeFromStream(std::move(streamAsset),
                                                      ttcIndex);
  }
  sk_sp<SkTypeface> onMakeFromStreamArgs(
      std::unique_ptr<SkStreamAsset> streamAsset,
      const SkFontArguments& arguments) const override {
    return delegate_mac_font_manager_->makeFromStream(std::move(streamAsset),
                                                      arguments);
  }
  sk_sp<SkTypeface> onMakeFromFontData(
      std::unique_ptr<SkFontData> fontData) const override {
    // We can't support this since SkFontData doesn't have a public header and
    // we can't move this unique_ptr from a forward type declaration. Doesn't
    // really matter since this isn't used by Flutter.
    return nullptr;
  }
  sk_sp<SkTypeface> onMakeFromFile(const char path[],
                                   int ttcIndex) const override {
    return delegate_mac_font_manager_->makeFromFile(path, ttcIndex);
  }

  sk_sp<SkTypeface> onLegacyMakeTypeface(const char familyName[],
                                         SkFontStyle style) const override {
    return delegate_mac_font_manager_->legacyMakeTypeface(familyName, style);
  }
};
}
#endif

sk_sp<SkFontMgr> GetDefaultFontManager() {
#if TARGET_OS_EMBEDDED || TARGET_OS_SIMULATOR
  return sk_make_sp<SkFontMgr_MacSystem>(SkFontMgr::RefDefault());
#else
  return SkFontMgr::RefDefault();
#endif
  // return RefDefaultFontManager();
}

}  // namespace txt
