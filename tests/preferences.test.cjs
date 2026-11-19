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

test('values are checked; missing ones take the defaults', () => {
  const ok = (key, value) => Prefs.valid(Schema.fields, key, value);
  const table = [
    ['barCount', 'today', true], ['barCount', 'none', true], ['barCount', 'all', false],
    ['panelWidth', 'standard', true], ['panelWidth', 'wide', true], ['panelWidth', 'large', true], ['panelWidth', 'huge', false],
    ['afterAdd', 'close', true], ['afterAdd', 'keep', true], ['afterAdd', 'stay', false],
    ['openOn', 'last', true], ['openOn', 'project', false],
    ['othersTasks', 'hide', true], ['othersTasks', 'show', true], ['othersTasks', 'all', false],
    ['refreshSeconds', 60, true], ['refreshSeconds', 1800, true], ['refreshSeconds', 30, false],
    ['refreshSeconds', 3600, false], ['refreshSeconds', '300', false],
  ];
  for (const [key, value, expected] of table) assert.equal(ok(key, value), expected, `${key}=${JSON.stringify(value)}`);
  assert.equal(Prefs.value(Schema.fields, {}, 'refreshSeconds'), 300);
  assert.equal(Prefs.value(Schema.fields, {}, 'othersTasks'), 'hide');
  assert.equal(Prefs.value(Schema.fields, {}, 'afterAdd'), 'close');
  // A size saved before Large existed still reads as it was.
  assert.equal(Prefs.value(Schema.fields, { panelWidth: 'wide' }, 'panelWidth'), 'wide');
  assert.equal(Prefs.value(Schema.fields, { refreshSeconds: 5 }, 'refreshSeconds'), 300);
  // Every refresh choice the settings page offers is a valid value.
  for (const seconds of Schema.refreshChoices) assert.ok(ok('refreshSeconds', seconds), seconds);
});

test('the open command: a bare command name or an absolute path, no shell, no control characters', () => {
  const ok = (value) => Prefs.valid(Schema.fields, 'openCommand', value) && Schema.validOpenCommand(value);
  for (const value of ['', 'xdg-open', 'omarchy-launch-or-focus-webapp Todoist {url}', '/usr/bin/firefox --new-window {url}', 'firefox  {url}  ', 'my_open.sh {url}'])
    assert.ok(ok(value), JSON.stringify(value));
  for (const value of [' firefox', '{url}', 'firefox\t{url}', 'firefox {url}\n', 'fire\u0007fox', 'a'.repeat(301), '-x {url}', 'fire\u0000fox', '../bin/open', 'bin/open {url}'])
    assert.ok(!ok(value), JSON.stringify(value));
  assert.equal(Prefs.value(Schema.fields, {}, 'openCommand'), '');
});
