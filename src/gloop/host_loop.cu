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
#include "host_loop.cuh"
#include <cassert>
#include <cstdio>
#include <cuda_runtime_api.h>
namespace gloop {

HostLoop::HostLoop(volatile GPUGlobals* globals)
    : m_globals(globals)
    , m_loop(uv_loop_new())
{
    runPoller();
}

HostLoop::~HostLoop()
{
    uv_loop_close(m_loop);
    stopPoller();
}

void HostLoop::runPoller()
{
    assert(!m_poller);
    m_stop.store(false, std::memory_order_release);
    m_poller.reset(new std::thread([this]() {
        pollerMain();
    }));
}

void HostLoop::stopPoller()
{
    m_stop.store(true, std::memory_order_release);
    if (m_poller) {
        m_poller->join();
        m_poller.reset();
    }
}

void HostLoop::pollerMain()
{
    while (!m_stop.load(std::memory_order_acquire)) {
        while (false) {
        }
    }
}

}  // namespace gloop
