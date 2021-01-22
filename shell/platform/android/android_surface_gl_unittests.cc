// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <memory>
#include "flutter/shell/platform/android/android_surface_gl.h"

#include "flutter/shell/platform/android/android_context_gl.h"
#include "flutter/shell/platform/android/jni/jni_mock.h"
#include "flutter/shell/platform/android/surface/android_surface.h"
#include "flutter/testing/testing.h"
#include "gmock/gmock.h"
#include "gtest/gtest.h"

#include "third_party/skia/include/gpu/GrDirectContext.h"

namespace flutter {
namespace testing {

using ::testing::ByMove;
using ::testing::Return;

class MockAndroidContextGl : public AndroidContextGL {
  public:
  MockAndroidContextGl(): AndroidContextGL(AndroidRenderingAPI::kOpenGLES, nullptr) {}

  MOCK_METHOD(std::unique_ptr<AndroidEGLSurface>, CreateOffscreenSurface, (), (const));
};

class MockAndroidEGLSurface : public AndroidEGLSurface {
  public:
  MockAndroidEGLSurface(): AndroidEGLSurface(nullptr, nullptr, nullptr) {}

  MOCK_METHOD(bool, IsValid, (), (const));
};

TEST(AndroidSurfaceGL, CreateGPUSurfaceWithGrDirectContext) {
  auto android_context = std::make_shared<MockAndroidContextGl>();
  auto jni_mock = std::make_shared<JNIMock>();

  auto android_egl_surface = new MockAndroidEGLSurface();
  auto android_egl_surface_ptr = std::unique_ptr<MockAndroidEGLSurface>(android_egl_surface);

  auto gr_context = GrDirectContext::MakeMock(nullptr);

  EXPECT_CALL(*android_egl_surface, IsValid()).WillOnce(Return(true));
  EXPECT_CALL(*android_context, CreateOffscreenSurface()).WillOnce(Return(ByMove(std::move(android_egl_surface_ptr))));

  auto surface_under_test = AndroidSurfaceGL(android_context, jni_mock);

  surface_under_test.CreateGPUSurface(gr_context.get());
}

}  // namespace testing
}  // namespace flutter
