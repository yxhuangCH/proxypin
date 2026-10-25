/*
 * Copyright 2023 Hongen Wang All rights reserved.
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

import 'dart:convert';

import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/components/manager/request_rewrite_manager.dart';
import 'package:proxypin/network/components/manager/rewrite_rule.dart';
import 'package:proxypin/network/console/console_store.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/http_client.dart';
import 'package:proxypin/network/http/http_headers.dart';
import 'package:proxypin/network/util/file_read.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/utils/har.dart';

/// 静态资源加载器（默认从 Flutter rootBundle 读取，测试可注入）
typedef ConsoleAssetLoader = Future<List<int>?> Function(String assetPath);

/// Web 控制台：复用代理端口的本地请求分支，提供静态页面与 JSON API。
///
/// 控制台请求不会进入代理转发，也不会出现在抓包列表中（见方案 4.2）。
class WebConsole {
  static const String cookieName = 'proxypin_console_token';
  static const String staticPrefix = '/console';
  static const String apiPrefix = '/api/console';

  /// 是否属于控制台路径
  static bool isConsolePath(String path) {
    return path == staticPrefix ||
        path.startsWith('$staticPrefix/') ||
        path == apiPrefix ||
        path.startsWith('$apiPrefix/');
  }

  /// 处理控制台请求；非控制台路径返回 false（交回现有本地路由）
  static Future<bool> handle(ChannelContext channelContext, HttpRequest request, Channel channel,
      {Configuration? configuration, ConsoleCaptureStore? store, ConsoleAssetLoader? assetLoader}) async {
    var response =
        await route(request, configuration: configuration, store: store, assetLoader: assetLoader);
    if (response == null) {
      return false;
    }
    await channel.writeAndClose(channelContext, response);
    return true;
  }

  /// 纯路由，返回 null 表示不是控制台请求；便于单元测试
  static Future<HttpResponse?> route(HttpRequest request,
      {Configuration? configuration, ConsoleCaptureStore? store, ConsoleAssetLoader? assetLoader}) async {
    var path = request.path;
    if (!isConsolePath(path)) {
      return null;
    }

    var config = configuration ?? await Configuration.instance;
    if (!config.webConsoleEnabled) {
      return _jsonResponse(request, HttpStatus.notFound, {'error': 'web console is disabled'});
    }

    if (!_authorized(request, config)) {
      return _jsonResponse(request, HttpStatus.unauthorized, {'error': 'invalid or missing token'});
    }

    // 首次通过 URL token 访问后种植 Cookie，后续静态资源与 API 同源携带
    var setCookie = request.queries['token'] == config.webConsoleToken ? _cookieValue(config) : null;

    if (path.startsWith(apiPrefix)) {
      return _routeApi(request, config, store ?? ConsoleCaptureStore.current, setCookie: setCookie);
    }

    return _routeStatic(request, path, assetLoader ?? _defaultAssetLoader, setCookie: setCookie);
  }

  static bool _authorized(HttpRequest request, Configuration config) {
    var token = config.webConsoleToken;
    if (token.isEmpty) {
      return false;
    }
    if (request.queries['token'] == token) {
      return true;
    }

    var cookie = request.headers.get('Cookie');
    if (cookie == null || cookie.isEmpty) {
      return false;
    }
    for (var part in cookie.split(';')) {
      var index = part.indexOf('=');
      if (index <= 0) {
        continue;
      }
      var name = part.substring(0, index).trim();
      var value = part.substring(index + 1).trim();
      if (name == cookieName && value == token) {
        return true;
      }
    }
    return false;
  }

  static String _cookieValue(Configuration config) {
    return '$cookieName=${config.webConsoleToken}; Path=/; HttpOnly; SameSite=Strict';
  }

  /// API 路由
  static Future<HttpResponse> _routeApi(HttpRequest request, Configuration config, ConsoleCaptureStore? store,
      {String? setCookie}) async {
    var path = request.path;
    var method = request.method;

    if (path == '$apiPrefix/status' && method == HttpMethod.get) {
      return _jsonResponse(request, HttpStatus.ok, {
        'enabled': config.webConsoleEnabled,
        'port': config.port,
        'revision': store?.revision ?? 0,
        'count': store?.length ?? 0,
      }, setCookie: setCookie);
    }

    if (store == null) {
      return _jsonResponse(request, HttpStatus.serviceUnavailable, {'error': 'capture store unavailable'});
    }

    // 增量请求列表
    if (path == '$apiPrefix/requests' && method == HttpMethod.get) {
      var since = int.tryParse(request.queries['since'] ?? '') ?? 0;
      var entries = since <= 0 ? store.all() : store.sinceRevision(since);
      return _jsonResponse(request, HttpStatus.ok, {
        'revision': store.revision,
        'count': store.length,
        'requests': entries.map(summaryJson).toList(),
      }, setCookie: setCookie);
    }

    // 单条详情
    if (path.startsWith('$apiPrefix/requests/') && method == HttpMethod.get) {
      var id = path.substring('$apiPrefix/requests/'.length);
      var entry = store.get(id);
      if (entry == null) {
        return _jsonResponse(request, HttpStatus.notFound, {'error': 'request not found'});
      }
      return _jsonResponse(request, HttpStatus.ok, await detailJson(entry), setCookie: setCookie);
    }

    // HAR 导出
    if (path == '$apiPrefix/har' && method == HttpMethod.get) {
      var har = await Har.writeJson(store.all().map((e) => e.request).toList());
      var response = HttpResponse(HttpStatus.ok, protocolVersion: request.protocolVersion);
      response.headers.set(HttpHeaders.CONTENT_TYPE, 'application/json; charset=utf-8');
      response.headers.set('Content-Disposition', 'attachment; filename=proxypin-console.har');
      response.headers.set('Cache-Control', 'no-store');
      if (setCookie != null) {
        response.headers.set('Set-Cookie', setCookie);
      }
      response.body = utf8.encode(har);
      return response;
    }

    // 清空控制台数据
    if (path == '$apiPrefix/clear' && method == HttpMethod.post) {
      store.clear();
      return _jsonResponse(request, HttpStatus.ok, {'revision': store.revision}, setCookie: setCookie);
    }

    // 原样重发 / 从记录预填改写规则
    if (path.startsWith('$apiPrefix/requests/')) {
      var segments = path.substring('$apiPrefix/requests/'.length).split('/');
      var id = segments.first;
      var action = segments.length > 1 ? segments[1] : null;

      if (action == 'repeat' && method == HttpMethod.post) {
        return _repeatRequest(request, config, store, id, setCookie: setCookie);
      }
      if (action == 'rewrite' && method == HttpMethod.post) {
        return _prefillRewrite(request, store, id, setCookie: setCookie);
      }
    }

    // 编辑后发送
    if (path == '$apiPrefix/send' && method == HttpMethod.post) {
      return _handleSend(request, config, setCookie: setCookie);
    }

    // 响应改写规则
    if (path == '$apiPrefix/rewrites' || path.startsWith('$apiPrefix/rewrites/')) {
      return _handleRewrites(request, path, method, setCookie: setCookie);
    }

    return _jsonResponse(request, HttpStatus.notFound, {'error': 'not found'});
  }

  /// 原样重发：通过本机代理发送，确保继续经过现有拦截器并出现在列表
  static Future<HttpResponse> _repeatRequest(
      HttpRequest request, Configuration config, ConsoleCaptureStore store, String id,
      {String? setCookie}) async {
    var entry = store.get(id);
    if (entry == null) {
      return _jsonResponse(request, HttpStatus.notFound, {'error': 'request not found'}, setCookie: setCookie);
    }

    var copy = entry.request.copy(uri: entry.request.requestUrl);
    try {
      var response = await HttpClients.proxyRequest(copy, proxyInfo: ProxyInfo.of('127.0.0.1', config.port));
      return _jsonResponse(request, HttpStatus.ok,
          {'status': response.status.code, 'statusText': response.status.reasonPhrase}, setCookie: setCookie);
    } catch (e) {
      return _jsonResponse(request, HttpStatus.badGateway, {'error': e.toString()}, setCookie: setCookie);
    }
  }

  /// 编辑后发送：服务端构造 HttpRequest，不让网页拼接原始报文
  static Future<HttpResponse> _handleSend(HttpRequest request, Configuration config, {String? setCookie}) async {
    HttpRequest sendRequest;
    try {
      var decoded = jsonDecode(request.bodyAsString);
      if (decoded is! Map) {
        throw const FormatException('body must be a JSON object');
      }
      sendRequest = buildSendRequest(decoded);
    } catch (e) {
      return _jsonResponse(request, HttpStatus.badRequest, {'error': e.toString()}, setCookie: setCookie);
    }

    try {
      var response = await HttpClients.proxyRequest(sendRequest, proxyInfo: ProxyInfo.of('127.0.0.1', config.port));
      return _jsonResponse(request, HttpStatus.ok,
          {'status': response.status.code, 'statusText': response.status.reasonPhrase}, setCookie: setCookie);
    } catch (e) {
      return _jsonResponse(request, HttpStatus.badGateway, {'error': e.toString()}, setCookie: setCookie);
    }
  }

  /// 把编辑后发送的 JSON 转为 HttpRequest；非法输入抛 FormatException
  static HttpRequest buildSendRequest(Map<dynamic, dynamic> payload) {
    var url = payload['url']?.toString() ?? '';
    var uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      throw const FormatException('invalid url, expect absolute http(s) url');
    }

    var method = HttpMethod.valueOf(payload['method']?.toString() ?? 'GET');
    var sendRequest = HttpRequest(method, url);

    var headers = payload['headers'];
    if (headers is Map) {
      headers.forEach((key, value) {
        if (key != null && value != null) {
          sendRequest.headers.set(key.toString(), value.toString());
        }
      });
    }

    var bodyText = payload['bodyText'];
    var bodyBase64 = payload['bodyBase64'];
    if (bodyText != null && bodyBase64 != null) {
      throw const FormatException('bodyText and bodyBase64 are mutually exclusive');
    }
    if (bodyBase64 != null) {
      try {
        sendRequest.body = base64Decode(bodyBase64.toString());
      } on FormatException {
        throw const FormatException('invalid bodyBase64');
      }
    } else if (bodyText != null) {
      sendRequest.body = utf8.encode(bodyText.toString());
    }
    if (sendRequest.body != null) {
      sendRequest.headers.contentLength = sendRequest.body!.length;
    }
    return sendRequest;
  }

  /// 从选中请求预填响应改写规则（前端确认后再 POST /rewrites 落盘）
  static HttpResponse _prefillRewrite(HttpRequest request, ConsoleCaptureStore store, String id,
      {String? setCookie}) {
    var entry = store.get(id);
    if (entry == null) {
      return _jsonResponse(request, HttpStatus.notFound, {'error': 'request not found'}, setCookie: setCookie);
    }
    var response = entry.response;
    if (response == null) {
      return _jsonResponse(request, HttpStatus.badRequest, {'error': 'response not captured yet'},
          setCookie: setCookie);
    }

    return _jsonResponse(
        request,
        HttpStatus.ok,
        {
          'name': '${entry.request.method.name} ${entry.request.path}',
          'enabled': true,
          'type': RuleType.responseReplace.name,
          'url': entry.request.domainPath,
          'method': entry.request.method.name,
          'items': RewriteItem.fromResponse(response).map((e) => e.toJson()).toList(),
        },
        setCookie: setCookie);
  }

  /// 重写规则 CRUD，复用 RequestRewriteManager
  static Future<HttpResponse> _handleRewrites(HttpRequest request, String path, HttpMethod method,
      {String? setCookie}) async {
    var manager = await RequestRewriteManager.instance;

    if (path == '$apiPrefix/rewrites') {
      if (method == HttpMethod.get) {
        return _jsonResponse(request, HttpStatus.ok, await manager.toFullJson(), setCookie: setCookie);
      }

      if (method == HttpMethod.post) {
        try {
          var payload = _jsonBody(request);
          await manager.addRule(buildRewriteRule(payload), buildRewriteItems(payload['items']));
          await manager.flushRequestRewriteConfig();
          return _jsonResponse(request, HttpStatus.ok, await manager.toFullJson(), setCookie: setCookie);
        } catch (e) {
          return _jsonResponse(request, HttpStatus.badRequest, {'error': e.toString()}, setCookie: setCookie);
        }
      }
    }

    if (path.startsWith('$apiPrefix/rewrites/')) {
      var index = int.tryParse(path.substring('$apiPrefix/rewrites/'.length));
      if (index == null || index < 0 || index >= manager.rules.length) {
        return _jsonResponse(request, HttpStatus.notFound, {'error': 'rewrite rule not found'}, setCookie: setCookie);
      }

      if (method == HttpMethod.put) {
        try {
          var payload = _jsonBody(request);
          var rule = buildRewriteRule(payload);
          // 沿用原条目的 items 文件，避免每次编辑都产生新文件
          rule.rewritePath = manager.rules[index].rewritePath;
          var items = payload.containsKey('items') ? buildRewriteItems(payload['items']) : null;
          await manager.updateRule(index, rule, items);
          await manager.flushRequestRewriteConfig();
          return _jsonResponse(request, HttpStatus.ok, await manager.toFullJson(), setCookie: setCookie);
        } catch (e) {
          return _jsonResponse(request, HttpStatus.badRequest, {'error': e.toString()}, setCookie: setCookie);
        }
      }

      if (method == HttpMethod.delete) {
        await manager.removeIndex([index]);
        await manager.flushRequestRewriteConfig();
        return _jsonResponse(request, HttpStatus.ok, await manager.toFullJson(), setCookie: setCookie);
      }
    }

    return _jsonResponse(request, HttpStatus.notFound, {'error': 'not found'}, setCookie: setCookie);
  }

  static Map<dynamic, dynamic> _jsonBody(HttpRequest request) {
    var decoded = jsonDecode(request.bodyAsString);
    if (decoded is! Map) {
      throw const FormatException('body must be a JSON object');
    }
    return decoded;
  }

  /// 构造重写规则；非法输入抛异常
  static RequestRewriteRule buildRewriteRule(Map<dynamic, dynamic> payload) {
    return RequestRewriteRule.formJson(payload);
  }

  /// 构造重写条目列表
  static List<RewriteItem> buildRewriteItems(dynamic raw) {
    if (raw is! List) {
      return [];
    }
    return raw.whereType<Map>().map((e) => RewriteItem.fromJson(e)).toList();
  }

  /// 列表摘要（不携带 body，避免长期抓包后接口膨胀）
  static Map<String, dynamic> summaryJson(ConsoleEntry entry) {
    var request = entry.request;
    var response = entry.response;
    return {
      'id': request.requestId,
      'method': request.method.name,
      'url': request.requestUrl,
      'host': request.remoteDomain() ?? '',
      'path': request.pathAndQuery,
      'status': response?.status.code,
      'statusText': response?.status.reasonPhrase,
      'contentType': response?.headers.contentType ?? request.headers.contentType,
      'requestTime': request.requestTime.millisecondsSinceEpoch,
      'responseTime': response?.responseTime.millisecondsSinceEpoch,
      'costTime': response?.responseTime.difference(request.requestTime).inMilliseconds,
      'requestSize': request.body?.length ?? 0,
      'responseSize': response?.body?.length ?? 0,
      'revision': entry.revision,
    };
  }

  /// 单条完整详情（body 按需读取，超出上限截断）
  static Future<Map<String, dynamic>> detailJson(ConsoleEntry entry, {int bodyLimit = maxDetailBodyBytes}) async {
    var request = entry.request;
    var response = entry.response;
    return {
      ...summaryJson(entry),
      'request': {
        'protocolVersion': request.protocolVersion,
        'headers': _headersJson(request),
        'body': await _bodyJson(request, bodyLimit),
      },
      'response': response == null
          ? null
          : {
              'protocolVersion': response.protocolVersion,
              'headers': _headersJson(response),
              'body': await _bodyJson(response, bodyLimit),
            },
    };
  }

  /// 详情接口 body 展示上限
  static const int maxDetailBodyBytes = 256 * 1024;

  static List<Map<String, String>> _headersJson(HttpMessage message) {
    var list = <Map<String, String>>[];
    message.headers.forEach((name, values) {
      for (var value in values) {
        list.add({'name': name, 'value': value});
      }
    });
    return list;
  }

  static Future<Map<String, dynamic>> _bodyJson(HttpMessage message, int bodyLimit) async {
    var body = message.body;
    if (body == null || body.isEmpty) {
      return {'size': 0, 'text': '', 'base64': null, 'encoding': null, 'truncated': false};
    }

    // 二进制返回 base64，避免 String.fromCharCodes 破坏字节
    if (message.contentType.isBinary) {
      var bytes = body.length > bodyLimit ? body.sublist(0, bodyLimit) : body;
      return {
        'size': body.length,
        'text': null,
        'base64': base64Encode(bytes),
        'encoding': 'base64',
        'truncated': body.length > bodyLimit,
      };
    }

    var text = await message.decodeBodyString();
    var truncated = text.length > bodyLimit;
    return {
      'size': body.length,
      'text': truncated ? text.substring(0, bodyLimit) : text,
      'base64': null,
      'encoding': null,
      'truncated': truncated,
    };
  }

  /// 静态资源：/console -> index.html，其余按相对路径读取
  static Future<HttpResponse> _routeStatic(
      HttpRequest request, String path, ConsoleAssetLoader loader, {String? setCookie}) async {
    if (request.method != HttpMethod.get && request.method != HttpMethod.head) {
      return _jsonResponse(request, HttpStatus.valueOf(405), {'error': 'method not allowed'});
    }

    var relative = path == staticPrefix || path == '$staticPrefix/'
        ? 'index.html'
        : path.substring(staticPrefix.length + 1);
    if (relative.isEmpty) {
      relative = 'index.html';
    }
    if (relative.contains('..')) {
      return _jsonResponse(request, HttpStatus.notFound, {'error': 'not found'});
    }

    List<int>? bytes;
    try {
      bytes = await loader('web/console/$relative');
    } catch (e) {
      logger.w('load web console asset failed: $relative $e');
    }
    if (bytes == null) {
      return _jsonResponse(request, HttpStatus.notFound, {'error': 'asset not found'});
    }

    var response = HttpResponse(HttpStatus.ok, protocolVersion: request.protocolVersion);
    response.headers.set(HttpHeaders.CONTENT_TYPE, _contentTypeOf(relative));
    // 控制台页面随时更新，禁用缓存避免浏览器拿到旧版本
    response.headers.set('Cache-Control', 'no-store');
    if (setCookie != null) {
      response.headers.set('Set-Cookie', setCookie);
    }
    if (request.method == HttpMethod.get) {
      response.body = bytes;
    }
    return response;
  }

  static String _contentTypeOf(String name) {
    if (name.endsWith('.html')) return 'text/html; charset=utf-8';
    if (name.endsWith('.js')) return 'application/javascript; charset=utf-8';
    if (name.endsWith('.css')) return 'text/css; charset=utf-8';
    if (name.endsWith('.json')) return 'application/json; charset=utf-8';
    if (name.endsWith('.svg')) return 'image/svg+xml';
    if (name.endsWith('.png')) return 'image/png';
    if (name.endsWith('.ico')) return 'image/x-icon';
    return 'application/octet-stream';
  }

  static HttpResponse _jsonResponse(HttpRequest request, HttpStatus status, Object body, {String? setCookie}) {
    var response = HttpResponse(status, protocolVersion: request.protocolVersion);
    response.headers.set(HttpHeaders.CONTENT_TYPE, 'application/json; charset=utf-8');
    response.headers.set('Cache-Control', 'no-store');
    if (setCookie != null) {
      response.headers.set('Set-Cookie', setCookie);
    }
    response.body = utf8.encode(jsonEncode(body));
    return response;
  }

  static Future<List<int>?> _defaultAssetLoader(String assetPath) async {
    try {
      return await FileRead.read(assetPath);
    } catch (e) {
      logger.w('web console asset not found: $assetPath');
      return null;
    }
  }
}
