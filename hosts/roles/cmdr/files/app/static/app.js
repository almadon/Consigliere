(() => {
  'use strict';
  const $ = (id) => document.getElementById(id);
  const store = {
    get(k, d) { try { return localStorage.getItem('cmdr.' + k) || d; } catch (e) { return d; } },
    set(k, v) { try { localStorage.setItem('cmdr.' + k, v); } catch (e) { /* private mode: not remembered */ } },
  };
  const state = { data: null, q: '', types: new Set(), problems: false, selected: null, view: store.get('view', 'grid'), sort: store.get('sort', 'status'), pal: { items: [], at: 0 } };

  // DOM helper: text only, never HTML, so nothing from the data can inject markup.
  function h(tag, props, ...kids) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(props || {})) {
      if (v === undefined || v === null || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
      else el.setAttribute(k, v === true ? '' : v);
    }
    for (const kid of kids.flat()) if (kid !== null && kid !== undefined && kid !== false) el.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
    return el;
  }
  const ago = (ts) => {
    if (!ts) return '';
    const s = Math.max(0, Math.floor(Date.now() / 1000 - ts));
    if (s < 90) return 'just now';
    if (s < 5400) return Math.round(s / 60) + ' min ago';
    if (s < 129600) return Math.round(s / 3600) + ' h ago';
    return Math.round(s / 86400) + ' d ago';
  };
  const safeUrl = (u) => (/^https?:\/\//i.test(u) ? u : '#');
  const fill = (tpl, host) => tpl.replaceAll('{host_q}', encodeURIComponent(host)).replaceAll('{host}', host);
  const hue = (s) => { let x = 7; for (const c of s) x = (x * 31 + c.charCodeAt(0)) % 360; return x; };

  // ---------------------------------------------------------------- feedback
  let toastTimer = 0;
  function toast(text) {
    const t = $('toast');
    t.textContent = text; t.hidden = false;
    clearTimeout(toastTimer); toastTimer = setTimeout(() => { t.hidden = true; }, 2600);
  }
  function copy(text, btn, label) {
    const done = () => {
      toast('Copied: ' + text);
      if (btn) { const old = btn.textContent; btn.classList.add('done'); btn.textContent = 'copied ✓'; setTimeout(() => { btn.classList.remove('done'); btn.textContent = old; }, 1400); }
    };
    if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(text).then(done, () => toast('Could not copy: select it by hand'));
    else { const t = h('textarea', { class: 'sr' }); t.value = text; document.body.append(t); t.select(); try { document.execCommand('copy'); done(); } catch (e) { toast('Could not copy: select it by hand'); } t.remove(); }
  }

  // ---------------------------------------------------------------- health
  function hostHealth(host) {
    const st = host.status || {};
    const r = st.reconcile;
    let rec = { cls: 'unk', text: st.alive === null ? 'status unavailable' : 'no run seen (24 h)' };
    if (r) {
      const age = Date.now() / 1000 - r.ts;
      if (r.failed > 0 || r.unreachable > 0) rec = { cls: 'bad', text: `reconcile failed (${r.failed} failed) ${ago(r.ts)}` };
      else if (age > 3 * 3600) rec = { cls: 'warn', text: `last reconcile ${ago(r.ts)}` };
      else rec = { cls: r.changed > 0 ? 'warn' : 'ok', text: (r.changed > 0 ? `changed ${r.changed}, ` : 'in sync, ') + ago(r.ts) };
    }
    const ships = (host.feat || []).includes('otel');
    const dot = st.alive === null || st.alive === undefined ? 'unk' : st.alive ? 'ok' : ships ? 'bad' : 'unk';
    if (!ships && !st.alive && !r) rec = { cls: 'unk', text: 'not set up to ship logs or report runs' };
    const attention = dot === 'bad' || rec.cls === 'bad';
    const level = attention ? 'bad' : rec.cls === 'warn' ? 'warn' : dot === 'ok' ? 'ok' : 'unk';
    return { dot, rec, attention, ships, level };
  }
  const rank = { bad: 0, warn: 1, unk: 2, ok: 3 };
  function routeNames(host) {
    const seen = new Map();
    for (const r of host.routes || []) for (const n of r.hosts || []) if (!seen.has(n)) seen.set(n, !!r.internal);
    return [...seen].map(([name, internal]) => ({ name, internal }));
  }
  const exposureFor = (name) => (state.data.exposure || []).filter((e) => e.target === name);
  const alertsFor = (name) => exposureFor(name).some((e) => (e.findings || []).some((f) => f.severity === 'alert'));

  function matches(host) {
    if (state.types.size && !state.types.has(host.type || '?')) return false;
    if (state.problems) {
      const hh = hostHealth(host);
      if (!hh.attention && !alertsFor(host.name) && hh.rec.cls !== 'warn') return false;
    }
    if (!state.q) return true;
    const hay = [host.name, host.type, host.org, host.site, ...(host.util || []), ...(host.feat || []), ...(host.prop || []), ...(host.cert || []),
      ...(host.routes || []).flatMap((r) => r.hosts || [])].join(' ').toLowerCase();
    return state.q.toLowerCase().split(/\s+/).every((w) => hay.includes(w));
  }
  function sorted(list) {
    const by = state.sort;
    return [...list].sort((a, b) => {
      if (by === 'status') { const d = rank[hostHealth(a).level] - rank[hostHealth(b).level]; if (d) return d; }
      if (by === 'type') { const d = (a.type || '').localeCompare(b.type || ''); if (d) return d; }
      return a.name.localeCompare(b.name);
    });
  }

  // ---------------------------------------------------------------- commands
  const hostCmds = () => state.data.host_commands || [];
  const globalCmds = () => state.data.commands || [];
  const hostLinks = (host) => (state.data.host_links || []).map((l) => h('a', { class: 'b', href: safeUrl(fill(l.url, host.name)), target: '_blank', rel: 'noopener noreferrer' }, l.name + ' ↗'));
  function quick(host) {
    const first = hostCmds()[0];
    return h('div', { class: 'btns', onclick: (e) => e.stopPropagation() },
      first ? h('button', { class: 'b go', type: 'button', title: fill(first.cmd, host.name), onclick: (e) => copy(fill(first.cmd, host.name), e.currentTarget) }, first.name) : null,
      h('button', { class: 'b', type: 'button', title: 'ssh root@' + host.name, onclick: (e) => copy('ssh root@' + host.name, e.currentTarget) }, 'ssh'),
      hostLinks(host),
      h('button', { class: 'b', type: 'button', onclick: () => openHost(host.name) }, 'more…'));
  }

  // ---------------------------------------------------------------- tags, stats
  function tagInfo(kind, tag) {
    const k = (state.data.tag_kinds || {})[kind] || {};
    const ov = (state.data.tag_overrides || {});
    const o = ov[kind + '/' + tag] || ov[tag] || {};
    return { label: o.label || tag, desc: o.desc || (state.data.tags[kind] || {})[tag] || k.desc || '', color: o.color || k.color || '' };
  }
  function tagEl(kind, tag) {
    const i = tagInfo(kind, tag);
    const el = h('span', { class: 'tag', title: i.desc ? `${i.label}: ${i.desc}` : i.label }, i.label);
    if (i.color) el.style.setProperty('--k', i.color);
    return el;
  }
  const specificDesc = (kind, tag) => { const o = (state.data.tag_overrides || {}); const ov = o[kind + '/' + tag] || o[tag] || {}; return ov.desc || (state.data.tags[kind] || {})[tag] || ''; };
  const kindLabel = (kind) => ((state.data.tag_kinds || {})[kind] || {}).label || kind;
  function section(label, kind, body) {
    const sl = h('span', { class: 'sl' }, label);
    if (kind) { const c = ((state.data.tag_kinds || {})[kind] || {}).color; if (c) sl.style.setProperty('--k', c); }
    return h('div', { class: 'sec' }, sl, h('div', { class: 'sc' }, body));
  }
  const level = (v) => (v >= 0.9 ? 'bad' : v >= 0.75 ? 'warn' : 'ok');
  function meter(label, v, title) {
    if (v === null || v === undefined) return null;
    const fillEl = h('span', { class: 'fill ' + level(v) });
    fillEl.style.width = Math.max(2, Math.min(100, Math.round(v * 100))) + '%';
    return h('div', { class: 'm', title: title || label }, h('span', { class: 'ml' }, label), h('span', { class: 'track' }, fillEl), h('span', { class: 'mv' }, Math.round(v * 100) + '%'));
  }
  function meters(host) {
    const st = (host.status || {}).stats;
    if (!st) return null;
    const stale = Date.now() / 1000 - st.ts > 900;
    return h('div', { class: 'meters' + (stale ? ' stale' : '') }, meter('CPU', st.cpu, st.cores ? `${st.cores} cores, now` : 'now'), meter('MEM', st.mem), meter('DISK', st.disk, 'root filesystem'));
  }
  function spark(points, color) {
    const NS = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(NS, 'svg'); svg.setAttribute('viewBox', '0 0 200 40'); svg.setAttribute('class', 'spark'); svg.setAttribute('preserveAspectRatio', 'none');
    if (points.length < 2) return svg;
    const t0 = points[0][0], t1 = points[points.length - 1][0] || t0 + 1;
    const xy = points.map(([t, v]) => `${(((t - t0) / (t1 - t0 || 1)) * 200).toFixed(1)},${(38 - Math.max(0, Math.min(1, v)) * 36).toFixed(1)}`);
    const area = document.createElementNS(NS, 'polygon'); area.setAttribute('points', `0,40 ${xy.join(' ')} 200,40`); area.setAttribute('class', 'sa');
    const line = document.createElementNS(NS, 'polyline'); line.setAttribute('points', xy.join(' ')); line.setAttribute('class', 'sl2');
    svg.append(area, line);
    return svg;
  }

  // ---------------------------------------------------------------- cards
  function card(host) {
    const hh = hostHealth(host);
    const routes = routeNames(host);
    const kinds = [['util', host.util], ['feat', host.feat], ['prop', host.prop]].filter(([, l]) => (l || []).length);
    return h('div', { class: `card s-${hh.level}`, tabindex: '0', role: 'button', 'aria-label': 'Details for ' + host.name, onclick: () => openHost(host.name),
      onkeydown: (e) => { if (e.target === e.currentTarget && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); openHost(host.name); } } },
      h('div', { class: 'row head' }, h('span', { class: 'dot ' + hh.dot, title: hh.dot === 'ok' ? 'sending logs' : hh.dot === 'bad' ? 'no logs in 10 minutes' : 'unknown' }),
        h('span', { class: 'name' }, host.name), h('span', { class: 'type' }, host.type || '?')),
      h('div', { class: 'stat' }, h('span', { class: 'dot ' + hh.rec.cls }), h('span', null, hh.rec.text)),
      meters(host),
      kinds.length || routes.length ? h('div', { class: 'secs' },
        kinds.map(([k, list]) => section(kindLabel(k), k, list.map((t) => tagEl(k, t)))),
        routes.length ? section('Serves', null, routes.map((r) =>
          h('a', { class: 'route' + (r.internal ? ' int' : ''), href: safeUrl('https://' + r.name), target: '_blank', rel: 'noopener noreferrer', onclick: (e) => e.stopPropagation(),
            title: r.internal ? 'Open (reachable from the LAN or tailnet only)' : 'Open' }, r.name, r.internal ? h('i', { class: 'lock', 'aria-label': 'tailnet only' }, 'tailnet') : null))) : null) : null,
      quick(host));
  }

  // ---------------------------------------------------------------- drawer
  function openHost(name) {
    state.selected = name;
    const host = state.data.hosts.find((x) => x.name === name);
    if (!host) return;
    const hh = hostHealth(host);
    const kv = (k, v) => h('tr', null, h('th', null, k), h('td', null, v));
    const tags = (list, kind) => (list || []).length ? h('span', { class: 'sc' }, list.map((t) => tagEl(kind, t))) : h('span', { class: 'mute' }, 'none');
    const ex = exposureFor(name);
    const cmds = [{ name: 'Shell', cmd: 'ssh root@{host}' }, ...hostCmds()];
    const d = $('drawer');
    d.replaceChildren(
      h('div', { class: 'row' }, h('span', { class: 'dot ' + hh.dot }), h('h3', null, host.name), h('button', { class: 'b x', type: 'button', onclick: closeHost }, 'close ✕')),
      h('div', { class: 'stat' }, h('span', null, hh.dot === 'ok' ? 'sending logs' : hh.dot === 'bad' ? 'silent for 10 minutes' : hh.ships ? 'status unknown' : 'not set up to ship logs'), h('span', null, '· ' + hh.rec.text)),
      h('div', { class: 'btns' }, h('a', { class: 'b go', href: 'ssh://root@' + encodeURIComponent(host.name) }, 'open ssh ↗'), hostLinks(host)),
      statsBlock(host),
      h('h2', null, 'Commands'),
      h('div', { class: 'cmds' }, cmds.map((c) => { const full = fill(c.cmd, host.name);
        return h('div', { class: 'cmd' }, h('b', null, c.name), h('code', null, full), h('button', { class: 'b', type: 'button', onclick: (e) => copy(full, e.currentTarget) }, 'copy')); })),
      h('div', { class: 'note' }, 'Paste into a terminal in the fleet repo checkout. cmdr itself never runs anything on a host.'),
      h('h2', null, 'Details'),
      h('table', null,
        kv('Type', host.type || '?'), kv('Organisation', host.org || ''), kv('Site', host.site || ''),
        kv(kindLabel('util'), tags(host.util, 'util')), kv(kindLabel('feat'), tags(host.feat, 'feat')), kv(kindLabel('prop'), tags(host.prop, 'prop')),
        kv('Certificates', (host.cert || []).join(', ') || 'none'), kv('Public ports (fw)', (host.fw || []).join(', ') || 'none (tailnet only)')),
      h('h2', null, 'Routes'),
      (host.routes || []).length ? h('table', null, host.routes.map((r) => h('tr', null,
        h('td', null, (r.hosts || []).map((n) => h('div', null, h('a', { href: safeUrl('https://' + n), target: '_blank', rel: 'noopener noreferrer' }, n)))),
        h('td', { class: 'mute' }, r.redirect ? 'redirect → ' + r.redirect : r.backend), h('td', null, r.internal ? 'internal' : r.profile || '')))) : h('div', { class: 'empty' }, 'No routes: this host serves nothing through Traefik.'),
      h('h2', null, 'Public exposure'),
      ex.length ? h('table', null, ex.map((e) => h('tr', null, h('td', null, e.ip), h('td', null, 'open ' + ((e.open_tcp || []).join(', ') || 'nothing')),
        h('td', null, (e.findings || []).length ? e.findings.map((f) => h('div', { class: 'sev-' + f.severity }, `${f.kind} ${f.proto}/${f.port}`)) : h('span', { class: 'sev-info' }, 'as declared'))))) :
        h('div', { class: 'empty' }, 'No scan result seen for this host yet.'));
    d.hidden = false; $('scrim').hidden = false;
    d.setAttribute('tabindex', '-1'); d.focus();
  }
  function statsBlock(host) {
    const st = (host.status || {}).stats;
    if (!state.data.stats_on) return null;
    if (!st) return h('div', { class: 'note' }, 'No CPU, memory or disk numbers for this host yet (it needs the metrics agent: otel_agent_hostmetrics).');
    const box = h('div', { class: 'statbox' }, h('h2', null, 'Stats'), meters(host),
      h('div', { class: 'note' }, (st.load !== null && st.load !== undefined ? `load ${st.load.toFixed(2)}` : '') + (st.cores ? ` · ${st.cores} cores` : '') + ' · updated ' + ago(st.ts)));
    const sparks = h('div', { class: 'sparks' }); box.append(sparks);
    fetch('/api/stats?host=' + encodeURIComponent(host.name), { credentials: 'same-origin' }).then((r) => r.json()).then((d) => {
      for (const [k, label] of [['cpu', 'CPU, 6 h'], ['mem', 'Memory, 6 h']]) if (d[k] && d[k].length > 1) sparks.append(h('div', { class: 'sp' }, h('span', { class: 'ml' }, label), spark(d[k])));
    }).catch(() => {});
    return box;
  }
  function closeHost() { $('drawer').hidden = true; $('scrim').hidden = true; state.selected = null; }

  // ---------------------------------------------------------------- sections
  function renderStrip() {
    const hosts = state.data.hosts;
    const att = hosts.filter((x) => hostHealth(x).attention);
    const silent = hosts.filter((x) => hostHealth(x).dot === 'bad').length;
    const rbad = att.length - silent;
    const reporting = hosts.filter((x) => hostHealth(x).dot === 'ok').length;
    const alerts = (state.data.exposure || []).reduce((n, e) => n + (e.findings || []).filter((f) => f.severity === 'alert').length, 0);
    const types = {}; for (const x of hosts) types[x.type || '?'] = (types[x.type || '?'] || 0) + 1;
    const T = (cls, k, v, s, onclick) => h(onclick ? 'button' : 'div', { class: 'tile ' + cls, type: onclick ? 'button' : false, onclick }, h('span', { class: 'k' }, k), h('span', { class: 'v' }, v), h('span', { class: 's' }, s));
    $('strip').replaceChildren(
      T('', 'Fleet', hosts.length, Object.entries(types).map(([k, n]) => `${n} ${k}`).join(' · ')),
      T(silent ? 'bad' : 'ok', 'Reporting', `${reporting}/${hosts.length}`, silent ? `${silent} silent for 10 min` : 'every host is sending logs', silent ? () => { state.problems = true; render(); } : null),
      T(rbad ? 'bad' : 'ok', 'Reconciles', rbad ? rbad : 'OK', rbad ? 'host' + (rbad > 1 ? 's' : '') + ' with a failed run' : 'last runs succeeded', rbad ? () => { state.problems = true; render(); } : null),
      T(alerts ? 'bad' : 'ok', 'Exposure', alerts || 'Clear', alerts ? 'unexpected open port' + (alerts > 1 ? 's' : '') + ' on the internet' : 'nothing unexpected is open'));
    const s = $('attention');
    if (att.length) { s.hidden = false; s.replaceChildren(h('div', { class: 'bar' }, h('h2', null, 'Needs attention')), h('div', { class: 'grid' }, att.map(card))); } else s.hidden = true;
  }
  function renderTools() {
    const groups = new Map();
    for (const t of state.data.tools || []) { const g = t.group || 'Tools'; if (!groups.has(g)) groups.set(g, []); groups.get(g).push(t); }
    $('tools').replaceChildren(...[...groups].map(([g, items]) => h('div', { class: 'tgroup' }, h('span', { class: 'gl' }, g),
      h('div', { class: 'tiles' }, items.map((t) => {
        const ic = h('span', { class: 'ic', 'aria-hidden': 'true' }, t.name.trim().slice(0, 2));
        ic.style.background = `hsl(${hue(t.name)} 38% 34%)`;
        const mk = (state.data.mgmt_kinds || {})[t.mgmt];
        const badge = mk ? h('span', { class: 'mg', title: `${mk.label}: ${mk.desc}` }, mk.label) : null;
        if (badge && mk.color) badge.style.setProperty('--k', mk.color);
        return h('a', { class: 'tool', href: safeUrl(t.url), target: '_blank', rel: 'noopener noreferrer' }, ic,
          h('span', null, h('b', null, t.name), t.desc ? h('small', null, t.desc) : null, badge), t.tailnet ? h('span', { class: 'tn', title: 'reachable from the LAN or tailnet only' }, 'tailnet') : null);
      })))));
  }
  function renderKey() {
    const d = state.data; const kinds = d.tag_kinds || {};
    const used = (kind) => [...new Set(d.hosts.flatMap((x) => x[kind] || []))].sort();
    const col = (kind) => h('div', { class: 'kcol' }, h('h4', null, ((kinds[kind] || {}).label || kind)), h('p', null, (kinds[kind] || {}).desc || ''),
      h('dl', null, used(kind).flatMap((t) => [h('dt', null, tagEl(kind, t)), h('dd', null, specificDesc(kind, t))])));
    $('keybody').replaceChildren(
      h('div', { class: 'kcols' }, ['util', 'feat', 'prop'].map(col)),
      h('div', { class: 'kcols' },
        h('div', { class: 'kcol' }, h('h4', null, 'Status'), h('p', null,
          'Top dot: sending logs (green) or silent for 10 minutes (red). Second line: the last reconcile run: in sync, changed something, failed, or not seen in 24 hours. The bar on the left edge takes the worst of these.')),
        h('div', { class: 'kcol' }, h('h4', null, 'Serves'), h('p', null, 'The hostnames Traefik serves for this host. Dashed with a "tailnet" label = only reachable from the LAN or tailnet.')),
        h('div', { class: 'kcol' }, h('h4', null, 'CPU, MEM, DISK'), h('p', null, 'Right now, from the host\'s metrics agent. Amber from 75%, red from 90%. DISK is the root filesystem. Hosts without the agent show no bars.'))),
      h('div', { class: 'kcols' }, Object.entries(d.mgmt_kinds || {}).map(([k, m]) => { const t = h('span', { class: 'mg' }, m.label); if (m.color) t.style.setProperty('--k', m.color);
        return h('div', { class: 'kcol' }, h('h4', null, 'Launchpad badge'), h('p', null, t, ' ', m.desc)); })),
      h('p', { class: 'note' }, 'Names and colours of the kinds, and any single tag, are set in the fleet repo (cmdr_tag_kinds, cmdr_tag_overrides); a tag\'s description comes from its manifest.'));
  }
  function renderChips() {
    const types = [...new Set(state.data.hosts.map((x) => x.type || '?'))].sort();
    $('chips').replaceChildren(...types.map((t) => h('button', { class: 'chip', type: 'button', 'aria-pressed': String(state.types.has(t)), onclick: () => { state.types.has(t) ? state.types.delete(t) : state.types.add(t); render(); } }, t)),
      h('button', { class: 'chip', type: 'button', 'aria-pressed': String(state.problems), onclick: () => { state.problems = !state.problems; render(); } }, 'problems only'));
  }
  function renderExposure() {
    const rows = state.data.exposure || [];
    $('exposure').replaceChildren(h('div', { class: 'bar' }, h('h2', null, 'Public exposure')),
      rows.length ? h('div', { class: 'exp' }, h('table', null,
        h('tr', null, h('th', null, 'Target'), h('th', null, 'Address'), h('th', null, 'Open TCP'), h('th', null, 'Findings'), h('th', null, 'Scanned')),
        rows.map((e) => h('tr', null, h('td', null, e.target), h('td', { class: 'mono' }, e.ip), h('td', { class: 'mono' }, (e.open_tcp || []).join(', ') || 'none'),
          h('td', null, (e.findings || []).length ? e.findings.map((f) => h('div', { class: 'sev-' + f.severity }, `${f.kind} ${f.proto}/${f.port}`)) : h('span', { class: 'sev-info' }, 'as declared')), h('td', { class: 'mute' }, ago(e.ts)))))) :
        h('div', { class: 'empty' }, 'No exposure scan seen in the logs yet. It runs daily from the scanner host; run it now with scripts/exposure.sh run.'));
  }
  function render() {
    const d = state.data;
    renderStrip(); renderTools(); renderChips(); renderKey(); renderExposure();
    const list = sorted(d.hosts.filter(matches));
    const g = $('hosts');
    g.className = 'grid' + (state.view === 'list' ? ' list' : '');
    g.replaceChildren(...(list.length ? list.map(card) : [h('div', { class: 'empty' }, 'No hosts match.')]));
    $('v-grid').setAttribute('aria-pressed', String(state.view !== 'list')); $('v-list').setAttribute('aria-pressed', String(state.view === 'list'));
    $('sort').value = state.sort;
    const b = $('banner');
    if (!d.status.ok) { b.hidden = false; b.textContent = 'Live status is incomplete: ' + (d.status.error || 'not collected yet') + '. Inventory and links below are from the fleet repo and still correct.'; } else b.hidden = true;
    const initials = (d.user.name || '?').split(/\s+/).map((w) => w[0]).slice(0, 2).join('').toUpperCase();
    $('user').replaceChildren(h('span', { class: 'avatar', 'aria-hidden': 'true' }, initials), h('span', { class: 'hide-s' }, d.user.name + ' · ' + d.user.role), h('a', { href: '/auth/logout' }, 'sign out'));
    $('foot').textContent = 'inventory generated ' + (d.generated ? ago(d.generated) : 'never') + ' · status updated ' + (d.status.updated ? ago(d.status.updated) : 'never');
    if (state.selected) openHost(state.selected);
  }

  // ---------------------------------------------------------------- command palette
  function paletteIndex() {
    const d = state.data; const items = [];
    const act = (title, hint, run) => items.push({ kind: 'action', title, hint, run });
    act('Refresh live status', 'read Loki now', refresh);
    act('Show problems only', 'filter hosts', () => { state.problems = true; render(); });
    act('Show all hosts', 'clear filters', () => { state.problems = false; state.types.clear(); state.q = ''; $('q').value = ''; render(); });
    act('Switch theme', 'auto / dark / light', cycleTheme);
    for (const c of globalCmds()) items.push({ kind: 'run', title: c.name, hint: c.cmd, run: () => copy(c.cmd) });
    for (const x of d.hosts) items.push({ kind: 'host', title: x.name, hint: [x.type, ...(x.util || [])].filter(Boolean).join(' · '), run: () => openHost(x.name) });
    for (const x of d.hosts) for (const c of hostCmds()) { const full = fill(c.cmd, x.name); items.push({ kind: 'run', title: `${c.name} · ${x.name}`, hint: full, run: () => copy(full) }); }
    for (const x of d.hosts) for (const r of routeNames(x)) items.push({ kind: 'open', title: r.name, hint: x.name + (r.internal ? ' · tailnet' : ''), run: () => window.open(safeUrl('https://' + r.name), '_blank', 'noopener') });
    for (const t of d.tools || []) items.push({ kind: 'open', title: t.name, hint: t.group || 'tool', run: () => window.open(safeUrl(t.url), '_blank', 'noopener') });
    return items;
  }
  function paletteFilter(q) {
    const all = paletteIndex();
    const words = q.toLowerCase().split(/\s+/).filter(Boolean);
    if (!words.length) return all.filter((i) => i.kind === 'action' || (i.kind === 'run' && !i.title.includes(' · '))).concat(all.filter((i) => i.kind === 'host')).slice(0, 14);
    const scored = [];
    for (const i of all) {
      const t = i.title.toLowerCase(); const hay = `${i.kind} ${t} ${i.hint.toLowerCase()}`;
      if (!words.every((w) => hay.includes(w))) continue;
      scored.push([t.startsWith(words[0]) ? 0 : t.includes(words[0]) ? 1 : 2, i]);
    }
    return scored.sort((a, b) => a[0] - b[0]).slice(0, 40).map((x) => x[1]);
  }
  function paletteRender() {
    const q = $('pin').value; const items = paletteFilter(q); state.pal.items = items;
    state.pal.at = Math.min(state.pal.at, Math.max(items.length - 1, 0));
    const kindLabel = { host: 'host', run: 'copy', open: 'open', action: 'do' };
    $('plist').replaceChildren(...(items.length ? items.map((i, n) => h('li', { role: 'option', 'aria-selected': String(n === state.pal.at), onmouseenter: () => { state.pal.at = n; mark(); }, onclick: () => paletteRun(n) },
      h('span', { class: 'kind' }, kindLabel[i.kind]), h('span', { class: 't' }, i.title), h('span', { class: 'h' }, i.kind === 'run' ? '' : i.hint))) : [h('li', null, h('span', { class: 't mute' }, 'Nothing matches.'))]));
  }
  function mark() { [...$('plist').children].forEach((li, n) => { li.setAttribute('aria-selected', String(n === state.pal.at)); if (n === state.pal.at) li.scrollIntoView({ block: 'nearest' }); }); }
  function paletteRun(n) { const it = state.pal.items[n]; if (!it) return; paletteClose(); it.run(); }
  function paletteOpen() { if (!state.data) return; $('pal').hidden = false; $('pscrim').hidden = false; $('pin').value = ''; state.pal.at = 0; paletteRender(); $('pin').focus(); }
  function paletteClose() { $('pal').hidden = true; $('pscrim').hidden = true; }

  // ---------------------------------------------------------------- theme, refresh, load
  function cycleTheme() {
    const cur = document.documentElement.dataset.theme || 'auto';
    const next = cur === 'auto' ? 'dark' : cur === 'dark' ? 'light' : 'auto';
    if (next === 'auto') delete document.documentElement.dataset.theme; else document.documentElement.dataset.theme = next;
    store.set('theme', next); toast('Theme: ' + next);
  }
  async function refresh() {
    const b = $('refresh'); b.setAttribute('aria-busy', 'true');
    try {
      const r = await fetch('/api/refresh', { method: 'POST', credentials: 'same-origin', headers: { 'X-Cmdr': '1' } });
      if (r.status === 429) toast('Just refreshed: give it a few seconds');
      else if (!r.ok) toast('Refresh failed (' + r.status + ')');
      else { toast('Reading live status…'); await new Promise((ok) => setTimeout(ok, 2500)); await load(); }
    } catch (e) { toast('Refresh failed: ' + e.message); }
    b.removeAttribute('aria-busy');
  }
  async function load() {
    try {
      const r = await fetch('/api/fleet', { credentials: 'same-origin' });
      if (r.status === 401) { location.reload(); return; }
      state.data = await r.json();
      render();
    } catch (e) {
      const b = $('banner'); b.hidden = false; b.textContent = 'Could not load the fleet data: ' + e.message;
    }
  }

  $('q').addEventListener('input', (e) => { state.q = e.target.value.trim(); if (state.data) render(); });
  $('sort').addEventListener('change', (e) => { state.sort = e.target.value; store.set('sort', state.sort); if (state.data) render(); });
  $('v-grid').addEventListener('click', () => { state.view = 'grid'; store.set('view', 'grid'); if (state.data) render(); });
  $('v-list').addEventListener('click', () => { state.view = 'list'; store.set('view', 'list'); if (state.data) render(); });
  $('omni').addEventListener('click', paletteOpen);
  $('refresh').addEventListener('click', refresh);
  $('theme').addEventListener('click', cycleTheme);
  $('scrim').addEventListener('click', closeHost);
  $('pscrim').addEventListener('click', paletteClose);
  $('pin').addEventListener('input', () => { state.pal.at = 0; paletteRender(); });
  $('pin').addEventListener('keydown', (e) => {
    const n = state.pal.items.length;
    if (e.key === 'ArrowDown') { e.preventDefault(); state.pal.at = (state.pal.at + 1) % Math.max(n, 1); mark(); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); state.pal.at = (state.pal.at - 1 + Math.max(n, 1)) % Math.max(n, 1); mark(); }
    else if (e.key === 'Enter') { e.preventDefault(); paletteRun(state.pal.at); }
  });
  document.addEventListener('keydown', (e) => {
    const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement && document.activeElement.tagName);
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); $('pal').hidden ? paletteOpen() : paletteClose(); }
    else if (e.key === 'Escape') { if (!$('pal').hidden) paletteClose(); else closeHost(); }
    else if (e.key === '/' && !typing) { e.preventDefault(); $('q').focus(); }
  });
  load();
  setInterval(load, 60000);
})();
