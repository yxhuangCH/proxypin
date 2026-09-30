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

/**
 * 隧道栈 napi 薄接口（路线 A 第 1 期）。
 *
 * 同一个 libvpntunnel.so 被两个进程加载：
 * - VPN 扩展进程（ProxyPinVpnAbility）：startTunnel / stopTunnel（驱动隧道）
 * - 主进程 Flutter 插件（ProxyPinVpnPlugin / ProxyPinProcessInfoPlugin）：
 *   isTunnelRunning / getRemoteByPort（跨进程查询扩展进程的隧道状态与端口映射）
 *
 * 跨进程查询走 127.0.0.1:<kControlPort> 的控制通道，见 tunnel.cpp。
 */

#include "napi/native_api.h"
#include <hilog/log.h>

#include <string>

#include "tunnel.h"

#define LOG_TAG "ProxyPinTunnel"

namespace {

using proxypin::RemoteTarget;
using proxypin::Tunnel;

napi_value StartTunnel(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
        napi_throw_error(env, nullptr, "startTunnel(fd, proxyHost, proxyPort) 需要 3 个参数");
        return nullptr;
    }

    int32_t fd = -1;
    napi_get_value_int32(env, args[0], &fd);
    char proxyHost[64] = {0};
    size_t proxyHostLen = 0;
    napi_get_value_string_utf8(env, args[1], proxyHost, sizeof(proxyHost) - 1, &proxyHostLen);
    int32_t proxyPort = 0;
    napi_get_value_int32(env, args[2], &proxyPort);
    if (fd <= 0 || proxyHostLen == 0 || proxyPort <= 0 || proxyPort > 65535) {
        napi_throw_error(env, nullptr, "startTunnel 参数非法");
        return nullptr;
    }

    bool ok = Tunnel::instance().start(fd, proxyHost, static_cast<uint16_t>(proxyPort));
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, LOG_TAG, "startTunnel fd=%{public}d ok=%{public}d", fd, ok ? 1 : 0);

    napi_value result = nullptr;
    napi_get_boolean(env, ok, &result);
    return result;
}

napi_value StopTunnel(napi_env env, napi_callback_info info) {
    (void)env;
    (void)info;
    Tunnel::instance().stop();
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, LOG_TAG, "stopTunnel");
    return nullptr;
}

napi_value IsTunnelRunning(napi_env env, napi_callback_info info) {
    (void)info;
    bool running = Tunnel::query_running();
    napi_value result = nullptr;
    napi_get_boolean(env, running, &result);
    return result;
}

napi_value GetRemoteByPort(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t port = 0;
    if (argc < 1 || napi_get_value_int32(env, args[0], &port) != napi_ok || port <= 0 || port > 65535) {
        napi_value nil = nullptr;
        napi_get_null(env, &nil);
        return nil;
    }

    RemoteTarget target{};
    if (!Tunnel::query_remote(static_cast<uint16_t>(port), &target)) {
        napi_value nil = nullptr;
        napi_get_null(env, &nil);
        return nil;
    }

    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_value host = nullptr;
    napi_create_string_utf8(env, target.host.c_str(), NAPI_AUTO_LENGTH, &host);
    napi_set_named_property(env, result, "remoteHost", host);
    napi_value remotePort = nullptr;
    napi_create_int32(env, target.port, &remotePort);
    napi_set_named_property(env, result, "remotePort", remotePort);
    return result;
}

EXTERN_C_START
napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"startTunnel", nullptr, StartTunnel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopTunnel", nullptr, StopTunnel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isTunnelRunning", nullptr, IsTunnelRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getRemoteByPort", nullptr, GetRemoteByPort, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

napi_module vpnTunnelModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "vpntunnel",
    .nm_priv = nullptr,
    .reserved = {0},
};

}  // namespace

extern "C" __attribute__((constructor)) void RegisterVpnTunnelModule(void) {
    napi_module_register(&vpnTunnelModule);
}
