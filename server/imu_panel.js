/* ============================================================================
 * imu_panel.js - AX650 / ICM-45686 IMU 实时数据浮层
 * ----------------------------------------------------------------------------
 * 接入方式（任意播放页加一行即可）：
 *   <script src="imu_panel.js"></script>
 * 可选：页面顶栏放一个 <button id="imu-toggle">IMU 数据</button> 作为开关，
 *       没有的话面板自带收起/关闭按钮，也能工作。
 *
 * URL 参数：
 *   imu=auto|hub|board|demo|off|<完整URL>   数据源模式（默认 auto）
 *   board=http://192.168.137.226:8099        板端 HTTP 服务根地址（board 模式 / auto 兜底）
 *   hub=imu_latest.json                      同源 JSON 路径（hub 模式）
 *   poll=200                                 轮询间隔 ms
 *   raw=1                                    强制把数值当原始 LSB 换算
 *
 * 数据信封（板端 / 服务器统一格式，页面负责解析）：
 * {
 *   "src":  "icm45686",
 *   "ts":   1731467890.123,        // 采集/接收时刻 epoch 秒
 *   "seq":  123,                   // 帧序号（用于算丢帧）
 *   "lines":["ts_us=... ax=... ay=... az=... gx=... gy=... gz=... temp=...", ...],
 *   "conf": "acc_odr=200 Hz ...",  // sample_icm45686 --conf 原文
 *   "caps": "...",                 // --caps / --range 原文（可选）
 *   "irq":  123456,                // /proc/interrupts 中 icm45686-int1 累计
 *   "raw":  "..."                  // 其它诊断原文（可选）
 * }
 *
 * 解析策略：优先 key=value / acc=[..] gyr=[..]，再退化为 CSV 与纯数字序列；
 * 完全无法识别时，原始文本仍会在「原始输出」里显示，不会白屏。
 * ==========================================================================*/
