// Turns an RGBA image into a paint-by-numbers template:
// one color label per pixel, the palette, and where each field's number goes.

export function buildTemplate(rgba, w, h, k, minArea = Math.max(16, Math.round((w * h) / 2500))) {
  let { labels, palette } = quantize(rgba, w * h, k);
  smooth(labels, w, h);
  smooth(labels, w, h);
  mergeSmall(labels, w, h, minArea);
  ({ labels, palette } = compact(labels, palette));
  return { w, h, labels, palette, positions: numberPositions(labels, w, h) };
}

const rng = (seed) => () => (seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296;
const dist = (a, o, c) => (a[o] - c[0]) ** 2 + (a[o + 1] - c[1]) ** 2 + (a[o + 2] - c[2]) ** 2;

function nearest(a, o, cent) {
  let best = 0, bd = Infinity;
  for (let c = 0; c < cent.length; c++) {
    const d = dist(a, o, cent[c]);
    if (d < bd) { bd = d; best = c; }
  }
  return best;
}

// k-means on a pixel sample (k-means++ init, fixed seed so the same photo gives the same template)
export function quantize(rgba, n, k, iters = 12) {
  const rand = rng(1);
  const step = Math.max(1, Math.floor(n / 20000));
  const samples = [];
  for (let i = 0; i < n; i += step) samples.push(i * 4);

  const pick = (o) => [rgba[o], rgba[o + 1], rgba[o + 2]];
  const cent = [pick(samples[Math.floor(rand() * samples.length)])];
  const d2 = new Float64Array(samples.length).fill(Infinity);
  while (cent.length < k) {
    const c = cent[cent.length - 1];
    let sum = 0;
    for (let s = 0; s < samples.length; s++) {
      d2[s] = Math.min(d2[s], dist(rgba, samples[s], c));
      sum += d2[s];
    }
    if (sum === 0) break; // fewer distinct colors than k
    let t = rand() * sum, s = 0;
    while ((t -= d2[s]) > 0 && s < samples.length - 1) s++;
    cent.push(pick(samples[s]));
  }

  for (let it = 0; it < iters; it++) {
    const acc = cent.map(() => [0, 0, 0, 0]);
    for (const o of samples) {
      const a = acc[nearest(rgba, o, cent)];
      a[0] += rgba[o]; a[1] += rgba[o + 1]; a[2] += rgba[o + 2]; a[3]++;
    }
    acc.forEach((a, c) => { if (a[3]) cent[c] = [a[0] / a[3], a[1] / a[3], a[2] / a[3]]; });
  }

  const labels = new Uint8Array(n);
  for (let i = 0; i < n; i++) labels[i] = nearest(rgba, i * 4, cent);
  return { labels, palette: cent.map((c) => c.map(Math.round)) };
}

// 3x3 majority filter against pixel noise
export function smooth(labels, w, h) {
  const src = labels.slice();
  const cnt = new Uint16Array(256);
  const nb = [];
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      nb.length = 0;
      for (let dy = -1; dy <= 1; dy++) {
        const yy = y + dy;
        if (yy < 0 || yy >= h) continue;
        for (let dx = -1; dx <= 1; dx++) {
          const xx = x + dx;
          if (xx >= 0 && xx < w) nb.push(src[yy * w + xx]);
        }
      }
      const own = src[y * w + x];
      let best = own;
      for (const l of nb) if (++cnt[l] > cnt[best]) best = l;
      for (const l of nb) cnt[l] = 0;
      labels[y * w + x] = best;
    }
  }
}

// 4-connected regions of equal label
export function components(labels, w, h) {
  const region = new Int32Array(w * h).fill(-1);
  const stack = new Int32Array(w * h);
  const sizes = [];
  for (let p0 = 0; p0 < w * h; p0++) {
    if (region[p0] >= 0) continue;
    const id = sizes.length, l = labels[p0];
    let top = 0, size = 0;
    stack[top++] = p0;
    region[p0] = id;
    while (top) {
      const p = stack[--top], x = p % w;
      size++;
      for (const q of [x > 0 ? p - 1 : -1, x < w - 1 ? p + 1 : -1, p - w, p + w]) {
        if (q >= 0 && q < w * h && region[q] < 0 && labels[q] === l) { region[q] = id; stack[top++] = q; }
      }
    }
    sizes.push(size);
  }
  return { region, sizes };
}

// Recolor fields smaller than minArea with their dominant neighbor (large neighbors win)
export function mergeSmall(labels, w, h, minArea) {
  for (let pass = 0; pass < 20; pass++) {
    const { region, sizes } = components(labels, w, h);
    const votes = new Map();
    for (let p = 0; p < w * h; p++) {
      const r = region[p];
      if (sizes[r] >= minArea) continue;
      const x = p % w;
      for (const q of [x > 0 ? p - 1 : -1, x < w - 1 ? p + 1 : -1, p - w, p + w]) {
        if (q < 0 || q >= w * h || region[q] === r) continue;
        let m = votes.get(r);
        if (!m) votes.set(r, (m = new Map()));
        m.set(labels[q], (m.get(labels[q]) || 0) + (sizes[region[q]] >= minArea ? 1000 : 1));
      }
    }
    if (!votes.size) return;
    const target = new Map();
    for (const [r, m] of votes) target.set(r, [...m].sort((a, b) => b[1] - a[1])[0][0]);
    for (let p = 0; p < w * h; p++) {
      const t = target.get(region[p]);
      if (t !== undefined) labels[p] = t;
    }
  }
}

// Drop unused palette entries so numbers run 1..n without gaps
export function compact(labels, palette) {
  const map = new Int16Array(palette.length).fill(-1);
  const pal = [];
  for (let i = 0; i < labels.length; i++) {
    const l = labels[i];
    if (map[l] < 0) { map[l] = pal.length; pal.push(palette[l]); }
    labels[i] = map[l];
  }
  return { labels, palette: pal };
}

// Per field: the pixel farthest from its border (chamfer distance), d = room for the number
export function numberPositions(labels, w, h) {
  const { region, sizes } = components(labels, w, h);
  const d = new Float32Array(w * h);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const p = y * w + x, l = labels[p];
      const edge = x === 0 || y === 0 || x === w - 1 || y === h - 1 ||
        labels[p - 1] !== l || labels[p + 1] !== l || labels[p - w] !== l || labels[p + w] !== l;
      d[p] = edge ? 0 : 1e9;
    }
  }
  const D = Math.SQRT2;
  for (let y = 1; y < h; y++) {
    for (let x = 1; x < w - 1; x++) {
      const p = y * w + x;
      d[p] = Math.min(d[p], d[p - 1] + 1, d[p - w] + 1, d[p - w - 1] + D, d[p - w + 1] + D);
    }
  }
  for (let y = h - 2; y >= 0; y--) {
    for (let x = w - 2; x >= 1; x--) {
      const p = y * w + x;
      d[p] = Math.min(d[p], d[p + 1] + 1, d[p + w] + 1, d[p + w + 1] + D, d[p + w - 1] + D);
    }
  }
  const bestP = new Int32Array(sizes.length).fill(-1);
  for (let p = 0; p < w * h; p++) {
    const r = region[p];
    if (bestP[r] < 0 || d[p] > d[bestP[r]]) bestP[r] = p;
  }
  return [...bestP].map((p) => ({ x: p % w, y: Math.floor(p / w), d: d[p], color: labels[p] }));
}
