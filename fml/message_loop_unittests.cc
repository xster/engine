// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <thread>

#include "flutter/fml/message_loop.h"
#include "gtest/gtest.h"
#include "lib/ftl/synchronization/waitable_event.h"

#define TIME_SENSITIVE(x) TimeSensitiveTest_##x

TEST(MessageLoop, GetCurrent) {
  std::thread thread([]() {
    fml::MessageLoop::EnsureInitializedForCurrentThread();
    ASSERT_TRUE(fml::MessageLoop::GetCurrent().GetTaskRunner());
  });
  thread.join();
}

TEST(MessageLoop, DifferentThreadsHaveDifferentLoops) {
  fml::MessageLoop* loop1 = nullptr;
  ftl::AutoResetWaitableEvent latch1;
  ftl::AutoResetWaitableEvent term1;
  std::thread thread1([&loop1, &latch1, &term1]() {
    fml::MessageLoop::EnsureInitializedForCurrentThread();
    loop1 = &fml::MessageLoop::GetCurrent();
    latch1.Signal();
    term1.Wait();
  });

  fml::MessageLoop* loop2 = nullptr;
  ftl::AutoResetWaitableEvent latch2;
  ftl::AutoResetWaitableEvent term2;
  std::thread thread2([&loop2, &latch2, &term2]() {
    fml::MessageLoop::EnsureInitializedForCurrentThread();
    loop2 = &fml::MessageLoop::GetCurrent();
    latch2.Signal();
    term2.Wait();
  });
  latch1.Wait();
  latch2.Wait();
  ASSERT_FALSE(loop1 == loop2);
  term1.Signal();
  term2.Signal();
  thread1.join();
  thread2.join();
}

TEST(MessageLoop, CanRunAndTerminate) {
  bool started = false;
  bool terminated = false;
  std::thread thread([&started, &terminated]() {
    fml::MessageLoop::EnsureInitializedForCurrentThread();
    auto& loop = fml::MessageLoop::GetCurrent();
    ASSERT_TRUE(loop.GetTaskRunner());
    loop.GetTaskRunner()->PostTask([&terminated]() {
      fml::MessageLoop::GetCurrent().Terminate();
      terminated = true;
    });
    loop.Run();
    started = true;
  });
  thread.join();
  ASSERT_TRUE(started);
  ASSERT_TRUE(terminated);
}

TEST(MessageLoop, NonDelayedTasksAreRunInOrder) {
  const size_t count = 100;
  bool started = false;
  bool terminated = false;
  std::thread thread([&started, &terminated, count]() {
    fml::MessageLoop::EnsureInitializedForCurrentThread();
    auto& loop = fml::MessageLoop::GetCurrent();
    size_t current = 0;
    for (size_t i = 0; i < count; i++) {
      loop.GetTaskRunner()->PostTask([&terminated, i, &current]() {
        ASSERT_EQ(current, i);
        current++;
        if (count == i + 1) {
          fml::MessageLoop::GetCurrent().Terminate();
          terminated = true;
        }
      });
    }
    loop.Run();
    ASSERT_EQ(current, count);
    started = true;
  });
  thread.join();
  ASSERT_TRUE(started);
  ASSERT_TRUE(terminated);
}

TEST(MessageLoop, DelayedTasksAtSameTimeAreRunInOrder) {
  const size_t count = 100;
  bool started = false;
  bool terminated = false;
  std::thread thread([&started, &terminated, count]() {
    fml::MessageLoop::EnsureInitializedForCurrentThread();
    auto& loop = fml::MessageLoop::GetCurrent();
    size_t current = 0;
    const auto now_plus_some =
        ftl::TimePoint::Now() + ftl::TimeDelta::FromMilliseconds(2);
    for (size_t i = 0; i < count; i++) {
      loop.GetTaskRunner()->PostTaskForTime(
          [&terminated, i, &current]() {
            ASSERT_EQ(current, i);
            current++;
            if (count == i + 1) {
              fml::MessageLoop::GetCurrent().Terminate();
              terminated = true;
            }
          },
          now_plus_some);
    }
    loop.Run();
    ASSERT_EQ(current, count);
    started = true;
  });
  thread.join();
  ASSERT_TRUE(started);
  ASSERT_TRUE(terminated);
}

TEST(MessageLoop, CheckRunsTaskOnCurrentThread) {
  ftl::RefPtr<ftl::TaskRunner> runner;
  ftl::AutoResetWaitableEvent latch;
  std::thread thread([&runner, &latch]() {
    fml::MessageLoop::EnsureInitializedForCurrentThread();
    auto& loop = fml::MessageLoop::GetCurrent();
    runner = loop.GetTaskRunner();
    latch.Signal();
    ASSERT_TRUE(loop.GetTaskRunner()->RunsTasksOnCurrentThread());
  });
  latch.Wait();
  ASSERT_TRUE(runner);
  ASSERT_FALSE(runner->RunsTasksOnCurrentThread());
  thread.join();
}

