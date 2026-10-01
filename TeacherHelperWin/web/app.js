/* 教师助手 Windows 版 —— 前端逻辑（数据与 macOS 版共用同一套 JSON）
   约定：
   · 星期编号沿用 macOS 语义：1=周日 … 7=周六
   · 任何编辑即时落盘（与 macOS 2.5.10 起的「全板块编辑即落盘」一致）
   · 纯显示偏好（隐藏列等）只放 localStorage，不写进数据文件 */

const WEEK_LABEL = { 2: '周一', 3: '周二', 4: '周三', 5: '周四', 6: '周五', 7: '周六', 1: '周日' };
const DAY_ORDER = [2, 3, 4, 5, 6, 7, 1];      // 周一…周日（取值仍是 1=周日…7=周六）
const SHORT = { 2: '周一', 3: '周二', 4: '周三', 5: '周四', 6: '周五', 7: '周六', 1: '周日' };

const SECTIONS = [
  { key: '本人课表', id: 'personal', icon: '▦', legacy: [] },
  { key: '延时监考', id: 'extend', icon: '⏱', legacy: ['延时 & 监考'] },
  { key: '班级课表', id: 'class', icon: '▤', legacy: [] },
  { key: '他人课表', id: 'teacher', icon: '☰', legacy: [] },
  { key: '学生信息', id: 'students', icon: '👤', legacy: [] },
  { key: '学生座位', id: 'seating', icon: '🪑', legacy: ['班级学生座位安排'] },
  { key: '日程提醒', id: 'reminders', icon: '🔔', legacy: ['提醒设置'] },
  { key: '校历日历', id: 'calendar', icon: '📅', legacy: ['重庆校历'] },
  { key: '年级师资', id: 'staff', icon: '👥', legacy: ['年级师资安排'] },
  { key: '教师工位', id: 'office', icon: '🏢', legacy: ['办公室工位布局'] },
  { key: '教室布局', id: 'classroom', icon: '🚪', legacy: ['教室分布'] },
];

let S = {};        // 全部数据文件
let META = {};
let tab = localStorage.getItem('tab') || 'personal';
let saveTimers = {};

/* ---------------- 基础工具 ---------------- */
function $(id) { return document.getElementById(id); }
function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }
function doc(name) { return S[name]; }
function setDoc(name, v) { S[name] = v; }
function toast(msg) { const t = $('toast'); t.textContent = msg; t.classList.add('show'); clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove('show'), 1600); }

function save(name, immediate) {
  const doSave = () => fetch('/api/save?file=' + encodeURIComponent(name), {
    method: 'POST', body: JSON.stringify(S[name])
  }).then(r => r.json()).then(r => { if (!r.ok) toast('保存失败：' + (r.error || '')); }).catch(e => toast('保存失败：' + e));
  if (immediate) { clearTimeout(saveTimers[name]); return doSave(); }
  clearTimeout(saveTimers[name]);
  saveTimers[name] = setTimeout(doSave, 350);
}

/* ⚠️ 路径是相对「某个 json 文件」的（如 grid.3.2、rows.5.cells.1），
   不是相对整个数据对象 —— 必须先从 S[file] 开始走，否则一编辑就抛异常。 */
function setPathIn(file, path, val) {
  const p = path.split('.');
  let o = S[file];
  for (let i = 0; i < p.length - 1; i++) o = o[p[i]];
  o[p[p.length - 1]] = val;
}

/* 取元素纯文本：优先 textContent（innerText 在部分环境/旧内核里不存在） */
function textOf(el) { return (el.textContent || '').replace(/\s+/g, ' ').trim(); }

/* contenteditable 单元格编辑 → 即时写回 + 落盘 */
function cellEdit(el, file, path, isNum) {
  let v = textOf(el);
  if (isNum) v = v === '' ? 0 : Number(v) || 0;
  setPathIn(file, path, v);
  save(file, true);
}
function cellOnKey(e) { if (e.key === 'Enter') { e.preventDefault(); e.target.blur(); } }

function classColor(text) {
  const t = String(text || '');
  if (!t) return '';
  if (t.indexOf('巡') >= 0) return t.indexOf('16') >= 0 ? '#2aa3a3' : '#8e44ad';
  if (t.indexOf('考试') >= 0) return '#8e8e93';
  if (t.indexOf('7') >= 0) return '#f0a020';
  if (t.indexOf('8') >= 0) return '#3b82c4';
  return '#8a8a90';
}

/* ---------------- 启动 ---------------- */
async function boot() {
  S = await (await fetch('/api/data')).json();
  try { META = await (await fetch('/api/meta')).json(); } catch (e) { META = {}; }
  $('brandText').textContent = '教师助手' + (META.version ? '' : '');
  renderNav();
  render();
  setInterval(() => fetch('/api/ping', { method: 'POST' }).catch(() => { }), 2500);
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape' && !document.querySelector('.mask') && !(document.activeElement && document.activeElement.isContentEditable)) {
      fetch('/api/hide', { method: 'POST' });
    }
  });
}

/* ---------------- 左栏导航 ---------------- */
function navOrder() {
  const prefs = doc('nav_prefs.json') || {};
  const order = Array.isArray(prefs.order) && prefs.order.length ? prefs.order : SECTIONS.map(s => s.key);
  const hidden = new Set(prefs.hidden || []);
  const out = [];
  order.forEach(k => {
    if (hidden.has(k)) return;
    const sec = SECTIONS.find(s => s.key === k || s.legacy.indexOf(k) >= 0);
    if (sec && !out.includes(sec)) out.push(sec);
  });
  SECTIONS.forEach(s => { if (!out.includes(s)) out.push(s); });   // 兜底：没在 order 里的也显示
  return out;
}
function navTitle(sec) {
  const t = doc('titles.json') || {};
  return t['nav_' + sec.key] || t[sec.key] || sec.key;
}
function renderNav() {
  $('navList').innerHTML = navOrder().map(sec => {
    const active = sec.id === tab ? ' active' : '';
    return `<div class="nav-item${active}" data-tab="${sec.id}" onclick="go('${sec.id}')"
       ondblclick="renameNav('${sec.key}')" title="双击可改名"><span class="ico">${sec.icon}</span>${esc(navTitle(sec))}</div>`;
  }).join('');
}
function go(id) {
  tab = id; localStorage.setItem('tab', id);
  renderNav(); render();
}
function renameNav(key) {
  const cur = navTitle(SECTIONS.find(s => s.key === key));
  const v = prompt('把左侧「' + key + '」改名为：', cur);
  if (v == null || !v.trim()) return;
  const t = doc('titles.json') || {};
  t['nav_' + key] = v.trim();
  setDoc('titles.json', t); save('titles.json', true);
  renderNav(); render();
}

