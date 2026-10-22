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

import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
  StandardMethodCodec,
} from '@ohos/flutter_ohos';
import { vpnExtension } from '@kit.NetworkKit';
import Want from '@ohos.app.ability.Want';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import vpntunnel from 'libvpntunnel.so';
import ProxyPinPipPlugin, { VpnStopper } from './ProxyPinPipPlugin';

const TAG: string = 'ProxyPinVpnPlugin';
const CHANNEL_NAME: string = 'com.proxy/proxyVpn';
const VPN_ABILITY_NAME: string = 'ProxyPinVpnAbility';

/** vpntunnel napi 接口（libvpntunnel.so） */
interface VpnTunnel {
  startTunnel(tunFd: number, proxyHost: string, proxyPort: number): boolean;
  stopTunnel(): void;
  /** 跨进程查询：扩展进程隧道是否在运行（经 127.0.0.1 控制通道） */
  isTunnelRunning(): boolean;
  getRemoteByPort(localPort: number): Record<string, Object> | null;
}

const tunnel: VpnTunnel = vpntunnel as VpnTunnel;

/**
 * 本机 VPN 抓包插件（路线 A，channel 与 Android VpnServicePlugin 同名同协议，
 * Dart 侧 lib/native/vpn.dart 零改动）。
 *
 * startVpn → vpnExtension.startVpnExtensionAbility(want)（首次系统弹授权框），
 * 配置经 want.parameters 传给 ProxyPinVpnAbility；
 * stopVpn → stopVpnExtensionAbility；isRunning → 经隧道控制通道跨进程查询（扩展在独立进程）。
 *
 * 鸿蒙差异（见 harmony/docs/09）：
 * - proxyPassDomains（CIDR 排除路由）鸿蒙 VpnConfig 无对应物，忽略；
 * - setSystemProxy 无对应系统 API，忽略；
 * - trustedApplications/blockedApplications 互斥，白名单优先（对齐 Dart 取值逻辑）。
 */
export default class ProxyPinVpnPlugin implements FlutterPlugin, MethodCallHandler, VpnStopper {
  private channel: MethodChannel | null = null;
  private uiContext: common.UIAbilityContext;
  private pipPlugin: ProxyPinPipPlugin | null = null;

  constructor(uiContext: common.UIAbilityContext) {
    this.uiContext = uiContext;
  }

  /// 注入 PiP 插件：VPN 启停作为画中画 arm/disarm 的驱动源（harmony/docs/10）
  setPipPlugin(pipPlugin: ProxyPinPipPlugin): void {
    this.pipPlugin = pipPlugin;
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(
      binding.getBinaryMessenger(),
      CHANNEL_NAME,
      StandardMethodCodec.INSTANCE,
    );
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
  }

  getUniqueClassName(): string {
    return TAG;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'startVpn':
        this.startVpn(call, result);
        break;
      case 'stopVpn':
        this.stopVpn(result);
        break;
      case 'restartVpn':
        this.restartVpn(call, result);
        break;
      case 'isRunning': {
        // 扩展在独立进程，静态状态不可见（PoC 结论 P1）：经 127.0.0.1 控制通道查询隧道
        const running: boolean = tunnel.isTunnelRunning();
        // 冷启动时同步 VPN 初始状态，驱动 PiP arm/disarm
        this.pipPlugin?.onVpnStateChanged(running);
        result.success(running);
        break;
      }
      default:
        result.notImplemented();
        break;
    }
  }

  private buildWant(proxyHost: string, proxyPort: number, trustedApps: string[], blockedApps: string[]): Want {
    return {
      bundleName: this.uiContext.abilityInfo.bundleName,
      abilityName: VPN_ABILITY_NAME,
      parameters: {
        'proxyHost': proxyHost,
        'proxyPort': proxyPort,
        'trustedApps': trustedApps,
        'blockedApps': blockedApps,
      } as Record<string, Object>,
    };
  }

  private startVpn(call: MethodCall, result: MethodResult): void {
    const args: ESObject = call.args;
    const proxyHost: string = (args.get('proxyHost') as string) ?? '127.0.0.1';
    const proxyPort: number = (args.get('proxyPort') as number) ?? 9099;
    const allowApps: string[] = (args.get('allowApps') as string[]) ?? [];
    const disallowApps: string[] = (args.get('disallowApps') as string[]) ?? [];
    hilog.info(0x0000, TAG,
      'startVpn %{public}s:%{public}d allow=[%{public}s] disallow=[%{public}s]',
      proxyHost, proxyPort, allowApps.join(','), disallowApps.join(','));

    const want = this.buildWant(proxyHost, proxyPort, allowApps, disallowApps);
    vpnExtension.startVpnExtensionAbility(want).then(() => {
      hilog.info(0x0000, TAG, 'vpn extension started');
      this.pipPlugin?.onVpnStateChanged(true);
      result.success(true);
    }).catch((e: BusinessError) => {
      // 常见：用户拒绝授权 / 2203002 已有活跃 VPN
      hilog.error(0x0000, TAG, 'startVpn failed: %{public}d %{public}s', e.code, e.message ?? '');
      result.error(`VPN_START_FAILED_${e.code}`, e.message ?? '', null);
    });
  }

  private stopVpn(result: MethodResult): void {
    const want: Want = {
      bundleName: this.uiContext.abilityInfo.bundleName,
      abilityName: VPN_ABILITY_NAME,
    };
    vpnExtension.stopVpnExtensionAbility(want).then(() => {
      hilog.info(0x0000, TAG, 'vpn extension stopped');
      this.pipPlugin?.onVpnStateChanged(false);
      result.success(true);
    }).catch((e: BusinessError) => {
      hilog.warn(0x0000, TAG, 'stopVpn failed: %{public}d %{public}s', e.code, e.message ?? '');
      result.success(false);
    });
  }

  /// 由画中画挂断键触发（harmony/docs/10）：等价 stopVpn 通道调用，
  /// 停止后经 onVpnStateChanged(false) 驱动 PiP disarm 退出小窗
  stopVpnFromPip(): void {
    const want: Want = {
      bundleName: this.uiContext.abilityInfo.bundleName,
      abilityName: VPN_ABILITY_NAME,
    };
    vpnExtension.stopVpnExtensionAbility(want).then(() => {
      hilog.info(0x0000, TAG, 'vpn extension stopped by pip');
      this.pipPlugin?.onVpnStateChanged(false);
    }).catch((e: BusinessError) => {
      hilog.warn(0x0000, TAG, 'stopVpnFromPip failed: %{public}d %{public}s', e.code, e.message ?? '');
    });
  }

  private restartVpn(call: MethodCall, result: MethodResult): void {
    const want: Want = {
      bundleName: this.uiContext.abilityInfo.bundleName,
      abilityName: VPN_ABILITY_NAME,
    };
    vpnExtension.stopVpnExtensionAbility(want).catch((e: BusinessError) => {
      hilog.warn(0x0000, TAG, 'restart stop failed: %{public}d', e.code);
    }).then(() => {
      this.startVpn(call, result);
    });
  }
}
