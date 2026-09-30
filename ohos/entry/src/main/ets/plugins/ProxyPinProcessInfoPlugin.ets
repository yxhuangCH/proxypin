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
import { hilog } from '@kit.PerformanceAnalysisKit';
import vpntunnel from 'libvpntunnel.so';

const TAG: string = 'ProxyPinProcessInfoPlugin';
const CHANNEL_NAME: string = 'com.proxy/processInfo';

/** vpntunnel napi 接口（libvpntunnel.so），跨进程查扩展进程隧道的端口映射 */
interface VpnTunnel {
  getRemoteByPort(localPort: number): Record<string, Object> | null;
}

const tunnel: VpnTunnel = vpntunnel as VpnTunnel;

/**
 * 进程信息插件（channel 与 Android ProcessInfoPlugin 同名同协议）。
 *
 * 鸿蒙无法枚举应用 / 查 /proc，故：
 * - getProcessByPort → 恒返回 null（Dart 侧 supportProcessInfo() 已把 ohos 排除，正常不会走到）；
 * - getRemoteAddressByPort → 查隧道 port_map（本地上行端口 → 原始目标），
 *   供 channel_dispatcher 的 _fixAndroidVpnPort 修正明文 HTTP 的非标准端口。
 */
export default class ProxyPinProcessInfoPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;

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
      case 'getRemoteAddressByPort': {
        const port: number = (call.args as ESObject)?.get('port') as number;
        const remote = tunnel.getRemoteByPort(port);
        result.success(remote);
        break;
      }
      case 'getProcessByPort':
        result.success(null);
        break;
      default:
        result.notImplemented();
        break;
    }
  }
}
