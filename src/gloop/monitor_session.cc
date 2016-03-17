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
#include <boost/bind.hpp>
#include <chrono>
#include <mutex>
#include <vector>
#include "data_log.h"
#include "make_unique.h"
#include "monitor_server.h"
#include "monitor_session.h"
#include "sync_read_write.h"

namespace gloop {
namespace monitor {

Session::Session(Server& server, uint32_t id)
    : m_id(id)
    , m_server(server)
    , m_socket(server.ioService())
    , m_kernelLock(server.kernelLock(), std::defer_lock)
    , m_timer(server.ioService())
{
}

Session::~Session()
{
    // NOTE: This destructor is always executed in single thread.
    m_server.unregisterSession(*this);
    GLOOP_DATA_LOG("server:(%u),close:(%u)\n", m_server.id(), static_cast<unsigned>(id()));
    if (m_thread) {
        m_thread->interrupt();
        m_thread->join();
        m_thread.reset();
    }
}

void Session::handShake()
{
    GLOOP_DATA_LOG("server:(%u),open:(%u)\n", m_server.id(), static_cast<unsigned>(id()));
    boost::asio::async_read(m_socket, boost::asio::buffer(&m_buffer, sizeof(Command)), boost::bind(&Session::handleRead, this, boost::asio::placeholders::error));
}

void Session::handleRead(const boost::system::error_code& error)
{
    if (error) {
        delete this;
        return;
    }
    Command command(*buffer());
    this->handle(command);
    // handle command
    boost::asio::async_write(m_socket, boost::asio::buffer(&command, sizeof(Command)), boost::bind(&Session::handleWrite, this, boost::asio::placeholders::error));
}

void Session::handleWrite(const boost::system::error_code& error)
{
    if (error) {
        delete this;
        return;
    }

    boost::asio::async_read(m_socket, boost::asio::buffer(&m_buffer, sizeof(Command)), boost::bind(&Session::handleRead, this, boost::asio::placeholders::error));
}

void Session::kill()
{
    std::lock_guard<Lock> guard(m_lock);
    if (m_kernelLock.owns_lock()) {
        syncWrite<uint32_t>(static_cast<volatile uint32_t*>(m_signal->get_address()), 1);
    }
}

void Session::configureTick(boost::asio::high_resolution_timer& timer)
{
    timer.expires_from_now(std::chrono::milliseconds(GLOOP_KILL_TIME));
    timer.async_wait([&](const boost::system::error_code& ec) {
        if (!ec) {
            // This is ASIO call. So it is executed under the main thread now. (Since only the main thread invokes ASIO's ioService.run()).
            for (auto& session : m_server.sessionList()) {
                if (&session != this) {
                    if (session.isAttemptingToLaunch()) {
                        // Found. Let's kill the current kernel executing.
                        kill();
                        break;
                    }
                }
            }
            configureTick(timer);
        }
    });
}

bool Session::handle(Command& command)
{
    switch (command.type) {
    case Command::Type::Initialize:
        return initialize(command);

    case Command::Type::Operation:
        return false;

    case Command::Type::Lock: {
        GLOOP_DEBUG("[%u] Attempt to lock kernel token.\n", m_id);
        {
            std::lock_guard<Lock> guard(m_lock);
            m_attemptToLaunch.store(true);

            m_kernelLock.lock();
            while (!m_server.isAllowed(*this)) {
                GLOOP_DEBUG("[%u] Sleep\n", m_id);
                m_server.condition().wait(m_kernelLock);
            }
            GLOOP_DEBUG("[%u] Lock kernel token.\n", m_id);

            m_timeWatch.begin();
            m_attemptToLaunch.store(false);
            configureTick(m_timer);
        }
        return true;
    }

    case Command::Type::Unlock: {
        {
            std::lock_guard<Lock> guard(m_lock);
            m_timer.cancel();
            m_timeWatch.end();

            bool acquireLockSoon = static_cast<bool>(command.payload);
            if (acquireLockSoon) {
                // This flag makes the current ready to schedule.
                m_attemptToLaunch.store(true);
            }

            {
                std::lock_guard<Lock> serverStatusGuard(m_server.serverStatusLock());
                m_used += (m_timeWatch.ticks() / m_costPerBit);
                m_server.calculateNextSession(serverStatusGuard);
            }
            m_kernelLock.unlock();
            m_server.condition().notify_all();
            GLOOP_DEBUG("[%u] Unlock kernel token, used:(%llu).\n", m_id, (long long unsigned)m_used.count());
        }
        return false;
    }

    case Command::Type::IO: {
        GLOOP_UNREACHABLE();
    }
    }
    return false;
}

bool Session::initialize(Command& command)
{
    m_requestQueue = Session::createQueue(GLOOP_SHARED_REQUEST_QUEUE, id(), true);
    m_responseQueue = Session::createQueue(GLOOP_SHARED_RESPONSE_QUEUE, id(), true);
    m_sharedMemory = Session::createMemory(GLOOP_SHARED_MEMORY, id(), GLOOP_SHARED_MEMORY_SIZE, true);
    m_signal = make_unique<boost::interprocess::mapped_region>(*m_sharedMemory.get(), boost::interprocess::read_write, /* Offset. */ 0, GLOOP_SHARED_MEMORY_SIZE);

    assert(m_requestQueue);
    assert(m_responseQueue);

    // NOTE: This initialize method is always executed in the single event loop thread.
    m_server.registerSession(*this);
    m_thread = make_unique<boost::thread>(&Session::main, this);

    command = (Command) {
        .type = Command::Type::Initialize,
        .payload = id()
    };
    return true;
}

std::string Session::createName(const std::string& prefix, uint32_t id)
{
    std::vector<char> name(prefix.size() + 100);
    const int ret = std::snprintf(name.data(), name.size() - 1, "%s%u", prefix.c_str(), id);
    if (ret < 0) {
        std::perror(nullptr);
        std::exit(1);
    }
    name[ret] = '\0';
    return std::string(name.data(), ret);
}

std::unique_ptr<boost::interprocess::message_queue> Session::createQueue(const std::string& prefix, uint32_t id, bool create)
{
    const std::string name = createName(prefix, id);
    if (create) {
        boost::interprocess::message_queue::remove(name.c_str());
        return make_unique<boost::interprocess::message_queue>(boost::interprocess::create_only, name.c_str(), 0x1000, sizeof(Command));
    }
    return make_unique<boost::interprocess::message_queue>(boost::interprocess::open_only, name.c_str());
}

std::unique_ptr<boost::interprocess::shared_memory_object> Session::createMemory(const std::string& prefix, uint32_t id, std::size_t sharedMemorySize, bool create)
{
    const std::string name = createName(prefix, id);
    std::unique_ptr<boost::interprocess::shared_memory_object> memory;
    if (create) {
        boost::interprocess::shared_memory_object::remove(name.c_str());
        memory = make_unique<boost::interprocess::shared_memory_object>(boost::interprocess::create_only, name.c_str(), boost::interprocess::read_write);
    } else {
        memory = make_unique<boost::interprocess::shared_memory_object>(boost::interprocess::open_only, name.c_str(), boost::interprocess::read_write);
    }
    memory->truncate(sharedMemorySize);
    return memory;
}


void Session::main()
{
    while (true) {
        unsigned int priority { };
        std::size_t size { };
        Command command { };
        if (m_requestQueue->try_receive(&command, sizeof(Command), size, priority)) {
            if (handle(command)) {
                m_responseQueue->send(&command, sizeof(Command), 0);
            }
        } else {
            // FIXME
            boost::this_thread::interruption_point();
        }
    }
}

void Session::burnUsed(const Duration& currentVirtualTime)
{
    m_used -= currentVirtualTime;
    if (m_used < Duration(0))
        m_used = Duration(0);
}

void Session::setUsed(const Duration& used)
{
    m_used = used;
}

} }  // namsepace gloop::monitor
