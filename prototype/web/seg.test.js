import test from 'node:test';
import assert from 'node:assert/strict';
import { buildTemplate } from './seg.js';

// 40x20: left half red, right half blue, one green speck that must disappear
function image() {
  const w = 40, h = 20, rgba = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const o = (y * w + x) * 4;
      rgba.set(x < 20 ? [220, 20, 20, 255] : [20, 20, 220, 255], o);
    }
  }
  rgba.set([20, 220, 20, 255], (5 * w + 5) * 4);
  return { rgba, w, h };
}

test('two halves become two numbered fields, the speck is merged away', () => {
  const { rgba, w, h } = image();
  const t = buildTemplate(rgba, w, h, 3, 10);
  assert.equal(t.palette.length, 2);
  assert.equal(t.positions.length, 2);
  assert.notEqual(t.labels[0], t.labels[w - 1]);
  assert.equal(t.labels[5 * w + 5], t.labels[0]);
  for (const p of t.positions) assert.equal(t.labels[p.y * w + p.x], p.color);
});
