/*
  Copyright (C) 2015 Yusuke Suzuki <yusuke.suzuki@sslab.ics.keio.ac.jp>

  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.

  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
  ARE DISCLAIMED. IN NO EVENT SHALL <COPYRIGHT HOLDER> BE LIABLE FOR ANY
  DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
  (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
  THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/
#ifndef GLOOP_ENTRY_H_
#define GLOOP_ENTRY_H_
#include <utility>
#include "device_loop.cuh"
#include "function.cuh"
#include "serialized.cuh"

namespace gloop {

#define GLOOP_SHARED_SLOT_SIZE 1024

template<typename Callback, class... Args>
inline __global__ void launch(const Callback& callback, Args... args)
{
    __shared__ uint64_t buffer[GLOOP_SHARED_SLOT_SIZE];
    DeviceLoop loop(reinterpret_cast<DeviceLoop::Function*>(buffer), GLOOP_SHARED_SLOT_SIZE * sizeof(uint64_t) / sizeof(DeviceLoop::Function));
    callback(&loop, std::forward<Args>(args)...);
    while (!loop.done()) {
        DeviceLoop::Function* lambda = reinterpret_cast<DeviceLoop::Function*>(loop.dequeue());
        (*lambda)(&loop);
    }
}

}  // namespace gloop
#endif  // GLOOP_ENTRY_H_