/* ---------------- 页面调度 ---------------- */
const PAGES = {};
function render() {
  const sec = SECTIONS.find(s => s.id === tab) || SECTIONS[0];
  $('pageTitle').textContent = navTitle(sec);
  $('headActions').innerHTML = '';
  $('pageHint').innerHTML = '';
  const fn = PAGES[sec.id];
  if (fn) fn(); else $('content').innerHTML = '<div class="card">该板块暂未实现</div>';
}
function openDataDir() { fetch('/api/open?target=datadir', { method: 'POST' }); }
function openHelp() {
  const dir = META.dataDir || '';
  dialog('使用说明', `
    <div class="note" style="color:var(--text)">
      · 左键点托盘图标：弹出/收起本面板；右键：菜单（测试提醒 / 开机自启 / 退出）<br>
      · <kbd>Esc</kbd>：收起面板<br>
      · 所有编辑即时保存，无需点「保存」<br>
      · 数据目录：<code>${esc(dir)}</code>（与 macOS 版同一套 JSON，可直接互相拷贝）<br>
      · 想做成便携版：把 exe 放进一个文件夹，再建 <code>data</code> 子文件夹把 JSON 拷进去即可。
    </div>`, '<button class="btn primary" onclick="closeDialog()">知道了</button>');
}

/* ---------------- 通用弹窗 ---------------- */
function dialog(title, bodyHTML, footHTML, onOpen) {
  closeDialog();
  const m = document.createElement('div');
  m.className = 'mask'; m.id = 'mask';
  m.innerHTML = `<div class="dialog"><h2>${esc(title)}</h2>${bodyHTML}<div class="foot">${footHTML || ''}</div></div>`;
  document.body.appendChild(m);
  if (onOpen) onOpen();
}
function closeDialog() { const m = $('mask'); if (m) m.remove(); }

/* ============================================================
   1. 我的课表
   ============================================================ */
PAGES.personal = function () {
  const p = doc('personal.json') || { grid: [], groups: [] };
  const grid = p.grid || [], groups = p.groups || [];
  const vis = visibleCols();
  const periods = [];
  groups.forEach(g => (g.periods || []).forEach(x => periods.push(x)));
  let html = `<div class="toolbar">
      <span class="pill">点击格子直接改内容</span>
      ${DAY_ORDER.map(w => `<span class="chip${vis.has(w) ? ' on' : ''}" onclick="toggleCol(${w})">${SHORT[w]}</span>`).join('')}
      <span class="pill" style="margin-left:6px">班级色</span>
      <span class="tag" style="color:#f0a020">● 7班</span>
      <span class="tag" style="color:#3b82c4">● 8班</span>
      <span class="tag" style="color:#8e44ad">● 巡1-15班</span>
      <span class="tag" style="color:#2aa3a3">● 巡16-30班</span>
    </div>`;
  html += `<table class="sched"><tr><th class="period">节次</th>` +
    DAY_ORDER.filter(w => vis.has(w)).map(w => `<th>${SHORT[w]}</th>`).join('') + `</tr>`;
  let gi = 0, rowBase = 0;
  groups.forEach((g, groupIdx) => {
    html += `<tr><td colspan="${vis.size + 1}" style="background:none;padding:2px 0">
        <div class="group-title">${esc(g.title || '')}</div></td></tr>`;
    (g.periods || []).forEach((per, k) => {
      const row = grid[rowBase + k] || [];
      html += `<tr><th class="period">${esc(per)}</th>`;
      DAY_ORDER.forEach((w, col) => {
        if (!vis.has(w)) return;
        const v = row[col] == null ? '' : row[col];
        const c = classColor(v);
        const style = c ? `background:${c};color:#fff` : '';
        html += `<td contenteditable="true" style="${style}" data-ph=""
            onkeydown="cellOnKey(event)" onblur="cellEdit(this,'personal.json','grid.${rowBase + k}.${col}')"
            >${esc(v)}</td>`;
      });
      html += `</tr>`;
    });
    rowBase += (g.periods || []).length;
    gi++;
  });
  html += `</table>`;
  $('content').innerHTML = html;
  $('pageHint').textContent = '不勾任何星期 = 一次性提醒那条规则不适用于课表；此页仅记录课程，点击格子即可编辑，改完自动保存。';
};

function visibleCols() {
  const saved = localStorage.getItem('visCols');
  const arr = saved ? JSON.parse(saved) : [2, 3, 4, 5, 6, 1];   // 默认隐藏周六（与 macOS 默认一致）
  return new Set(arr);
}
function toggleCol(w) {
  const vis = visibleCols();
  vis.has(w) ? vis.delete(w) : vis.add(w);
  localStorage.setItem('visCols', JSON.stringify([...vis]));
  render();
}

/* ============================================================
   2. 班级课表
   ============================================================ */
