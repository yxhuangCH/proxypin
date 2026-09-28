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
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { window } from '@kit.ArkUI';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'ProxyPinKeepAlivePlugin';
const CHANNEL_NAME: string = 'proxypin/keepalive';

/**
 * ProxyPin 自研鸿蒙后台保活插件：
 * - start/stop：申请/释放 dataTransfer 类型长时任务（需 ohos.permission.KEEP_BACKGROUND_RUNNING
 *   且 module.json5 声明 backgroundModes），降低退后台后代理 socket 被挂起的概率；
 * - setKeepScreenOn：设置窗口常亮（wakelock 兜底，配合"前台常亮"设置项）。
 * Dart 侧入口 lib/native/keep_alive.dart，仅在 Platforms.isOhos() 时调用。
 */
export default class ProxyPinKeepAlivePlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private uiContext: common.UIAbilityContext;
  private running: boolean = false;

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
    switch (call.method) {
      case 'start':
        this.startKeepAlive(result);
        break;
      case 'stop':
        this.stopKeepAlive(result);
        break;
      case 'setKeepScreenOn':
        this.setKeepScreenOn(call, result);
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  /// 申请长时任务；失败（如系统拒绝）返回 false，由 Dart 侧降级为前台提示
  private async startKeepAlive(result: MethodResult): Promise<void> {
    if (this.running) {
      result.success(true);
      return;
    }

    try {
      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: this.uiContext.abilityInfo.bundleName,
            abilityName: this.uiContext.abilityInfo.name,
          },
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
      };
      // 注意：本 SDK 未导出 WantAgent 类型，用 Object 承接（startBackgroundRunning 入参为 object）
      const agent: Object = await wantAgent.getWantAgent(wantAgentInfo);
      await backgroundTaskManager.startBackgroundRunning(
        this.uiContext,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
        agent,
      );
      this.running = true;
      hilog.info(0x0000, TAG, 'continuous task started');
      result.success(true);
    } catch (e) {
      const err = e as BusinessError;
      // 常见：201 权限未授予 / 9800001 系统拒绝（上架审核风险项），降级处理不阻断代理启动
      hilog.warn(0x0000, TAG, 'start continuous task failed: %{public}d %{public}s', err.code, err.message ?? '');
      this.running = false;
      result.success(false);
    }
  }

  private async stopKeepAlive(result: MethodResult): Promise<void> {
    if (!this.running) {
      result.success(null);
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.uiContext);
      this.running = false;
      hilog.info(0x0000, TAG, 'continuous task stopped');
      result.success(null);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG, 'stop continuous task failed: %{public}d %{public}s', err.code, err.message ?? '');
      this.running = false;
      result.error('KEEP_ALIVE_STOP_FAILED', `${err.code}: ${err.message}`, null);
    }
  }

  private async setKeepScreenOn(call: MethodCall, result: MethodResult): Promise<void> {
    const map: ESObject = call.args;
    const on: boolean = map.get('on') === true;
    try {
      const win: window.Window = await window.getLastWindow(this.uiContext);
      win.setWindowKeepScreenOn(on);
      hilog.info(0x0000, TAG, 'keep screen on: %{public}s', `${on}`);
      result.success(null);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG, 'set keep screen on failed: %{public}d %{public}s', err.code, err.message ?? '');
      result.error('KEEP_SCREEN_ON_FAILED', `${err.code}: ${err.message}`, null);
    }
  }
}
