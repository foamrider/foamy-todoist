// Preferences.js: the inline schema mirrors manifest.json, and the kit's
// FoamyPrefs accepts and rejects values by it.
const test = require('node:test');
const assert = require('node:assert/strict');
const Schema = require('../Preferences.js');
const manifest = require('../manifest.json');
const Prefs = require('../kit/node-loader.cjs').load('FoamyPrefs');

test('the inline schema mirrors the manifest', () => {
  const schema = manifest.barWidget.schema;
  assert.deepEqual(Schema.fields.map((f) => f.key), schema.map((f) => f.key));
  for (const field of Schema.fields) {
    const entry = schema.find((f) => f.key === field.key);
    assert.equal(entry.type, field.type, field.key);
    assert.deepEqual(entry.defaultValue, field.defaultValue, field.key);
    assert.deepEqual(manifest.barWidget.defaults[field.key], field.defaultValue, field.key);
    if (field.options) assert.deepEqual(entry.options, field.options, field.key);
    for (const bound of ['min', 'max', 'step']) if (field[bound] !== undefined) assert.equal(entry[bound], field[bound], `${field.key}.${bound}`);
  }
  // The token is never a setting.
  assert.ok(!Schema.fields.some((f) => /token/i.test(f.key)));
});

test('every refresh choice the settings page offers is a valid value', () => {
  for (const seconds of Schema.refreshChoices) assert.ok(Prefs.valid(Schema.fields, 'refreshSeconds', seconds), `refresh choice ${seconds} s is not a valid setting`);
});

test('a saved "large" (the size Wide took over) reads as Wide, quietly', () => {
  const read = (settings) => Prefs.value(Schema.fields, Schema.current(settings), 'panelWidth');
  assert.equal(read({ panelWidth: 'large' }), 'wide');
  // Nothing in it reads as invalid, so nothing warns about it.
  assert.equal(JSON.stringify(Prefs.storedProblems(Schema.fields, Schema.current({ panelWidth: 'large', barCount: 'none' }))), '{}');
  // Without current() it would: the schema no longer lists "large".
  assert.equal(Prefs.storedProblem(Schema.fields, { panelWidth: 'large' }, 'panelWidth'), Prefs.NOT_ALLOWED);
  // The other settings and the other sizes are left as they are.
  assert.equal(Prefs.value(Schema.fields, Schema.current({ panelWidth: 'large', barCount: 'none' }), 'barCount'), 'none');
  assert.equal(read({ panelWidth: 'standard' }), 'standard');
  assert.equal(read({ panelWidth: 'wide' }), 'wide');
  assert.equal(read({ panelWidth: 'huge' }), 'standard');
  assert.equal(read({}), 'standard');
  // The stored entry itself isn't changed.
  const stored = { panelWidth: 'large' };
  Schema.current(stored);
  assert.equal(stored.panelWidth, 'large');
});

test('the open command: a bare command name or an absolute path, no shell, no control characters', () => {
  // Two separate paths: the schema pattern decides what a stored value reads as,
  // and validOpenCommand is the settings field's own check. Each must hold alone.
  for (const value of ['', 'xdg-open', 'omarchy-launch-or-focus-webapp Todoist {url}', '/usr/bin/firefox --new-window {url}', 'firefox  {url}  ', 'my_open.sh {url}']) {
    assert.ok(Prefs.valid(Schema.fields, 'openCommand', value), `schema accepts ${JSON.stringify(value)}`);
    assert.ok(Schema.validOpenCommand(value), `settings field accepts ${JSON.stringify(value)}`);
  }
  for (const value of [' firefox', '{url}', 'firefox\t{url}', 'firefox {url}\n', 'fire\u0007fox', 'a'.repeat(301), '-x {url}', 'fire\u0000fox', '../bin/open', 'bin/open {url}']) {
    assert.ok(!Prefs.valid(Schema.fields, 'openCommand', value), `schema refuses ${JSON.stringify(value)}`);
    assert.ok(!Schema.validOpenCommand(value), `settings field refuses ${JSON.stringify(value)}`);
  }
  // The manifest has no pattern, so a value set by hand or by the CLI can reach
  // the stored entry. The panel must not run it: it reads as the default.
  for (const stored of ['-x {url}', 'firefox\t{url}'])
    assert.equal(Prefs.value(Schema.fields, { openCommand: stored }, 'openCommand'), '', JSON.stringify(stored));
  assert.equal(Prefs.value(Schema.fields, {}, 'openCommand'), '');
});