(function () {
  'use strict';

  var qs = new URLSearchParams(location.search);
  var LS_KEY = 'imuPanelCfg.v1';
  var saved = {};
  try { saved = JSON.parse(localStorage.getItem(LS_KEY) || '{}'); } catch (e) {}

  var CFG = {
    mode: qs.get('imu') || saved.mode || 'auto',
    board: qs.get('board') || saved.board || 'http://192.168.137.226:8099',
    hub: qs.get('hub') || 'imu_latest.json',
    poll: Math.max(60, parseInt(qs.get('poll') || '200', 10) || 200),
    raw: qs.get('raw') === '1'
  };

  var S = {
    hist: [], lastAt: 0, frames: 0, seq: 0, seqLost: 0,
    irq: null, irqPrev: null, irqAt: 0, irqRate: 0,
    rate: 0, lost: 0, lastEnv: null, lastErr: '',
    diag: {}, srcLabel: '-', scaleRaw: CFG.raw,
    timer: null, jsonpSeq: 0, online: false, busy: false, autoSrc: '',
    lastFrameId: null, lastParsed: 0, lastFreshAt: 0, demoT0: 0
  };
  var MAX_HIST = 600;

  /* ------------------------------------------------------------------ CSS */
  var css = [
    '#imu-panel{position:fixed;right:14px;bottom:14px;width:334px;max-width:calc(100vw - 28px);',
    '  max-height:calc(100vh - 80px);background:rgba(24,26,29,.94);border:1px solid #3a4149;',
    '  border-radius:10px;box-shadow:0 8px 30px rgba(0,0,0,.55);color:#e6edf3;',
    '  font:12px/1.45 -apple-system,"Segoe UI","Microsoft YaHei",sans-serif;z-index:9999;',
    '  display:flex;flex-direction:column;overflow:hidden;backdrop-filter:blur(4px)}',
    '#imu-panel.imu-hide{display:none}',
    '.imu-head{display:flex;align-items:center;gap:8px;padding:8px 10px;cursor:pointer;',
    '  background:#20252b;border-bottom:1px solid #333b43;user-select:none}',
    '.imu-head b{font-size:12px;letter-spacing:.3px;color:#4fc3f7;font-weight:600}',
    '.imu-dot{width:8px;height:8px;border-radius:50%;background:#777;flex:0 0 auto;',
    '  box-shadow:0 0 0 3px rgba(255,255,255,.05)}',
    '.imu-dot.ok{background:#4caf50}.imu-dot.demo{background:#ffb300}.imu-dot.bad{background:#ef5350}',
    '.imu-state{color:#9aa7b2;font-size:11px;flex:1;text-align:right;overflow:hidden;',
    '  white-space:nowrap;text-overflow:ellipsis}',
    '.imu-head button{background:transparent;border:1px solid #46515b;color:#b9c4ce;',
    '  border-radius:5px;width:22px;height:22px;line-height:18px;padding:0;cursor:pointer;font-size:14px}',
    '.imu-head button:hover{background:#33404b}',
    '.imu-body{overflow-y:auto;padding:10px;scrollbar-width:thin}',
    '.imu-body.imu-fold{display:none}',
    '.imu-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:6px}',
    '.imu-cell{background:#171b1f;border:1px solid #303841;border-radius:6px;padding:5px 6px}',
    '.imu-cell label{display:block;color:#8b98a5;font-size:10px;letter-spacing:.5px}',
    '.imu-cell strong{display:inline-block;font:600 15px/1.3 ui-monospace,Consolas,"Courier New",monospace;',
    '  font-variant-numeric:tabular-nums;color:#eaf2f8;min-width:62px}',
    '.imu-cell em{font-style:normal;color:#6f7d89;font-size:10px;margin-left:2px}',
    '.imu-sub{display:flex;flex-wrap:wrap;gap:4px 12px;color:#9aa7b2;margin:8px 2px 6px;font-size:11px}',
    '.imu-sub b{color:#cfd8e3;font-weight:500;font-variant-numeric:tabular-nums}',
    '.imu-chart{position:relative;height:70px;margin:6px 0;background:#12161a;',
    '  border:1px solid #2c343c;border-radius:6px;overflow:hidden}',
    '.imu-chart canvas{display:block;width:100%;height:100%}',
    '.imu-tag{position:absolute;left:6px;top:3px;color:#788693;font-size:10px;pointer-events:none}',
    '.imu-legend{position:absolute;right:6px;top:3px;font-size:10px;pointer-events:none}',
    '.imu-legend i{font-style:normal;margin-left:6px}',
    '.imu-diag{width:100%;border-collapse:collapse;margin-top:6px;font-size:11px}',
    '.imu-diag td{padding:3px 4px;border-bottom:1px solid #262d34}',
    '.imu-diag td:first-child{color:#8b98a5;width:42%}',
    '.imu-diag td:last-child{text-align:right;color:#dce6ee;',
    '  font-family:ui-monospace,Consolas,monospace;font-variant-numeric:tabular-nums}',
    '.imu-src{display:flex;gap:5px;align-items:center;margin-top:9px;flex-wrap:wrap}',
    '.imu-src select,.imu-src input{background:#12161a;color:#dce6ee;border:1px solid #3a444e;',
    '  border-radius:5px;padding:4px 5px;font-size:11px;min-width:0}',
    '.imu-src select{flex:0 0 92px}.imu-src input{flex:1 1 130px}',
    '.imu-src button{background:#2196f3;color:#fff;border:0;border-radius:5px;padding:5px 9px;',
    '  font-size:11px;cursor:pointer}.imu-src button:hover{background:#1976d2}',
    '.imu-raw{margin-top:8px;color:#8b98a5;font-size:10px}',
    '.imu-raw summary{cursor:pointer;outline:none}',
    '.imu-raw pre{max-height:120px;overflow:auto;background:#0e1114;border:1px solid #2c343c;',
    '  border-radius:5px;padding:6px;margin:5px 0 0;color:#9fb3c2;',
    '  font:10px/1.4 ui-monospace,Consolas,monospace;white-space:pre-wrap;word-break:break-all}',
    '#imu-toggle{background:#26313a;color:#4fc3f7;border:1px solid #3d5060;border-radius:6px;',
    '  padding:5px 10px;font-size:12px;cursor:pointer}',
    '#imu-toggle:hover{background:#30404d}#imu-toggle.off{color:#8b98a5;border-color:#3a4149}',
    '@media(max-width:520px){#imu-panel{right:8px;bottom:8px;width:calc(100vw - 16px)}}'
  ].join('\n');
  var st = document.createElement('style'); st.textContent = css;
  document.head.appendChild(st);

  /* ----------------------------------------------------------------- DOM */
  var AX = ['X', 'Y', 'Z'];
  var COLORS = ['#ff6b6b', '#51cf66', '#4fc3f7'];
  var panel = document.createElement('div');
  panel.id = 'imu-panel';
  panel.innerHTML = [
    '<div class="imu-head" id="imu-head">',
    '  <span class="imu-dot" id="imu-dot"></span><b>IMU · ICM-45686</b>',
    '  <span class="imu-state" id="imu-state">等待数据</span>',
    '  <button id="imu-fold" title="折叠/展开">-</button>',
    '  <button id="imu-close" title="关闭">x</button>',
    '</div>',
    '<div class="imu-body" id="imu-body">',
    '  <div class="imu-grid" id="imu-grid"></div>',
    '  <div class="imu-sub">',
    '    <span>温度 <b id="imu-temp">--</b> C</span>',
    '    <span>时间戳 <b id="imu-ts">--</b></span>',
    '    <span>帧 <b id="imu-seq">--</b></span>',
    '    <span>延迟 <b id="imu-lag">--</b></span>',
    '  </div>',
    '  <div class="imu-chart"><canvas id="imu-c1"></canvas>',
    '    <span class="imu-tag">ACC (g)</span><span class="imu-legend">',
    '    <i style="color:#ff6b6b">X</i><i style="color:#51cf66">Y</i><i style="color:#4fc3f7">Z</i></span></div>',
    '  <div class="imu-chart"><canvas id="imu-c2"></canvas>',
    '    <span class="imu-tag">GYR (dps)</span></div>',
    '  <table class="imu-diag"><tbody id="imu-diag"></tbody></table>',
    '  <div class="imu-src">',
    '    <select id="imu-mode">',
    '      <option value="auto">自动</option><option value="hub">服务器中转</option>',
    '      <option value="board">板端直连</option><option value="demo">演示数据</option>',
    '      <option value="off">关闭</option></select>',
    '    <input id="imu-url" type="text" spellcheck="false" placeholder="板端地址 / 自定义 URL" />',
    '    <button id="imu-apply">应用</button>',
    '  </div>',
    '  <details class="imu-raw"><summary>原始驱动输出</summary><pre id="imu-raw">--</pre></details>',
    '</div>'
  ].join('\n');
  document.body.appendChild(panel);

  var $ = function (id) { return document.getElementById(id); };
  var cells = [];
  (function buildCells() {
    var g = $('imu-grid'), html = '';
    ['ACC', 'GYR'].forEach(function (pre) {
      for (var i = 0; i < 3; i++) {
        html += '<div class="imu-cell"><label>' + pre + ' ' + AX[i] + '</label>' +
          '<strong id="imu-' + pre.toLowerCase() + i + '">--</strong><em>' +
          (pre === 'ACC' ? 'g' : 'dps') + '</em></div>';
      }
    });
    g.innerHTML = html;
    ['ACC', 'GYR'].forEach(function (pre) {
      for (var i = 0; i < 3; i++) cells.push($('imu-' + pre.toLowerCase() + i));
    });
  })();

  var DIAG_KEYS = [
    ['数据源', 'src'], ['ODR', 'odr'], ['量程', 'fs'], ['功耗模式', 'power'],
    ['DRDY 中断', 'irq'], ['中断速率', 'irqRate'], ['实测速率', 'rate'],
    ['丢样/丢帧', 'lost'], ['本帧样本', 'samples'], ['链路延迟', 'lag'],
    ['数值单位', 'unit']
  ];
  $('imu-diag').innerHTML = DIAG_KEYS.map(function (k) {
    return '<tr><td>' + k[0] + '</td><td id="imu-d-' + k[1] + '">--</td></tr>';
  }).join('');

  var toggle = $('imu-toggle');
  function setVisible(v) {
    panel.classList.toggle('imu-hide', !v);
    if (toggle) { toggle.classList.toggle('off', !v); toggle.textContent = v ? 'IMU 数据' : 'IMU (关)'; }
  }
  if (toggle) toggle.addEventListener('click', function () {
    setVisible(panel.classList.contains('imu-hide'));
  });
  $('imu-close').addEventListener('click', function (e) { e.stopPropagation(); setVisible(false); });
  $('imu-head').addEventListener('click', function () { $('imu-body').classList.toggle('imu-fold'); });

  /* -------------------------------------------------------- 解析驱动输出 */
  var ODR_CODE = { 3: 6400, 4: 3200, 5: 1600, 6: 800, 7: 400, 8: 200, 9: 100,
    10: 50, 11: 25, 12: 12.5, 13: 6.25, 14: 3.125, 15: 1.5625 };

  function numAt(arr, i) { return (i < arr.length && isFinite(arr[i])) ? arr[i] : null; }
  function compact(s) { return String(s).toLowerCase().replace(/[_.\-\[\]]/g, ''); }

  function pickKV(kv, names) {
    for (var i = 0; i < names.length; i++) {
      if (kv[names[i]] !== undefined && isFinite(kv[names[i]])) return kv[names[i]];
    }
    return null;
  }

  /* 把一行驱动输出解析成 {acc:[3], gyr:[3], temp, ts} */
  function parseLine(line) {
    if (typeof line !== 'string' || !line.trim()) return null;
    var out = { acc: null, gyr: null, temp: null, ts: null }, kv = {};

    // 1) key=value / key: value
    line.replace(/([A-Za-z_][\w.\-\[\]]*)\s*[:=]\s*(-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)/g,
      function (m, k, v) { kv[compact(k)] = parseFloat(v); return m; });

    var ts = pickKV(kv, ['tsus', 'timestampus', 'tus', 'timestamp', 'ts', 'time']);
    if (ts !== null) out.ts = ts;

    var acc = [
      pickKV(kv, ['ax', 'accx', 'accelx', 'acc0', 'a0']),
      pickKV(kv, ['ay', 'accy', 'accely', 'acc1', 'a1']),
      pickKV(kv, ['az', 'accz', 'accelz', 'acc2', 'a2'])
    ];
    var gyr = [
      pickKV(kv, ['gx', 'gyrx', 'gyrox', 'gyr0', 'g0']),
      pickKV(kv, ['gy', 'gyry', 'gyroy', 'gyr1', 'g1']),
      pickKV(kv, ['gz', 'gyrz', 'gyroz', 'gyr2', 'g2'])
    ];
    var temp = pickKV(kv, ['temp', 'temperature', 'tempc', 't']);

    // 2) acc=[a,b,c] / gyr=[a,b,c]（含无方括号的空格分隔形式）
    function group(re) {
      var m = re.exec(line);
      if (!m) return null;
      var a = (m[1].match(/-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/g) || []).map(Number);
      return a.length >= 3 ? [a[0], a[1], a[2]] : null;
    }
    var ga = group(/\bacc(?:el)?\w*\s*[:=]?\s*\[([^\]]+)\]/i);
    var gg = group(/\bgyr(?:o)?\w*\s*[:=]?\s*\[([^\]]+)\]/i);
    if (ga) acc = ga;
    if (gg) gyr = gg;

    // 3) CSV / 纯数字序列兜底
    if (!acc[0] && acc[0] !== 0 || !gyr[0] && gyr[0] !== 0) {
      var cleaned = line.replace(/\d{1,2}:\d{2}:\d{2}(?:[.,]\d+)?/g, ' ');
      var nums = (cleaned.match(/-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/g) || []).map(Number);
      var off = 0;
      if (nums.length >= 7 && (Math.abs(nums[0]) > 1e6)) off = 1;  // 首列是 us/ns 时间戳
      if (nums.length - off >= 6) {
        acc = [nums[off], nums[off + 1], nums[off + 2]];
        gyr = [nums[off + 3], nums[off + 4], nums[off + 5]];
        if (temp === null) temp = numAt(nums, off + 6);
        if (out.ts === null && off) out.ts = nums[0];
      }
    }

    if (acc.every(function (v) { return v !== null && isFinite(v); }) &&
        gyr.every(function (v) { return v !== null && isFinite(v); })) {
      out.acc = acc; out.gyr = gyr;
      if (temp !== null && Math.abs(temp) < 200) out.temp = temp;
      return out;
    }
    return null;
  }

  function parseConf(txt) {
    var d = {}, t = String(txt || '');
    var m;
    if ((m = /(?:acc_?odr|odr|sample_?rate)\s*[:=]\s*(0x[0-9a-f]+|\d+(?:\.\d+)?)/i.exec(t))) {
      var v = /^0x/i.test(m[1]) ? ODR_CODE[parseInt(m[1], 16)] : parseFloat(m[1]);
      if (v) d.odr = v;
    }
    if ((m = /(?:acc_?(?:fs|range|fssel)|acc[^0-9]{0,12})\s*[:=]?\s*[±+-]?\s*(\d+(?:\.\d+)?)\s*g\b/i.exec(t))) d.accFs = parseFloat(m[1]);
    if ((m = /(?:gyr_?(?:fs|range|fssel)|gyr[^0-9]{0,12})\s*[:=]?\s*[±+-]?\s*(\d+(?:\.\d+)?)\s*dps/i.exec(t))) d.gyrFs = parseFloat(m[1]);
    if ((m = /(?:power|pwr|mode)\s*[:=]?\s*([a-z][a-z0-9\- ]{2,20})/i.exec(t))) {
      d.power = m[1].trim().replace(/\s+(hz|dps|g).*$/i, '').trim();
    }
    if ((m = /(?:\brate|measured|freq)\s*[:=]?\s*(\d+(?:\.\d+)?)\s*(?:hz|sps)?/i.exec(t))) d.rate = parseFloat(m[1]);
    if ((m = /(?:lost|drop|miss|overrun)\w*\s*[:=]?\s*(\d+)/i.exec(t))) d.lost = parseInt(m[1], 10);
    if ((m = /(?:jitter|std)\s*[:=]?\s*(\d+(?:\.\d+)?)/i.exec(t))) d.jitter = parseFloat(m[1]);
    return d;
  }

  /* 原始 LSB -> 物理量（驱动默认 ±16g / ±1000dps，16bit） */
  function scaleSample(s) {
    var a = Math.max(Math.abs(s.acc[0]), Math.abs(s.acc[1]), Math.abs(s.acc[2]));
    var g = Math.max(Math.abs(s.gyr[0]), Math.abs(s.gyr[1]), Math.abs(s.gyr[2]));
    if (!CFG.raw && !(a > 40 || g > 5000)) return false;
    s.acc = s.acc.map(function (v) { return v / 2048; });
    s.gyr = s.gyr.map(function (v) { return v / 32.768; });
    return true;
  }

  /* ------------------------------------------------------------ 数据接入 */
  function jsonp(url, timeoutMs) {
    return new Promise(function (resolve, reject) {
      var cb = '__imuCb' + (++S.jsonpSeq) + '_' + Date.now();
      var s = document.createElement('script'), done = false;
      function cleanup() {
        done = true; clearTimeout(timer);
        try { delete window[cb]; } catch (e) { window[cb] = undefined; }
        if (s.parentNode) s.parentNode.removeChild(s);
      }
      var timer = setTimeout(function () { if (!done) { cleanup(); reject(new Error('JSONP 超时')); } },
        timeoutMs || Math.max(1200, Math.min(4000, CFG.poll * 3)));
      window[cb] = function (data) { if (!done) { cleanup(); resolve(data); } };
      s.onerror = function () { if (!done) { cleanup(); reject(new Error('板端服务不可达')); } };
      s.src = url + (url.indexOf('?') < 0 ? '?' : '&') + 'cb=' + cb + '&_=' + Date.now();
      document.head.appendChild(s);
    });
  }
  function fetchJson(url) {
    return fetch(url + (url.indexOf('?') < 0 ? '?' : '&') + '_=' + Date.now(),
      { cache: 'no-store', credentials: 'omit' }).then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
      });
  }
  function boardUrl() {
    var u = (CFG.board || '').replace(/\/+$/, '');
    if (!u) return '';
    if (/\/cgi-bin\//.test(u) || /\?/.test(u) || /\.json$/.test(u)) return u;
    return u + '/cgi-bin/imu';
  }
  function getEnvelope() {
    var m = CFG.mode;
    if (m === 'demo') return Promise.resolve(makeDemo());
    if (m === 'off') return Promise.resolve(null);
    if (m === 'hub') return fetchJson(CFG.hub);
    if (m === 'board') return jsonp(boardUrl());
    if (m.indexOf('http') === 0) {
      return fetchJson(m)['catch'](function () { return jsonp(m); });
    }
    // auto: 同源中转优先，失败再试板端直连；成功后锁定该源，避免每轮双请求
    if (S.autoSrc === 'board') return jsonp(boardUrl());
    if (S.autoSrc === 'hub') return fetchJson(CFG.hub);
    return fetchJson(CFG.hub).then(function (e) { S.autoSrc = 'hub'; return e; })['catch'](function (e) {
      var b = boardUrl();
      if (!b) throw e;
      return jsonp(b).then(function (e2) { S.autoSrc = 'board'; return e2; })['catch'](function () { throw e; });
    });
  }

  function makeDemo() {
    var t = Date.now() / 1000, lines = [];
    if (!S.demoT0) S.demoT0 = t - 10;                 // 模拟驱动「上电计时」时间戳
    for (var i = 0; i < 8; i++) {
      var x = t - 0.4 + i * 0.05;
      lines.push('ts_us=' + Math.round((x - S.demoT0) * 1e6) +
        ' ax=' + (0.14 * Math.sin(x * 2.1)).toFixed(4) +
        ' ay=' + (0.09 * Math.cos(x * 1.4)).toFixed(4) +
        ' az=' + (9.801 + 0.04 * Math.sin(x * 3)).toFixed(4) +
        ' gx=' + (4.2 * Math.sin(x * 1.7)).toFixed(3) +
        ' gy=' + (2.6 * Math.cos(x * 2.3)).toFixed(3) +
        ' gz=' + (0.8 * Math.sin(x * 0.9)).toFixed(3) +
        ' temp=' + (32.4 + 0.2 * Math.sin(x * 0.3)).toFixed(2));
    }
    S.seq++;
    return {
      src: 'icm45686 (演示)', ts: t, seq: S.seq, lines: lines,
      conf: 'acc_odr=200 Hz gyr_odr=200 Hz acc_fs=16 g gyr_fs=1000 dps power=low-noise',
      irq: 200000 + S.seq * 40
    };
  }

  /* ------------------------------------------------------------ 渲染 */
  function fmt(v, d) { return (v === null || v === undefined || !isFinite(v)) ? '--' : Number(v).toFixed(d === undefined ? 3 : d); }
  function fmtTs(us) {
    if (us === null || us === undefined || !isFinite(us)) return '--';
    if (us > 1e14) us /= 1000;               // ns -> us
    return (us / 1e6).toFixed(3) + ' s';      // 驱动 us 时间戳（上电计时）
  }
  function setDiag(k, v) { var el = $('imu-d-' + k); if (el) el.textContent = v; }

  function applyEnv(env) {
    if (!env || typeof env !== 'object') return;
    var now = Date.now() / 1000;
    // 同源 JSON 轮询会反复读到同一帧，用 hub_seq/seq 去重，避免波形被同一批点填满
    var frameId = (typeof env.hub_seq === 'number') ? env.hub_seq
      : (typeof env.seq === 'number' ? env.seq : null);
    var fresh = (frameId === null) || (frameId !== S.lastFrameId);
    S.lastFrameId = frameId;
    S.lastAt = Date.now(); S.frames++; S.lastEnv = env; S.online = true;

    var lines = Array.isArray(env.lines) ? env.lines : [];
    if (!lines.length && typeof env.line === 'string') lines = [env.line];
    if (!lines.length && typeof env.raw === 'string') lines = env.raw.split(/\r?\n/);

    if (!fresh) {
      render(lines, S.diag, $('imu-lag').textContent, S.lastParsed);
      return;
    }
    S.lastFreshAt = Date.now();

    var pts = [], parsed = 0;
    for (var i = 0; i < lines.length; i++) {
      var s = parseLine(lines[i]);
      if (!s) continue;
      if (scaleSample(s)) S.scaleRaw = true;
      parsed++;
      pts.push({ t: (s.ts && s.ts > 1e6) ? s.ts / 1e6 : now - (lines.length - i) * 0.005,
        ts: s.ts, acc: s.acc, gyr: s.gyr, temp: s.temp });
    }
    if (pts.length) {
      S.hist = S.hist.concat(pts);
      if (S.hist.length > MAX_HIST) S.hist = S.hist.slice(-MAX_HIST);
    }

    // 诊断：配置原文 + 统计
    var d = parseConf((env.conf || '') + '\n' + (env.caps || '') + '\n' + (env.raw || ''));
    S.diag = d;
    S.srcLabel = env.src || (CFG.mode === 'demo' ? '演示' : CFG.mode);

    // 帧序号 / 丢帧
    if (typeof env.seq === 'number') {
      if (S.seq && env.seq > S.seq + 1) S.seqLost += env.seq - S.seq - 1;
      S.seq = env.seq;
    } else S.seq++;

    // 中断计数与速率
    if (typeof env.irq === 'number') {
      var ms = Date.now();
      if (S.irqPrev !== null && ms > S.irqAt) {
        S.irqRate = (env.irq - S.irqPrev) * 1000 / (ms - S.irqAt);
      }
      S.irqPrev = env.irq; S.irqAt = ms; S.irq = env.irq;
    }

    // 实测采样率：优先用时间戳差，否则用本帧样本数 / 轮询间隔
    if (pts.length > 1 && pts[pts.length - 1].t > pts[0].t) {
      S.rate = (pts.length - 1) / (pts[pts.length - 1].t - pts[0].t);
    } else if (parsed) {
      S.rate = parsed * 1000 / CFG.poll;
    }
    var expect = d.odr || S.irqRate || S.rate;
    if (expect > 0 && S.rate > 0) {
      S.lost = Math.max(0, Math.round(expect - S.rate)) + S.seqLost;
    }

    // 链路延迟（仅当两端时钟可比时）
    var lag = '--';
    var refTs = (typeof env.hub_ts === 'number') ? env.hub_ts : env.ts;
    if (typeof refTs === 'number' && refTs > 1e9 && Math.abs(now - refTs) < 86400) {
      lag = Math.max(0, now - refTs).toFixed(2) + ' s';
    }
    $('imu-lag').textContent = lag;
    S.lastParsed = parsed;

    render(lines, d, lag, parsed);
  }

  function render(lines, d, lag, parsed) {
    var last = S.hist.length ? S.hist[S.hist.length - 1] : null;
    for (var i = 0; i < 6; i++) {
      cells[i].textContent = last ? fmt(i < 3 ? last.acc[i] : last.gyr[i - 3]) : '--';
    }
    $('imu-temp').textContent = last && last.temp !== null ? fmt(last.temp, 2) : '--';
    $('imu-ts').textContent = last ? fmtTs(last.ts) : '--';
    $('imu-ts').title = last && last.ts ? String(last.ts) : '';
    $('imu-seq').textContent = S.seq || '--';

    var dot = $('imu-dot'), state = $('imu-state');
    var demo = CFG.mode === 'demo';
    var idle = (Date.now() - (S.lastFreshAt || 0)) / 1000;   // 多久没有新帧
    var stale = !demo && (idle > 3);
    dot.className = 'imu-dot ' + (demo ? 'demo' : (stale ? 'bad' : (S.online ? 'ok' : 'bad')));
    state.textContent = demo ? '演示数据'
      : stale ? ('数据陈旧 ' + idle.toFixed(0) + 's · 检查采集端')
        : (S.online ? S.srcLabel + ' · 实时' : '离线');
    if (!demo && Date.now() - S.lastAt > 3000) {
      dot.className = 'imu-dot bad';
      state.textContent = '无数据 · ' + (S.lastErr || '检查采集端');
    }

    setDiag('src', S.srcLabel);
    setDiag('odr', d.odr ? d.odr + ' Hz' : '--');
    setDiag('fs', (d.accFs ? '±' + d.accFs + ' g' : '--') + ' / ' + (d.gyrFs ? '±' + d.gyrFs + ' dps' : '--'));
    setDiag('power', d.power || '--');
    setDiag('irq', S.irq === null ? '--' : S.irq.toLocaleString());
    setDiag('irqRate', S.irqRate ? S.irqRate.toFixed(1) + ' /s' : '--');
    setDiag('rate', S.rate ? S.rate.toFixed(1) + ' Hz' : '--');
    setDiag('lost', S.lost ? S.lost.toString() : '0');
    setDiag('samples', parsed + ' 行 / 帧');
    setDiag('lag', lag);
    setDiag('unit', S.scaleRaw ? '原始 LSB 已换算' : 'g / dps');

    var raw = lines.slice(-20).join('\n');
    if (S.lastEnv && S.lastEnv.conf) raw += '\n-- conf --\n' + S.lastEnv.conf;
    if (S.lastEnv && S.lastEnv.caps) raw += '\n-- caps --\n' + S.lastEnv.caps;
    $('imu-raw').textContent = raw || '--';

    drawChart($('imu-c1'), 'acc');
    drawChart($('imu-c2'), 'gyr');
  }
  function drawChart(cv, key) {
    if (!cv) return;
    var dpr = window.devicePixelRatio || 1;
    var w = cv.clientWidth || 300, h = cv.clientHeight || 70;
    if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) {
      cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr);
    }
    var c = cv.getContext('2d');
    c.setTransform(dpr, 0, 0, dpr, 0, 0);
    c.clearRect(0, 0, w, h);
    c.strokeStyle = '#242c34'; c.lineWidth = 1;
    for (var gy = 1; gy < 4; gy++) {
      c.beginPath(); c.moveTo(0, h * gy / 4); c.lineTo(w, h * gy / 4); c.stroke();
    }
    var pts = S.hist.slice(-240);
    if (pts.length < 2) return;
    var lo = Infinity, hi = -Infinity;
    pts.forEach(function (p) {
      p[key].forEach(function (v) { if (v < lo) lo = v; if (v > hi) hi = v; });
    });
    var minSpan = key === 'acc' ? 0.4 : 8;
    if (hi - lo < minSpan) { var mid = (hi + lo) / 2; lo = mid - minSpan / 2; hi = mid + minSpan / 2; }
    var pad = (hi - lo) * 0.12; lo -= pad; hi += pad;
    // 零线
    if (lo < 0 && hi > 0) {
      var zy = h - (0 - lo) / (hi - lo) * h;
      c.strokeStyle = '#3a4650'; c.setLineDash([3, 3]);
      c.beginPath(); c.moveTo(0, zy); c.lineTo(w, zy); c.stroke(); c.setLineDash([]);
    }
    for (var ch = 0; ch < 3; ch++) {
      c.strokeStyle = COLORS[ch]; c.lineWidth = 1.4; c.beginPath();
      for (var i = 0; i < pts.length; i++) {
        var x = i / (pts.length - 1) * w;
        var y = h - (pts[i][key][ch] - lo) / (hi - lo) * h;
        if (i === 0) c.moveTo(x, y); else c.lineTo(x, y);
      }
      c.stroke();
    }
  }

  /* ------------------------------------------------------------ 轮询循环 */
  function tick() {
    if (CFG.mode === 'off' || S.busy) return;
    S.busy = true;
    getEnvelope().then(function (env) {
      if (env) { applyEnv(env); S.lastErr = ''; }
    })['catch'](function (e) {
      S.online = false; S.lastErr = e.message || String(e);
      var dot = $('imu-dot'); dot.className = 'imu-dot bad';
      $('imu-state').textContent = '无数据 · ' + S.lastErr;
    }).then(function () { S.busy = false; }, function () { S.busy = false; });
  }
  function restart() {
    clearInterval(S.timer);
    S.hist = []; S.seqLost = 0; S.irqPrev = null; S.autoSrc = ''; S.busy = false;
    S.lastFrameId = null; S.lastParsed = 0; S.lastFreshAt = 0;
    tick();
    if (CFG.mode !== 'off') S.timer = setInterval(tick, CFG.poll);
  }

  /* ------------------------------------------------------------ 数据源 UI */
  var sel = $('imu-mode'), input = $('imu-url');
  if (['auto', 'hub', 'board', 'demo', 'off'].indexOf(CFG.mode) >= 0) sel.value = CFG.mode;
  else sel.value = 'auto';
  input.value = CFG.mode.indexOf('http') === 0 ? CFG.mode : CFG.board;
  $('imu-apply').addEventListener('click', function () {
    var v = input.value.trim();
    var m = sel.value;
    if (m === 'board' || m === 'auto') { CFG.board = v || CFG.board; }
    if (v.indexOf('http') === 0 && m === 'auto') m = v;   // 输入框填完整 URL 时按自定义源
    CFG.mode = m;
    try { localStorage.setItem(LS_KEY, JSON.stringify({ mode: CFG.mode, board: CFG.board })); } catch (e) {}
    setVisible(true);
    restart();
  });
  input.addEventListener('keydown', function (e) { if (e.key === 'Enter') $('imu-apply').click(); });
  sel.addEventListener('change', function () {
    if (sel.value === 'board' && input.value.indexOf('http') !== 0) input.value = CFG.board;
  });

  window.addEventListener('resize', function () { drawChart($('imu-c1'), 'acc'); drawChart($('imu-c2'), 'gyr'); });
  document.addEventListener('visibilitychange', function () { if (!document.hidden) tick(); });

  if (CFG.mode === 'off') setVisible(false);
  restart();
})();