PAGES.class = function () {
  const c = doc('classes.json') || {};
  const list = c.classes || [];
  if (!c.defaultClass && list.length) c.defaultClass = list[0];
  const cur = c.defaultClass;
  const bank = (c.bank || {})[cur] || null;
  const legacy = doc('class7.json') || { groups: [], cells: {} };
  const data = bank || legacy;
  const groups = data.groups || [];
  const cells = data.cells || {};
  const vis = visibleCols();

  $('headActions').innerHTML =
    `<select onchange="pickClass(this.value)">${list.map(n => `<option${n === cur ? ' selected' : ''}>${esc(n)}</option>`).join('')}</select>
     <button class="btn" onclick="addClass()">＋ 新班级</button>`;

  let html = `<div class="toolbar">${DAY_ORDER.map(w =>
    `<span class="chip${vis.has(w) ? ' on' : ''}" onclick="toggleCol(${w})">${SHORT[w]}</span>`).join('')}</div>`;
  html += `<table class="sched"><tr><th class="period">节次</th>` +
    DAY_ORDER.filter(w => vis.has(w)).map(w => `<th>${SHORT[w]}</th>`).join('') + `</tr>`;
  groups.forEach(g => {
    html += `<tr><td colspan="${vis.size + 1}" style="background:none;padding:2px 0">
      <div class="group-title">${esc(g.title || '')}</div></td></tr>`;
    (g.periods || []).forEach(per => {
      const row = cells[per] || [];
      html += `<tr><th class="period">${esc(per)}</th>`;
      DAY_ORDER.forEach((w, col) => {
        if (!vis.has(w)) return;
        const v = row[col] == null ? '' : row[col];
        const bg = v ? '#f6f6f8' : '#f2f2f4';
        const path = bank ? `bank.${cur}.cells.${per}.${col}` : `cells.${per}.${col}`;
        const file = bank ? 'classes.json' : 'class7.json';
        html += `<td contenteditable="true" style="background:${bg}"
            onkeydown="cellOnKey(event)" onblur="cellEdit(this,'${file}','${path}')">${esc(v)}</td>`;
      });
      html += `</tr>`;
    });
  });
  html += `</table>`;
  $('content').innerHTML = html;
  $('pageHint').textContent = '这是「班级课表」：上面下拉切换班级；点击格子直接编辑（如「数学·林科」）。';
};
function pickClass(name) { S['classes.json'].defaultClass = name; save('classes.json', true); render(); }
function addClass() {
  const c = S['classes.json'];
  const n = prompt('新班级名称（如 初1-5）：');
  if (!n || !n.trim()) return;
  const name = n.trim();
  if (!c.classes.includes(name)) c.classes.push(name);
  if (!c.bank[name]) {
    const base = c.bank[c.defaultClass] || { groups: [{ title: '上午', periods: ['第1节', '第2节', '第3节', '第4节', '第5节'] }, { title: '下午', periods: ['第6节', '第7节', '第8节', '第9节'] }, { title: '晚自习', periods: ['第10节', '第11节', '第12节', '第13节'] }], cells: {} };
    c.bank[name] = JSON.parse(JSON.stringify(base));
  }
  c.defaultClass = name;
  save('classes.json', true); render();
}

/* ============================================================
   3. 他人课表
   ============================================================ */
PAGES.teacher = function () {
  const list = doc('teacher_schedules.json') || [];
  if (!list.length) { $('content').innerHTML = '<div class="card">还没有他人课表数据。</div>'; return; }
  if (!window._tIdx || window._tIdx >= list.length) window._tIdx = 0;
  const idx = window._tIdx, t = list[idx];
  const vis = visibleCols();
  $('headActions').innerHTML = `<select onchange="pickTeacher(this.value)">${list.map((x, i) =>
    `<option value="${i}"${i === idx ? ' selected' : ''}>${esc(x.teacher)}</option>`).join('')}</select>`;
  let html = `<div class="toolbar">${DAY_ORDER.map(w =>
    `<span class="chip${vis.has(w) ? ' on' : ''}" onclick="toggleCol(${w})">${SHORT[w]}</span>`).join('')}</div>`;
  html += `<table class="sched"><tr><th class="period">节次</th>` +
    DAY_ORDER.filter(w => vis.has(w)).map(w => `<th>${SHORT[w]}</th>`).join('') + `</tr>`;
  (t.periods || []).forEach((per, r) => {
    html += `<tr><th class="period">${esc(per)}</th>`;
    DAY_ORDER.forEach((w, col) => {
      if (!vis.has(w)) return;
      const v = (t.cells[r] || [])[col] || '';
      const c = classColor(v);
      html += `<td contenteditable="true" style="${c && v ? 'background:' + c + ';color:#fff' : ''}"
        onkeydown="cellOnKey(event)" onblur="cellEdit(this,'teacher_schedules.json','${idx}.cells.${r}.${col}')">${esc(v)}</td>`;
    });
    html += `</tr>`;
  });
  html += `</table>`;
  $('content').innerHTML = html;
  $('pageHint').textContent = '各位老师的课表：下拉切换老师，点击格子直接编辑。';
};
function pickTeacher(i) { window._tIdx = Number(i); render(); }

/* ============================================================
   4. 延时 / 监考
   ============================================================ */
PAGES.extend = function () {
  const blocks = doc('extend.json') || [];
  let html = '';
  blocks.forEach((b, bi) => {
    html += `<div class="card"><div class="toolbar" style="margin-bottom:6px">
      <b>${esc(b.title)}</b>
      <span class="pill">${b.kind === 'exam' ? '监考' : '延时'}</span>
      <span class="spacer" style="flex:1"></span>
      <button class="btn" onclick="addExtendRow(${bi})">＋ 加一行</button>
      <button class="btn" onclick="delExtendBlock(${bi})">删除本表</button>
    </div><table class="grid"><tr>${(b.header || []).map(h => `<th>${esc(h)}</th>`).join('')}<th style="width:40px"></th></tr>`;
    (b.rows || []).forEach((row, ri) => {
      html += `<tr>` + (b.header || []).map((h, ci) =>
        `<td class="editable" contenteditable="true" onkeydown="cellOnKey(event)"
          onblur="cellEdit(this,'extend.json','${bi}.rows.${ri}.${ci}')">${esc(row[ci] || '')}</td>`).join('') +
        `<td><button class="btn plain" onclick="delExtendRow(${bi},${ri})">✕</button></td></tr>`;
    });
    html += `</table></div>`;
  });
  html += `<button class="btn" onclick="addExtendBlock()">＋ 新建一张表</button>`;
  $('content').innerHTML = html;
  $('pageHint').textContent = '延时与监考安排：点击单元格直接改，改完自动保存。';
};
function addExtendRow(bi) {
  const b = S['extend.json'][bi];
  b.rows.push(new Array((b.header || []).length).fill(''));
  save('extend.json', true); render();
}
function delExtendRow(bi, ri) { S['extend.json'][bi].rows.splice(ri, 1); save('extend.json', true); render(); }
function delExtendBlock(bi) { if (!confirm('删除这张表？')) return; S['extend.json'].splice(bi, 1); save('extend.json', true); render(); }
function addExtendBlock() {
  const t = prompt('新表标题（如 周三延时）：'); if (!t) return;
  S['extend.json'].push({ id: uid(), title: t, kind: 'delay', header: ['第几周', '班级', '节次'], rows: [] });
  save('extend.json', true); render();
}

