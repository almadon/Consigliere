(() => {
  'use strict';
  // The fleet on a world map: one marker per place (hosts at the same coordinates share it), coloured by the worst status of the hosts there, with optional
  // arcs for where telemetry and backups flow. Drag to pan, wheel or +/- to zoom, hover for the hosts, click for the host (or the list at a shared place).
  // Land outlines are in world.js (Natural Earth, public domain). Text only, never HTML, like the rest of the page.
  const NS = 'http://www.w3.org/2000/svg';
  const W = 1000, H = 500;
  const el = (tag, attrs, ...kids) => {
    const n = document.createElementNS(NS, tag);
    for (const [k, v] of Object.entries(attrs || {})) if (v !== undefined && v !== null && v !== false) n.setAttribute(k, v);
    for (const kid of kids.flat()) if (kid) n.append(kid);
    return n;
  };
  const px = ([lat, lon]) => [((lon + 180) / 360) * W, ((90 - lat) / 180) * H];
  const rank = { bad: 0, warn: 1, unk: 2, ok: 3 };
  const validGeo = (g) => Array.isArray(g) && g.length === 2 && g.every((v) => typeof v === 'number' && Number.isFinite(v)) && Math.abs(g[0]) <= 90 && Math.abs(g[1]) <= 180;

  // Where each kind of traffic goes: from the hosts that run the agent to the host that provides the service.
  const LAYERS = [
    { id: 'telemetry', label: 'Telemetry', desc: 'Logs and metrics: every host with the otel agent sends to the host that runs Loki.', feat: 'otel', util: 'loki' },
    { id: 'backups', label: 'Backups', desc: 'Arkeep agents report to the Arkeep server.', feat: 'arkeep', util: 'arkeep' },
  ];

  function render(box, o) {
    const h = o.h;
    const placed = o.hosts.filter((x) => validGeo(x.geo));
    const unplaced = o.hosts.filter((x) => !validGeo(x.geo));
    if (!placed.length) {
      box.replaceChildren(h('div', { class: 'empty' }, 'No host has coordinates yet. Add geo: [latitude, longitude] to a host in the host table (config/inventory/hosts.yml) and it appears here.'));
      return;
    }
    // Places: hosts at the same coordinates.
    const places = new Map();
    for (const x of placed) {
      const key = x.geo.map((v) => v.toFixed(2)).join(',');
      if (!places.has(key)) places.set(key, { key, geo: x.geo, hosts: [], location: x.location || '' });
      places.get(key).hosts.push(x);
    }
    const list = [...places.values()];
    for (const p of list) {
      p.xy = px(p.geo);
      p.level = p.hosts.map((x) => o.health(x).level).sort((a, b) => rank[a] - rank[b])[0];
      p.sites = [...new Set(p.hosts.map((x) => x.site).filter(Boolean))];
    }
    const placeOf = new Map(); for (const p of list) for (const x of p.hosts) placeOf.set(x.name, p);

    const on = o.layers;      // Set of enabled layer ids (kept by the caller across refreshes)
    const view = o.view;      // {x, y, w, h}, also kept by the caller
    const svg = el('svg', { class: 'worldmap', viewBox: `${view.x} ${view.y} ${view.w} ${view.h}`, role: 'img', 'aria-label': 'Map of the fleet' });
    const grat = el('g', { class: 'grat' });
    for (let lon = -150; lon <= 180; lon += 30) grat.append(el('line', { x1: ((lon + 180) / 360) * W, y1: 0, x2: ((lon + 180) / 360) * W, y2: H }));
    for (let lat = -60; lat <= 90; lat += 30) grat.append(el('line', { x1: 0, y1: ((90 - lat) / 180) * H, x2: W, y2: ((90 - lat) / 180) * H }));
    const land = el('path', { class: 'land', d: window.CMDR_WORLD || '' });
    const arcs = el('g', { class: 'arcs' });
    for (const L of LAYERS) {
      if (!on.has(L.id)) continue;
      const hubs = o.hosts.filter((x) => (x.util || []).includes(L.util) && placeOf.has(x.name));
      if (!hubs.length) continue;
      const hub = hubs[0];
      const to = placeOf.get(hub.name);
      const seen = new Set();
      for (const x of placed) {
        if (!(x.feat || []).includes(L.feat) || x.name === hub.name) continue;
        const from = placeOf.get(x.name);
        if (from === to || seen.has(from.key)) continue;
        seen.add(from.key);
        const [x1, y1] = from.xy, [x2, y2] = to.xy;
        const lift = Math.min(120, Math.hypot(x2 - x1, y2 - y1) * 0.32);
        const d = `M${x1},${y1} Q${(x1 + x2) / 2},${(y1 + y2) / 2 - lift} ${x2},${y2}`;
        arcs.append(el('path', { class: 'arc ' + L.id, d }, el('title', null, `${L.label}: ${[...new Set(placed.filter((y) => placeOf.get(y.name) === from && (y.feat || []).includes(L.feat)).map((y) => y.name))].join(', ')} → ${hub.name}`)));
      }
    }
    const marks = el('g', { class: 'marks' });
    const dots = [];
    for (const p of list) {
      const [cx, cy] = p.xy;
      const g = el('g', { class: 'mk ' + p.level, tabindex: '0', role: 'button', 'aria-label': `${p.location || 'Location'}: ${p.hosts.map((x) => x.name).join(', ')}`, transform: `translate(${cx} ${cy})` });
      const pulse = el('circle', { class: 'pulse', r: 6 });
      const dot = el('circle', { class: 'pt', r: 4.5 });
      const count = p.hosts.length > 1 ? el('text', { class: 'ct', y: 3.2 }, String(p.hosts.length)) : null;
      g.append(pulse, dot, count);
      dots.push({ pulse, dot, count });
      const open = (ev) => { ev.stopPropagation(); if (p.hosts.length === 1) o.open(p.hosts[0].name); else pop(p, ev); };
      g.addEventListener('click', open);
      g.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); open(e); } });
      g.addEventListener('pointerenter', (e) => tip(p, e));
      g.addEventListener('pointermove', (e) => tip(p, e));
      g.addEventListener('pointerleave', () => { tipEl.hidden = true; });
      g.addEventListener('focus', () => tip(p, null, g));
      g.addEventListener('blur', () => { tipEl.hidden = true; });
      marks.append(g);
    }
    svg.append(el('rect', { class: 'sea', x: 0, y: 0, width: W, height: H }), grat, land, arcs, marks);

    // Marker size stays readable at every zoom: the SVG scales with the view, so the markers are scaled back.
    const rescale = () => {
      const k = Math.max(view.w / W, 0.12); // never smaller than a tenth: zoomed far in, the markers stay put
      marks.querySelectorAll('.mk').forEach((m, i) => { const [cx, cy] = list[i].xy; m.setAttribute('transform', `translate(${cx} ${cy}) scale(${k * 1.9})`); });
      svg.setAttribute('viewBox', `${view.x} ${view.y} ${view.w} ${view.h}`);
    };
    const clamp = () => {
      view.w = Math.min(W, Math.max(W / 24, view.w)); view.h = view.w / 2;
      view.x = Math.min(W - view.w, Math.max(0, view.x)); view.y = Math.min(H - view.h, Math.max(0, view.y));
    };
    const zoomAt = (f, fx = 0.5, fy = 0.5) => {
      const nw = view.w * f; view.x += (view.w - nw) * fx; view.y += (view.h - nw / 2) * fy; view.w = nw; clamp(); rescale();
    };
    svg.addEventListener('wheel', (e) => {
      e.preventDefault();
      const r = svg.getBoundingClientRect();
      zoomAt(e.deltaY < 0 ? 0.8 : 1.25, (e.clientX - r.left) / r.width, (e.clientY - r.top) / r.height);
    }, { passive: false });
    let drag = null;
    svg.addEventListener('pointerdown', (e) => { if (e.target.closest('.mk')) return; drag = { x: e.clientX, y: e.clientY, vx: view.x, vy: view.y }; svg.setPointerCapture(e.pointerId); svg.classList.add('drag'); });
    svg.addEventListener('pointermove', (e) => {
      if (!drag) return;
      const r = svg.getBoundingClientRect();
      view.x = drag.vx - ((e.clientX - drag.x) / r.width) * view.w; view.y = drag.vy - ((e.clientY - drag.y) / r.height) * view.h; clamp(); rescale();
    });
    const end = () => { drag = null; svg.classList.remove('drag'); };
    svg.addEventListener('pointerup', end); svg.addEventListener('pointercancel', end);
    svg.addEventListener('click', () => { popEl.hidden = true; });

    // Tooltip and the list shown when several hosts share a place.
    const tipEl = h('div', { class: 'maptip', hidden: true, role: 'tooltip' });
    const popEl = h('div', { class: 'mappop', hidden: true });
    const place = (n, ev, anchor) => {
      const b = box.getBoundingClientRect();
      let x, y;
      if (ev) { x = ev.clientX - b.left; y = ev.clientY - b.top; } else { const r = anchor.getBoundingClientRect(); x = r.left - b.left + r.width / 2; y = r.top - b.top; }
      n.hidden = false;
      n.style.setProperty('left', Math.max(8, Math.min(b.width - n.offsetWidth - 8, x + 14)) + 'px');
      n.style.setProperty('top', Math.max(8, Math.min(b.height - n.offsetHeight - 8, y + 14)) + 'px');
    };
    const hostLine = (x) => h('div', { class: 'tl' }, h('span', { class: 'dot ' + o.health(x).dot }), h('b', null, x.name), h('span', { class: 'mute' }, ' · ' + (x.type || '?') + (o.health(x).rec ? ' · ' + o.health(x).rec.text : '')));
    function tip(p, ev, anchor) {
      tipEl.replaceChildren(h('div', { class: 'th' }, p.location || 'Unnamed place', p.sites.length ? h('span', { class: 'mute' }, ' · ' + p.sites.join(', ')) : null), ...p.hosts.map(hostLine));
      place(tipEl, ev, anchor);
    }
    function pop(p, ev) {
      tipEl.hidden = true;
      popEl.replaceChildren(h('div', { class: 'th' }, p.location || 'Unnamed place'),
        ...p.hosts.map((x) => h('button', { class: 'tl btn-row', type: 'button', onclick: () => { popEl.hidden = true; o.open(x.name); } }, h('span', { class: 'dot ' + o.health(x).dot }), h('b', null, x.name), h('span', { class: 'mute' }, ' · ' + (x.type || '?')))));
      place(popEl, ev);
    }

    const btn = (label, title, fn) => h('button', { class: 'b', type: 'button', title, 'aria-label': title, onclick: fn }, label);
    const controls = h('div', { class: 'mapctl' }, btn('+', 'Zoom in', () => zoomAt(0.7)), btn('−', 'Zoom out', () => zoomAt(1.4)), btn('⤢', 'Show the whole world', () => { Object.assign(view, { x: 0, y: 0, w: W, h: H }); rescale(); }));
    const layers = h('div', { class: 'maplayers' }, h('span', { class: 'mute' }, 'Show flows:'),
      LAYERS.map((L) => h('button', { class: 'chip ' + L.id, type: 'button', title: L.desc, 'aria-pressed': String(on.has(L.id)), onclick: () => { on.has(L.id) ? on.delete(L.id) : on.add(L.id); o.again(); } }, L.label)));
    const legend = h('div', { class: 'maplegend' },
      [['ok', 'reporting, in sync'], ['warn', 'drift or changes'], ['bad', 'needs attention'], ['unk', 'unknown']].map(([c, t]) => h('span', null, h('span', { class: 'dot ' + c }), ' ' + t)));
    box.replaceChildren(h('div', { class: 'mapwrap' }, svg, controls, tipEl, popEl), h('div', { class: 'mapfoot' }, layers, legend,
      unplaced.length ? h('span', { class: 'mute', title: 'Add geo: [latitude, longitude] to these hosts in the host table to place them' }, 'Not on the map (no coordinates): ' + unplaced.map((x) => x.name).join(', ')) : null));
    rescale();
  }

  window.CmdrMap = { render };
})();
