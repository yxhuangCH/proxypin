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
 * 路线 A PoC：验证 C++ NDK 层可 read tun fd（鸿蒙 vpnExtension.create() 返回的原生 fd）。
 * startTunLog 起 pthread 循环 poll+read，解析 IPv4 头后打 hilog。
 * 第 1 期将替换为完整隧道栈（tun_pump/connection_handler/forwarder 等，见 doc 09 §5）。
 */

#include "napi/native_api.h"
#include <hilog/log.h>
#include <poll.h>
#include <pthread.h>
#include <unistd.h>
#include <atomic>

#define LOG_TAG "ProxyPinVpnTunnel"
#define MAX_PACKET_LEN 2048

static std::atomic<bool> g_running(false);
static std::atomic<int> g_tunFd(-1);
static pthread_t g_thread;
static pthread_mutex_t g_threadMutex = PTHREAD_MUTEX_INITIALIZER;

static void *TunLogThread(void *arg)
{
    (void)arg;
    int fd = g_tunFd.load();
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, LOG_TAG, "tun log thread started, fd=%{public}d", fd);

    unsigned char buf[MAX_PACKET_LEN];
    while (g_running.load()) {
        struct pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        pfd.revents = 0;
        int ret = poll(&pfd, 1, 500);
        if (ret <= 0) {
            continue;
        }
        if ((pfd.revents & POLLIN) == 0) {
            continue;
        }
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n <= 0) {
            continue;
        }

        // 解析 IPv4 头：版本/IHL/协议/源/目的地址
        if (n < 20 || (buf[0] >> 4) != 4) {
            OH_LOG_Print(LOG_APP, LOG_WARN, 0x0000, LOG_TAG, "non-ipv4 packet, len=%{public}zd", n);
            continue;
        }
        unsigned int ihl = static_cast<unsigned int>(buf[0] & 0x0F) * 4;
        if (ihl < 20 || static_cast<ssize_t>(n) < static_cast<ssize_t>(ihl)) {
            continue;
        }
        int proto = buf[9];
        const unsigned char *src = buf + 12;
        const unsigned char *dst = buf + 16;

        if (proto == 6 || proto == 17) { // TCP / UDP，附带端口
            if (static_cast<ssize_t>(n) < static_cast<ssize_t>(ihl + 4)) {
                continue;
            }
            int srcPort = (buf[ihl] << 8) | buf[ihl + 1];
            int dstPort = (buf[ihl + 2] << 8) | buf[ihl + 3];
            OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, LOG_TAG,
                "pkt len=%{public}zd proto=%{public}d "
                "%{public}u.%{public}u.%{public}u.%{public}u:%{public}d -> "
                "%{public}u.%{public}u.%{public}u.%{public}u:%{public}d",
                n, proto, src[0], src[1], src[2], src[3], srcPort,
                dst[0], dst[1], dst[2], dst[3], dstPort);
        } else {
            OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, LOG_TAG,
                "pkt len=%{public}zd proto=%{public}d "
                "%{public}u.%{public}u.%{public}u.%{public}u -> "
                "%{public}u.%{public}u.%{public}u.%{public}u",
                n, proto, src[0], src[1], src[2], src[3], dst[0], dst[1], dst[2], dst[3]);
        }
    }

    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, LOG_TAG, "tun log thread stopped");
    return nullptr;
}

static napi_value StartTunLog(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int fd = -1;
    napi_get_value_int32(env, args[0], &fd);
    if (fd <= 0) {
        napi_throw_error(env, nullptr, "invalid tun fd");
        return nullptr;
    }

    pthread_mutex_lock(&g_threadMutex);
    if (g_running.load()) {
        pthread_mutex_unlock(&g_threadMutex);
        return nullptr;
    }
    g_tunFd.store(fd);
    g_running.store(true);
    pthread_create(&g_thread, nullptr, TunLogThread, nullptr);
    pthread_mutex_unlock(&g_threadMutex);
    return nullptr;
}

static napi_value StopTunLog(napi_env env, napi_callback_info info)
{
    (void)env;
    (void)info;
    pthread_mutex_lock(&g_threadMutex);
    if (g_running.load()) {
        g_running.store(false);
        pthread_join(g_thread, nullptr);
    }
    pthread_mutex_unlock(&g_threadMutex);
    return nullptr;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"startTunLog", nullptr, StartTunLog, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopTunLog", nullptr, StopTunLog, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module vpnTunnelModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "vpntunnel",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterVpnTunnelModule(void)
{
    napi_module_register(&vpnTunnelModule);
}
