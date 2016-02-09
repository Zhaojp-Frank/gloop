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
#ifndef GLOOP_HOST_CONTEXT_CU_H_
#define GLOOP_HOST_CONTEXT_CU_H_
#include <cuda.h>
#include <memory>
#include <utility>
#include <vector>
#include "device_context.cuh"
#include "io.cuh"
#include "mapped_memory.cuh"
#include "noncopyable.h"
#include "spinlock.h"
namespace gloop {

class HostLoop;

class HostContext {
GLOOP_NONCOPYABLE(HostContext);
public:
    __host__ ~HostContext();

    __host__ static std::unique_ptr<HostContext> create(HostLoop&, dim3 blocks);

    __host__ DeviceContext deviceContext() { return m_context; }

    dim3 blocks() const { return m_blocks; }

    __host__ IPC* tryPeekRequest();

    FileDescriptorTable& table() { return m_table; }

    typedef Spinlock Mutex;
    Mutex& mutex() { return m_mutex; }

    void prepareForLaunch();

    uint32_t pending() const;

    void addExitRequired(IPC* ipc)
    {
        // Mutex should be held.
        m_exitRequired.push_back(ipc);
    }

    bool addUnmapRequest(void* pointer)
    {
        // Mutex should be held.
        m_unmapRequests.push_back(pointer);
        bool scheduled = m_exitHandlerScheduled;
        m_exitHandlerScheduled = true;
        return scheduled;
    }

    void clearUnmapRequests()
    {
        m_unmapRequests.clear();
        m_exitHandlerScheduled = false;
    }

    std::vector<void*> unmapRequests() { return m_unmapRequests; }

private:
    HostContext(dim3 blocks);
    bool initialize();

    Mutex m_mutex;
    FileDescriptorTable m_table { };
    std::unique_ptr<IPC[]> m_ipc { nullptr };
    std::shared_ptr<MappedMemory> m_pending { nullptr };
    DeviceContext m_context { nullptr };
    dim3 m_blocks { };
    std::vector<IPC*> m_exitRequired;
    std::vector<void*> m_unmapRequests;
    bool m_exitHandlerScheduled { false };
};


}  // namespace gloop
#endif  // GLOOP_HOST_CONTEXT_CU_H_
