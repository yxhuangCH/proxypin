/*
 * Copyright (c) 2026 ProxyPin
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "port_map.h"

namespace proxypin {

PortMap &PortMap::instance() {
    static PortMap instance;
    return instance;
}

void PortMap::set(uint16_t local_port, uint32_t host_ip, uint16_t port) {
    std::lock_guard<std::mutex> lock(mutex_);
    RemoteAddress &addr = map_[local_port];
    addr.host_ip = host_ip;
    addr.port = port;
}

void PortMap::erase(uint16_t local_port) {
    std::lock_guard<std::mutex> lock(mutex_);
    map_.erase(local_port);
}

void PortMap::clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    map_.clear();
}

bool PortMap::get(uint16_t local_port, RemoteAddress *out) const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = map_.find(local_port);
    if (it == map_.end()) {
        return false;
    }
    if (out != nullptr) {
        *out = it->second;
    }
    return true;
}

}  // namespace proxypin
