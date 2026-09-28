/*
 * Copyright (c) 2026 ProxyPin
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
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
import { scanBarcode, scanCore } from '@kit.ScanKit';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'ProxyPinScanPlugin';
const CHANNEL_NAME: string = 'proxypin/scan';

/**
 * ProxyPin 自研鸿蒙扫码插件：调 Scan Kit 系统级扫码界面（startScanForResult），
 * 扫码页由系统应用提供，无需申请 CAMERA 权限。Dart 侧入口 QrCodeScanner.scan()。
 */
export default class ProxyPinScanPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private uiContext: common.UIAbilityContext;

  constructor(uiContext: common.UIAbilityContext) {
    this.uiContext = uiContext;
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
    if (call.method !== 'scan') {
      result.notImplemented();
      return;
    }

    const options: scanBarcode.ScanOptions = {
      scanTypes: [scanCore.ScanType.ALL],
      enableMultiMode: true,
      enableAlbum: true,
    };

    scanBarcode
      .startScanForResult(this.uiContext, options)
      .then((scanResult: scanBarcode.ScanResult) => {
        hilog.info(0x0000, TAG, 'scan success: %{public}s', scanResult.originalValue);
        result.success(scanResult.originalValue);
      })
      .catch((err: BusinessError) => {
        // 用户取消或系统扫码不可用，统一按取消处理返回 null
        hilog.warn(0x0000, TAG, 'scan canceled/failed: %{public}d %{public}s', err.code, err.message ?? '');
        result.success(null);
      });
  }
}
