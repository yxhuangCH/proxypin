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
 *
 * 实现参考 share_plus_ohos (https://github.com/ClosedHarmony/share_plus_ohos, Apache-2.0)。
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
import systemShare from '@hms.collaboration.systemShare';
import uniformTypeDescriptor from '@ohos.data.uniformTypeDescriptor';
import { fileUri } from '@kit.CoreFileKit';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG: string = 'ProxyPinSharePlugin';
const CHANNEL_NAME: string = 'proxypin/share';

/**
 * ProxyPin 自研鸿蒙分享插件：打开系统分享面板（Share Kit）。
 * share_plus 暂无 ohos 官方实现，且其 ohos 适配版要求 share_plus 13 依赖链，
 * 为不动全平台依赖而自研。Dart 侧入口 lib/utils/share.dart。
 */
export default class ProxyPinSharePlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  // Share Kit 分享面板必须锚定 UIAbilityContext，applicationContext 会报 ShowCallback failed(6)
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
    try {
      switch (call.method) {
        case 'shareText': {
          this.shareText(call, result);
          break;
        }
        case 'shareUri': {
          this.shareUri(call, result);
          break;
        }
        case 'shareFiles': {
          this.shareFiles(call, result);
          break;
        }
        default: {
          result.notImplemented();
        }
      }
    } catch (e) {
      const err = e as BusinessError;
      result.error('SHARE_ERROR', err.message ?? `${e}`, null);
    }
  }

  private stringArg(call: MethodCall, key: string): string {
    const map: ESObject = call.args;
    const value: ESObject = map.get(key);
    return value == null ? '' : `${value}`;
  }

  private shareText(call: MethodCall, result: MethodResult): void {
    const text = this.stringArg(call, 'text');
    if (text.length === 0) {
      result.error('EMPTY_CONTENT', 'Nothing to share', null);
      return;
    }
    const record: systemShare.SharedRecord = {
      utd: uniformTypeDescriptor.UniformDataType.PLAIN_TEXT,
      content: text,
    };
    const title = this.stringArg(call, 'title');
    if (title.length > 0) {
      record.title = title;
    }
    const subject = this.stringArg(call, 'subject');
    if (subject.length > 0) {
      record.description = subject;
    }
    this.show([record], result);
  }

  private shareUri(call: MethodCall, result: MethodResult): void {
    const uri = this.stringArg(call, 'uri');
    if (uri.length === 0) {
      result.error('EMPTY_CONTENT', 'Nothing to share', null);
      return;
    }
    const record: systemShare.SharedRecord = {
      utd: uniformTypeDescriptor.UniformDataType.HYPERLINK,
      content: uri,
    };
    const title = this.stringArg(call, 'title');
    if (title.length > 0) {
      record.title = title;
    }
    this.show([record], result);
  }

  private shareFiles(call: MethodCall, result: MethodResult): void {
    const map: ESObject = call.args;
    const paths: ESObject = map.get('paths');
    const names: ESObject = map.get('names');
    if (paths == null || paths.length === 0) {
      result.error('EMPTY_CONTENT', 'No files to share', null);
      return;
    }
    const records: systemShare.SharedRecord[] = [];
    for (let i = 0; i < paths.length; i++) {
      const path: string = `${paths[i]}`;
      const record: systemShare.SharedRecord = {
        utd: this.utdForPath(path),
        uri: fileUri.getUriFromPath(path),
      };
      if (names != null && i < names.length && names[i] != null && `${names[i]}`.length > 0) {
        record.title = `${names[i]}`;
      }
      records.push(record);
    }
    // 附带说明文本（如分享文件时的标题）
    const text = this.stringArg(call, 'text');
    if (text.length > 0) {
      records.push({
        utd: uniformTypeDescriptor.UniformDataType.PLAIN_TEXT,
        content: text,
      });
    }
    this.show(records, result);
  }

  private utdForPath(path: string): string {
    const lower = path.toLowerCase();
    if (
      lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.webp') ||
      lower.endsWith('.bmp')
    ) {
      return uniformTypeDescriptor.UniformDataType.IMAGE;
    }
    return uniformTypeDescriptor.UniformDataType.FILE;
  }

  private show(records: systemShare.SharedRecord[], result: MethodResult): void {
    const data = new systemShare.SharedData(records[0]);
    for (let i = 1; i < records.length; i++) {
      data.addRecord(records[i]);
    }
    const controller = new systemShare.ShareController(data);
    controller
      .show(this.uiContext, { selectionMode: systemShare.SelectionMode.SINGLE })
      .then(() => {
        result.success(null);
      })
      .catch((err: BusinessError) => {
        result.error('SHARE_FAILED', `${err.code}: ${err.message}`, null);
      });
  }
}