/* ============================================================
   5. 学生信息
   ============================================================ */
PAGES.students = function () {
  const d = doc('students.json') || { headers: [], rows: [] };
  const q = (window._stuQ || '').trim();
  $('headActions').innerHTML = `<input type="text" placeholder="搜索姓名/班级…" value="${esc(q)}"
      oninput="window._stuQ=this.value; stuSearch()" style="width:180px">
    <button class="btn" onclick="addStudent()">＋ 添加学生</button>`;
  let html = `<table class="grid" id="stuTable"><tr>${(d.headers || []).map(h => `<th>${esc(h)}</th>`).join('')}<th style="width:40px"></th></tr>`;
  (d.rows || []).forEach((r, ri) => {
    const txt = (r.cells || []).join(' ');
    const hit = !q || txt.indexOf(q) >= 0;
    html += `<tr style="${hit ? '' : 'display:none'}">` + (d.headers || []).map((h, ci) =>
      `<td class="editable" contenteditable="true" onkeydown="cellOnKey(event)"
        onblur="cellEdit(this,'students.json','rows.${ri}.cells.${ci}')">${esc((r.cells || [])[ci] || '')}</td>`).join('') +
      `<td><button class="btn plain" onclick="delStudent(${ri})">✕</button></td></tr>`;
  });
  html += `</table>`;
  $('content').innerHTML = html;
  $('pageHint').textContent = `共 ${(d.rows || []).length} 名学生。姓名/电话等直接点格子改；改完自动保存。`;
};
// ⚠️ 搜索不能整页重绘：输入框会被 innerHTML 换掉 → 每敲一个字就丢焦点。这里只切换行的显示。
function stuSearch() {
  const q = (window._stuQ || '').trim();
  const table = $('stuTable');
  if (!table) return;
  for (let i = 1; i < table.rows.length; i++) {
    const tr = table.rows[i];
    tr.style.display = (!q || textOf(tr).indexOf(q) >= 0) ? '' : 'none';
  }
}
function addStudent() {
  const d = S['students.json'];
  d.rows.push({ id: uid(), cells: new Array((d.headers || []).length).fill('') });
  save('students.json', true); render();
}
function delStudent(ri) { S['students.json'].rows.splice(ri, 1); save('students.json', true); render(); }

/* ============================================================
   6. 学生座位（含讲台与待排池）
   ============================================================ */
PAGES.seating = function () {
  const d = doc('seating.json') || { grid: [], pool: [], genders: {}, podium: { row: 0, col: 0, span: 3 } };
  const grid = d.grid || [], pool = d.pool || [], genders = d.genders || {};
  const pod = d.podium || { row: 0, col: 0, span: 3 };
  const cols = grid.reduce((m, r) => Math.max(m, r.length), 0) || 11;
  $('headActions').innerHTML = `<button class="btn" onclick="seatAutoFill()">一键排座（按名单顺序）</button>
    <button class="btn" onclick="seatClearAll()">清空所有座位</button>`;
  let html = `<div class="toolbar"><span class="pill">待排学生（${pool.length}）：${esc(pool.join('、'))}</span>
      <span class="pill">蓝=男 粉=女（据性别字段自动着色）</span></div>`;
  html += `<div class="seat-grid" style="grid-template-columns:repeat(${cols},minmax(64px,1fr))">`;
  for (let r = 0; r < grid.length; r++) {
    for (let c = 0; c < cols; c++) {
      if (r === pod.row && c === pod.col) {
        html += `<div class="seat podium" style="grid-column:span ${pod.span}">讲台</div>`;
        c += pod.span - 1;
        continue;
      }
      const v = (grid[r] || [])[c] || '';
      const g = genders[v] || '';
      const cls = 'seat ' + (v ? (g === '男' ? 'male' : g === '女' ? 'female' : '') : 'empty');
      html += `<div class="${cls}" onclick="seatClick(${r},${c})" title="点击：放入/清空/换人">${esc(v)}</div>`;
    }
  }
  html += `</div>`;
  $('content').innerHTML = html;
  $('pageHint').textContent = '点格子：空位→从待排池补人；有人→清回待排池；也可在待排区选人后点格子安排。';
};
function seatClick(r, c) {
  const d = S['seating.json'];
  d.grid[r] = d.grid[r] || [];
  const cur = d.grid[r][c] || '';
  if (cur) { d.pool.push(cur); d.grid[r][c] = ''; }
  else if (d.pool.length) d.grid[r][c] = d.pool.shift();
  save('seating.json', true); render();
}
function seatAutoFill() {
  const d = S['seating.json'];
  const pod = d.podium || { row: 0, col: 0, span: 3 };
  const pool = d.pool.slice();
  const grid = d.grid.map(row => row.slice());
  for (let r = 0; r < grid.length && pool.length; r++) {
    for (let c = 0; c < (grid[r] || []).length && pool.length; c++) {
      if (r === pod.row && c >= pod.col && c < pod.col + pod.span) continue;
      if (!grid[r][c]) grid[r][c] = pool.shift();
    }
  }
  d.grid = grid; d.pool = pool;
  save('seating.json', true); render();
}
function seatClearAll() {
  if (!confirm('把所有人放回待排池？')) return;
  const d = S['seating.json'];
  d.grid.forEach((row, r) => row.forEach((v, c) => { if (v) { d.pool.push(v); d.grid[r][c] = ''; } }));
  save('seating.json', true); render();
}

