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
import { PiPWindow, typeNode } from '@kit.ArkUI';
import { NodeController, FrameNode } from '@kit.ArkUI';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'ProxyPinPipPlugin';
const CHANNEL_NAME: string = 'com.proxy/pictureInPicture';
const LIFECYCLE_CHANNEL_NAME: string = 'com.proxy/appLifecycle';
/** 小窗保留的最近请求行数 */
const MAX_LINES: number = 12;

/** 控制面板回调目标：VpnPlugin 显式 implements（ArkTS 不支持结构化类型） */
export interface VpnPipControl {
  startVpnFromPip(): void;

  stopVpnFromPip(): void;
}

/**
 * 小窗覆盖层：以原生 Text 列表渲染最近请求 URL。
 * PiP customUIController 为覆盖在内容之上的自定义布局（只读、不可交互）。
 */
class PipOverlayController extends NodeController {
  private lines: string[] = [];

  setLines(lines: string[]): void {
    this.lines = lines;
    this.rebuild();
  }

  makeNode(uiContext: UIContext): FrameNode | null {
    const col = typeNode.createNode(uiContext, 'Column');
    col.initialize();
    const colAttr = typeNode.getAttribute(col, 'Column');
    colAttr?.width('100%');
    colAttr?.height('100%');
    colAttr?.backgroundColor(0xF2FFFFFF);
    colAttr?.padding(14);
    colAttr?.justifyContent(FlexAlign.Center);
    for (const line of this.lines) {
      const text = typeNode.createNode(uiContext, 'Text');
      text.initialize(line);
      const textAttr = typeNode.getAttribute(text, 'Text');
      textAttr?.fontSize(13);
      textAttr?.fontColor(0xFF333333);
      textAttr?.maxLines(1);
      textAttr?.textOverflow({ overflow: TextOverflow.Ellipsis });
      textAttr?.margin({ top: 4, bottom: 4 });
      col.appendChild(text);
    }
    return col;
  }
}

/**
 * ProxyPin 鸿蒙画中画插件（channel 与 Android PictureInPicturePlugin 同名，
 * Dart 侧 lib/native/pip.dart 零改动）。
 *
 * 实现路线（harmony/docs/10，POC 结论后采用 Plan B）：
 * - POC 证实复用 Flutter 渲染面（getAttachedFrameNodeById 取 XComponent）会得到白屏小窗：
 *   Flutter 的 XComponent 由引擎直管 surface，已挂树的节点无法被 PiP 重挂载；
 * - 因此使用 typeNode.createNode 离屏创建自有 SURFACE XComponent 作为内容占位，
 *   再以 customUIController 覆盖层渲染最近请求 URL（只读）；
 * - setAutoStartEnabled(true) 让系统在 Home 手势退后台时自动进入小窗；
 * - stateChange 经 `com.proxy/appLifecycle` 的 `onPictureInPictureModeChanged` 回传 Dart。
 *
 * 控制面板（对齐 Android 语义，图标受平台预定义控件限制）：
 * - VIDEO_LIVE 模板 + VIDEO_PLAY_PAUSE：播放/暂停 = 启动/停止 VPN；
 * - MUTE_SWITCH：系统无垃圾桶图标，以喇叭（静音）图标代替「清空请求」，
 *   点击后经 cleanSession 通知 Dart 清理会话。
 */
