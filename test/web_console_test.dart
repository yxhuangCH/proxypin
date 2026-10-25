import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/components/manager/rewrite_rule.dart';
import 'package:proxypin/network/console/console_store.dart';
import 'package:proxypin/network/console/web_console.dart';
import 'package:proxypin/network/http/http.dart';

void main() {
  Configuration config({bool enabled = true, String token = 'secret-token'}) {
    var c = Configuration.fromJson({});
    c.webConsoleEnabled = enabled;
    c.webConsoleToken = token;
    return c;
  }

  HttpRequest request(String pathAndQuery, {HttpMethod method = HttpMethod.get}) {
    return HttpRequest(method, 'http://192.168.1.10:9099$pathAndQuery');
  }

  Future<List<int>?> fakeLoader(String assetPath) async {
    if (assetPath == 'web/console/index.html') {
      return utf8.encode('<html>console</html>');
    }
    if (assetPath == 'web/console/app.js') {
      return utf8.encode('// js');
    }
    return null;
  }

  group('路由骨架', () {
    test('非控制台路径不拦截', () async {
      var response = await WebConsole.route(request('/ping'), configuration: config());
      expect(response, isNull);
    });

    test('控制台关闭时统一 404', () async {
      var response = await WebConsole.route(request('/console?token=secret-token'),
          configuration: config(enabled: false));
      expect(response?.status.code, 404);
    });

    test('token 缺失或错误返回 401', () async {
      var missing = await WebConsole.route(request('/api/console/status'), configuration: config());
      expect(missing?.status.code, 401);

      var wrong = await WebConsole.route(request('/api/console/status?token=wrong'), configuration: config());
      expect(wrong?.status.code, 401);
    });

    test('空 token 时始终拒绝', () async {
      var response =
          await WebConsole.route(request('/api/console/status'), configuration: config(token: ''));
      expect(response?.status.code, 401);
    });

    test('URL token 授权并种植 HttpOnly Cookie', () async {
      var response = await WebConsole.route(request('/console?token=secret-token'),
          configuration: config(), assetLoader: fakeLoader);
      expect(response?.status.code, 200);
      var cookie = response?.headers.get('Set-Cookie');
      expect(cookie, contains('${WebConsole.cookieName}=secret-token'));
      expect(cookie, contains('HttpOnly'));
      expect(cookie, contains('SameSite=Strict'));
    });

    test('Cookie 授权访问 API', () async {
      var req = request('/api/console/status');
      req.headers.set('Cookie', 'a=b; ${WebConsole.cookieName}=secret-token; c=d');
      var response = await WebConsole.route(req, configuration: config());
      expect(response?.status.code, 200);
    });

    test('/console 返回 index.html', () async {
      var response = await WebConsole.route(request('/console?token=secret-token'),
          configuration: config(), assetLoader: fakeLoader);
      expect(utf8.decode(response!.body!), contains('console'));
      expect(response.headers.get('Content-Type'), contains('text/html'));
    });

    test('/console/ 与静态资源', () async {
      var index = await WebConsole.route(request('/console/?token=secret-token'),
          configuration: config(), assetLoader: fakeLoader);
      expect(index?.status.code, 200);

      var js = await WebConsole.route(request('/console/app.js?token=secret-token'),
          configuration: config(), assetLoader: fakeLoader);
      expect(js?.status.code, 200);
      expect(js?.headers.get('Content-Type'), contains('javascript'));
    });

    test('路径穿越不会读到控制台之外的文件', () async {
      // Uri 规范化后 /console/../config 变为 /config，不进入控制台分支
      var normalized = await WebConsole.route(request('/console/../config?token=secret-token'),
          configuration: config(), assetLoader: fakeLoader);
      expect(normalized, isNull);

      // 编码后的 .. 同样在 Uri 解析阶段被规范化，不会进入控制台
      var encoded = await WebConsole.route(request('/console/%2e%2e/config?token=secret-token'),
          configuration: config(), assetLoader: fakeLoader);
      expect(encoded, isNull);
    });

    test('资源缺失返回 404', () async {
      var response = await WebConsole.route(request('/console/missing.js?token=secret-token'),
          configuration: config(), assetLoader: fakeLoader);
      expect(response?.status.code, 404);
    });

    test('静态资源只允许 GET/HEAD', () async {
      var response = await WebConsole.route(
          request('/console/app.js?token=secret-token', method: HttpMethod.post),
          configuration: config(),
          assetLoader: fakeLoader);
      expect(response?.status.code, 405);
    });

    test('status 返回开关、端口与 revision', () async {
      var store = ConsoleCaptureStore();
      var response = await WebConsole.route(request('/api/console/status?token=secret-token'),
          configuration: config(), store: store);
      var body = jsonDecode(utf8.decode(response!.body!));
      expect(body['enabled'], isTrue);
      expect(body['port'], 9099);
      expect(body['revision'], store.revision);
      expect(body['count'], 0);
    });
  });

  group('只读 API', () {
    HttpRequest newRequest(String id, {HttpMethod method = HttpMethod.get, String url = 'http://example.com/x'}) {
      return HttpRequest(method, url)..requestId = id;
    }

    HttpResponse newResponse({String contentType = 'application/json; charset=utf-8', List<int>? body}) {
      return HttpResponse(HttpStatus.ok)
        ..headers.set('Content-Type', contentType)
        ..body = body;
    }

    Future<Map<String, dynamic>> callApi(
      String pathAndQuery, {
      required ConsoleCaptureStore store,
      HttpMethod method = HttpMethod.get,
    }) async {
      var response = await WebConsole.route(request(pathAndQuery, method: method),
          configuration: config(enabled: true), store: store);
      return jsonDecode(utf8.decode(response!.body!));
    }

    test('增量列表 since 无重复无遗漏', () async {
      var store = ConsoleCaptureStore();
      store.addRequest(newRequest('a'));
      store.addRequest(newRequest('b'));
      store.addRequest(newRequest('c'));

      var first = await callApi('/api/console/requests?token=secret-token&since=0', store: store);
      expect(first['requests'], hasLength(3));
      expect(first['revision'], 3);

      var sinceOne = await callApi('/api/console/requests?token=secret-token&since=1', store: store);
      expect((sinceOne['requests'] as List).map((e) => e['id']), ['b', 'c']);

      var latest = await callApi('/api/console/requests?token=secret-token&since=3', store: store);
      expect(latest['requests'], isEmpty);
      expect(latest['revision'], 3);
    });

    test('列表摘要不含 body', () async {
      var store = ConsoleCaptureStore();
      var req = newRequest('a', method: HttpMethod.post, url: 'http://example.com/login?x=1');
      req.body = utf8.encode('{"user":"u"}');
      store.addRequest(req);
      store.addResponse(newResponse(body: utf8.encode('{"ok":true}')), req);

      var body = await callApi('/api/console/requests?token=secret-token', store: store);
      var item = (body['requests'] as List).single;
      expect(item['method'], 'POST');
      expect(item['url'], 'http://example.com/login?x=1');
      expect(item['path'], '/login?x=1');
      expect(item['status'], 200);
      expect(item['requestSize'], req.body!.length);
      expect(item.containsKey('request'), isFalse);
      expect(item.containsKey('body'), isFalse);
    });

    test('详情返回头与文本 body', () async {
      var store = ConsoleCaptureStore();
      var req = newRequest('a', method: HttpMethod.post, url: 'http://example.com/api');
      req.headers.set('X-Test', 'v');
      req.body = utf8.encode('request-body');
      store.addRequest(req);
      var resp = newResponse(body: utf8.encode('{"ok":true}'));
      resp.headers.set('X-Resp', 'r');
      store.addResponse(resp, req);

      var detail = await callApi('/api/console/requests/a?token=secret-token', store: store);
      expect(detail['id'], 'a');
      expect(detail['request']['body']['text'], 'request-body');
      expect(detail['request']['body']['truncated'], isFalse);
      expect((detail['request']['headers'] as List).any((e) => e['name'] == 'X-Test'), isTrue);
      expect(detail['response']['body']['text'], '{"ok":true}');
      expect((detail['response']['headers'] as List).any((e) => e['name'] == 'X-Resp'), isTrue);
    });

    test('二进制 body 返回 base64', () async {
      var store = ConsoleCaptureStore();
      var req = newRequest('a');
      store.addRequest(req);
      var bytes = [0x89, 0x50, 0x4e, 0x47, 0x00, 0xff];
      store.addResponse(newResponse(contentType: 'image/png', body: bytes), req);

      var detail = await callApi('/api/console/requests/a?token=secret-token', store: store);
      var body = detail['response']['body'];
      expect(body['encoding'], 'base64');
      expect(body['text'], isNull);
      expect(base64Decode(body['base64']), bytes);
      expect(body['size'], bytes.length);
    });

    test('大 body 截断并标记', () async {
      var store = ConsoleCaptureStore();
      var req = newRequest('a');
      store.addRequest(req);
      store.addResponse(newResponse(contentType: 'text/plain', body: utf8.encode('0123456789')), req);

      var detail = await WebConsole.detailJson(store.get('a')!, bodyLimit: 4);
      var body = detail['response']['body'];
      expect(body['text'], '0123');
      expect(body['truncated'], isTrue);
      expect(body['size'], 10);
    });

    test('未知 id 返回 404', () async {
      var response = await WebConsole.route(request('/api/console/requests/nope?token=secret-token'),
          configuration: config(), store: ConsoleCaptureStore());
      expect(response?.status.code, 404);
    });

    test('HAR 导出包含条目', () async {
      var store = ConsoleCaptureStore();
      var req = newRequest('a', url: 'http://example.com/page');
      store.addRequest(req);
      store.addResponse(newResponse(body: utf8.encode('ok')), req);

      var response =
          await WebConsole.route(request('/api/console/har?token=secret-token'), configuration: config(), store: store);
      expect(response?.status.code, 200);
      expect(response?.headers.get('Content-Disposition'), contains('attachment'));

      var har = jsonDecode(utf8.decode(response!.body!));
      expect(har['log']['entries'], hasLength(1));
      expect(har['log']['entries'][0]['request']['url'], 'http://example.com/page');
    });

    test('清空返回新 revision 并移除条目', () async {
      var store = ConsoleCaptureStore();
      store.addRequest(newRequest('a'));
      var before = store.revision;

      var body = await callApi('/api/console/clear?token=secret-token', store: store, method: HttpMethod.post);
      expect(body['revision'], greaterThan(before));
      expect(store.length, 0);
    });

    test('未认证的写操作被拒绝', () async {
      var store = ConsoleCaptureStore();
      store.addRequest(newRequest('a'));

      var response = await WebConsole.route(request('/api/console/clear', method: HttpMethod.post),
          configuration: config(), store: store);
      expect(response?.status.code, 401);
      expect(store.length, 1);
    });
  });

  group('写操作', () {
    test('编辑后发送：文本 body 构造正确', () {
      var req = WebConsole.buildSendRequest({
        'method': 'POST',
        'url': 'http://example.com/api',
        'headers': {'Content-Type': 'application/json'},
        'bodyText': '{"a":1}',
      });

      expect(req.method, HttpMethod.post);
      expect(req.requestUrl, 'http://example.com/api');
      expect(req.headers.get('Content-Type'), 'application/json');
      expect(utf8.decode(req.body!), '{"a":1}');
      expect(req.headers.contentLength, req.body!.length);
    });

    test('编辑后发送：base64 body 构造正确', () {
      var bytes = [0x00, 0x01, 0xff];
      var req = WebConsole.buildSendRequest({
        'method': 'PUT',
        'url': 'https://example.com/upload',
        'bodyBase64': base64Encode(bytes),
      });
      expect(req.method, HttpMethod.put);
      expect(req.body, bytes);
    });

    test('编辑后发送：非法输入被拒绝', () {
      expect(() => WebConsole.buildSendRequest({'url': 'ftp://example.com/x'}), throwsFormatException);
      expect(() => WebConsole.buildSendRequest({'url': '/relative'}), throwsFormatException);
      expect(() => WebConsole.buildSendRequest({'method': 'NOT_A_METHOD', 'url': 'http://e.com/x'}),
          throwsA(anything));
      expect(
          () => WebConsole.buildSendRequest(
              {'url': 'http://e.com', 'bodyText': 'a', 'bodyBase64': 'YQ=='}),
          throwsFormatException);
      expect(() => WebConsole.buildSendRequest({'url': 'http://e.com', 'bodyBase64': '***'}),
          throwsFormatException);
    });

    test('发送接口非法 JSON 返回 400', () async {
      var req = request('/api/console/send?token=secret-token', method: HttpMethod.post)
        ..body = utf8.encode('not-json');
      var response = await WebConsole.route(req, configuration: config(), store: ConsoleCaptureStore());
      expect(response?.status.code, 400);
    });

    test('原样重发未知 id 返回 404', () async {
      var response = await WebConsole.route(
          request('/api/console/requests/nope/repeat?token=secret-token', method: HttpMethod.post),
          configuration: config(),
          store: ConsoleCaptureStore());
      expect(response?.status.code, 404);
    });

    test('从记录预填响应改写规则', () async {
      var store = ConsoleCaptureStore();
      var req = HttpRequest(HttpMethod.get, 'http://example.com/api/user?id=1')..requestId = 'a';
      store.addRequest(req);
      var resp = HttpResponse(HttpStatus.ok)
        ..headers.set('Content-Type', 'application/json')
        ..body = utf8.encode('{"ok":true}');
      store.addResponse(resp, req);

      var response = await WebConsole.route(
          request('/api/console/requests/a/rewrite?token=secret-token', method: HttpMethod.post),
          configuration: config(),
          store: store);
      expect(response?.status.code, 200);

      var payload = jsonDecode(utf8.decode(response!.body!));
      expect(payload['type'], RuleType.responseReplace.name);
      expect(payload['url'], 'http://example.com/api/user');
      expect(payload['method'], 'GET');
      var types = (payload['items'] as List).map((e) => e['type']).toList();
      expect(types, containsAll(['replaceResponseStatus', 'replaceResponseHeader', 'replaceResponseBody']));
    });

    test('未完成的响应不能预填改写', () async {
      var store = ConsoleCaptureStore();
      store.addRequest(HttpRequest(HttpMethod.get, 'http://example.com/x')..requestId = 'a');

      var response = await WebConsole.route(
          request('/api/console/requests/a/rewrite?token=secret-token', method: HttpMethod.post),
          configuration: config(),
          store: store);
      expect(response?.status.code, 400);
    });

    test('从记录预填请求改写规则（无响应也可）', () async {
      var store = ConsoleCaptureStore();
      var req = HttpRequest(HttpMethod.post, 'http://example.com/api/user?id=1')
        ..requestId = 'a'
        ..body = utf8.encode('{"name":"x"}');
      req.headers.set('Content-Type', 'application/json');
      store.addRequest(req);

      var response = await WebConsole.route(
          request('/api/console/requests/a/rewrite?token=secret-token&type=requestReplace', method: HttpMethod.post),
          configuration: config(),
          store: store);
      expect(response?.status.code, 200);

      var payload = jsonDecode(utf8.decode(response!.body!));
      expect(payload['type'], RuleType.requestReplace.name);
      expect(payload['url'], 'http://example.com/api/user');
      expect(payload['method'], 'POST');
      var types = (payload['items'] as List).map((e) => e['type']).toList();
      expect(types, containsAll(['replaceRequestLine', 'replaceRequestHeader', 'replaceRequestBody']));
    });

    test('构造重写规则与条目', () {
      var rule = WebConsole.buildRewriteRule({
        'enabled': true,
        'type': 'responseReplace',
        'url': 'http://example.com/api',
        'method': 'POST',
      });
      expect(rule.type, RuleType.responseReplace);
      expect(rule.method, HttpMethod.post);

      var items = WebConsole.buildRewriteItems([
        {'type': 'replaceResponseStatus', 'enabled': true, 'values': {'statusCode': 418}},
      ]);
      expect(items.single.type, RewriteType.replaceResponseStatus);
      expect(items.single.statusCode, 418);

      expect(WebConsole.buildRewriteItems(null), isEmpty);
    });
  });

  group('捕获存储', () {
    HttpRequest newRequest(String id) {
      return HttpRequest(HttpMethod.get, 'http://example.com/$id')..requestId = id;
    }

    test('请求进入存储，revision 递增', () {
      var store = ConsoleCaptureStore();
      store.addRequest(newRequest('a'));
      expect(store.length, 1);
      expect(store.revision, 1);
      expect(store.sinceRevision(0).map((e) => e.request.requestId), ['a']);
      expect(store.sinceRevision(1), isEmpty);
    });

    test('响应回填并更新 revision', () {
      var store = ConsoleCaptureStore();
      var req = newRequest('a');
      store.addRequest(req);
      var since = store.revision;

      var resp = HttpResponse(HttpStatus.ok)..body = utf8.encode('hi');
      store.addResponse(resp, req);

      expect(store.get('a')?.response, same(resp));
      expect(store.sinceRevision(since).single.request.requestId, 'a');
      expect(store.get('a')?.response?.request, same(req));
    });

    test('重复 requestId 忽略', () {
      var store = ConsoleCaptureStore();
      var req = newRequest('a');
      store.addRequest(req);
      store.addRequest(req);
      expect(store.length, 1);
      expect(store.revision, 1);
    });

    test('环形缓冲按条数淘汰最旧条目', () {
      var store = ConsoleCaptureStore(maxEntries: 2);
      store.addRequest(newRequest('a'));
      store.addRequest(newRequest('b'));
      store.addRequest(newRequest('c'));
      expect(store.length, 2);
      expect(store.get('a'), isNull);
      expect(store.get('c'), isNotNull);
    });

    test('环形缓冲按字节淘汰最旧条目', () {
      var store = ConsoleCaptureStore(maxEntries: 100, maxBytes: 10);
      var a = newRequest('a')..body = List.filled(8, 1);
      var b = newRequest('b')..body = List.filled(8, 1);
      store.addRequest(a);
      store.addRequest(b);
      expect(store.length, 1);
      expect(store.get('a'), isNull);
      expect(store.get('b'), isNotNull);
    });

    test('清空后 revision 继续递增，旧 since 拉不到旧数据', () {
      var store = ConsoleCaptureStore();
      store.addRequest(newRequest('a'));
      var before = store.revision;
      store.clear();
      expect(store.length, 0);
      expect(store.revision, greaterThan(before));
      expect(store.sinceRevision(before), isEmpty);
      expect(store.all(), isEmpty);
    });
  });
}
