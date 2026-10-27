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

import 'package:proxypin/network/bin/listener.dart';
import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/http/http.dart';

/// Web 控制台抓包条目：请求 + 响应引用，以及最后一次变更时的 revision
class ConsoleEntry {
  final HttpRequest request;
  HttpResponse? response;

  /// 最近一次变更（新建/回填响应）时的 revision
  int revision;

  ConsoleEntry(this.request, this.revision);

  int get byteSize => (request.body?.length ?? 0) + (response?.body?.length ?? 0);
}

/// 独立于 Flutter UI 的抓包存储（供 Web 控制台使用）。
///
/// 通过 [ProxyServer.addListener] 注册，保存请求/响应对象引用（不复制 body），
/// 使用条数 + 总字节双上限的环形缓冲，并维护单调递增 [revision] 供浏览器增量轮询。
class ConsoleCaptureStore extends EventListener {
  /// 当前注册的存储实例（由 ProxyServer 构造时设置），避免网络层反向依赖 UI
  static ConsoleCaptureStore? current;

  /// 最大保留条数
  final int maxEntries;

  /// 最大保留字节数（请求 + 响应 body 合计）
  final int maxBytes;

  final Map<String, ConsoleEntry> _byId = {};

  /// 按到达顺序保存 requestId，用于淘汰最旧条目
  final List<String> _order = [];

  int _revision = 0;
  int _bytes = 0;

  ConsoleCaptureStore({this.maxEntries = 1000, this.maxBytes = 32 * 1024 * 1024});

  /// 单调递增 revision，清空后也会继续递增
  int get revision => _revision;

  int get length => _order.length;

  int get bytes => _bytes;

  @override
  void onRequest(Channel channel, HttpRequest request) {
    addRequest(request);
  }

  @override
  void onResponse(ChannelContext channelContext, HttpResponse response) {
    addResponse(response, channelContext.currentRequest);
  }

  /// 记录请求；同一 requestId 重复上报时忽略
  void addRequest(HttpRequest request) {
    if (_byId.containsKey(request.requestId)) {
      return;
    }
    var entry = ConsoleEntry(request, ++_revision);
    _byId[request.requestId] = entry;
    _order.add(request.requestId);
    _bytes += entry.byteSize;
    _evict();
  }

  /// 回填响应；[requestHint] 用于 response.request 未设置时按当前请求关联
  void addResponse(HttpResponse response, [HttpRequest? requestHint]) {
    var request = response.request ?? requestHint;
    var id = request?.requestId;
    if (id == null) {
      return;
    }
    var entry = _byId[id];
    if (entry == null) {
      return;
    }
    _bytes -= entry.byteSize;
    entry.response = response;
    response.request ??= entry.request;
    entry.revision = ++_revision;
    _bytes += entry.byteSize;
    _evict();
  }

  /// 按 requestId 查询
  ConsoleEntry? get(String id) => _byId[id];

  /// revision 大于 [since] 的条目（按到达顺序）
  List<ConsoleEntry> sinceRevision(int since) {
    var list = <ConsoleEntry>[];
    for (var id in _order) {
      var entry = _byId[id];
      if (entry != null && entry.revision > since) {
        list.add(entry);
      }
    }
    return list;
  }

  /// 全部条目（按到达顺序）
  List<ConsoleEntry> all() {
    return [for (var id in _order) if (_byId[id] != null) _byId[id]!];
  }

  /// 清空并递增 revision，避免客户端把旧数据重新合并回来
  void clear() {
    _byId.clear();
    _order.clear();
    _bytes = 0;
    _revision++;
  }

  void _evict() {
    while (_order.isNotEmpty && (_order.length > maxEntries || _bytes > maxBytes)) {
      var oldest = _order.removeAt(0);
      var entry = _byId.remove(oldest);
      if (entry != null) {
        _bytes -= entry.byteSize;
      }
    }
  }
}
