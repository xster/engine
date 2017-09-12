// Copyright 2015 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/shell/common/platform_view.h"

#include <utility>

#include "flutter/common/threads.h"
#include "flutter/lib/ui/painting/resource_context.h"
#include "flutter/shell/common/rasterizer.h"
#include "flutter/shell/common/vsync_waiter_fallback.h"
#include "lib/ftl/functional/make_copyable.h"
#include "third_party/skia/include/gpu/GrContextOptions.h"
#include "third_party/skia/include/gpu/gl/GrGLInterface.h"

namespace shell {

PlatformView::PlatformView(std::unique_ptr<Rasterizer> rasterizer)
    : rasterizer_(std::move(rasterizer)), size_(SkISize::Make(0, 0)) {}

PlatformView::~PlatformView() {
  blink::Threads::UI()->PostTask([] { Shell::Shared().PurgePlatformViews(); });

  Rasterizer* rasterizer = rasterizer_.release();
  blink::Threads::Gpu()->PostTask([rasterizer]() { delete rasterizer; });

  Engine* engine = engine_.release();
  blink::Threads::UI()->PostTask([engine]() { delete engine; });
}

void PlatformView::CreateEngine() {
  engine_.reset(new Engine(this));
}

// Add this to the shell's list of PlatformVIews.
// Subclasses should call this after the object is fully constructed.
void PlatformView::PostAddToShellTask() {
  blink::Threads::UI()->PostTask(
      [self = shared_from_this()] { Shell::Shared().AddPlatformView(self); });
}

void PlatformView::DispatchPlatformMessage(
    ftl::RefPtr<blink::PlatformMessage> message) {
  blink::Threads::UI()->PostTask(
      [ engine = engine_->GetWeakPtr(), message = std::move(message) ] {
        if (engine) {
          engine->DispatchPlatformMessage(message);
        }
      });
}

void PlatformView::DispatchSemanticsAction(int32_t id,
                                           blink::SemanticsAction action) {
  blink::Threads::UI()->PostTask(
      [ engine = engine_->GetWeakPtr(), id, action ] {
        if (engine) {
          engine->DispatchSemanticsAction(
              id, static_cast<blink::SemanticsAction>(action));
        }
      });
}

void PlatformView::SetSemanticsEnabled(bool enabled) {
  blink::Threads::UI()->PostTask([ engine = engine_->GetWeakPtr(), enabled ] {
    if (engine)
      engine->SetSemanticsEnabled(enabled);
  });
}

void PlatformView::NotifyCreated(std::unique_ptr<Surface> surface) {
  NotifyCreated(std::move(surface), []() {});
}

void PlatformView::NotifyCreated(std::unique_ptr<Surface> surface,
                                 ftl::Closure caller_continuation) {
  ftl::AutoResetWaitableEvent latch;

  auto ui_continuation = ftl::MakeCopyable([
    this,                          //
    surface = std::move(surface),  //
    caller_continuation,           //
    &latch
  ]() mutable {
    auto gpu_continuation = ftl::MakeCopyable([
      this,                          //
      surface = std::move(surface),  //
      caller_continuation,           //
      &latch
    ]() mutable {
      FTL_DLOG(ERROR) << "========================= rasterizer_->Setup";
      // Runs on the GPU Thread. So does the Caller Continuation.
      rasterizer_->Setup(std::move(surface), caller_continuation, &latch);
    });
    FTL_DLOG(ERROR) << "========================= engine_->OnOutputSurfaceCreated";
    // Runs on the UI Thread.
    engine_->OnOutputSurfaceCreated(std::move(gpu_continuation));
  });

  // Runs on the Platform Thread.
  blink::Threads::UI()->PostTask(std::move(ui_continuation));

  latch.Wait();
}

void PlatformView::NotifyDestroyed() {
  FTL_DLOG(ERROR) << "========================= PlatformView::NotifyDestroyed()";
  ftl::AutoResetWaitableEvent latch;

  auto engine_continuation = [this, &latch]() {
    rasterizer_->Teardown(&latch);
  };

  blink::Threads::UI()->PostTask([this, engine_continuation]() {
    engine_->OnOutputSurfaceDestroyed(engine_continuation);
  });

  latch.Wait();
}

std::weak_ptr<PlatformView> PlatformView::GetWeakPtr() {
  return shared_from_this();
}

VsyncWaiter* PlatformView::GetVsyncWaiter() {
  if (!vsync_waiter_)
    vsync_waiter_ = std::make_unique<VsyncWaiterFallback>();
  return vsync_waiter_.get();
}

void PlatformView::UpdateSemantics(std::vector<blink::SemanticsNode> update) {}

void PlatformView::HandlePlatformMessage(
    ftl::RefPtr<blink::PlatformMessage> message) {
  if (auto response = message->response())
    response->CompleteEmpty();
}

void PlatformView::SetupResourceContextOnIOThread() {
  ftl::AutoResetWaitableEvent latch;

  blink::Threads::IO()->PostTask(
      [this, &latch]() { SetupResourceContextOnIOThreadPerform(&latch); });

  latch.Wait();
}

void PlatformView::SetupResourceContextOnIOThreadPerform(
    ftl::AutoResetWaitableEvent* latch) {
  if (blink::ResourceContext::Get() != nullptr) {
    // The resource context was already setup. This could happen if platforms
    // try to setup a context multiple times, or, if there are multiple platform
    // views. In any case, there is nothing else to do. So just signal the
    // latch.
    latch->Signal();
    return;
  }

  bool current = ResourceContextMakeCurrent();

  if (!current) {
    FTL_DLOG(WARNING)
        << "WARNING: Could not setup a context on the resource loader.";
    latch->Signal();
    return;
  }

  GrContextOptions options;
  // There is currently a bug with doing GPU YUV to RGB conversions on the IO
  // thread. The necessary work isn't being flushed or synchronized with the
  // other threads correctly, so the textures end up blank.  For now, suppress
  // that feature, which will cause texture uploads to do CPU YUV conversion.
  options.fDisableGpuYUVConversion = true;
  options.fRequireDecodeDisableForSRGB = false;

  blink::ResourceContext::Set(GrContext::Create(
      GrBackend::kOpenGL_GrBackend,
      reinterpret_cast<GrBackendContext>(GrGLCreateNativeInterface()),
      options));

  // Do not cache textures created by the image decoder.  These textures should
  // be deleted when they are no longer referenced by an SkImage.
  if (blink::ResourceContext::Get())
    blink::ResourceContext::Get()->setResourceCacheLimits(0, 0);

  latch->Signal();
}

}  // namespace shell
