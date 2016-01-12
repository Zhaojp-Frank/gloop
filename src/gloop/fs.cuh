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
#ifndef GLOOP_FS_H_
#define GLOOP_FS_H_
#include <gpufs/libgpufs/fs_calls.cu.h>
#include <type_traits>
#include <utility>
#include "device_loop.cuh"
#include "nvfunction.cuh"
#include "serialized.cuh"

namespace gloop {
namespace fs {

template<typename Callback>
inline __device__ Serialized makeSerialized(const Callback& callback, int value)
{
    return { value, callback };
}

template<typename Callback>
inline __device__ auto open(DeviceLoop* loop, char* filename, int mode, Callback callback) -> void
{
    int fd = gopen(filename, mode);
    loop->enqueue(makeSerialized([callback, fd](DeviceLoop* loop, int) {
        callback(loop, fd);
    }, fd));
}

template<typename Callback>
inline __device__ auto write(DeviceLoop* loop, int fd, size_t offset, size_t count, unsigned char* buffer, Callback callback) -> void
{
    size_t writtenSize = gwrite(fd, offset, count, buffer);
    loop->enqueue(makeSerialized([callback, writtenSize](DeviceLoop* loop, int) {
        callback(loop, writtenSize);
    }, writtenSize));
}

template<typename Callback>
inline __device__ auto fstat(DeviceLoop* loop, int fd, Callback callback) -> void
{
    size_t value = ::fstat(fd);
    loop->enqueue(makeSerialized([callback, value](DeviceLoop* loop, int) {
        callback(loop, value);
    }, value));
}

template<typename Callback>
inline __device__ auto close(DeviceLoop* loop, int fd, Callback callback) -> void
{
    int err = gclose(fd);
    loop->enqueue(makeSerialized([callback, err](DeviceLoop* loop, int) {
        callback(loop, err);
    }, err));
}

template<typename Callback>
inline __device__ auto read(DeviceLoop* loop, int fd, size_t offset, size_t size, unsigned char* buffer, Callback callback) -> void
{
    size_t bytesRead = gread(fd, offset, size, buffer);
    loop->enqueue(makeSerialized([callback, bytesRead](DeviceLoop* loop, int) {
        callback(loop, bytesRead);
    }, bytesRead));
}

} }  // namespace gloop::fs
#endif  // GLOOP_FS_H_
