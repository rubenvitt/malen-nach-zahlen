import { buildTemplate } from './seg.js';

const MAX = 600; // template grid size (longest side)
const S = 2;     // canvas pixels per grid pixel, keeps borders thin and numbers sharp

const $ = (id) => document.getElementById(id);
const view = $('view'), stage = $('stage'), hint = $('hint');
const base = $('base'), paint = $('paint'), lines = $('lines');
const pctx = paint.getContext('2d');
const scratch = document.createElement('canvas');
const sctx = scratch.getContext('2d');

let tpl = null, img = null, dirty = false, current = 0;
let z = 1, tx = 0, ty = 0;
const masks = new Map();

const showHint = (text) => { hint.textContent = text; hint.hidden = !text; };

// --- template ---------------------------------------------------------------

function generate() {
  const s = Math.min(1, MAX / Math.max(img.width, img.height));
  const w = Math.round(img.width * s), h = Math.round(img.height * s);
  const c = document.createElement('canvas');
  c.width = w; c.height = h;
  const x = c.getContext('2d');
  x.fillStyle = '#fff';
  x.fillRect(0, 0, w, h);
  x.drawImage(img, 0, 0, w, h);
  showHint('Vorlage wird erstellt …');
  setTimeout(() => {
    setTemplate(buildTemplate(x.getImageData(0, 0, w, h).data, w, h, +$('colors').value));
    dirty = false;
    save();
  }, 30); // let the hint paint before the blocking work
}

function setTemplate(t) {
  tpl = t;
  masks.clear();
  const W = t.w * S, H = t.h * S;
  for (const c of [base, paint, lines, scratch]) { c.width = W; c.height = H; }
  stage.style.width = t.w + 'px';
  stage.style.height = t.h + 'px';
  drawNumbers();
  drawLines();
  drawPalette();
  fit();
  showHint('');
}

function drawNumbers() {
  const b = base.getContext('2d');
  b.fillStyle = '#fff';
  b.fillRect(0, 0, base.width, base.height);
  b.fillStyle = '#777';
  b.textAlign = 'center';
  b.textBaseline = 'middle';
  for (const p of tpl.positions) {
    b.font = `${Math.max(7, Math.min(22, p.d * S * 1.3))}px system-ui, sans-serif`;
    b.fillText(String(p.color + 1), (p.x + 0.5) * S, (p.y + 0.5) * S);
  }
}

function drawLines() {
  const { w, labels } = tpl, W = lines.width, H = lines.height;
  const out = new ImageData(W, H);
  const L = (X, Y) => labels[((Y / S) | 0) * w + ((X / S) | 0)];
  for (let Y = 0; Y < H; Y++) {
    for (let X = 0; X < W; X++) {
      const l = L(X, Y);
      if ((X < W - 1 && L(X + 1, Y) !== l) || (Y < H - 1 && L(X, Y + 1) !== l)) out.data[(Y * W + X) * 4 + 3] = 255;
    }
  }
  lines.getContext('2d').putImageData(out, 0, 0);
}

function drawPalette() {
  const nav = $('palette');
  nav.replaceChildren(...tpl.palette.map(([r, g, b], i) => {
    const btn = document.createElement('button');
    btn.textContent = i + 1;
    btn.setAttribute('aria-label', `Farbe ${i + 1}`);
    btn.style.background = `rgb(${r},${g},${b})`;
    btn.style.color = 0.3 * r + 0.59 * g + 0.11 * b > 140 ? '#000' : '#fff';
    btn.onclick = () => select(i);
    return btn;
  }));
  select(0);
}

function select(i) {
  current = i;
  [...$('palette').children].forEach((b, j) => b.classList.toggle('active', j === i));
}

// Canvas that is opaque exactly where the fields with color c are
function mask(c) {
  if (masks.has(c)) return masks.get(c);
  const { w, h, labels } = tpl;
  const small = new ImageData(w, h);
  for (let p = 0; p < w * h; p++) if (labels[p] === c) small.data[p * 4 + 3] = 255;
  const m = document.createElement('canvas');
  m.width = w * S; m.height = h * S;
  const tmp = document.createElement('canvas');
  tmp.width = w; tmp.height = h;
  tmp.getContext('2d').putImageData(small, 0, 0);
  const mc = m.getContext('2d');
  mc.imageSmoothingEnabled = false;
  mc.drawImage(tmp, 0, 0, m.width, m.height);
  masks.set(c, m);
  return m;
}

// --- painting -----------------------------------------------------------------

