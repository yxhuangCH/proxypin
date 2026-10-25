(() => {
  'use strict';

  // ---------- token & api ----------
  const params = new URLSearchParams(location.search);
  const urlToken = params.get('token');
  if (urlToken) {
    localStorage.setItem('proxypin_console_token', urlToken);
    // 去掉地址栏里的 token，避免被截图/复制时泄露
    params.delete('token');
    const query = params.toString();
    history.replaceState(null, '', location.pathname + (query ? '?' + query : ''));
  }
  const token = urlToken || localStorage.getItem('proxypin_console_token') || '';

  function api(path) {
    if (!token) return path;
    return path + (path.includes('?') ? '&' : '?') + 'token=' + encodeURIComponent(token);
  }

  async function fetchJson(path, options) {
    const response = await fetch(api(path), options);
    if (response.status === 401) {
      throw new Error('认证失败：请使用手机 App 中带 token 的控制台地址重新打开');
    }
    if (!response.ok) {
      let message = response.status + ' ' + response.statusText;
      try {
        const body = await response.json();
        if (body && body.error) message = body.error;
      } catch (_) { /* ignore */ }
      throw new Error(message);
    }
    return response.json();
  }

  function postJson(path, payload) {
    return fetchJson(path, {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: payload === undefined ? undefined : JSON.stringify(payload),
    });
  }

  function putJson(path, payload) {
    return fetchJson(path, {
      method: 'PUT',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify(payload),
    });
  }

  // ---------- dom helpers ----------
  function el(tag, attrs, ...children) {
    const node = document.createElement(tag);
    if (attrs) {
      for (const [key, value] of Object.entries(attrs)) {
        if (value == null || value === false) continue;
        if (key === 'class') node.className = value;
        else if (key === 'text') node.textContent = value;
        else if (key.startsWith('on')) node.addEventListener(key.slice(2), value);
        else node.setAttribute(key, value);
      }
    }
    for (const child of children.flat(Infinity)) {
      if (child == null || child === false) continue;
      node.append(child instanceof Node ? child : document.createTextNode(String(child)));
    }
    return node;
  }

  function clear(node) {
    while (node.firstChild) node.removeChild(node.firstChild);
  }

  function formatBytes(size) {
    if (size == null) return '';
    if (size < 1024) return size + ' B';
    if (size < 1024 * 1024) return (size / 1024).toFixed(1) + ' KB';
    return (size / 1024 / 1024).toFixed(1) + ' MB';
  }

  function formatTime(ms) {
    if (!ms) return '';
    const d = new Date(ms);
    const pad = (n) => String(n).padStart(2, '0');
    return pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
  }

  function formatCost(ms) {
    if (ms == null) return '';
    return ms > 1000 ? (ms / 1000).toFixed(2) + 's' : ms + 'ms';
  }

  function statusClass(status) {
    if (status == null) return 'muted';
    if (status < 0) return 'm-err';
    return 'm-' + Math.floor(status / 100) + 'xx';
  }

  function toast(message, isError) {
    const node = document.getElementById('toast');
    node.textContent = message;
    node.className = 'show' + (isError ? ' err' : '');
    clearTimeout(toast.timer);
    toast.timer = setTimeout(() => {
      node.className = '';
    }, 2600);
  }

  // 手机直接提供页面时是 http://手机IP，不属于安全上下文，navigator.clipboard 不可用，
  // 回退到隐藏 textarea + execCommand('copy')（需由点击事件触发）。
  // 注意：不能移出视口或设 visibility:hidden，部分浏览器/WebView 会拒绝从不可见元素复制。
  function fallbackCopy(text) {
    const area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', '');
    area.style.position = 'fixed';
    area.style.left = '0';
    area.style.top = '0';
    area.style.width = '2em';
    area.style.height = '2em';
    area.style.padding = '0';
    area.style.border = 'none';
    area.style.outline = 'none';
    area.style.background = 'transparent';
    area.style.opacity = '0.01';
    document.body.appendChild(area);

    const selection = document.getSelection();
    const saved = selection && selection.rangeCount > 0 ? selection.getRangeAt(0) : null;
    let ok = false;
    try {
      area.focus();
      area.select();
      area.setSelectionRange(0, area.value.length);
      ok = document.execCommand('copy');
    } catch (_) {
      ok = false;
    }
    document.body.removeChild(area);
    if (saved && selection) {
      selection.removeAllRanges();
      selection.addRange(saved);
    }
    if (!ok) throw new Error('copy failed');
  }

  // 最终兜底：自动复制全部失败时，弹出已全选的文本框让用户手动 Ctrl+C / 长按复制。
  let copyDialog = null;
  function showCopyDialog(text, label) {
    if (!copyDialog) {
      const area = el('textarea', {class: 'copy-area', rows: '12', readonly: '', spellcheck: 'false'});
      copyDialog = el('dialog', null,
          el('div', {class: 'dialog-form'},
              el('h2', {text: '手动复制'}),
              el('p', {class: 'muted', text: '浏览器拦截了自动复制，文本已全选，请按 Ctrl+C（Mac 按 ⌘C）复制。'}),
              area,
              el('div', {class: 'dialog-actions'},
                  el('button', {text: '关闭', onclick: () => copyDialog.close()}))));
      copyDialog._area = area;
      document.body.appendChild(copyDialog);
    }
    copyDialog._area.value = text;
    copyDialog.showModal();
    copyDialog._area.focus();
    copyDialog._area.select();
    toast('自动复制被拦截，请手动复制', true);
  }

  async function copy(text, label) {
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(text);
        toast((label || '内容') + '已复制');
        return;
      }
    } catch (_) { /* 剪贴板 API 被拒（如页面未聚焦），继续走 execCommand */ }
    try {
      fallbackCopy(text);
      toast((label || '内容') + '已复制');
    } catch (_) {
      showCopyDialog(text, label);
    }
  }

  // ---------- state ----------
  const listEl = document.getElementById('request-list');
  const detailEl = document.getElementById('detail');
  const statusEl = document.getElementById('status');
  const filterEl = document.getElementById('filter');

  const requests = new Map(); // id -> summary
  const order = [];           // 到达顺序
  const rowById = new Map();
  let revision = 0;
  let selectedId = null;
  let selectedRevision = -1;
  let lastDetail = null;
  let listDirty = true;
  let pollTimer = null;
  let polling = false;
  let listTab = 'all';        // all=全部请求 / domains=域名列表（对齐鸿蒙 App）
  let activeDomain = null;    // 域名 Tab 下钻中的域名

  // ---------- list ----------
  function visibleIds() {
    const keyword = filterEl.value.trim().toLowerCase();
    return order.filter((id) => {
      const item = requests.get(id);
      if (!item) return false;
      if (activeDomain && item.host !== activeDomain) return false;
      if (!keyword) return true;
      return (item.method + ' ' + item.url + ' ' + (item.status ?? '')).toLowerCase().includes(keyword);
    });
  }

  // 域名分组：最近活跃的域名排在顶部（对齐 App 域名列表）
  function domainGroups() {
    const groups = new Map(); // host -> {count, lastTime}
    for (const id of order) {
      const item = requests.get(id);
      if (!item) continue;
      const host = item.host || '(未知)';
      const group = groups.get(host);
      if (group) {
        group.count++;
        group.lastTime = Math.max(group.lastTime, item.requestTime || 0);
      } else {
        groups.set(host, {count: 1, lastTime: item.requestTime || 0});
      }
    }
    return [...groups.entries()].sort((a, b) => b[1].lastTime - a[1].lastTime);
  }

  function requestRow(item) {
    const id = item.id;
    const row = el('div', {
      class: 'row' + (id === selectedId ? ' selected' : ''),
      onclick: () => selectRequest(id),
    },
        el('span', {class: 'method m-' + item.method.toLowerCase(), text: item.method}),
        el('span', {class: 'url', title: item.url, text: item.path || item.url}),
        el('span', {class: 'status ' + statusClass(item.status),
          text: item.status == null ? '…' : String(item.status)}),
        el('span', {class: 'size', text: formatBytes(item.responseSize || item.requestSize)}),
        el('span', {class: 'meta', title: item.host, text: item.host}),
        el('span', {class: 'time', text: formatTime(item.requestTime)}),
    );
    rowById.set(id, row);
    return row;
  }

  function renderList() {
    if (!listDirty) return;
    listDirty = false;
    clear(listEl);
    rowById.clear();

    // 域名列表 Tab（未下钻）：域名 + 请求数 + 最后时间，点击下钻
    if (listTab === 'domains' && !activeDomain) {
      const keyword = filterEl.value.trim().toLowerCase();
      const groups = domainGroups()
          .filter(([host]) => !keyword || host.toLowerCase().includes(keyword));
      if (groups.length === 0) {
        listEl.append(el('div', {class: 'placeholder muted', style: 'padding:24px;text-align:center'},
            order.length === 0 ? '暂无抓包记录' : '没有匹配的域名'));
        return;
      }
      const fragment = document.createDocumentFragment();
      for (const [host, group] of groups) {
        fragment.append(el('div', {
          class: 'domain-row',
          onclick: () => {
            activeDomain = host;
            listDirty = true;
            renderList();
          },
        },
            el('div', {class: 'info'},
                el('div', {class: 'domain', title: host, text: host}),
                el('div', {class: 'sub', text: group.count + ' 条请求 · 最后 ' + formatTime(group.lastTime)})),
            el('span', {class: 'chevron', text: '›'})));
      }
      listEl.append(fragment);
      return;
    }

    const ids = visibleIds();
    const fragment = document.createDocumentFragment();
    // 下钻态：顶部返回行（即使该域名暂时没有请求也保留，避免无法返回）
    if (activeDomain) {
      fragment.append(el('div', {class: 'back-row', onclick: () => {
        activeDomain = null;
        listDirty = true;
        renderList();
      }}, el('span', {text: '‹ ' + activeDomain})));
    }
    if (ids.length === 0) {
      fragment.append(el('div', {class: 'placeholder muted', style: 'padding:24px;text-align:center'},
          order.length === 0 ? '暂无抓包记录' : '没有匹配的请求'));
    } else {
      for (const id of ids) {
        const item = requests.get(id);
        if (!item) continue;
        fragment.append(requestRow(item));
      }
    }
    listEl.append(fragment);
  }

  function updateSelection() {
    for (const [id, row] of rowById) {
      row.classList.toggle('selected', id === selectedId);
    }
  }

  // ---------- detail ----------
  function kvTable(rows) {
    const table = el('table', {class: 'kv'});
    for (const [name, value] of rows) {
      if (value == null || value === '') continue;
      table.append(el('tr', null, el('td', {text: name}), el('td', {text: String(value)})));
    }
    return table;
  }

  function headerTable(headers) {
    if (!headers || headers.length === 0) {
      return el('div', {class: 'muted', text: '（无）'});
    }
    const table = el('table', {class: 'kv'});
    for (const header of headers) {
      table.append(el('tr', null,
          el('td', {text: header.name}),
          el('td', {text: header.value})));
    }
    return table;
  }

  function bodyView(body) {
    if (!body || body.size === 0) {
      return el('div', {class: 'muted', text: '（空）'});
    }

    const caption = [formatBytes(body.size), body.encoding ? 'base64' : null, body.truncated ? '已截断' : null]
        .filter(Boolean).join(' · ');

    let text = body.text;
    if (text == null) {
      text = body.base64 || '';
    } else {
      try {
        text = JSON.stringify(JSON.parse(text), null, 2);
      } catch (_) { /* 非 JSON，按原文展示 */ }
    }

    const pre = el('pre', {class: 'body', text: text});
    return el('div', null,
        el('div', {class: 'body-caption', text: caption}),
        el('div', {class: 'toolbar'}, el('button', {
          text: '复制 body',
          onclick: () => copy(text, 'Body'),
        })),
        pre);
  }

  function toCurl(detail) {
    const escape = (s) => String(s).replace(/'/g, "'\\''");
    const lines = ["curl -X " + detail.method + " '" + escape(detail.url) + "'"];
    for (const header of detail.request.headers || []) {
      if (/^(host|content-length)$/i.test(header.name)) continue;
      lines.push("  -H '" + escape(header.name + ': ' + header.value) + "'");
    }
    const body = detail.request.body;
    if (body) {
      if (body.text != null && body.text !== '') {
        lines.push("  --data-raw '" + escape(body.text) + "'");
      } else if (body.base64) {
        lines.push('  # 二进制 body，base64: ' + body.base64);
      }
    }
    return lines.join(' \\\n');
  }

  let detailTab = 'request'; // 详情区 Tab：request / response（对齐鸿蒙 App）

  function queryParamsOf(url) {
    try {
      const params = [];
      new URL(url).searchParams.forEach((value, name) => params.push([name, value]));
      return params;
    } catch (_) {
      return [];
    }
  }

  function renderDetail(detail) {
    lastDetail = detail;
    clear(detailEl);

    const response = detail.response;

    const toolbar = el('div', {class: 'toolbar'},
        el('button', {text: '复制 URL', onclick: () => copy(detail.url, 'URL')}),
        el('button', {text: '复制 cURL', onclick: () => copy(toCurl(detail), 'cURL')}),
        el('button', {text: '原样重发', onclick: () => repeatRequest(detail.id)}),
        el('button', {text: '编辑后发送', onclick: () => openSendDialog(detail)}),
    );

    const tabBar = el('div', {class: 'detail-tabs'},
        [['request', 'Request'], ['response', 'Response']].map(([key, label]) =>
            el('button', {
              class: 'tab' + (detailTab === key ? ' active' : ''),
              text: label,
              onclick: () => {
                detailTab = key;
                renderDetail(detail);
              },
            })));

    detailEl.append(
        el('div', {class: 'detail-title', text: detail.method + ' ' + detail.url, title: detail.url}),
        toolbar,
        tabBar);

    if (detailTab === 'request') {
      // Request tab：Path / 请求参数 / 请求头 / 请求体，可编辑（生成 requestReplace 规则）
      const children = [
        kvTable([
          ['Path', detail.path],
          ['请求时间', detail.requestTime ? new Date(detail.requestTime).toLocaleString() : ''],
          ['请求大小', formatBytes(detail.requestSize)],
        ]),
      ];
      const params = queryParamsOf(detail.url);
      if (params.length > 0) {
        children.push(el('h3', {text: '请求参数'}), kvTable(params));
      }
      children.push(
          el('h3', {text: '请求头'}),
          headerTable(detail.request.headers),
          el('div', {class: 'body-head'},
              el('h3', {text: '请求体'}),
              el('button', {text: '编辑（请求重写）', onclick: () => prefillRewrite(detail.id, 'requestReplace')})),
          bodyView(detail.request.body));
      detailEl.append(children);
      return;
    }

    // Response tab：状态码 / 响应头 / 响应体，可编辑（生成 responseReplace 规则）
    if (!response) {
      detailEl.append(el('div', {class: 'placeholder muted', text: '（尚未收到响应）'}));
      return;
    }
    detailEl.append(
        kvTable([
          ['状态码', response.status?.code + ' ' + (response.status?.reasonPhrase || '')],
          ['耗时', formatCost(detail.costTime)],
          ['响应大小', formatBytes(detail.responseSize)],
          ['响应时间', detail.responseTime ? new Date(detail.responseTime).toLocaleString() : ''],
        ]),
        el('h3', {text: '响应头'}),
        headerTable(response.headers),
        el('div', {class: 'body-head'},
            el('h3', {text: '响应体'}),
            el('button', {text: '编辑（响应重写）', onclick: () => prefillRewrite(detail.id, 'responseReplace')})),
        bodyView(response.body));
  }

  async function selectRequest(id) {
    selectedId = id;
    updateSelection();
    await loadDetail(id);
  }

  async function loadDetail(id) {
    try {
      const detail = await fetchJson('/api/console/requests/' + encodeURIComponent(id));
      if (selectedId !== id) return;
      selectedRevision = requests.get(id)?.revision ?? selectedRevision;
      renderDetail(detail);
    } catch (error) {
      if (selectedId !== id) return;
      clear(detailEl);
      detailEl.append(el('div', {class: 'placeholder error', text: error.message}));
    }
  }

  // ---------- actions ----------
  async function repeatRequest(id) {
    try {
      const result = await postJson('/api/console/requests/' + encodeURIComponent(id) + '/repeat');
      toast('已重发，状态 ' + (result.status ?? '?'));
      schedulePoll(300);
    } catch (error) {
      toast(error.message, true);
    }
  }

  // 编辑后发送
  const sendDialog = document.getElementById('send-dialog');
  const sendForm = document.getElementById('send-form');
  const sendMethod = document.getElementById('send-method');
  const sendUrl = document.getElementById('send-url');
  const sendHeaders = document.getElementById('send-headers');
  const sendBody = document.getElementById('send-body');
  const sendError = document.getElementById('send-error');
  const sendTitle = document.getElementById('send-title');

  function openSendDialog(detail) {
    sendError.textContent = '';
    if (detail) {
      sendTitle.textContent = '编辑后发送';
      sendMethod.value = detail.method;
      sendUrl.value = detail.url;
      sendHeaders.value = (detail.request.headers || [])
          .map((header) => header.name + ': ' + header.value)
          .join('\n');
      const body = detail.request.body;
      sendBody.value = body && body.text != null ? body.text : '';
      if (body && body.base64) {
        sendBody.placeholder = '该请求体是二进制，请使用「原样重发」';
      } else {
        sendBody.placeholder = '';
      }
    } else {
      sendTitle.textContent = '新建请求';
      sendMethod.value = 'GET';
      sendUrl.value = '';
      sendHeaders.value = 'Accept: */*';
      sendBody.value = '';
      sendBody.placeholder = '';
    }
    sendDialog.showModal();
  }

  function parseHeaders(text) {
    const headers = {};
    for (const line of text.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      const index = trimmed.indexOf(':');
      if (index <= 0) continue;
      headers[trimmed.slice(0, index).trim()] = trimmed.slice(index + 1).trim();
    }
    return headers;
  }

  document.getElementById('send-cancel').addEventListener('click', () => sendDialog.close());
  document.getElementById('send-submit').addEventListener('click', async () => {
    const url = sendUrl.value.trim();
    if (!url) {
      sendError.textContent = '请填写 URL';
      return;
    }
    const payload = {
      method: sendMethod.value,
      url: url,
      headers: parseHeaders(sendHeaders.value),
    };
    const bodyText = sendBody.value;
    if (bodyText !== '') payload.bodyText = bodyText;

    try {
      const result = await postJson('/api/console/send', payload);
      sendDialog.close();
      toast('发送完成，状态 ' + (result.status ?? '?'));
      schedulePoll(300);
    } catch (error) {
      sendError.textContent = error.message;
    }
  });
  sendForm.addEventListener('submit', (event) => event.preventDefault());

  document.getElementById('btn-new').addEventListener('click', () => openSendDialog(null));

  // ---------- rewrites ----------
  const rewritesDialog = document.getElementById('rewrites-dialog');
  const rewritesList = document.getElementById('rewrites-list');
  const ruleDialog = document.getElementById('rule-dialog');
  const ruleJson = document.getElementById('rule-json');
  const ruleError = document.getElementById('rule-error');
  const ruleTitle = document.getElementById('rule-title');
  let rewrites = null;
  let editingIndex = null;

  function ruleSubtitle(rule) {
    const method = rule.method ? rule.method + ' ' : '';
    const count = (rule.items || []).length;
    return rule.type + ' · ' + method + count + ' 条改写项';
  }

  function renderRewrites() {
    clear(rewritesList);
    const rules = rewrites?.rules || [];
    if (rules.length === 0) {
      rewritesList.append(el('div', {class: 'muted', style: 'padding:12px 0', text: '暂无改写规则'}));
      return;
    }

    rules.forEach((rule, index) => {
      const toggle = el('input', {
        type: 'checkbox',
        title: '启用/停用',
        onchange: () => toggleRule(index, toggle.checked),
      });
      toggle.checked = rule.enabled !== false;

      rewritesList.append(el('div', {class: 'rule'},
          toggle,
          el('div', {class: 'info'},
              el('div', {text: rule.name || '(未命名规则)', title: rule.name || ''}),
              el('div', {class: 'sub', text: rule.url}),
              el('div', {class: 'sub', text: ruleSubtitle(rule)}),
          ),
          el('button', {text: '编辑', onclick: () => openRuleDialog(index)}),
          el('button', {class: 'danger', text: '删除', onclick: () => deleteRule(index)}),
      ));
    });
  }

  async function loadRewrites() {
    rewrites = await fetchJson('/api/console/rewrites');
    renderRewrites();
  }

  async function openRewrites() {
    try {
      await loadRewrites();
      rewritesDialog.showModal();
    } catch (error) {
      toast(error.message, true);
    }
  }

  async function toggleRule(index, enabled) {
    const rule = rewrites.rules[index];
    try {
      rewrites = await putJson('/api/console/rewrites/' + index, Object.assign({}, rule, {enabled: enabled}));
      renderRewrites();
      toast(enabled ? '规则已启用' : '规则已停用');
    } catch (error) {
      toast(error.message, true);
      renderRewrites();
    }
  }

  async function deleteRule(index) {
    const rule = rewrites.rules[index];
    if (!confirm('删除规则「' + (rule.name || rule.url) + '」？')) return;
    try {
      rewrites = await fetchJson('/api/console/rewrites/' + index, {method: 'DELETE'});
      renderRewrites();
      toast('规则已删除');
    } catch (error) {
      toast(error.message, true);
    }
  }

  function openRuleDialog(index, template) {
    ruleError.textContent = '';
    editingIndex = index;
    if (index == null) {
      ruleTitle.textContent = '新增改写规则';
      editingRule = template || {
        name: '新规则',
        enabled: true,
        type: 'responseReplace',
        url: 'http://example.com/api/*',
        items: [
          {enabled: false, type: 'replaceResponseStatus', values: {statusCode: 200}},
          {enabled: false, type: 'replaceResponseHeader', values: {headers: {}}},
          {enabled: true, type: 'replaceResponseBody', values: {body: '', bodyType: 'text'}},
        ],
      };
    } else {
      ruleTitle.textContent = '编辑改写规则';
      editingRule = JSON.parse(JSON.stringify(rewrites.rules[index]));
    }
    // 表单不支持的规则类型（修改请求/重定向等）直接 JSON 模式
    jsonMode = !FORM_RULE_TYPES.includes(editingRule.type);
    ruleJson.value = JSON.stringify(editingRule, null, 2);
    renderRuleFields();
    applyJsonMode();
    ruleDialog.showModal();
  }

  async function prefillRewrite(id, type) {
    try {
      const template = await postJson('/api/console/requests/' + encodeURIComponent(id) + '/rewrite' +
          (type ? '?type=' + encodeURIComponent(type) : ''));
      await loadRewrites();
      rewritesDialog.showModal();
      openRuleDialog(null, template);
    } catch (error) {
      toast(error.message, true);
    }
  }

  // ---------- 规则表单（与鸿蒙 App 编辑页对齐：responseReplace 三分区 / responseUpdate 改写项列表） ----------
  const ruleFields = document.getElementById('rule-fields');
  const ruleJsonToggle = document.getElementById('rule-json-toggle');
  // 表单支持的规则类型（其余类型走 JSON 高级编辑）
  const FORM_RULE_TYPES = ['requestReplace', 'responseReplace', 'responseUpdate'];
  const RULE_TYPE_LABELS = {requestReplace: '替换请求', responseReplace: '替换响应', responseUpdate: '修改响应'};
  const UPDATE_ITEM_TYPES = [
    ['updateBody', '修改Body'],
    ['addHeader', '添加头部'],
    ['updateHeader', '修改头部'],
    ['removeHeader', '删除头部'],
  ];
  let editingRule = null;
  let jsonMode = false;

  function findItem(rule, type) {
    return (rule.items || []).find((it) => it.type === type);
  }

  function applyJsonMode() {
    ruleFields.hidden = jsonMode;
    ruleJson.hidden = !jsonMode;
    ruleJsonToggle.classList.toggle('primary', jsonMode);
    ruleJsonToggle.disabled = !FORM_RULE_TYPES.includes(editingRule?.type);
    ruleJsonToggle.title = ruleJsonToggle.disabled ? '该类型规则仅支持 JSON 编辑' : '切换 JSON 高级编辑';
  }

  function renderRuleFields() {
    clear(ruleFields);
    const rule = editingRule;
    if (!rule) return;

    // 名称 + 启用
    const nameInput = el('input', {type: 'text', id: 'rf-name', placeholder: '规则名称'});
    nameInput.value = rule.name || '';
    const enabledBox = el('input', {type: 'checkbox', id: 'rf-enabled'});
    enabledBox.checked = rule.enabled !== false;

    // 类型 + 方法
    const typeSelect = el('select', {id: 'rf-type'},
        FORM_RULE_TYPES.map((t) => el('option', {value: t, text: RULE_TYPE_LABELS[t] || t})));
    typeSelect.value = FORM_RULE_TYPES.includes(rule.type) ? rule.type : 'responseReplace';
    typeSelect.addEventListener('change', () => {
      rule.type = typeSelect.value;
      renderItemsSection();
    });
    const methodSelect = el('select', {id: 'rf-method'},
        ['', 'GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS']
            .map((m) => el('option', {value: m, text: m || '任意方法'})));
    methodSelect.value = rule.method || '';

    // URL
    const urlInput = el('input', {type: 'text', id: 'rf-url', placeholder: 'http://example.com/api/*  支持 * 通配'});
    urlInput.value = rule.url || '';

    ruleFields.append(
        el('div', {class: 'rf-row'},
            el('label', {class: 'fld'}, el('span', {text: '名称'}), nameInput),
            el('label', {class: 'fld chk'}, enabledBox, el('span', {text: '启用'}))),
        el('div', {class: 'rf-row'},
            el('label', {class: 'fld'}, el('span', {text: '类型'}), typeSelect),
            el('label', {class: 'fld'}, el('span', {text: '方法'}), methodSelect)),
        el('label', {class: 'fld'}, el('span', {text: 'URL'}), urlInput),
        el('div', {id: 'rf-items'}));

    renderItemsSection();
  }

  function renderItemsSection() {
    const container = ruleFields.querySelector('#rf-items');
    if (!container) return;
    clear(container);
    const rule = editingRule;
    if (rule.type === 'requestReplace') renderRequestReplaceSections(container, rule);
    else if (rule.type === 'responseReplace') renderReplaceSections(container, rule);
    else if (rule.type === 'responseUpdate') renderUpdateSections(container, rule);
  }

  // 替换请求：请求行（方法/Path/URL参数）/ 请求头 / 请求体 三个分区（对齐 App 的请求 Tab）
  function renderRequestReplaceSections(container, rule) {
    const lineItem = findItem(rule, 'replaceRequestLine');
    const headerItem = findItem(rule, 'replaceRequestHeader');
    const bodyItem = findItem(rule, 'replaceRequestBody');

    // 请求行：留空表示该项不修改（对应后端 item.method ?? request.method / Uri.replace 的 null 语义）
    const lineBox = el('input', {type: 'checkbox', id: 'rf-line-enabled'});
    lineBox.checked = lineItem?.enabled === true;
    const methodSelect = el('select', {id: 'rf-line-method'},
        ['', 'GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS']
            .map((m) => el('option', {value: m, text: m || '不改'})));
    methodSelect.value = lineItem?.values?.method || '';
    const pathInput = el('input', {type: 'text', id: 'rf-line-path', spellcheck: 'false',
        placeholder: 'Path，例如 /api/v1/user（留空不改）'});
    pathInput.value = lineItem?.values?.path || '';
    const queryInput = el('input', {type: 'text', id: 'rf-line-query', spellcheck: 'false',
        placeholder: 'URL参数，例如 id=1&name=2（留空不改）'});
    queryInput.value = lineItem?.values?.queryParam || '';

    // 请求头
    const headerBox = el('input', {type: 'checkbox', id: 'rf-req-header-enabled'});
    headerBox.checked = headerItem?.enabled === true;
    const headerRows = el('div', {id: 'rf-req-header-rows'});
    const headers = headerItem?.values?.headers || {};
    for (const [name, value] of Object.entries(headers)) addHeaderRow(headerRows, name, value);
    if (Object.keys(headers).length === 0) addHeaderRow(headerRows, '', '');

    // 请求体（同响应体：Web 只支持文本；文件型保留原值）
    const bodyBox = el('input', {type: 'checkbox', id: 'rf-req-body-enabled'});
    bodyBox.checked = bodyItem ? bodyItem.enabled !== false : true;
    const isFileBody = bodyItem?.values?.bodyType === 'file';
    const bodyArea = el('textarea', {id: 'rf-req-body', rows: '8', spellcheck: 'false',
        placeholder: '{"key":"value"}'});
    bodyArea.value = isFileBody ? '' : (bodyItem?.values?.body || '');

    container.append(
        el('div', {class: 'rw-section'},
            el('div', {class: 'rw-head'},
                el('label', null, lineBox, el('span', {text: '替换请求行'}))),
            el('div', {class: 'rf-row'},
                el('label', {class: 'fld'}, el('span', {text: '方法'}), methodSelect)),
            pathInput,
            queryInput),
        el('div', {class: 'rw-section'},
            el('div', {class: 'rw-head'},
                el('label', null, headerBox, el('span', {text: '替换请求头'})),
                el('button', {type: 'button', text: '+ 添加', onclick: () => addHeaderRow(headerRows, '', '')})),
            headerRows),
        el('div', {class: 'rw-section'},
            el('div', {class: 'rw-head'},
                el('label', null, bodyBox, el('span', {text: '替换请求体'}))),
            isFileBody
                ? el('p', {class: 'muted', text: '当前为文件型 body（' + (bodyItem.values.bodyFile || '') + '），Web 端不支持编辑，保存时保留原配置。'})
                : bodyArea));
  }

  // 替换响应：状态码 / 响应头 / 响应体 三个分区，各自带启用开关（对齐 App 的三个 Tab）
  function renderReplaceSections(container, rule) {
    const statusItem = findItem(rule, 'replaceResponseStatus');
    const headerItem = findItem(rule, 'replaceResponseHeader');
    const bodyItem = findItem(rule, 'replaceResponseBody');

    // 状态码
    const statusBox = el('input', {type: 'checkbox', id: 'rf-status-enabled'});
    statusBox.checked = statusItem?.enabled === true;
    const statusInput = el('input', {type: 'number', id: 'rf-status', min: '100', max: '599', placeholder: '200'});
    if (statusItem?.values?.statusCode != null) statusInput.value = statusItem.values.statusCode;

    // 响应头
    const headerBox = el('input', {type: 'checkbox', id: 'rf-header-enabled'});
    headerBox.checked = headerItem?.enabled === true;
    const headerRows = el('div', {id: 'rf-header-rows'});
    const headers = headerItem?.values?.headers || {};
    for (const [name, value] of Object.entries(headers)) addHeaderRow(headerRows, name, value);
    if (Object.keys(headers).length === 0) addHeaderRow(headerRows, '', '');

    // 响应体（Web 只支持文本；文件型 body 保留原值并提示到 App 编辑）
    const bodyBox = el('input', {type: 'checkbox', id: 'rf-body-enabled'});
    bodyBox.checked = bodyItem ? bodyItem.enabled !== false : true;
    const isFileBody = bodyItem?.values?.bodyType === 'file';
    const bodyArea = el('textarea', {id: 'rf-body', rows: '8', spellcheck: 'false',
        placeholder: '{"code":0,"data":{}}'});
    bodyArea.value = isFileBody ? '' : (bodyItem?.values?.body || '');

    container.append(
        el('div', {class: 'rw-section'},
            el('div', {class: 'rw-head'},
                el('label', null, statusBox, el('span', {text: '替换状态码'}))),
            statusInput),
        el('div', {class: 'rw-section'},
            el('div', {class: 'rw-head'},
                el('label', null, headerBox, el('span', {text: '替换响应头'})),
                el('button', {type: 'button', text: '+ 添加', onclick: () => addHeaderRow(headerRows, '', '')})),
            headerRows),
        el('div', {class: 'rw-section'},
            el('div', {class: 'rw-head'},
                el('label', null, bodyBox, el('span', {text: '替换响应体'}))),
            isFileBody
                ? el('p', {class: 'muted', text: '当前为文件型 body（' + (bodyItem.values.bodyFile || '') + '），Web 端不支持编辑，保存时保留原配置。'})
                : bodyArea));
  }

  function addHeaderRow(rowsEl, name, value) {
    const keyInput = el('input', {type: 'text', placeholder: 'Header', spellcheck: 'false'});
    keyInput.value = name || '';
    const valInput = el('input', {type: 'text', placeholder: 'Value', spellcheck: 'false'});
    valInput.value = value || '';
    const row = el('div', {class: 'kv-row'}, keyInput, valInput,
        el('button', {type: 'button', class: 'danger icon', text: '×', title: '删除', onclick: () => row.remove()}));
    rowsEl.append(row);
  }

  // 修改响应：改写项列表（对齐 App 的 UpdateList：类型/启用/匹配/替换/正则）
  function renderUpdateSections(container, rule) {
    const rows = el('div', {id: 'rf-upd-rows'});
    for (const item of rule.items || []) {
      if (UPDATE_ITEM_TYPES.some(([t]) => t === item.type)) addUpdateRow(rows, item);
    }
    container.append(
        el('div', {class: 'rw-section'},
            el('div', {class: 'rw-head'},
                el('span', {text: '改写项'}),
                el('button', {type: 'button', text: '+ 添加', onclick: () => addUpdateRow(rows, null)})),
            rows));
  }

  function addUpdateRow(rowsEl, item) {
    const typeSelect = el('select', {},
        UPDATE_ITEM_TYPES.map(([value, label]) => el('option', {value: value, text: label})));
    typeSelect.value = item?.type || 'updateBody';

    const enabledBox = el('input', {type: 'checkbox', title: '启用'});
    enabledBox.checked = item ? item.enabled !== false : true;

    const keyInput = el('input', {type: 'text', spellcheck: 'false'});
    keyInput.value = item?.values?.key || '';
    const valueInput = el('input', {type: 'text', spellcheck: 'false'});
    valueInput.value = item?.values?.value || '';

    const regexBtn = el('button', {type: 'button', class: 'icon regex', text: '.*', title: '正则匹配'});
    let useRegex = item?.values?.useRegex !== false;
    const syncRegex = () => regexBtn.classList.toggle('regex-on', useRegex);
    regexBtn.addEventListener('click', () => {
      useRegex = !useRegex;
      syncRegex();
    });
    syncRegex();

    const syncPlaceholders = () => {
      const t = typeSelect.value;
      const isDelete = t === 'removeHeader';
      const isUpdate = t === 'updateBody' || t === 'updateHeader';
      keyInput.placeholder = isDelete ? '匹配规则（空则全删）' : isUpdate ? '匹配' : 'Header 名';
      valueInput.placeholder = isDelete ? '值（可空）' : isUpdate ? '替换为' : 'Header 值';
      regexBtn.style.visibility = t === 'addHeader' ? 'hidden' : 'visible';
    };
    typeSelect.addEventListener('change', syncPlaceholders);
    syncPlaceholders();

    const row = el('div', {class: 'upd-row'}, typeSelect, enabledBox, keyInput, valueInput, regexBtn,
        el('button', {type: 'button', class: 'danger icon', text: '×', title: '删除', onclick: () => row.remove()}));
    row._item = item || null; // 保留 values 中表单未覆盖的字段
    row._useRegex = () => useRegex;
    rowsEl.append(row);
  }

  // 表单 → 规则对象（保留原 items 中表单不管理的 values 字段，如 bodyFile）
  function collectRuleForm() {
    const rule = {
      name: ruleFields.querySelector('#rf-name').value.trim() || null,
      enabled: ruleFields.querySelector('#rf-enabled').checked,
      type: ruleFields.querySelector('#rf-type').value,
      url: ruleFields.querySelector('#rf-url').value.trim(),
    };
    const method = ruleFields.querySelector('#rf-method').value;
    if (method) rule.method = method;
    if (!rule.url) throw new Error('请填写 URL');

    if (rule.type === 'requestReplace') {
      const lineItem = findItem(editingRule, 'replaceRequestLine');
      const headerItem = findItem(editingRule, 'replaceRequestHeader');
      const bodyItem = findItem(editingRule, 'replaceRequestBody');

      // 空输入 → null，后端 null 表示该项不修改
      const lineMethod = ruleFields.querySelector('#rf-line-method').value || null;
      const linePath = ruleFields.querySelector('#rf-line-path').value.trim() || null;
      const lineQuery = ruleFields.querySelector('#rf-line-query').value.trim() || null;

      const headers = {};
      for (const row of ruleFields.querySelectorAll('#rf-req-header-rows .kv-row')) {
        const name = row.children[0].value.trim();
        if (!name) continue;
        headers[name] = row.children[1].value;
      }

      const bodyItemOut = {enabled: ruleFields.querySelector('#rf-req-body-enabled').checked,
          type: 'replaceRequestBody', values: Object.assign({}, bodyItem?.values)};
      if (bodyItem?.values?.bodyType === 'file') {
        // 文件型 body：保留原配置
      } else {
        bodyItemOut.values.body = ruleFields.querySelector('#rf-req-body').value;
        bodyItemOut.values.bodyType = 'text';
        delete bodyItemOut.values.bodyFile;
      }

      rule.items = [
        {enabled: ruleFields.querySelector('#rf-line-enabled').checked, type: 'replaceRequestLine',
            values: Object.assign({}, lineItem?.values,
                {method: lineMethod, path: linePath, queryParam: lineQuery})},
        {enabled: ruleFields.querySelector('#rf-req-header-enabled').checked, type: 'replaceRequestHeader',
            values: Object.assign({}, headerItem?.values, {headers: headers})},
        bodyItemOut,
      ];
      return rule;
    }

    if (rule.type === 'responseReplace') {
      const statusItem = findItem(editingRule, 'replaceResponseStatus');
      const headerItem = findItem(editingRule, 'replaceResponseHeader');
      const bodyItem = findItem(editingRule, 'replaceResponseBody');

      const statusEnabled = ruleFields.querySelector('#rf-status-enabled').checked;
      const statusText = ruleFields.querySelector('#rf-status').value.trim();
      const statusCode = statusText ? parseInt(statusText, 10) : null;
      if (statusEnabled && (statusCode == null || Number.isNaN(statusCode))) {
        throw new Error('状态码分区已启用，请填写状态码');
      }

      const headers = {};
      for (const row of ruleFields.querySelectorAll('#rf-header-rows .kv-row')) {
        const name = row.children[0].value.trim();
        if (!name) continue;
        headers[name] = row.children[1].value;
      }

      const bodyItemOut = {enabled: ruleFields.querySelector('#rf-body-enabled').checked,
          type: 'replaceResponseBody', values: Object.assign({}, bodyItem?.values)};
      if (bodyItem?.values?.bodyType === 'file') {
        // 文件型 body：保留原配置
      } else {
        bodyItemOut.values.body = ruleFields.querySelector('#rf-body').value;
        bodyItemOut.values.bodyType = 'text';
        delete bodyItemOut.values.bodyFile;
      }

      rule.items = [
        {enabled: statusEnabled, type: 'replaceResponseStatus',
            values: Object.assign({}, statusItem?.values, {statusCode: statusCode})},
        {enabled: ruleFields.querySelector('#rf-header-enabled').checked, type: 'replaceResponseHeader',
            values: Object.assign({}, headerItem?.values, {headers: headers})},
        bodyItemOut,
      ];
      return rule;
    }

    // responseUpdate
    const items = [];
    for (const row of ruleFields.querySelectorAll('#rf-upd-rows .upd-row')) {
      const type = row.children[0].value;
      const key = row.children[2].value;
      if (type !== 'removeHeader' && !key.trim()) throw new Error('改写项的匹配/名称不能为空');
      items.push({
        enabled: row.children[1].checked,
        type: type,
        values: Object.assign({}, row._item?.values, {
          key: key,
          value: row.children[3].value,
          useRegex: row._useRegex(),
        }),
      });
    }
    if (items.length === 0) throw new Error('请至少添加一条改写项');
    rule.items = items;
    return rule;
  }

  document.getElementById('btn-rewrites').addEventListener('click', openRewrites);
  document.getElementById('rewrites-close').addEventListener('click', () => rewritesDialog.close());
  document.getElementById('rewrites-add').addEventListener('click', () => openRuleDialog(null));
  document.getElementById('rule-cancel').addEventListener('click', () => ruleDialog.close());
  ruleJsonToggle.addEventListener('click', () => {
    if (!jsonMode) {
      // 表单 → JSON：把当前表单内容序列化进 textarea，避免丢失未保存修改
      try {
        ruleJson.value = JSON.stringify(collectRuleForm(), null, 2);
      } catch (error) {
        ruleError.textContent = error.message;
        return;
      }
      jsonMode = true;
    } else {
      // JSON → 表单：先校验可解析且类型支持
      try {
        const parsed = JSON.parse(ruleJson.value);
        if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
          throw new Error('规则必须是 JSON 对象');
        }
        if (!FORM_RULE_TYPES.includes(parsed.type)) {
          throw new Error('该类型规则仅支持 JSON 编辑');
        }
        editingRule = parsed;
      } catch (error) {
        ruleError.textContent = 'JSON 解析失败：' + error.message;
        return;
      }
      jsonMode = false;
      renderRuleFields();
    }
    ruleError.textContent = '';
    applyJsonMode();
  });
  document.getElementById('rule-submit').addEventListener('click', async () => {
    let payload;
    if (jsonMode) {
      try {
        payload = JSON.parse(ruleJson.value);
        if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) {
          throw new Error('规则必须是 JSON 对象');
        }
      } catch (error) {
        ruleError.textContent = 'JSON 解析失败：' + error.message;
        return;
      }
    } else {
      try {
        payload = collectRuleForm();
      } catch (error) {
        ruleError.textContent = error.message;
        return;
      }
    }

    try {
      if (editingIndex == null) {
        rewrites = await postJson('/api/console/rewrites', payload);
        toast('规则已创建');
      } else {
        rewrites = await putJson('/api/console/rewrites/' + editingIndex, payload);
        toast('规则已更新');
      }
      ruleDialog.close();
      renderRewrites();
    } catch (error) {
      ruleError.textContent = error.message;
    }
  });
  document.getElementById('rule-form').addEventListener('submit', (event) => event.preventDefault());

  // ---------- polling ----------
  async function poll() {
    if (polling) return;
    polling = true;
    try {
      const data = await fetchJson('/api/console/requests?since=' + revision);

      const cleared = (typeof data.revision === 'number' && data.revision < revision) ||
          (typeof data.count === 'number' && data.count < requests.size);
      if (cleared) {
        requests.clear();
        order.length = 0;
        revision = 0;
        listDirty = true;
        activeDomain = null;
        if (selectedId) {
          selectedId = null;
          clear(detailEl);
          detailEl.append(el('div', {class: 'placeholder muted', text: '选择左侧请求查看详情'}));
        }
        const full = await fetchJson('/api/console/requests?since=0');
        mergeRequests(full);
      } else {
        mergeRequests(data);
      }

      statusEl.textContent = '已连接 · ' + requests.size + ' 条';
      statusEl.className = 'muted';
    } catch (error) {
      statusEl.textContent = error.message.includes('认证') ? '认证失败' : '离线：' + error.message;
      statusEl.className = 'error';
    } finally {
      polling = false;
      renderList();
      maybeRefreshDetail();
      schedulePoll(1500);
    }
  }

  function mergeRequests(data) {
    const list = data.requests || [];
    for (const item of list) {
      if (!requests.has(item.id)) order.push(item.id);
      requests.set(item.id, item);
      listDirty = true;
    }
    if (typeof data.revision === 'number') {
      revision = Math.max(revision, data.revision);
    }
    // 客户端自身上限，避免长时间挂机后 DOM 过大
    while (order.length > 3000) {
      const removed = order.shift();
      requests.delete(removed);
      listDirty = true;
    }
  }

  let detailRefreshing = false;
  async function maybeRefreshDetail() {
    if (!selectedId || detailRefreshing) return;
    const summary = requests.get(selectedId);
    if (!summary || summary.revision === selectedRevision) return;

    detailRefreshing = true;
    try {
      await loadDetail(selectedId);
    } finally {
      detailRefreshing = false;
    }
  }

  function schedulePoll(delay) {
    clearTimeout(pollTimer);
    pollTimer = setTimeout(poll, delay == null ? 1500 : delay);
  }

  // ---------- header actions ----------
  document.querySelectorAll('#list-tabs .tab').forEach((tab) => {
    tab.addEventListener('click', () => {
      if (listTab === tab.dataset.tab) return;
      listTab = tab.dataset.tab;
      activeDomain = null;
      document.querySelectorAll('#list-tabs .tab').forEach((t) => t.classList.toggle('active', t === tab));
      listDirty = true;
      renderList();
    });
  });

  filterEl.addEventListener('input', () => {
    listDirty = true;
    renderList();
  });

  document.getElementById('btn-har').addEventListener('click', () => {
    location.href = api('/api/console/har');
  });

  document.getElementById('btn-clear').addEventListener('click', async () => {
    if (!confirm('清空控制台抓包数据？（不影响手机 App 的列表与代理）')) return;
    try {
      await postJson('/api/console/clear');
      requests.clear();
      order.length = 0;
      revision = 0;
      listDirty = true;
      selectedId = null;
      activeDomain = null;
      clear(detailEl);
      detailEl.append(el('div', {class: 'placeholder muted', text: '选择左侧请求查看详情'}));
      renderList();
      toast('已清空');
      schedulePoll(300);
    } catch (error) {
      toast(error.message, true);
    }
  });

  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) schedulePoll(200);
  });

  // ---------- start ----------
  if (!token) {
    statusEl.textContent = '缺少 token，请使用 App 内提供的控制台地址';
    statusEl.className = 'error';
  }
  poll();
})();
