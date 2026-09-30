import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import ProxyPinSharePlugin from '../plugins/ProxyPinSharePlugin';
import ProxyPinScanPlugin from '../plugins/ProxyPinScanPlugin';
import ProxyPinKeepAlivePlugin from '../plugins/ProxyPinKeepAlivePlugin';
import ProxyPinVpnPlugin from '../plugins/ProxyPinVpnPlugin';
import ProxyPinProcessInfoPlugin from '../plugins/ProxyPinProcessInfoPlugin';

/**
 * ProxyPin 鸿蒙入口 Ability。
 * Flutter 引擎由 FlutterAbility 托管；插件在 configureFlutterEngine 中注册。
 */
export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine);
    GeneratedPluginRegistrant.registerWith(flutterEngine);
    // 自研插件（不经过 pub，需手工注册）
    flutterEngine.getPlugins()?.add(new ProxyPinSharePlugin(this.context));
    flutterEngine.getPlugins()?.add(new ProxyPinScanPlugin(this.context));
    flutterEngine.getPlugins()?.add(new ProxyPinKeepAlivePlugin(this.context));
    flutterEngine.getPlugins()?.add(new ProxyPinVpnPlugin(this.context));
    flutterEngine.getPlugins()?.add(new ProxyPinProcessInfoPlugin());
  }
}
