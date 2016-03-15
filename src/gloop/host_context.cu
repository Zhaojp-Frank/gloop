/*
  Copyright (C) 2016 Yusuke Suzuki <yusuke.suzuki@sslab.ics.keio.ac.jp>

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
#include <mutex>
#include "data_log.h"
#include "device_context.cuh"
#include "ipc.cuh"
#include "host_context.cuh"
#include "host_loop.cuh"
#include "make_unique.h"
#include "sync_read_write.h"

namespace gloop {

std::unique_ptr<HostContext> HostContext::create(HostLoop& hostLoop, dim3 blocks, uint32_t pageCount)
{
    std::unique_ptr<HostContext> hostContext(new HostContext(hostLoop, blocks, pageCount));
    if (!hostContext->initialize(hostLoop)) {
        return nullptr;
    }
    return hostContext;
}

HostContext::HostContext(HostLoop& hostLoop, dim3 blocks, uint32_t pageCount)
    : m_hostLoop(hostLoop)
    , m_blocks(blocks)
    , m_pageCount(pageCount)
{
}

HostContext::~HostContext()
{
    if (m_context.context) {
        std::lock_guard<gloop::HostLoop::KernelLock> lock(m_hostLoop.kernelLock());
        cudaFree(m_context.context);
    }
}

bool HostContext::initialize(HostLoop& hostLoop)
{
    {
        std::lock_guard<gloop::HostLoop::KernelLock> lock(hostLoop.kernelLock());

        m_ipc = make_unique<IPC[]>(m_blocks.x * m_blocks.y * GLOOP_SHARED_SLOT_SIZE);
        m_pending = MappedMemory::create(sizeof(uint32_t));

        GLOOP_CUDA_SAFE_CALL(cudaHostGetDevicePointer(&m_context.channels, m_ipc.get(), 0));

        GLOOP_CUDA_SAFE_CALL(cudaHostGetDevicePointer(&m_context.pending, m_pending->mappedPointer(), 0));

        GLOOP_CUDA_SAFE_CALL(cudaMalloc(&m_context.context, sizeof(DeviceLoop::PerBlockContext) * m_blocks.x * m_blocks.y));
        if (m_pageCount) {
            GLOOP_CUDA_SAFE_CALL(cudaMalloc(&m_context.pages, sizeof(DeviceLoop::OnePage) * m_pageCount * m_blocks.x * m_blocks.y));
        }
    }
    return true;
}

uint32_t HostContext::pending() const
{
    return readNoCache<uint32_t>(m_pending->mappedPointer());
}

void HostContext::prepareForLaunch()
{
    writeNoCache<uint32_t>(m_pending->mappedPointer(), 0);
    // Clean up ExitRequired flags.
    {
        std::lock_guard<Mutex> guard(m_mutex);
        for (IPC* ipc : m_exitRequired) {
            ipc->emit(Code::Complete);
        }
        m_exitRequired.clear();
        for (void* pointer : m_unmapRequests) {
            GLOOP_CUDA_SAFE_CALL(cudaHostUnregister(pointer));
        }
        m_unmapRequests.clear();
    }
    __sync_synchronize();
}

}  // namespace gloop
