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
#ifndef GLOOP_HOST_LOOP_INLINES_CU_H_
#define GLOOP_HOST_LOOP_INLINES_CU_H_
#include "host_context.cuh"
#include "host_loop.cuh"
#include "entry.cuh"
namespace gloop {

template<typename DeviceLambda, class... Args>
void HostLoop::launch(HostContext& hostContext, dim3 threads, DeviceLambda callback, Args... args)
{
    std::shared_ptr<gloop::Benchmark> benchmark = std::make_shared<gloop::Benchmark>();
    benchmark->begin();
    prologue(hostContext, threads);
    {
        refKernel();
        m_kernelService.post([=] {
            {
                std::lock_guard<KernelLock> lock(m_kernelLock);
                // GLOOP_DATA_LOG("acquire for launch\n");
                prepareForLaunch();
                gloop::resume<<<m_currentContext->physicalBlocks(), m_threads, 0, m_pgraph>>>(m_deviceSignal, m_currentContext->deviceContext(), callback, args...);
                cudaError_t error = cudaGetLastError();
                GLOOP_CUDA_SAFE(error);
                GLOOP_CUDA_SAFE_CALL(cudaStreamSynchronize(m_pgraph));
            }

            if (m_currentContext->pending()) {
                resume(callback, args...);
                return;
            }
            derefKernel();
        });
        drain();
    }
    epilogue();
}

template<typename DeviceLambda, typename... Args>
void HostLoop::resume(DeviceLambda callback, Args... args)
{
    // GLOOP_DEBUG("resume\n");
    m_kernelService.post([=] {
        bool acquireLockSoon = false;
        {
            {
#if 1
                // FIXME: Provide I/O boosting.
                std::unique_lock<HostContext::Mutex> lock(m_currentContext->mutex());
                while (!m_currentContext->isReadyForResume(lock)) {
                    m_currentContext->condition().wait(lock);
                }
#endif
                m_kernelLock.lock();
            }
            // GLOOP_DATA_LOG("acquire for resume\n");
            prepareForLaunch();

            {
                gloop::resume<<<m_currentContext->physicalBlocks(), m_threads, 0, m_pgraph>>>(nullptr, m_currentContext->deviceContext(), callback, args...);
                cudaError_t error = cudaGetLastError();
                GLOOP_CUDA_SAFE(error);
                GLOOP_CUDA_SAFE_CALL(cudaStreamSynchronize(m_pgraph));
            }

            acquireLockSoon = m_currentContext->pending();

            // m_kernelLock.unlock(acquireLockSoon);
            // m_kernelLock.unlock();

            {
                // FIXME: Fix this.
                std::unique_lock<HostContext::Mutex> lock(m_currentContext->mutex());
                Command::ReleaseStatus releaseStatus = Command::ReleaseStatus::IO;
                if (m_currentContext->isReadyForResume(lock)) {
                    releaseStatus = Command::ReleaseStatus::Ready;
                }
                m_kernelLock.unlock(releaseStatus);
            }
        }
        if (acquireLockSoon) {
            resume(callback, args...);
            return;
        }
        derefKernel();
    });
}

void HostLoop::lockLaunch()
{
    unsigned int priority { };
    std::size_t size { };
    Command command {
        .type = Command::Type::Lock,
        .payload = 0
    };
    m_requestQueue->send(&command, sizeof(Command), 0);
    m_responseQueue->receive(&command, sizeof(Command), size, priority);
}

void HostLoop::unlockLaunch(Command::ReleaseStatus releaseStatus)
{
    Command command {
        .type = Command::Type::Unlock,
        .payload = static_cast<uint64_t>(releaseStatus)
    };
    m_requestQueue->send(&command, sizeof(Command), 0);
}

}  // namespace gloop
#endif  // GLOOP_HOST_LOOP_INLINES_CU_H_
