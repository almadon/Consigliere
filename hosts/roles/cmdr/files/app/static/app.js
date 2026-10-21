(() => {
  'use strict';
  const $ = (id) => document.getElementById(id);
  const state = { data: null, q: '', types: new Set(), problems: false, selected: null };

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
    return { dot, rec, attention, ships };
  }

  function routeNames(host) {
    const seen = new Map();
    for (const r of host.routes || []) for (const n of r.hosts || []) if (!seen.has(n)) seen.set(n, !!r.internal);
    return [...seen].map(([name, internal]) => ({ name, internal }));
  }

  function exposureFor(name) {
    return (state.data.exposure || []).filter((e) => e.target === name);
  }

  function matches(host) {
    if (state.types.size && !state.types.has(host.type || '?')) return false;
    if (state.problems) {
      const hh = hostHealth(host);
      const ex = exposureFor(host.name).some((e) => (e.findings || []).some((f) => f.severity === 'alert'));
      if (!hh.attention && !ex && hh.rec.cls !== 'warn') return false;
    }
    if (!state.q) return true;
    const hay = [host.name, host.type, host.org, host.site, ...(host.util || []), ...(host.feat || []), ...(host.prop || []), ...(host.cert || []),
      ...(host.routes || []).flatMap((r) => r.hosts || [])].join(' ').toLowerCase();
    return state.q.toLowerCase().split(/\s+/).every((w) => hay.includes(w));
  }

  function copy(text, btn) {
    const done = () => { const old = btn.textContent; btn.textContent = 'copied'; setTimeout(() => { btn.textContent = old; }, 1200); };
    if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(text).then(done, () => {});
    else { const t = h('textarea', { style: 'position:fixed;opacity:0' }); t.value = text; document.body.append(t); t.select(); try { document.execCommand('copy'); done(); } catch (e) { /* ignore */ } t.remove(); }
  }

  function hostLinks(host) {
    return (state.data.host_links || []).map((l) => h('a', { class: 'b', href: safeUrl(l.url.replaceAll('{host}', host.name).replaceAll('{host_q}', encodeURIComponent(host.name))), target: '_blank', rel: 'noopener noreferrer' }, l.name));
  }

  function card(host) {
    const hh = hostHealth(host);
    const tags = [...(host.util || []).map((t) => ['util', t]), ...(host.feat || []).map((t) => ['feat', t]), ...(host.prop || []).map((t) => ['prop', t])];
    return h('div', { class: 'card' + (hh.attention ? ' attn' : ''), tabindex: '0', role: 'button', 'aria-label': 'Details for ' + host.name, onclick: () => open(host.name),
      onkeydown: (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); open(host.name); } } },
      h('div', { class: 'row' }, h('span', { class: 'dot ' + hh.dot, title: hh.dot === 'ok' ? 'sending logs' : hh.dot === 'bad' ? 'no logs in 10 minutes' : 'unknown' }),
        h('span', { class: 'name' }, host.name), h('span', { class: 'type' }, host.type || '?')),
      h('div', { class: 'stat' }, h('span', { class: 'dot ' + hh.rec.cls }), h('span', null, hh.rec.text)),
      tags.length ? h('div', { class: 'row' }, tags.map(([k, t]) => h('span', { class: 'tag ' + k, title: (state.data.tags[k] || {})[t] || '' }, t))) : null,
      routeNames(host).length ? h('div', { class: 'routes' }, routeNames(host).map((r) =>
        h('a', { class: 'route' + (r.internal ? ' int' : ''), href: safeUrl('https://' + r.name), target: '_blank', rel: 'noopener noreferrer', onclick: (e) => e.stopPropagation(), title: r.internal ? 'tailnet / LAN only' : '' }, r.name))) : null,
      h('div', { class: 'btns', onclick: (e) => e.stopPropagation() },
        h('button', { class: 'b', type: 'button', onclick: (e) => copy('ssh root@' + host.name, e.currentTarget) }, 'copy ssh'), hostLinks(host)));
  }

  function open(name) {
    state.selected = name;
    const host = state.data.hosts.find((x) => x.name === name);
    if (!host) return;
    const hh = hostHealth(host);
    const kv = (k, v) => h('tr', null, h('th', null, k), h('td', null, v));
    const tags = (list, kind) => (list || []).length ? h('span', null, list.map((t) => h('span', { class: 'tag ' + kind, title: (state.data.tags[kind] || {})[t] || '' }, t + ' '))) : h('span', { class: 'mute' }, 'none');
    const ex = exposureFor(name);
    const d = $('drawer');
    d.replaceChildren(
      h('div', { class: 'row' }, h('h3', null, host.name), h('button', { class: 'b x', type: 'button', onclick: close }, 'close')),
      h('div', { class: 'stat' }, h('span', { class: 'dot ' + hh.dot }), h('span', null, hh.dot === 'ok' ? 'sending logs' : hh.dot === 'bad' ? 'silent for 10 minutes' : hh.ships ? 'status unknown' : 'not set up to ship logs'), h('span', { class: 'mute' }, '· ' + hh.rec.text)),
      h('table', null,
        kv('Type', host.type || '?'), kv('Organisation', host.org || ''), kv('Site', host.site || ''),
        kv('Provides (util)', tags(host.util, 'util')), kv('Runs (feat)', tags(host.feat, 'feat')), kv('Properties', tags(host.prop, 'prop')),
        kv('Certificates', (host.cert || []).join(', ') || 'none'), kv('Public ports (fw)', (host.fw || []).join(', ') || 'none (tailnet only)')),
      h('h2', null, 'Routes'),
      (host.routes || []).length ? h('table', null, host.routes.map((r) => h('tr', null,
        h('td', null, (r.hosts || []).map((n) => h('div', null, h('a', { href: safeUrl('https://' + n), target: '_blank', rel: 'noopener noreferrer' }, n)))),
        h('td', { class: 'mute' }, r.redirect ? 'redirect → ' + r.redirect : r.backend), h('td', null, r.internal ? 'internal' : r.profile || '')))) : h('div', { class: 'empty' }, 'No routes: this host serves nothing through Traefik.'),
      h('h2', null, 'Public exposure'),
      ex.length ? h('table', null, ex.map((e) => h('tr', null, h('td', null, e.ip), h('td', null, 'open ' + ((e.open_tcp || []).join(', ') || 'nothing')),
        h('td', null, (e.findings || []).length ? e.findings.map((f) => h('div', { class: 'sev-' + f.severity }, `${f.kind} ${f.proto}/${f.port}`)) : h('span', { class: 'sev-info' }, 'as declared'))))) :
        h('div', { class: 'empty' }, 'No scan result seen for this host yet.'),
      h('div', { class: 'btns' }, h('button', { class: 'b', type: 'button', onclick: (e) => copy('ssh root@' + host.name, e.currentTarget) }, 'copy ssh'), hostLinks(host)));
    d.hidden = false;
    d.focus && d.setAttribute('tabindex', '-1');
  }
  function close() { $('drawer').hidden = true; state.selected = null; }

  function renderTools() {
    const groups = new Map();
    for (const t of state.data.tools || []) { const g = t.group || 'Tools'; if (!groups.has(g)) groups.set(g, []); groups.get(g).push(t); }
    $('tools').replaceChildren(h('div', { class: 'tools' }, [...groups].map(([g, items]) => h('div', { class: 'tgroup' }, h('span', { class: 'gl' }, g),
      items.map((t) => h('a', { class: 'tool', href: safeUrl(t.url), target: '_blank', rel: 'noopener noreferrer', title: t.desc || '' }, t.name, t.tailnet ? h('small', null, 'tailnet') : null))))));
  }

  function renderSummary() {
    const hosts = state.data.hosts;
    const bad = hosts.filter((x) => hostHealth(x).attention).length;
    const alerts = (state.data.exposure || []).reduce((n, e) => n + (e.findings || []).filter((f) => f.severity === 'alert').length, 0);
    const silent = hosts.filter((x) => hostHealth(x).dot === 'bad').length;
    $('summary').replaceChildren(h('span', { class: 'pill' }, hosts.length + ' hosts'),
      h('span', { class: 'pill ' + (silent ? 'bad' : 'ok') }, silent ? silent + ' silent' : 'all reporting'),
      h('span', { class: 'pill ' + (bad - silent > 0 ? 'bad' : 'ok') }, bad - silent > 0 ? (bad - silent) + ' reconcile problem' + (bad - silent > 1 ? 's' : '') : 'reconciles ok'),
      h('span', { class: 'pill ' + (alerts ? 'bad' : 'ok') }, alerts ? alerts + ' exposure alert' + (alerts > 1 ? 's' : '') : 'no exposure alerts'));
    const att = hosts.filter((x) => hostHealth(x).attention);
    const s = $('attention');
    if (att.length) { s.hidden = false; s.replaceChildren(h('div', { class: 'bar' }, h('h2', null, 'Needs attention')), h('div', { class: 'grid' }, att.map(card))); } else s.hidden = true;
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
        rows.map((e) => h('tr', null, h('td', null, e.target), h('td', null, e.ip), h('td', null, (e.open_tcp || []).join(', ') || 'none'),
          h('td', null, (e.findings || []).length ? e.findings.map((f) => h('div', { class: 'sev-' + f.severity }, `${f.kind} ${f.proto}/${f.port}`)) : h('span', { class: 'sev-info' }, 'as declared')), h('td', { class: 'mute' }, ago(e.ts)))))) :
        h('div', { class: 'empty' }, 'No exposure scan seen in the logs yet. It runs daily from the scanner host; run it now with scripts/exposure.sh run.'));
  }

  function render() {
    const d = state.data;
    renderSummary(); renderTools(); renderChips(); renderExposure();
    const list = d.hosts.filter(matches);
    $('hosts').replaceChildren(...(list.length ? list.map(card) : [h('div', { class: 'empty' }, 'No hosts match.')]));
    const b = $('banner');
    if (!d.status.ok) { b.hidden = false; b.textContent = 'Live status is incomplete: ' + (d.status.error || 'not collected yet') + '. Inventory and links below are from the fleet repo and still correct.'; } else b.hidden = true;
    $('user').replaceChildren(h('span', null, d.user.name + ' · ' + d.user.role), h('a', { href: '/auth/logout' }, 'sign out'));
    $('foot').textContent = 'inventory generated ' + (d.generated ? ago(d.generated) : 'never') + ' · status updated ' + (d.status.updated ? ago(d.status.updated) : 'never');
    if (state.selected) open(state.selected);
  }

  async function load() {
    try {
      const r = await fetch('/api/fleet', { credentials: 'same-origin' });
      if (r.status === 401) { location.href = '/auth/login?next=' + encodeURIComponent(location.pathname); return; }
      state.data = await r.json();
      render();
    } catch (e) {
      const b = $('banner'); b.hidden = false; b.textContent = 'Could not load the fleet data: ' + e.message;
    }
  }
  $('q').addEventListener('input', (e) => { state.q = e.target.value.trim(); if (state.data) render(); });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') close(); });
  load();
  setInterval(load, 60000);
})();
