// Edit.js: one field's save holds only what changed, checked before it is sent.
process.env.TZ = 'Europe/Oslo';
const test = require('node:test');
const assert = require('node:assert/strict');
const Edit = require('../Edit.js');
const Model = require('../Model.js');
const Fixtures = require('../preview/Fixtures.js');

const TODAY = '2026-11-16';
const model = Model.index(Fixtures.snapshot(TODAY));
// t4: "Review **pull request** #482" in Work › Review, p3 (API 2), @code, today 14:00.
const t4 = model.byId.t4;
const change = (key, value, description) => Edit.change(t4, key, value, description);

test('an unchanged field sends nothing', () => {
  for (const key of ['content', 'due', 'deadline', 'priority', 'labels', 'place'])
    assert.deepEqual(change(key, Edit.initial(t4, key)), { fields: null, error: '' }, key);
  assert.deepEqual(change('description', 'Notes', 'Notes'), { fields: null, error: '' });
  // Surrounding spaces are not a change.
  assert.deepEqual(change('content', `  ${t4.content} `), { fields: null, error: '' });
  // The label order is not a change; the case is.
  const two = Object.assign({}, t4, { labels: ['a', 'b'] });
  assert.equal(Edit.change(two, 'labels', ['b', 'a']).fields, null);
  assert.deepEqual(Edit.change(two, 'labels', ['A', 'b']).fields, { labels: ['A', 'b'] });
});

test('each field sends only itself, in the helper names', () => {
  assert.equal(Edit.initial(t4, 'content'), 'Review **pull request** #482', 'the raw content, Markdown kept');
  assert.deepEqual(change('content', ' Review it '), { fields: { content: 'Review it' }, error: '' });
  assert.deepEqual(change('due', 'next monday 9am').fields, { due_string: 'next monday 9am' });
  assert.deepEqual(change('deadline', '2026-12-01').fields, { deadline: '2026-12-01' });
  assert.deepEqual(change('priority', 4).fields, { priority: 4 });
  assert.deepEqual(change('labels', ['code', 'office']).fields, { labels: ['code', 'office'] });
  assert.deepEqual(change('labels', []).fields, { labels: [] });
  assert.deepEqual(change('description', 'Line 1\nLine 2\tend', 'old').fields, { description: 'Line 1\nLine 2\tend' });
  assert.deepEqual(change('description', '', 'old').fields, { description: '' });
  // The request: one update command for the task.
  assert.deepEqual(Edit.request('t4', { priority: 4 }), { commands: [{ op: 'update', id: 't4', priority: 4 }] });
});

test('an emptied date or deadline removes it; an empty one on a task without stays', () => {
  assert.deepEqual(Edit.change(model.byId.t3, 'due', '').fields, { due_string: '' });
  // The field starts with Todoist's words for the date; emptied, it removes it.
  assert.equal(Edit.initial(t4, 'due'), 'today 14:00');
  assert.equal(Edit.initial(model.byId.t3, 'due'), 'every weekday at 9:30', 'a recurring task shows its rule');
  assert.equal(change('due', 'today 14:00').fields, null);
  assert.deepEqual(change('due', '').fields, { due_string: '' });
  // A date without Todoist's words starts empty: empty is no change.
  const wordless = Object.assign({}, t4, { dueString: '' });
  assert.equal(Edit.change(wordless, 'due', '').fields, null);
  assert.deepEqual(change('deadline', '').fields, null, 't4 has no deadline');
  const withDeadline = Object.assign({}, t4, { deadline: '2026-11-20' });
  assert.deepEqual(Edit.change(withDeadline, 'deadline', ' ').fields, { deadline: '' });
  const undated = model.byId.t7;
  assert.equal(Edit.change(undated, 'due', '').fields, null);
});

test('moves: only what the user changed', () => {
  // Another project's root, another project's section, this project's root.
  assert.deepEqual(change('place', 'home/').fields, { project_id: 'home' });
  assert.deepEqual(change('place', 'work/s-ops').fields, { section_id: 's-ops' });
  assert.deepEqual(change('place', 'work/').fields, { project_id: 'work', section_id: '' });
  const inbox = model.byId.t6;
  assert.deepEqual(Edit.change(inbox, 'place', 'work/s-review').fields, { project_id: 'work', section_id: 's-review' });
  assert.equal(change('place', '/').fields, null);
});