export default class ProxyPinPipPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private lifecycleChannel: MethodChannel | null = null;
  private uiContext: common.UIAbilityContext;
  private controller: PiPWindow.PiPController | null = null;
  private xcompController: XComponentController | null = null;
  private overlay: PipOverlayController | null = null;
  private lines: string[] = [];
  private enabled: boolean = false;
  private vpnRunning: boolean = false;
  private inPip: boolean = false;
  private vpnControl: VpnPipControl | null = null;

  constructor(uiContext: common.UIAbilityContext) {
    this.uiContext = uiContext;
  }

  /// 注入 VPN 启停回调（EntryAbility 装配）：播放/暂停键 → 启动/停止 VPN
  setVpnControl(vpnControl: VpnPipControl): void {
    this.vpnControl = vpnControl;
  }

  /// VPN 状态变化（由 ProxyPinVpnPlugin 注入回调）：与 enabled 共同决定 arm/disarm
  onVpnStateChanged(running: boolean): void {
    this.vpnRunning = running;
    this.reconcile();
  }

  /// enabled && vpnRunning → arm（预创建控制器 + 允许自动拉起）；
  /// VPN 停止时若小窗仍显示则保留窗口（对齐 Android：可点播放键重启），否则 disarm
  private reconcile(): void {
    hilog.info(0x0000, TAG, 'reconcile enabled=%{public}s vpn=%{public}s inPip=%{public}s',
      `${this.enabled}`, `${this.vpnRunning}`, `${this.inPip}`);
    if (this.enabled && this.vpnRunning) {
      if (!PiPWindow.isPiPEnabled()) {
        return;
      }
      this.arm().catch((e: BusinessError) => {
        hilog.warn(0x0000, TAG, 'arm failed: %{public}d %{public}s', e.code ?? -1, e.message ?? '');
      });
    } else if (this.enabled && this.inPip) {
      this.controller?.setAutoStartEnabled(false);
      this.updatePlayPauseStatus(false);
    } else {
      this.disarm();
    }
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(
      binding.getBinaryMessenger(),
      CHANNEL_NAME,
      StandardMethodCodec.INSTANCE,
    );
    this.channel.setMethodCallHandler(this);
    this.lifecycleChannel = new MethodChannel(
      binding.getBinaryMessenger(),
      LIFECYCLE_CHANNEL_NAME,
      StandardMethodCodec.INSTANCE,
    );
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
    this.lifecycleChannel = null;
    this.controller?.off('stateChange');
    this.controller?.off('controlPanelActionEvent');
    this.controller = null;
    this.xcompController = null;
    this.overlay = null;
    this.inPip = false;
  }

  getUniqueClassName(): string {
    return TAG;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'enterPictureInPictureMode':
        this.enterPip(result);
        break;
      case 'exitPictureInPictureMode':
        this.exitPip(result);
        break;
      case 'setEnabled': {
        const args: ESObject = call.args;
        const enabled: boolean = args.get('enabled') === true;
        this.setEnabled(enabled, result);
        break;
      }
      case 'addData': {
        const text: string = `${call.args ?? ''}`;
        if (text.length > 0) {
          this.pushLine(text);
        }
        result.success(null);
        break;
      }
      case 'clearData':
        this.clearLines();
        result.success(null);
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  /// 清空最近请求缓冲（Dart 侧会话清理时同步，避免小窗残留已清除的条目）
  private clearLines(): void {
    this.lines = [];
    if (this.inPip) {
      this.overlay?.setLines([]);
    }
  }

  /// 追加一行最近请求，保持最多 MAX_LINES 行；仅小窗中刷新覆盖层
  private pushLine(text: string): void {
    this.lines.push(text);
    if (this.lines.length > MAX_LINES) {
      this.lines.splice(0, this.lines.length - MAX_LINES);
    }
    if (this.inPip) {
      this.overlay?.setLines([...this.lines]);
    }
  }

  private onPipStateChange(state: PiPWindow.PiPState, reason: string): void {
    hilog.info(0x0000, TAG, 'pip stateChange: %{public}d reason=%{public}s', state as number, reason);
    if (state === PiPWindow.PiPState.STARTED && !this.inPip) {
      this.inPip = true;
      this.overlay?.setLines([...this.lines]);
      this.updatePlayPauseStatus(this.vpnRunning);
      this.lifecycleChannel?.invokeMethod('onPictureInPictureModeChanged', true);
    } else if ((state === PiPWindow.PiPState.ABOUT_TO_RESTORE || state === PiPWindow.PiPState.STOPPED)
      && this.inPip) {
      this.inPip = false;
      this.lifecycleChannel?.invokeMethod('onPictureInPictureModeChanged', false);
      // 退出小窗且 VPN 未运行：释放控制器（VPN 运行中则保持 arm，便于再次自动拉起）
      if (!(this.enabled && this.vpnRunning)) {
        this.disarm();
      }
    }
  }

  /// 同步播放/暂停键状态（running → 暂停图标，stopped → 播放图标），对齐 Android
  private updatePlayPauseStatus(running: boolean): void {
    const controller = this.controller;
    if (controller == null) {
      return;
    }
    try {
      controller.updatePiPControlStatus(PiPWindow.PiPControlType.VIDEO_PLAY_PAUSE,
        running ? PiPWindow.PiPControlStatus.PLAY : PiPWindow.PiPControlStatus.PAUSE);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG, 'updatePiPControlStatus failed: %{public}d %{public}s', err.code ?? -1, err.message ?? '');
    }
  }

  /// 小窗「清空」按钮（喇叭图标）：先清本地缓冲（立即反馈），再通知 Dart 清理会话
  private clearSessionFromPip(): void {
    this.clearLines();
    this.channel?.invokeMethod('cleanSession', null);
  }

  private async ensureController(): Promise<PiPWindow.PiPController> {
    if (this.controller != null) {
      return this.controller;
    }
    const windowUIContext = this.uiContext.windowStage.getMainWindowSync().getUIContext();
    // 离屏 SURFACE XComponent 作为 PiP 内容占位（内容由覆盖层承载）
    this.xcompController = new XComponentController();
    const options: XComponentOptions = {
      type: XComponentType.SURFACE,
      controller: this.xcompController,
    };
    const contentNode = typeNode.createNode(windowUIContext, 'XComponent', options);
    this.overlay = new PipOverlayController();
    const config: PiPWindow.PiPConfiguration = {
      context: this.uiContext,
      componentController: this.xcompController,
      // 9:19 竖屏比例，对齐 Android Rational(9, 19)
      contentWidth: 640,
      contentHeight: 1350,
      // 控制面板仅支持预定义控件（doc10 §2.3）：
      // - 播放/暂停 = 启动/停止 VPN（图标与 Android 一致）
      // - 喇叭（静音）图标代替「清空请求」（系统无垃圾桶图标）
      templateType: PiPWindow.PiPTemplateType.VIDEO_LIVE,
      controlGroups: [
        PiPWindow.VideoLiveControlGroup.VIDEO_PLAY_PAUSE,
        PiPWindow.VideoLiveControlGroup.MUTE_SWITCH,
      ],
      customUIController: this.overlay,
    };
    const controller = await PiPWindow.create(config, contentNode);
    controller.on('stateChange', (state: PiPWindow.PiPState, reason: string) => {
      this.onPipStateChange(state, reason);
    });
    controller.on('controlPanelActionEvent', (event: PiPWindow.PiPActionEventType, status?: number) => {
      if (event === 'playbackStateChanged') {
        // status 为目标状态：PAUSE → 停止 VPN；PLAY → 启动 VPN
        if (status === PiPWindow.PiPControlStatus.PAUSE) {
          hilog.info(0x0000, TAG, 'pip pause → stop vpn');
          this.updatePlayPauseStatus(false);
          this.vpnControl?.stopVpnFromPip();
        } else if (status === PiPWindow.PiPControlStatus.PLAY) {
          hilog.info(0x0000, TAG, 'pip play → start vpn');
          this.updatePlayPauseStatus(true);
          this.vpnControl?.startVpnFromPip();
        }
      } else if (event === 'voiceStateChanged') {
        hilog.info(0x0000, TAG, 'pip mute → clear session');
        this.clearSessionFromPip();
      }
    });
    this.controller = controller;
    hilog.info(0x0000, TAG, 'pip controller created');
    return controller;
  }

  /// 开启：预创建控制器并允许系统自动拉起小窗
  private async arm(): Promise<void> {
    const controller = await this.ensureController();
    controller.setAutoStartEnabled(true);
    this.updatePlayPauseStatus(this.vpnRunning);
  }

  /// 关闭：退出小窗、禁用自动拉起并销毁控制器
  private async disarm(): Promise<void> {
    const controller = this.controller;
    if (controller == null) {
      return;
    }
    try {
      controller.setAutoStartEnabled(false);
      if (this.inPip) {
        await controller.stopPiP();
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(0x0000, TAG, 'disarm failed: %{public}d %{public}s', err.code ?? -1, err.message ?? '');
    }
    controller.off('stateChange');
    controller.off('controlPanelActionEvent');
    this.controller = null;
    this.xcompController = null;
    this.overlay = null;
    this.inPip = false;
  }

  private async setEnabled(enabled: boolean, result: MethodResult): Promise<void> {
    hilog.info(0x0000, TAG, 'setEnabled %{public}s', `${enabled}`);
    this.enabled = enabled;
    if (!enabled || !this.vpnRunning) {
      await this.disarm();
      result.success(null);
      return;
    }
    try {
      if (!PiPWindow.isPiPEnabled()) {
        result.success(false);
        return;
      }
      await this.arm();
      result.success(true);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'setEnabled failed: %{public}d %{public}s', err.code ?? -1, err.message ?? '');
      result.success(false);
    }
  }

  private async enterPip(result: MethodResult): Promise<void> {
    try {
      if (!PiPWindow.isPiPEnabled()) {
        hilog.warn(0x0000, TAG, 'PiP not enabled on this device');
        result.success(false);
        return;
      }
      const controller = await this.ensureController();
      await controller.startPiP();
      hilog.info(0x0000, TAG, 'startPiP ok');
      result.success(true);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'enterPip failed: %{public}d %{public}s', err.code ?? -1, err.message ?? '');
      result.success(false);
    }
  }

  private async exitPip(result: MethodResult): Promise<void> {
    try {
      if (this.controller != null && this.inPip) {
        await this.controller.stopPiP();
      }
      result.success(true);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'exitPip failed: %{public}d %{public}s', err.code ?? -1, err.message ?? '');
      result.success(false);
    }
  }
}