/* ============================================================
   7. 日程提醒
   ============================================================ */
function reminderList() { return doc('reminders.json') || []; }
function isOneShot(r) { return (!r.weekdays || !r.weekdays.length) && !r.longCycle; }
function isCompleted(r) { return isOneShot(r) && !!r.completedOn; }
function dayStr(d) { const p = n => String(n).padStart(2, '0'); return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()); }
/* 与 macOS 2.5.13 同规则：时刻今天已过 → 顺延到明天（绝不当天补弹） */
function oneShotDayFor(hour, minute, now) {
  now = now || new Date();
  const target = new Date(now.getFullYear(), now.getMonth(), now.getDate(), hour, minute, 0, 0);
  const d = new Date(now.getTime());
  if (!(now < target)) d.setDate(d.getDate() + 1);
  return dayStr(d);
}
function weekText(r) {
  if (r.longCycle) return ({ monthly: '每月', halfYearly: '每半年', yearly: '每年' })[r.longCycle] + ' 循环';
  if (isOneShot(r)) return r.oneShotDay ? '仅 ' + r.oneShotDay.slice(5) + ' 提醒一次' : '未设置提醒日';
  return DAY_ORDER.filter(w => (r.weekdays || []).includes(w)).map(w => SHORT[w]).join(' ');
}
function hm(r) { const p = n => String(n).padStart(2, '0'); return p(r.hour) + ':' + p(r.minute); }

PAGES.reminders = function () {
  const list = reminderList();
  const today = dayStr(new Date());
  $('headActions').innerHTML = `<button class="btn" onclick="fetch('/api/notify/test',{method:'POST'})">测试弹窗</button>
    <button class="btn primary" onclick="addReminder()">＋ 添加提醒</button>`;
  const active = list.filter(r => !isCompleted(r));
  const done = list.filter(r => isCompleted(r));
  let html = active.map(r => {
    const late = isOneShot(r) && r.oneShotDay === today && isPastDue(r);
    const tag = isOneShot(r)
      ? (r.oneShotDay === today ? (late ? '已弹窗 · 待处理' : '今天提醒') : (r.oneShotDay ? '已过期' : '未设置提醒日'))
      : '';
    return `<div class="rem-row">
      <span class="bell">⏰</span>
      <div><div class="t">${esc(r.title)}</div>
        <div class="meta">${hm(r)} · ${esc(weekText(r))}${tag ? ` <span class="tag">${tag}</span>` : ''}</div></div>
      <div class="spacer"></div>
      ${r.url ? `<button class="btn plain" title="打开 ${esc(r.url)}" onclick="fetch('/api/open?target=url&url=${encodeURIComponent(r.url)}',{method:'POST'})">🔗</button>` : ''}
      ${isOneShot(r) && !isCompleted(r) ? `<button class="btn plain" title="标记已完成" onclick="completeReminder('${r.id}')">✔</button>` : ''}
      <button class="btn plain" title="编辑" onclick="editReminder('${r.id}')">✎</button>
      <button class="btn plain" title="删除" onclick="delReminder('${r.id}')">🗑</button>
    </div>`;
  }).join('');
  if (!active.length) html = '<div class="card">还没有提醒，点右上角「添加提醒」。</div>';
  if (done.length) {
    html += `<div class="group-title" style="margin-top:14px">已完成（${done.length}）</div>`;
    html += done.map(r => `<div class="rem-row" style="opacity:.62">
        <span class="bell">✔</span><div><div class="t">${esc(r.title)}</div>
        <div class="meta">${hm(r)} · ${r.oneShotDay || ''} 已完成</div></div>
        <div class="spacer"></div>
        <button class="btn plain" onclick="restoreReminder('${r.id}')" title="重新启用">↺</button>
        <button class="btn plain" onclick="delReminder('${r.id}')">🗑</button></div>`).join('');
  }
  $('content').innerHTML = html;
  $('pageHint').textContent = '到点会弹置顶提醒窗：点「马上处理」= 完成（一次性提醒归入下方已完成列表）；点「等会处理」可选 10 分钟/30 分钟/1 小时/2 小时/明天。不勾任何星期 = 一次性提醒，且设置的时间早于当前时间时自动顺延到第二天。';
};
function isPastDue(r) {
  const n = new Date();
  return n.getHours() * 60 + n.getMinutes() >= r.hour * 60 + r.minute;
}
function addReminder() {
  const list = reminderList();
  const target = new Date(Date.now() + 30 * 60 * 1000);          // 默认：30 分钟后
  const r = {
    id: uid(), title: '新提醒', hour: target.getHours(), minute: target.getMinutes(),
    weekdays: [], url: '', oneShotDay: dayStr(target),
  };
  list.push(r);
  save('reminders.json', true);
  render();
  editReminder(r.id);
}
function delReminder(id) {
  const list = reminderList();
  const i = list.findIndex(r => r.id === id);
  if (i < 0) return;
  if (!confirm('删除提醒「' + list[i].title + '」？')) return;
  list.splice(i, 1); save('reminders.json', true); render();
}
function completeReminder(id) {
  const r = reminderList().find(x => x.id === id);
  if (!r) return;
  r.completedOn = dayStr(new Date());
  save('reminders.json', true); render();
}
function restoreReminder(id) {
  const r = reminderList().find(x => x.id === id);
  if (!r) return;
  delete r.completedOn; delete r.firedOn;
  if (isOneShot(r)) r.oneShotDay = oneShotDayFor(r.hour, r.minute);
  save('reminders.json', true); render();
}
function editReminder(id) {
  const r = reminderList().find(x => x.id === id);
  if (!r) return;
  const quick = [['30分钟后', 1800], ['1小时后', 3600], ['2小时后', 7200], ['4小时后', 14400]];
  const cycles = [['每月', 'monthly'], ['每半年', 'halfYearly'], ['每年', 'yearly']];
  dialog('提醒设置', `
    <div class="row"><input type="text" value="${esc(r.title)}" oninput="rEdit('title',this.value)"></div>
    <div class="row">
      <input type="time" value="${hm(r)}" onchange="rEditTime(this.value)">
      <label>每天该时刻（不勾任何星期 = 只提醒一次）</label>
    </div>
    <div class="row"><label>快捷</label>
      ${quick.map(q => `<span class="chip wide" onclick="rQuick(${q[1]})">${q[0]}</span>`).join('')}</div>
    <div class="row"><label>重复</label>
      ${DAY_ORDER.map(w => `<span class="chip${(r.weekdays || []).includes(w) ? ' on' : ''}" onclick="rToggleWeek(${w})">${SHORT[w]}</span>`).join('')}</div>
    <div class="row"><label>长周期</label>
      ${cycles.map(c => `<span class="chip wide${r.longCycle === c[1] ? ' on' : ''}" onclick="rToggleCycle('${c[1]}')">${c[0]}</span>`).join('')}</div>
    <div class="row"><label>网址</label><input type="text" value="${esc(r.url || '')}"
      placeholder="可选，点提醒即可打开" oninput="rEdit('url',this.value)"></div>
    <div class="note" id="rNote">${esc(rDesc(r))}</div>
    <div class="foot">
      <button class="btn" onclick="fetch('/api/notify/test',{method:'POST'})">测试弹窗</button>
      <div style="flex:1"></div>
      <button class="btn" onclick="closeDialog()">完成</button>
    </div>`, null, () => { window._editID = id; });
}
function rCur() { return reminderList().find(x => x.id === window._editID); }
function rDesc(r) {
  if (r.longCycle) return `每到${({ monthly: '每月', halfYearly: '每半年', yearly: '每年' })[r.longCycle]}的循环日 ${hm(r)} 提醒（锚点 ${r.oneShotDay || dayStr(new Date())}）；再点一次已选中的循环可取消。`;
  if (isOneShot(r)) return `一次性提醒：只在 ${r.oneShotDay || '（未设置）'} ${hm(r)} 提醒一次；设置的时刻早于当前时间时会自动顺延到第二天。`;
  return `每周${DAY_ORDER.filter(w => (r.weekdays || []).includes(w)).map(w => SHORT[w]).join('、')} ${hm(r)} 提醒。`;
}
function rEdit(key, val) {
  const r = rCur(); if (!r) return;
  r[key] = val;
  save('reminders.json', true);
  // ⚠️ 不要在输入文字时整体重绘弹窗：innerHTML 一换，输入框就丢焦点（打字只能进一个字）
  const note = $('rNote');
  if (note) note.textContent = rDesc(r);
}
function rEditTime(val) {
  const r = rCur(); if (!r || !val) return;
  const [h, m] = val.split(':').map(Number);
  r.hour = h; r.minute = m;
  if (isOneShot(r)) { r.oneShotDay = oneShotDayFor(h, m); delete r.completedOn; delete r.firedOn; }
  save('reminders.json', true); reRenderDialog(); render();
}
function rQuick(sec) {
  const r = rCur(); if (!r) return;
  const t = new Date(Date.now() + sec * 1000);
  r.hour = t.getHours(); r.minute = t.getMinutes();
  if (isOneShot(r)) { r.oneShotDay = dayStr(t); delete r.completedOn; delete r.firedOn; }
  save('reminders.json', true); reRenderDialog(); render();
}
function rToggleWeek(w) {
  const r = rCur(); if (!r) return;
  r.weekdays = r.weekdays || [];
  const i = r.weekdays.indexOf(w);
  i >= 0 ? r.weekdays.splice(i, 1) : r.weekdays.push(w);
  delete r.longCycle;
  if (r.weekdays.length) { delete r.oneShotDay; delete r.completedOn; }
  else r.oneShotDay = oneShotDayFor(r.hour, r.minute);
  save('reminders.json', true); reRenderDialog(); render();
}
function rToggleCycle(c) {
  const r = rCur(); if (!r) return;
  if (r.longCycle === c) { delete r.longCycle; r.oneShotDay = oneShotDayFor(r.hour, r.minute); }
  else { r.longCycle = c; r.weekdays = []; if (!r.oneShotDay) r.oneShotDay = dayStr(new Date()); delete r.completedOn; delete r.firedOn; }
  save('reminders.json', true); reRenderDialog(); render();
}
function reRenderDialog() { const id = window._editID; editReminder(id); }