// Paint only lands inside fields of the selected number: stroke on scratch, cut by the mask, copy over
function segment(a, b) {
  const r = (+$('size').value * S) / 2;
  const x0 = Math.max(0, Math.floor(Math.min(a.x, b.x) - r - 1));
  const y0 = Math.max(0, Math.floor(Math.min(a.y, b.y) - r - 1));
  const x1 = Math.min(paint.width, Math.ceil(Math.max(a.x, b.x) + r + 1));
  const y1 = Math.min(paint.height, Math.ceil(Math.max(a.y, b.y) + r + 1));
  const bw = x1 - x0, bh = y1 - y0;
  if (bw <= 0 || bh <= 0) return;
  const [cr, cg, cb] = tpl.palette[current];
  sctx.globalCompositeOperation = 'source-over';
  sctx.strokeStyle = `rgb(${cr},${cg},${cb})`;
  sctx.lineWidth = r * 2;
  sctx.lineCap = 'round';
  sctx.beginPath();
  sctx.moveTo(a.x, a.y);
  sctx.lineTo(b.x + 0.01, b.y); // zero-length lines draw nothing; this makes a dot
  sctx.stroke();
  sctx.globalCompositeOperation = 'destination-in';
  sctx.drawImage(mask(current), x0, y0, bw, bh, x0, y0, bw, bh);
  pctx.drawImage(scratch, x0, y0, bw, bh, x0, y0, bw, bh);
  sctx.globalCompositeOperation = 'source-over';
  sctx.clearRect(x0, y0, bw, bh);
  dirty = true;
}

function toCanvas(e) {
  const r = paint.getBoundingClientRect();
  return { x: ((e.clientX - r.left) * paint.width) / r.width, y: ((e.clientY - r.top) * paint.height) / r.height };
}

// --- one finger paints, two fingers pan/zoom ---------------------------------

const pts = new Map();
let last = null, pinch = null;

function apply() { stage.style.transform = `translate(${tx}px, ${ty}px) scale(${z})`; }

function fit() {
  if (!tpl) return;
  const v = view.getBoundingClientRect();
  z = Math.min(v.width / tpl.w, v.height / tpl.h) * 0.95;
  tx = (v.width - tpl.w * z) / 2;
  ty = (v.height - tpl.h * z) / 2;
  apply();
}

function gesture() {
  const [a, b] = [...pts.values()], v = view.getBoundingClientRect();
  return { x: (a.x + b.x) / 2 - v.left, y: (a.y + b.y) / 2 - v.top, d: Math.hypot(a.x - b.x, a.y - b.y) || 1 };
}

view.addEventListener('pointerdown', (e) => {
  if (!tpl) return;
  view.setPointerCapture(e.pointerId);
  pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
  if (pts.size === 2) {
    last = null;
    pinch = { ...gesture(), z, tx, ty };
  } else if (pts.size === 1 && !pinch) {
    last = toCanvas(e);
    segment(last, last);
  }
});

view.addEventListener('pointermove', (e) => {
  if (!pts.has(e.pointerId)) return;
  pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
  if (pinch && pts.size === 2) {
    const g = gesture();
    const nz = Math.min(12, Math.max(0.3, (pinch.z * g.d) / pinch.d));
    const k = nz / pinch.z;
    tx = g.x - (pinch.x - pinch.tx) * k;
    ty = g.y - (pinch.y - pinch.ty) * k;
    z = nz;
    apply();
  } else if (last) {
    // coalesced events give smooth lines with the Apple Pencil
    const evs = e.getCoalescedEvents?.() ?? [];
    for (const ev of evs.length ? evs : [e]) {
      const p = toCanvas(ev);
      segment(last, p);
      last = p;
    }
  }
});

function end(e) {
  if (!pts.delete(e.pointerId)) return;
  if (pts.size) return;
  if (last) save();
  last = null;
  pinch = null; // stays set until all fingers are up, so lifting one finger does not paint
}
view.addEventListener('pointerup', end);
view.addEventListener('pointercancel', end);

// --- saving (IndexedDB: one picture, so closing the tab loses nothing) --------

function db() {
  return new Promise((res, rej) => {
    const r = indexedDB.open('malen-nach-zahlen', 1);
    r.onupgradeneeded = () => r.result.createObjectStore('s');
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  });
}

async function store(fn, mode) {
  const d = await db();
  return new Promise((res, rej) => {
    const t = d.transaction('s', mode);
    const q = fn(t.objectStore('s'));
    t.oncomplete = () => res(q.result);
    t.onerror = () => rej(t.error);
  });
}

function save() {
  const t = tpl;
  paint.toBlob((blob) => {
    store((s) => s.put({ tpl: t, paint: blob }, 'current'), 'readwrite')
      .catch(() => showHint('Speichern hat nicht geklappt – Speicher voll?'));
  });
}

async function restore() {
  const v = await store((s) => s.get('current'), 'readonly').catch(() => null);
  if (!v) return;
  setTemplate(v.tpl);
  pctx.drawImage(await createImageBitmap(v.paint), 0, 0);
}

// --- controls -------------------------------------------------------------------

$('file').addEventListener('change', async (e) => {
  const f = e.target.files[0];
  e.target.value = '';
  if (!f) return;
  if (dirty && !confirm('Neues Bild anfangen? Das jetzige Bild wird ersetzt.')) return;
  try {
    img = await createImageBitmap(f);
  } catch {
    showHint('Dieses Bild kann ich nicht öffnen.');
    return;
  }
  generate();
});

$('colors').addEventListener('change', () => {
  if (img && (!dirty || confirm('Vorlage mit anderer Farbanzahl neu erstellen? Das Ausgemalte geht verloren.'))) generate();
});

$('fit').addEventListener('click', fit);
addEventListener('resize', fit);
restore();
