// Every text the plugin can show has an English entry and a Norwegian one with
// the same placeholders: literals passed to FoamyI18n (the plugin's and the
// synced kit components'), texts passed through as data (settings errors, the
// helper-unavailable text) and the helper's error and warning keys.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const en = require('../i18n/en.json');
const no = require('../i18n/no.json');
const Model = require('../Model.js');

const root = path.join(__dirname, '..');
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');
const files = (dir, ext) =>
  fs.readdirSync(path.join(root, dir)).filter((f) => ext.some((e) => f.endsWith(e))).map((f) => path.join(dir, f));
const tokens = (s) => [...String(s).matchAll(/%[1-9][0-9]*/g)].map((m) => m[0]).sort();
const forms = (v) => (typeof v === 'string' ? [v] : Object.values(v));
// Comments hold usage examples, not shown texts.
const code = (source) => source.split('\n').filter((line) => !/^\s*(\/\/|\*|\/\*)/.test(line)).join('\n');
const STRING = '"((?:[^"\\\\]|\\\\.)*)"';

function literals() {
  const found = [];
  const sources = files('.', ['.qml', '.js']).concat(files('kit', ['.qml', '.js']));
  for (const file of sources) {
    for (const [, fn, key] of code(read(file)).matchAll(new RegExp(`FoamyI18n\\.(tn?)\\(${STRING}`, 'g')))
      found.push({ file, fn, key: JSON.parse(`"${key}"`) });
    // The kit's FoamyI18n calls its own t/tn.
    if (file.endsWith('FoamyI18n.qml'))
      for (const [, fn, key] of code(read(file)).matchAll(new RegExp(`\\breturn (tn?)\\(${STRING}`, 'g')))
        found.push({ file, fn, key });
  }
  return found;
}

function helperKeys() {
  // Each file's test module (at its end) uses its own texts.
  const rust = files('native/src', ['.rs'])
    .map((file) => read(file).split(/#\[cfg\(test\)\]\s*mod tests/)[0])
    .join('\n');
  const keys = new Set();
  const patterns = [
    new RegExp(`Failure::coded\\(\\s*"[A-Z_]+",\\s*${STRING}`, 'g'),
    new RegExp(`\\bmessage\\(\\s*${STRING}`, 'g'),
    new RegExp(`\\binvalid\\(\\s*${STRING}`, 'g'),
    new RegExp(`\\bcache_failure\\(\\s*${STRING}`, 'g'),
    new RegExp(`"error":\\s*${STRING}`, 'g'),
    // parse_add's optional fields: optional("key", validator, "message").
    new RegExp(`\\boptional\\(\\s*"[a-z_]+",\\s*[\\w:]+,\\s*${STRING}`, 'g'),
    // Whole sentences built as Strings (a message without values).
    new RegExp(`${STRING}\\.to_string\\(\\)`, 'g'),
  ];
  for (const pattern of patterns)
    for (const [, key] of rust.matchAll(pattern)) {
      const text = JSON.parse(`"${key}"`);
      if (/\s/.test(text) && /[.)]$/.test(text)) keys.add(text);
    }
  // The vendored kit's TLS message, named by its constant.
  assert.match(rust, /tls::UNSUPPORTED/);
  keys.add(read('kit/rust/foamy-helper/src/tls.rs').match(/const UNSUPPORTED: &str = "((?:[^"\\]|\\.)*)";/)[1]);
  return [...keys];
}

function dataKeys() {
  const prefs = read('kit/FoamyPrefs.js');
  const queue = read('kit/FoamyPrefsQueue.qml');
  return [
    read('kit/FoamyNative.js').match(/UNAVAILABLE_TEXT = "([^"]+)"/)[1],
    ...[...prefs.matchAll(/^var [A-Z_]+ = "([^"]+)"/gm)].map((m) => m[1]),
    ...[...queue.matchAll(/error = "([^"]+)"/g)].map((m) => m[1]),
    // json::run's reply when the helper panics.
    'internal error',
    // Model.emptyText's keys, translated by the view.
    Model.TRUNCATED_TEXT,
    ...Object.values(Model.EMPTY_TEXTS),
    // Upcoming's words and date formats, through the `t` the view passes in.
    ...Model.UPCOMING_KEYS,
    ...Model.DETAIL_KEYS,
  ];
}

test('the English catalog lists source keys; Norwegian has every entry with the same placeholders', () => {
  for (const [key, value] of Object.entries(en)) {
    if (typeof value === 'string') assert.equal(value, key, `English source key: ${key}`);
    else assert.ok(typeof value.one === 'string' && typeof value.other === 'string', `English plural: ${key}`);
    assert.ok(Object.hasOwn(no, key), `Norwegian entry: ${key}`);
    assert.equal(typeof no[key], typeof value, `same entry shape: ${key}`);
    for (const form of forms(no[key])) {
      assert.ok(form.length > 0, `Norwegian text: ${key}`);
      assert.deepEqual(tokens(form), tokens(key), `placeholders: ${key}`);
    }
  }
  assert.deepEqual(Object.keys(no).sort(), Object.keys(en).sort(), 'no extra Norwegian entries');
});

test('every literal shown through FoamyI18n has an entry; tn keys are plural entries', () => {
  const found = literals();
  assert.ok(found.length > 60, `literals found: ${found.length}`);
  for (const { file, fn, key } of found) {
    assert.ok(Object.hasOwn(en, key), `missing catalog key (${file}): ${key}`);
    if (fn === 'tn') assert.equal(typeof en[key], 'object', `tn key needs a plural entry: ${key}`);
    else assert.equal(typeof en[key], 'string', `t key is a plain entry: ${key}`);
  }
});

test('texts passed as data are catalog keys too', () => {
  for (const key of dataKeys()) assert.ok(Object.hasOwn(en, key), `missing data key: ${key}`);
});

test("the helper's errors and warnings are catalog keys", () => {
  const keys = helperKeys();
  assert.ok(keys.length >= 30, `helper keys found: ${keys.length}`);
  for (const key of keys) assert.ok(Object.hasOwn(en, key), `missing helper key: ${key}`);
});

test('every entry is used', () => {
  const used = new Set([...literals().map((l) => l.key), ...dataKeys(), ...helperKeys()]);
  for (const key of Object.keys(en)) assert.ok(used.has(key), `unused catalog key: ${key}`);
});

if (process.argv.includes('--keys')) {
  const out = {};
  for (const { fn, key } of literals()) out[key] = fn;
  for (const key of [...dataKeys(), ...helperKeys()]) out[key] = out[key] || 't';
  console.log(JSON.stringify(out, null, 1));
}