function uid() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
    const r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16).toUpperCase();
  });
}

/* ============================================================
   8. 校历日历（22 周 + 周备注 + 日期颜色 + 月历）
   ============================================================ */
function firstMonday() {
  let w = doc('week.json');
  if (typeof w === 'string') w = w.replace(/"/g, '');
  const d = new Date((w || '2026-08-31') + 'T00:00:00');
  return isNaN(d) ? new Date(2026, 7, 31) : d;
}
PAGES.calendar = function () {
  const remarks = doc('calendar_remarks.json') || {};
  const colors = doc('calendar_day_colors.json') || {};
  const fm = firstMonday();
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const p = n => String(n).padStart(2, '0');
  $('headActions').innerHTML = `<button class="btn" onclick="setFirstWeek()">第 1 周开始日：${fm.getFullYear()}-${p(fm.getMonth() + 1)}-${p(fm.getDate())}</button>`;

  let html = `<div class="card"><b>周次表（共 22 周）</b><div style="height:6px"></div>`;
  html += `<table class="grid"><tr><th style="width:56px">周次</th><th style="width:190px">日期</th><th>本周重要事项（点击可编辑）</th><th style="width:120px">标记色</th></tr>`;
  for (let n = 1; n <= 22; n++) {
    const mon = new Date(fm.getTime()); mon.setDate(fm.getDate() + (n - 1) * 7);
    const sun = new Date(mon.getTime()); sun.setDate(mon.getDate() + 6);
    const isNow = today >= mon && today <= sun;
    const key = 'week-' + n;
    html += `<tr${isNow ? ' style="background:var(--accent-soft)"' : ''}>
      <td>第 ${n} 周${isNow ? ' <span class="tag">本周</span>' : ''}</td>
      <td>${mon.getMonth() + 1}月${mon.getDate()}日 – ${sun.getMonth() + 1}月${sun.getDate()}日</td>
      <td class="editable" contenteditable="true" onkeydown="cellOnKey(event)"
        onblur="cellEdit(this,'calendar_remarks.json','${key}')">${esc(remarks[key] || '')}</td>
      <td>${colorPicker(mon, colors)}</td></tr>`;
  }
  html += `</table></div>`;

  // 本月月历（带日期备注与颜色）
  const y = today.getFullYear(), m = today.getMonth();
  html += `<div class="card"><b>${y} 年 ${m + 1} 月</b><div style="height:6px"></div>
    <table class="grid"><tr>${[1, 2, 3, 4, 5, 6, 0].map(i => `<th>${['周日', '周一', '周二', '周三', '周四', '周五', '周六'][i]}</th>`).join('')}</tr><tr>`;
  const first = new Date(y, m, 1);
  const lead = first.getDay();
  for (let i = 0; i < lead; i++) html += `<td style="background:#fafafb"></td>`;
  const dim = new Date(y, m + 1, 0).getDate();
  for (let d = 1; d <= dim; d++) {
    const ds = y + '-' + p(m + 1) + '-' + p(d);
    const c = colors[ds];
    const rk = remarks['day-' + ds] || '';
    const isToday = d === today.getDate();
    html += `<td style="${c ? 'background:#' + c + ';color:#fff' : ''};${isToday ? 'outline:2px solid var(--accent)' : ''};vertical-align:top;height:64px">
      <div><b>${d}</b></div>
      <div class="editable" contenteditable="true" style="font-size:11px;opacity:.9"
        onkeydown="cellOnKey(event)" onblur="cellEdit(this,'calendar_remarks.json','day-${ds}')">${esc(rk)}</div>
      <div style="font-size:10px;margin-top:2px"><span class="chip" style="min-width:0;height:16px;padding:0 5px;font-size:10px"
        onclick="setDayColor('${ds}','${c || ''}')">色</span></div></td>`;
    if ((lead + d) % 7 === 0) html += `</tr><tr>`;
  }
  html += `</tr></table></div>`;
  $('content').innerHTML = html;
  $('pageHint').textContent = '周次表与月历都可编辑：直接改「本周重要事项」，点「色」给日期换标记色（再点一次同色=取消）。';
};
function colorPicker(mon, colors) {
  const p = n => String(n).padStart(2, '0');
  const ds = mon.getFullYear() + '-' + p(mon.getMonth() + 1) + '-' + p(mon.getDate());
  const c = colors[ds] || '';
  return `<span class="chip" style="min-width:0;padding:0 8px;${c ? 'background:#' + c + ';border-color:#' + c + ';color:#fff' : ''}"
    onclick="setDayColor('${ds}','${c}')">${c ? '●' + c : '设颜色'}</span>`;
}
const PALETTE = ['', 'E74C3C', 'F0A020', '2ECC71', '0A84FF', '8E44AD', '8E8E93'];
function setDayColor(ds, cur) {
  const i = PALETTE.indexOf(cur);
  const next = PALETTE[(i + 1) % PALETTE.length];
  const colors = doc('calendar_day_colors.json') || {};
  if (!next) delete colors[ds]; else colors[ds] = next;
  setDoc('calendar_day_colors.json', colors);
  save('calendar_day_colors.json', true);
  render();
}
function setFirstWeek() {
  const cur = firstMonday();
  const p = n => String(n).padStart(2, '0');
  const v = prompt('第 1 周的周一日期（格式 2026-08-31）：', `${cur.getFullYear()}-${p(cur.getMonth() + 1)}-${p(cur.getDate())}`);
  if (!v) return;
  const d = new Date(v + 'T00:00:00');
  if (isNaN(d)) { toast('日期格式不对'); return; }
  const dow = (d.getDay() + 6) % 7;              // 0=周一
  d.setDate(d.getDate() - dow);                  // 对齐到该周周一
  setDoc('week.json', dayStr(d));
  save('week.json', true); render();
}

/* ============================================================
   9. 年级师资
   ============================================================ */
PAGES.staff = function () {
  const d = doc('staff.json') || { headers: [], rows: [] };
  $('headActions').innerHTML = `<button class="btn" onclick="addStaff()">＋ 添加班级行</button>`;
  let html = `<table class="grid"><tr>${(d.headers || []).map(h => `<th>${esc(h)}</th>`).join('')}<th style="width:40px"></th></tr>`;
  (d.rows || []).forEach((r, ri) => {
    html += `<tr>` + (d.headers || []).map((h, ci) =>
      `<td class="editable" contenteditable="true" onkeydown="cellOnKey(event)"
        onblur="cellEdit(this,'staff.json','rows.${ri}.cells.${ci}')">${esc((r.cells || [])[ci] || '')}</td>`).join('') +
      `<td><button class="btn plain" onclick="delStaff(${ri})">✕</button></td></tr>`;
  });
  html += `</table>`;
  $('content').innerHTML = html;
  $('pageHint').textContent = '每行一个班级，列为各学科任课教师；直接点格子改，改完自动保存。';
};
function addStaff() {
  const d = S['staff.json'];
  d.rows.push({ id: uid(), cells: new Array((d.headers || []).length).fill(''), colors: {} });
  save('staff.json', true); render();
}
function delStaff(ri) { S['staff.json'].rows.splice(ri, 1); save('staff.json', true); render(); }

/* ============================================================
   10. 教师工位
   ============================================================ */
PAGES.office = function () {
  const list = doc('offices.json') || [];
  const byFloor = {};
  list.forEach(o => { const f = o.floor || '未分组'; (byFloor[f] = byFloor[f] || []).push(o); });
  let html = '';
  Object.keys(byFloor).forEach(f => {
    html += `<div class="group-title">${esc(f)}</div><div style="display:flex;gap:10px;flex-wrap:wrap">`;
    byFloor[f].forEach(o => {
      const idx = list.indexOf(o);
      const seats = o.seats || [];
      const cols = seats.reduce((m, r) => Math.max(m, r.length), 0) || 4;
      html += `<div class="card" style="min-width:270px">
        <div class="toolbar" style="margin-bottom:6px"><b>${esc(o.title)}</b>
          <span class="spacer" style="flex:1"></span>
          <button class="btn plain" onclick="renameOffice(${idx})">✎</button>
          <button class="btn plain" onclick="delOffice(${idx})">🗑</button></div>
        <div class="seat-grid" style="grid-template-columns:repeat(${cols},minmax(58px,1fr))">`;
      seats.forEach((row, r) => row.forEach((v, c) => {
        const key = (r + 1) + '-' + (c + 1);
        const col = (o.seatColors || {})[key];
        html += `<div class="seat${v ? '' : ' empty'}" style="${col ? 'background:#' + col + ';color:#fff' : ''}"
          contenteditable="true" onkeydown="cellOnKey(event)"
          onblur="cellEdit(this,'offices.json','${idx}.seats.${r}.${c}')"
          ondblclick="officeSeatColor(${idx},'${key}')" title="单击=改名，双击=换色">${esc(v)}</div>`;
      }));
      html += `</div></div>`;
    });
    html += `</div>`;
  });
  html += `<button class="btn" onclick="addOffice()">＋ 新增工位</button>`;
  $('content').innerHTML = html;
  $('pageHint').textContent = '每个办公室一块卡片；格子里是老师姓名（直接编辑），点格子可循环换座位颜色。';
};
function officeSeatColor(idx, key) {
  const o = S['offices.json'][idx];
  o.seatColors = o.seatColors || {};
  const cur = o.seatColors[key] || '';
  const next = PALETTE[(PALETTE.indexOf(cur) + 1) % PALETTE.length];
  if (!next) delete o.seatColors[key]; else o.seatColors[key] = next;
  save('offices.json', true);
}
function renameOffice(idx) {
  const o = S['offices.json'][idx];
  const v = prompt('工位名称：', o.title); if (!v) return;
  o.title = v; save('offices.json', true); render();
}
function delOffice(idx) { if (!confirm('删除这个工位？')) return; S['offices.json'].splice(idx, 1); save('offices.json', true); render(); }
function addOffice() {
  const t = prompt('新工位名称（如 X508）：'); if (!t) return;
  const f = prompt('所在楼层（如 5楼）：', '5楼') || '';
  S['offices.json'].push({ id: uid(), title: t, floor: f, seats: [['', '', '', '']], seatColors: {} });
  save('offices.json', true); render();
}

/* ============================================================
   11. 教室布局
   ============================================================ */
PAGES.classroom = function () {
  const list = doc('classrooms.json') || [];
  let html = '';
  list.forEach((floor, fi) => {
    html += `<div class="card"><div class="toolbar" style="margin-bottom:6px">
      <b>${esc(floor.title)}</b><span class="spacer" style="flex:1"></span>
      <button class="btn" onclick="addClassroomCell(${fi})">＋ 加一间</button>
      <button class="btn" onclick="delClassroomFloor(${fi})">删除本层</button></div>
      <div class="chips">`;
    (floor.cells || []).forEach((cell, ci) => {
      const bg = cell.kind === 'office' ? '#eef3ff' : '#f7f7f9';
      html += `<span class="chip wide" style="background:${bg};padding:4px 10px;height:auto;flex-direction:column;align-items:flex-start"
        onclick="editClassroomCell(${fi},${ci})" title="点击编辑">
        <span style="font-size:12px">${esc(cell.klass || cell.room || '未命名')}</span>
        <span style="font-size:10px;color:var(--sub)">${esc(cell.room || '')}${cell.room && cell.klass ? '' : ''}</span></span>`;
    });
    html += `</div></div>`;
  });
  html += `<button class="btn" onclick="addClassroomFloor()">＋ 新增楼层</button>`;
  $('content').innerHTML = html;
  $('pageHint').textContent = '每层一排房间/办公室；点房间可改名称与房号。';
};
function editClassroomCell(fi, ci) {
  const c = S['classrooms.json'][fi].cells[ci];
  dialog('编辑房间', `
    <div class="row"><label>名称/班级</label><input type="text" id="crk" value="${esc(c.klass || '')}"></div>
    <div class="row"><label>房号</label><input type="text" id="crr" value="${esc(c.room || '')}"></div>
    <div class="row"><label>类型</label>
      <select id="crt">
        <option value="room"${c.kind === 'room' ? ' selected' : ''}>教室</option>
        <option value="office"${c.kind === 'office' ? ' selected' : ''}>办公室</option>
      </select></div>`,
    `<button class="btn" onclick="delClassroomCell(${fi},${ci})">删除</button>
     <div style="flex:1"></div>
     <button class="btn" onclick="closeDialog()">取消</button>
     <button class="btn primary" onclick="saveClassroomCell(${fi},${ci})">保存</button>`);
}
function saveClassroomCell(fi, ci) {
  const c = S['classrooms.json'][fi].cells[ci];
  c.klass = $('crk').value; c.room = $('crr').value; c.kind = $('crt').value;
  save('classrooms.json', true); closeDialog(); render();
}
function delClassroomCell(fi, ci) {
  S['classrooms.json'][fi].cells.splice(ci, 1);
  save('classrooms.json', true); closeDialog(); render();
}
function addClassroomCell(fi) {
  S['classrooms.json'][fi].cells.push({ id: uid(), kind: 'room', klass: '新房间', room: '' });
  save('classrooms.json', true); render();
}
function delClassroomFloor(fi) { if (!confirm('删除整层？')) return; S['classrooms.json'].splice(fi, 1); save('classrooms.json', true); render(); }
function addClassroomFloor() {
  const t = prompt('楼层名称（如 X栋5楼）：'); if (!t) return;
  S['classrooms.json'].push({ id: uid(), title: t, cells: [], extraRows: [] });
  save('classrooms.json', true); render();
}

boot();