TEST(MessageLoop, TIME_SENSITIVE(SingleDelayedTaskByDelta)) {
  bool checked = false;
  std::thread thread([&checked]() {
    fml::MessageLoop::EnsureInitializedForCurrentThread();
    auto& loop = fml::MessageLoop::GetCurrent();
    auto begin = ftl::TimePoint::Now();
    loop.GetTaskRunner()->PostDelayedTask(
        [begin, &checked]() {
          auto delta = ftl::TimePoint::Now() - begin;
          auto ms = delta.ToMillisecondsF();
          ASSERT_GE(ms, 3);
          ASSERT_LE(ms, 7);
          checked = true;
          fml::MessageLoop::GetCurrent().Terminate();
        },
        ftl::TimeDelta::FromMilliseconds(5));
    loop.Run();
  });
  thread.join();
  ASSERT_TRUE(checked);
}

TEST(MessageLoop, TIME_SENSITIVE(SingleDelayedTaskForTime)) {
  bool checked = false;
  std::thread thread([&checked]() {
    fml::MessageLoop::EnsureInitializedForCurrentThread();
    auto& loop = fml::MessageLoop::GetCurrent();
    auto begin = ftl::TimePoint::Now();
    loop.GetTaskRunner()->PostTaskForTime(
        [begin, &checked]() {
          auto delta = ftl::TimePoint::Now() - begin;
          auto ms = delta.ToMillisecondsF();
          ASSERT_GE(ms, 3);
          ASSERT_LE(ms, 7);
          checked = true;
          fml::MessageLoop::GetCurrent().Terminate();
        },
        ftl::TimePoint::Now() + ftl::TimeDelta::FromMilliseconds(5));
    loop.Run();
  });
  thread.join();
  ASSERT_TRUE(checked);
}

TEST(MessageLoop, TIME_SENSITIVE(MultipleDelayedTasksWithIncreasingDeltas)) {
  const auto count = 10;
  int checked = false;
  std::thread thread([&checked]() {
    fml::MessageLoop::EnsureInitializedForCurrentThread();
    auto& loop = fml::MessageLoop::GetCurrent();
    for (int target_ms = 0 + 2; target_ms < count + 2; target_ms++) {
      auto begin = ftl::TimePoint::Now();
      loop.GetTaskRunner()->PostDelayedTask(
          [begin, target_ms, &checked]() {
            auto delta = ftl::TimePoint::Now() - begin;
            auto ms = delta.ToMillisecondsF();
            ASSERT_GE(ms, target_ms - 2);
            ASSERT_LE(ms, target_ms + 2);
            checked++;
            if (checked == count) {
              fml::MessageLoop::GetCurrent().Terminate();
            }
          },
          ftl::TimeDelta::FromMilliseconds(target_ms));
    }
    loop.Run();
  });
  thread.join();
  ASSERT_EQ(checked, count);
}

TEST(MessageLoop, TIME_SENSITIVE(MultipleDelayedTasksWithDecreasingDeltas)) {
  const auto count = 10;
  int checked = false;
  std::thread thread([&checked]() {
    fml::MessageLoop::EnsureInitializedForCurrentThread();
    auto& loop = fml::MessageLoop::GetCurrent();
    for (int target_ms = count + 2; target_ms > 0 + 2; target_ms--) {
      auto begin = ftl::TimePoint::Now();
      loop.GetTaskRunner()->PostDelayedTask(
          [begin, target_ms, &checked]() {
            auto delta = ftl::TimePoint::Now() - begin;
            auto ms = delta.ToMillisecondsF();
            ASSERT_GE(ms, target_ms - 2);
            ASSERT_LE(ms, target_ms + 2);
            checked++;
            if (checked == count) {
              fml::MessageLoop::GetCurrent().Terminate();
            }
          },
          ftl::TimeDelta::FromMilliseconds(target_ms));
    }
    loop.Run();
  });
  thread.join();
  ASSERT_EQ(checked, count);
}

class CustomTaskObserver : public fml::TaskObserver {
 public:
  CustomTaskObserver(std::function<void()> lambda) : lambda_(lambda){};

  ~CustomTaskObserver() override = default;

  void DidProcessTask() {
    if (lambda_) {
      lambda_();
    }
  };

 private:
  std::function<void()> lambda_;
};

TEST(MessageLoop, TaskObserverFire) {
  bool started = false;
  bool terminated = false;
  std::thread thread([&started, &terminated]() {
    fml::MessageLoop::EnsureInitializedForCurrentThread();
    const size_t count = 25;
    auto& loop = fml::MessageLoop::GetCurrent();
    size_t task_count = 0;
    size_t obs_count = 0;
    CustomTaskObserver obs([&obs_count]() { obs_count++; });
    for (size_t i = 0; i < count; i++) {
      loop.GetTaskRunner()->PostTask([&terminated, i, &task_count]() {
        ASSERT_EQ(task_count, i);
        task_count++;
        if (count == i + 1) {
          fml::MessageLoop::GetCurrent().Terminate();
          terminated = true;
        }
      });
    }
    loop.AddTaskObserver(&obs);
    loop.Run();
    ASSERT_EQ(task_count, count);
    ASSERT_EQ(obs_count, count);
    started = true;
  });
  thread.join();
  ASSERT_TRUE(started);
  ASSERT_TRUE(terminated);
}
