/*
 * Copyright 2023 Hongen Wang
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/// 鸿蒙预置应用清单
///
/// 背景：鸿蒙三方应用无法枚举已安装应用（需企业权限，见 harmony/docs/09 第 5 节），
/// 白名单/黑名单选择页在鸿蒙上降级为「手动输入 bundleName + 预置清单」。
///
/// 标注 [verified] 的包名取自真机（HarmonyOS 6.1.1.120，API 24）`bm dump -a` 实测；
/// 未标注的三方包名按各厂商已上架 HarmonyOS NEXT 版本的常见命名整理，**可能随版本变化**，
/// 若配置后抓不到流量，以手动输入准确包名为准。
class OhosPresetApp {
  final String name;
  final String bundleName;

  /// 是否经真机实测确认
  final bool verified;

  const OhosPresetApp(this.name, this.bundleName, {this.verified = false});
}

/// 华为自带应用
const List<OhosPresetApp> _systemApps = [
  OhosPresetApp('浏览器 Browser', 'com.huawei.hmos.browser', verified: true),
  OhosPresetApp('应用市场 AppGallery', 'com.huawei.hmsapp.appgallery', verified: true),
  OhosPresetApp('音乐 Music', 'com.huawei.hmsapp.music', verified: true),
  OhosPresetApp('视频 Video', 'com.huawei.hmos.videoplayer', verified: true),
  OhosPresetApp('主题 Themes', 'com.huawei.hmsapp.thememanager', verified: true),
  OhosPresetApp('游戏中心 GameCenter', 'com.huawei.hmsapp.gamecenter', verified: true),
  OhosPresetApp('天气 Weather', 'com.huawei.hms.weather', verified: true),
  OhosPresetApp('运动健康 Health', 'com.huawei.hmos.health', verified: true),
  OhosPresetApp('图库 Gallery', 'com.huawei.hmos.photos', verified: true),
  OhosPresetApp('备忘录 Notes', 'com.huawei.hmos.notepad', verified: true),
  OhosPresetApp('日历 Calendar', 'com.huawei.hmos.calendar', verified: true),
  OhosPresetApp('时钟 Clock', 'com.huawei.hmos.clock', verified: true),
  OhosPresetApp('相机 Camera', 'com.huawei.hmos.camera', verified: true),
  OhosPresetApp('邮件 Email', 'com.huawei.hmos.email', verified: true),
  OhosPresetApp('文件管理 Files', 'com.huawei.hmos.filemanager', verified: true),
  OhosPresetApp('云空间 Cloud', 'com.huawei.hmos.clouddrive', verified: true),
  OhosPresetApp('钱包 Wallet', 'com.huawei.hmos.wallet', verified: true),
];

/// 常用三方应用
const List<OhosPresetApp> _thirdPartyApps = [
  OhosPresetApp('支付宝 Alipay', 'com.alipay.mobile.client', verified: true),
  OhosPresetApp('美团 Meituan', 'com.sankuai.hmeituan', verified: true),
  OhosPresetApp('美团外卖 Meituan Waimai', 'com.meituan.takeaway', verified: true),
  OhosPresetApp('拼多多 Pinduoduo', 'com.xunmeng.pinduoduo.hos', verified: true),
  OhosPresetApp('WPS Office', 'cn.wps.mobileoffice.hap', verified: true),
  OhosPresetApp('微信 WeChat', 'com.tencent.wechat'),
  OhosPresetApp('抖音 Douyin', 'com.ss.hm.ugc.aweme'),
  OhosPresetApp('淘宝 Taobao', 'com.taobao.taobao'),
  OhosPresetApp('京东 JD', 'com.jd.hm.mall'),
  OhosPresetApp('小红书 RED', 'com.xingin.xhs'),
  OhosPresetApp('哔哩哔哩 Bilibili', 'com.bilibili.hmos'),
];

const List<OhosPresetApp> ohosPresetApps = [..._systemApps, ..._thirdPartyApps];

/// 按包名反查预置清单里的显示名；未收录时返回 null（调用方回落为包名）
String? ohosPresetAppName(String bundleName) {
  for (final app in ohosPresetApps) {
    if (app.bundleName == bundleName) {
      return app.name;
    }
  }
  return null;
}
