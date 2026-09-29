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

import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import Want from '@ohos.app.ability.Want';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import vpntunnel from 'libvpntunnel.so';

const TAG: string = 'ProxyPinVpnAbility';

/** 与 Android 侧 ProxyVpnService 对齐的常量 */
const VIRTUAL_HOST: string = '10.0.0.2';
const MTU: number = 1500;

/** want.parameters 键名（由 ProxyPinVpnPlugin 传入） */
export const PARAM_PROXY_PORT: string = 'proxyPort';
export const PARAM_TRUSTED_APPS: string = 'trustedApps';
export const PARAM_BLOCKED_APPS: string = 'blockedApps';

/**
 * 与同进程 ProxyPinVpnPlugin 共享的运行状态。
 * 鸿蒙 VpnExtensionAbility 生命周期仅 onCreate/onDestroy，
 * 插件经此类查询 tun fd 与运行状态（PoC 阶段仅用于日志观察）。
 */
export class VpnAbilityState {
  static isRunning: boolean = false;
  static tunFd: number = -1;
}

/**
 * 本机 VPN 抓包 ExtensionAbility（路线 A）。
 * module.json5 声明 type: "vpn"，三方 VPN 仅需 INTERNET 普通权限。
 * 实施文档：harmony/docs/09-应用白名单与VPN路线实施.md
 */
export default class ProxyPinVpnAbility extends VpnExtensionAbility {
  private vpnConnection: vpnExtension.VpnConnection | null = null;

  onCreate(want: Want): void {
    hilog.info(0x0000, TAG, 'onCreate');
    const params: Record<string, Object> = want.parameters ?? {};
    const proxyPort: number = (params[PARAM_PROXY_PORT] as number) ?? 9099;
    const trustedApps: string[] = (params[PARAM_TRUSTED_APPS] as string[]) ?? [];
    const blockedApps: string[] = (params[PARAM_BLOCKED_APPS] as string[]) ?? [];
    hilog.info(0x0000, TAG,
      'proxyPort=%{public}d trusted=%{public}zu blocked=%{public}zu',
      proxyPort, trustedApps.length, blockedApps.length);
    this.startVpn(trustedApps, blockedApps);
  }

  private startVpn(trustedApps: string[], blockedApps: string[]): void {
    try {
      this.vpnConnection = vpnExtension.createVpnConnection(this.context);
      const config: vpnExtension.VpnConfig = {
        addresses: [{
          address: { address: VIRTUAL_HOST, family: 1 },
          prefixLength: 32,
        }],
        routes: [{
          // VPN 虚拟网卡接口名固定为 vpn-tun
          interface: 'vpn-tun',
          destination: { address: { address: '0.0.0.0', family: 1 }, prefixLength: 0 },
          gateway: { address: '0.0.0.0', family: 1 }, // 必填字段，hasGateway=false 时为占位值
          hasGateway: false,
          isDefaultRoute: true,
        }],
        mtu: MTU,
        isIPv4Accepted: true,
        isIPv6Accepted: false,
        isBlocking: true,
      };
      // trustedApplications/blockedApplications 互斥，白名单优先（对齐 Android 语义）
      if (trustedApps.length > 0) {
        config.trustedApplications = trustedApps;
      } else if (blockedApps.length > 0) {
        config.blockedApplications = blockedApps;
      }

      this.vpnConnection.create(config).then((fd: number) => {
        VpnAbilityState.tunFd = fd;
        VpnAbilityState.isRunning = true;
        hilog.info(0x0000, TAG, 'tun created, fd=%{public}d', fd);
        // PoC：C++ 线程 poll+read tun fd，观察白名单过滤是否生效
        vpntunnel.startTunLog(fd);
      }).catch((e: BusinessError) => {
        hilog.error(0x0000, TAG, 'create failed: %{public}d %{public}s', e.code, e.message ?? '');
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'startVpn exception: %{public}d %{public}s', err.code, err.message ?? '');
    }
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG, 'onDestroy');
    vpntunnel.stopTunLog();
    VpnAbilityState.isRunning = false;
    VpnAbilityState.tunFd = -1;
    this.vpnConnection?.destroy().catch((e: BusinessError) => {
      hilog.warn(0x0000, TAG, 'destroy failed: %{public}d', e.code);
    });
    this.vpnConnection = null;
  }
}
