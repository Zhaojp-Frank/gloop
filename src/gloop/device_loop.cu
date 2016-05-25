/*
  Copyright (C) 2015-2016 Yusuke Suzuki <yusuke.suzuki@sslab.ics.keio.ac.jp>

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
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAfree AND
  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
  THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/
#include "device_context.cuh"
#include "device_loop_inlines.cuh"
#include "dump_memory.cuh"
#include "function.cuh"
#include "sync_read_write.h"
#include "utility.h"
namespace gloop {

// Initialize a device loop per thread block.
__device__ __shared__ DeviceLoop sharedDeviceLoop;
__device__ __shared__ uint2 logicalGridDim;
__device__ __shared__ uint2 logicalBlockIdx;
__device__ UninitializedDeviceCallbackStorage nextKernel;

__device__ void DeviceLoop::initializeImpl(DeviceContext deviceContext)
{
    GLOOP_ASSERT_SINGLE_THREAD();

    m_deviceContext = deviceContext;
    m_codes = deviceContext.codes + (GLOOP_BID() * GLOOP_SHARED_SLOT_SIZE);
    m_payloads = deviceContext.payloads + (GLOOP_BID() * GLOOP_SHARED_SLOT_SIZE);
    m_slots = reinterpret_cast<DeviceCallback*>(&context()->slots);

    uint64_t startClock = clock64();
    m_start = atomicCAS((unsigned long long*)&deviceContext.kernel->globalClock, 0ULL, (unsigned long long)startClock);
    if (m_start == 0)
        m_start = startClock;

#if defined(GLOOP_ENABLE_HIERARCHICAL_SLOT_MEMORY)
    m_scratchIndex1 = invalidPosition();
    m_scratchIndex2 = invalidPosition();
#endif
}

__device__ int DeviceLoop::initialize(volatile uint32_t* signal, DeviceContext deviceContext)
{
    GLOOP_ASSERT_SINGLE_THREAD();
    initializeImpl(deviceContext);
    resume();
#if defined(GLOOP_ENABLE_ELASTIC_KERNELS)
    logicalGridDim = m_control.logicalGridDim;
    logicalBlockIdx = m_control.logicalBlockIdx;
#endif
    return m_control.freeSlots != DeviceContext::DeviceLoopControl::allFilledFreeSlots();
}

__device__ void DeviceLoop::resume()
{
    GLOOP_ASSERT_SINGLE_THREAD();
    // __threadfence_system();  // FIXME
    DeviceContext::PerBlockContext* blockContext = context();
    m_control = blockContext->control;
    // __threadfence_system();  // FIXME
}

__device__ void DeviceLoop::freeOnePage(void* aPage)
{
    GLOOP_ASSERT_SINGLE_THREAD();
    uint32_t pos = position(static_cast<DeviceContext::OnePage*>(aPage));
    m_control.freePages |= (1UL << pos);
    GPU_ASSERT(pos < GLOOP_SHARED_PAGE_COUNT);
    int freePageWaitingCallbackPlusOne = __ffs(m_control.pageSleepSlots);
    if (freePageWaitingCallbackPlusOne) {
        m_control.wakeupSlots |= (1U << (freePageWaitingCallbackPlusOne - 1));
    }
}

}  // namespace gloop