test('what the helper would refuse is caught first, with its message', () => {
  assert.equal(change('content', '   ').error, 'Enter a task.');
  assert.equal(change('content', 'x'.repeat(501)).error, 'A task can have at most 500 characters.');
  assert.equal(change('content', '😀'.repeat(500)).error, '', '500 characters, though 1000 UTF-16 units');
  assert.equal(change('content', 'a\u0007b').error, "A task can't have line breaks or other control characters.");
  assert.equal(change('due', 'x'.repeat(201)).error, 'Enter the date in words, at most 200 characters.');
  for (const bad of ['2026-02-30', '26-12-01', 'friday', '2026-1-1'])
    assert.equal(change('deadline', bad).error, 'Enter a deadline as YYYY-MM-DD.', bad);
  assert.equal(change('labels', ['a', 'A']).error, 'A label is given twice.');
  assert.equal(change('labels', ['x'.repeat(61)]).error, 'Give at most 50 labels of 1 to 60 characters each, without control characters.');
  assert.equal(change('labels', Array.from({ length: 51 }, (_, i) => `l${i}`)).error, 'Give at most 50 labels of 1 to 60 characters each, without control characters.');
  assert.equal(change('description', 'x'.repeat(16384), '').error, 'A description can have at most 16383 characters.');
  assert.equal(change('description', 'a\u0000b', '').error, "A description can't have control characters other than line breaks and tabs.");
});

test('cut labels and an unloaded description are never sent', () => {
  const cut = Object.assign({}, t4, { labelsTruncated: true });
  assert.equal(Edit.change(cut, 'labels', ['other']).fields, null);
  assert.equal(change('description', 'typed', undefined).fields, null);
});

test('line ends alone are no change to a description', () => {
  // The text area reads CRLF (and a lone CR) back as LF.
  assert.deepEqual(change('description', 'Line one\nLine two\n', 'Line one\r\nLine two\r'), { fields: null, error: '' });
  assert.ok(Edit.sameDescription('a\r\nb', 'a\nb'));
  assert.ok(!Edit.sameDescription('a\nb', 'a b'));
  // A real edit still goes, as typed.
  assert.deepEqual(change('description', 'Line one\nLine 2', 'Line one\r\nLine two').fields, { description: 'Line one\nLine 2' });
});

test('the project menu: projects in order, each with its sections', () => {
  const projects = [{ id: 'inbox', name: 'Inbox' }].concat(Model.railProjects(model, {}));
  const all = Edit.placeOptions(model, projects);
  assert.deepEqual(all.slice(0, 4).map((o) => [o.value, o.label]), [
    ['inbox/', 'Inbox'],
    ['work/', 'Work'],
    ['work/s-review', 'Work › Review'],
    ['work/s-ops', 'Work › Ops'],
  ]);
  assert.deepEqual(all.slice(0, 4).map((o) => [o.projectId, o.section]), [
    ['inbox', false],
    ['work', false],
    ['work', true],
    ['work', true],
  ]);
  assert.deepEqual(Edit.parsePlace('work/s-ops'), { projectId: 'work', sectionId: 's-ops' });
});

test('an edit made while saves are in flight builds on them (Edit.pending)', () => {
  const three = Object.assign({}, t4, { labels: ['a', 'b', 'c'] });
  // Two labels removed before the first reply: the second starts from the first's list.
  const first = Edit.change(three, 'labels', ['b', 'c']).fields;
  const base = Edit.pending(three, [first]);
  assert.deepEqual(base.labels, ['b', 'c']);
  assert.deepEqual(three.labels, ['a', 'b', 'c'], 'the snapshot task is not changed');
  assert.deepEqual(Edit.change(base, 'labels', base.labels.filter((name) => name !== 'b')).fields, { labels: ['c'] });
  // Adding twice keeps both.
  const added = Edit.pending(three, [{ labels: ['a', 'b', 'c', 'x'] }]);
  assert.deepEqual(Edit.change(added, 'labels', added.labels.concat(['y'])).fields, { labels: ['a', 'b', 'c', 'x', 'y'] });
  // Text: the newest request wins; sending what is already in flight sends nothing.
  const texts = Edit.pending(t4, [{ content: 'One' }, { content: 'Two' }]);
  assert.equal(texts.content, 'Two');
  assert.equal(Edit.change(texts, 'content', 'Two').fields, null);
  assert.deepEqual(Edit.change(texts, 'content', t4.content).fields, { content: t4.content }, 'back to the old text is a change again');
  // A removed date, a deadline, a priority, a move.
  const rest = Edit.pending(t4, [{ due_string: '' }, { deadline: '2026-12-01' }, { priority: 4 }, { project_id: 'home' }]);
  assert.equal(rest.due, null);
  assert.equal(rest.dueString, '');
  assert.equal(rest.deadline, '2026-12-01');
  assert.equal(rest.priority, 4);
  assert.equal(rest.projectId, 'home');
  assert.equal(rest.sectionId, '', 'a move lands in the root');
  assert.equal(Edit.pending(t4, [{ section_id: 's-ops' }]).sectionId, 's-ops');
  assert.equal(Edit.pending(null, []), null);
  // A date set on an undated task, then emptied before the reply: the removal is sent.
  const dated = Edit.pending(model.byId.t7, [{ due_string: 'tomorrow' }]);
  assert.deepEqual(Edit.change(dated, 'due', '').fields, { due_string: '' });
});
