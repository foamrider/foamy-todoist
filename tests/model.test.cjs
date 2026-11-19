// Model.js with a fixed clock: today is Monday 2026-11-16, in Europe/Oslo
// (set before any date is made, so the daylight-saving cases are real).
process.env.TZ = 'Europe/Oslo';
const test = require('node:test');
const assert = require('node:assert/strict');
const Model = require('../Model.js');
const Fixtures = require('../preview/Fixtures.js');

const TODAY = '2026-11-16';
const { task, due } = Fixtures;
const model = (snapshot) => Model.index(snapshot || Fixtures.snapshot(TODAY));
const taskIds = (rows) => rows.filter((row) => row.kind === 'task').map((row) => row.id);
const kinds = (rows) => rows.map((row) => (row.kind === 'task' ? row.id : `${row.kind}:${row.title}`));

function snapshotWith(tasks, extra) {
  return Object.assign(
    {
      user: { id: '1', inbox_project_id: 'in' },
      projects: [
        { id: 'in', name: 'Inbox', color: 'charcoal', inbox: true },
        { id: 'p', name: 'Project', color: 'red' },
      ],
      sections: [],
      tasks,
    },
    extra || {},
  );
}

test('due dates: all-day, floating and fixed-zone (UTC, shown locally)', () => {
  const cases = [
    [{ date: '2026-11-16' }, { day: '2026-11-16', time: '', minutes: -1, recurring: false }],
    [{ date: '2026-11-16T09:05:00', is_recurring: true }, { day: '2026-11-16', time: '09:05', minutes: 545, recurring: true }],
    [{ date: '2026-11-16T23:30:00.000000Z' }, { day: '2026-11-17', time: '00:30', minutes: 30, recurring: false }],
    [{ date: '2026-07-01T22:15:00Z' }, { day: '2026-07-02', time: '00:15', minutes: 15, recurring: false }],
    [null, null],
    [{ date: 'soon' }, null],
    [{ date: '2026-11-16T' }, null],
  ];
  for (const [input, expected] of cases) assert.deepEqual(Model.dueOf(input), expected, JSON.stringify(input));
});

test('days: adding across a month end and the daylight-saving change', () => {
  // Oslo leaves summer time on 2026-10-25.
  assert.equal(Model.addDays('2026-10-24', 1), '2026-10-25');
  assert.equal(Model.addDays('2026-10-24', 2), '2026-10-26');
  assert.equal(Model.addDays('2026-10-31', 1), '2026-11-01');
  assert.equal(Model.addDays('2026-12-31', 1), '2027-01-01');
  assert.equal(Model.addDays('2026-03-28', 1), '2026-03-29');
  assert.equal(Model.addDays('2026-03-28', 2), '2026-03-30');
  assert.equal(Model.daysBetween('2026-10-24', '2026-10-26'), 2);
  const table = [
    ['2026-11-16', 'today'],
    ['2026-11-15', 'yesterday'],
    ['2026-11-17', 'tomorrow'],
    ['2026-11-11', 'weekday'],
    ['2026-11-22', 'weekday'],
    ['2026-11-09', 'date'],
    ['2026-11-23', 'date'],
  ];
  for (const [day, kind] of table) assert.equal(Model.dayKind(day, TODAY), kind, day);
});

test('the next local midnight, also on the night the clocks change', () => {
  assert.equal(Model.msToMidnight(new Date(2026, 10, 16, 23, 0, 0)), 3600 * 1000);
  // 2026-10-25 has 25 hours in Oslo: from 00:30 to midnight is 24.5 hours.
  assert.equal(Model.msToMidnight(new Date(2026, 9, 25, 0, 30, 0)), 24.5 * 3600 * 1000);
  assert.equal(Model.msToMidnight(new Date(2026, 10, 16, 23, 59, 59, 900)), 1000);
});

test('today: overdue first (oldest first), then today: timed by time, the rest by day order and priority', () => {
  const rows = Model.rows(model(), 'today', TODAY);
  assert.deepEqual(kinds(rows), ['header:overdue', 't1', 't2', 'header:today', 't3', 't4', 't5', 't6']);
  assert.equal(rows[0].count, 2);
  assert.equal(rows[0].urgent, true);
  const t1 = rows[1];
  assert.equal(t1.overdue, true);
  assert.equal(t1.dateKind, 'weekday');
  assert.equal(t1.priorityRole, 'error');
  assert.equal(t1.text, 'Send the quarterly report to Finance');
  assert.equal(rows[2].dateKind, 'yesterday');
  // Today's tasks show no date, only a time when they have one.
  assert.equal(rows[4].dateKind, '');
  assert.equal(rows[4].dueTime, '09:30');
  assert.equal(rows[4].recurring, true);

  const tie = snapshotWith([
    task('a', 'untimed, order 2, p4', 'p', { due: due(TODAY), day_order: 2, priority: 1 }),
    task('b', 'untimed, order 1', 'p', { due: due(TODAY), day_order: 1 }),
    task('c', 'untimed, order 2, p1', 'p', { due: due(TODAY), day_order: 2, priority: 4 }),
    task('d', 'at 13', 'p', { due: due(`${TODAY}T13:00:00`) }),
    task('e', 'at 8', 'p', { due: due(`${TODAY}T08:00:00`) }),
  ]);
  assert.deepEqual(kinds(Model.rows(Model.index(tie), 'today', TODAY)), ['e', 'd', 'b', 'c', 'a']);
  // Without overdue tasks there are no section headers.
  assert.equal(Model.rows(Model.index(tie), 'today', TODAY)[0].kind, 'task');
});

// A stand-in for Qt.locale's date formatting (QML passes the real one):
// dddd, ddd, d, MMMM, MMM, yyyy, other characters as they are.
const NAMES = {
  en: {
    days: ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'],
    short: ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'],
    months: ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'],
    shortMonths: ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'],
  },
  nb: {
    days: ['søndag', 'mandag', 'tirsdag', 'onsdag', 'torsdag', 'fredag', 'lørdag'],
    short: ['søn.', 'man.', 'tir.', 'ons.', 'tor.', 'fre.', 'lør.'],
    months: ['januar', 'februar', 'mars', 'april', 'mai', 'juni', 'juli', 'august', 'september', 'oktober', 'november', 'desember'],
    shortMonths: ['jan.', 'feb.', 'mar.', 'apr.', 'mai', 'jun.', 'jul.', 'aug.', 'sep.', 'okt.', 'nov.', 'des.'],
  },
};
const formatter = (lang) => (date, pattern) => pattern.replace(/dddd|ddd|d|MMMM|MMM|yyyy/g, (token) => ({
  dddd: NAMES[lang].days[date.getDay()], ddd: NAMES[lang].short[date.getDay()], d: String(date.getDate()),
  MMMM: NAMES[lang].months[date.getMonth()], MMM: NAMES[lang].shortMonths[date.getMonth()], yyyy: String(date.getFullYear()),
}[token]));
// The catalogs' formats and words, as FoamyI18n.t gives them.
const catalog = (lang) => {
  const text = lang === 'nb' ? require('../i18n/no.json') : require('../i18n/en.json');
  return (key, values) => {
    const entry = text[key];
    const out = typeof entry === 'string' ? entry : key;
    return (values || []).reduce((acc, value, i) => acc.replace(`%${i + 1}`, value), out);
  };
};
const MONDAY = 1;
const SUNDAY = 0;

test('upcoming groups: days to the end of this week, next week, later this month, then months', () => {
  // [today, week start, day, group, group key]
  const table = [
    ['2026-11-16', MONDAY, '2026-11-17', 'day', '2026-11-17'],
    ['2026-11-16', MONDAY, '2026-11-22', 'day', '2026-11-22'],
    ['2026-11-16', MONDAY, '2026-11-23', 'week', 'week'],
    ['2026-11-16', MONDAY, '2026-11-29', 'week', 'week'],
    ['2026-11-16', MONDAY, '2026-11-30', 'later', '2026-11'],
    ['2026-11-16', MONDAY, '2026-12-01', 'month', '2026-12'],
    // Wednesday, Sunday-start week (Sun 15 – Sat 21).
    ['2026-11-18', SUNDAY, '2026-11-21', 'day', '2026-11-21'],
    ['2026-11-18', SUNDAY, '2026-11-22', 'week', 'week'],
    ['2026-11-18', SUNDAY, '2026-11-28', 'week', 'week'],
    ['2026-11-18', SUNDAY, '2026-11-29', 'later', '2026-11'],
    // Saturday: Monday weeks still have Sunday; Sunday weeks have no day left.
    ['2026-11-21', MONDAY, '2026-11-22', 'day', '2026-11-22'],
    // The last day of the week: tomorrow is still its own day group.
    ['2026-11-21', SUNDAY, '2026-11-22', 'day', '2026-11-22'],
    ['2026-11-21', SUNDAY, '2026-11-23', 'week', 'week'],
    ['2026-11-21', SUNDAY, '2026-11-29', 'later', '2026-11'],
    // Sunday.
    ['2026-11-22', MONDAY, '2026-11-23', 'day', '2026-11-23'],
    ['2026-11-22', MONDAY, '2026-11-24', 'week', 'week'],
    ['2026-11-22', MONDAY, '2026-11-30', 'later', '2026-11'],
    ['2026-11-22', SUNDAY, '2026-11-28', 'day', '2026-11-28'],
    ['2026-11-22', SUNDAY, '2026-12-05', 'week', 'week'],
    ['2026-11-22', SUNDAY, '2026-12-06', 'month', '2026-12'],
    // Next week across the month end: nothing is "later" in November.
    ['2026-11-25', MONDAY, '2026-11-30', 'week', 'week'],
    ['2026-11-25', MONDAY, '2026-12-06', 'week', 'week'],
    ['2026-11-25', MONDAY, '2026-12-07', 'month', '2026-12'],
    // December into January.
    ['2026-12-23', MONDAY, '2027-01-03', 'week', 'week'],
    ['2026-12-23', MONDAY, '2027-01-04', 'month', '2027-01'],
    // The week Oslo leaves summer time (Sunday 2026-10-25).
    ['2026-10-23', MONDAY, '2026-10-25', 'day', '2026-10-25'],
    ['2026-10-23', MONDAY, '2026-11-01', 'week', 'week'],
    ['2026-10-23', MONDAY, '2026-11-02', 'month', '2026-11'],
  ];
  for (const [today, start, day, group, key] of table)
    assert.deepEqual(Model.upcomingGroup(day, today, start), { group, key }, `${today} (start ${start}) ${day}`);
});

test('upcoming rows: fold, day groups, then dividers and counts on the later groups; empty ones hidden', () => {
  const today = '2026-11-18'; // Wednesday
  const t = (id, date, extra) => task(id, id, 'p', Object.assign({ due: due(date) }, extra || {}));
  const snapshot = snapshotWith([
    t('late', '2026-11-10'),
    t('fri-b', '2026-11-20', { day_order: 2 }),
    t('fri-a', '2026-11-20', { day_order: 1 }),
    t('fri-9', '2026-11-20T09:00:00'),
    t('thu', '2026-11-19'),
    t('nw-wed', '2026-11-25T08:00:00'),
    t('nw-mon', '2026-11-23'),
    t('dec', '2026-12-01T10:00:00'),
    t('jan', '2027-01-04'),
  ]);
  const rows = Model.rows(Model.index(snapshot), 'upcoming', today, { weekStart: MONDAY });
  const shape = rows.map((row) => (row.kind === 'task' ? row.id : `${row.kind}:${row.group || row.title}${row.divider ? '|' : ''}:${row.count}`));
  assert.deepEqual(shape, [
    'fold:overdue:1',
    'header:day:-1', 'thu',
    'header:day:-1', 'fri-9', 'fri-a', 'fri-b',
    'header:week|:2', 'nw-mon', 'nw-wed',
    'header:month|:1', 'dec',
    'header:month|:1', 'jan',
  ]);
  assert.equal(rows[1].tomorrow, true);
  assert.deepEqual([rows[7].rangeStart, rows[7].rangeEnd], ['2026-11-23', '2026-11-29']);
  assert.deepEqual([rows[10].monthKey, rows[10].showYear, rows[12].monthKey, rows[12].showYear], ['2026-12', false, '2027-01', true]);
  // Trailing: nothing extra in day groups, the weekday next week, weekday and date later.
  const trail = (id) => rows.find((row) => row.id === id).trail;
  assert.deepEqual(['thu', 'fri-9', 'nw-mon', 'nw-wed', 'dec'].map(trail), ['', '', 'weekday', 'weekday', 'weekdayDate']);
  assert.deepEqual(['thu', 'nw-mon', 'dec'].map((id) => rows.find((row) => row.id === id).group), ['day', 'week', 'month']);
  // Without the fold the first group has no divider, even a later one.
  const onlyLater = Model.rows(Model.index(snapshotWith([t('nw', '2026-11-24')])), 'upcoming', today, { weekStart: MONDAY });
  assert.equal(onlyLater[0].divider, false);
  assert.deepEqual(Model.rows(Model.index(snapshotWith([])), 'upcoming', today, { weekStart: MONDAY }), []);
  // "Later in November" when the month goes on after next week.
  const later = Model.rows(Model.index(snapshotWith([t('end', '2026-11-30')])), 'upcoming', '2026-11-16', { weekStart: MONDAY });
  assert.deepEqual([later[0].group, later[0].monthKey], ['later', '2026-11']);
});

test('on the last day of the week, tomorrow heads its own group and next week starts after it', () => {
  const t = (id, date) => task(id, id, 'p', { due: due(date) });
  for (const [today, start] of [['2026-11-22', MONDAY], ['2026-11-21', SUNDAY]]) {
    const tomorrow = Model.addDays(today, 1);
    const rows = Model.rows(Model.index(snapshotWith([t('a', tomorrow), t('b', Model.addDays(today, 3))])), 'upcoming', today, { weekStart: start });
    const heads = rows.filter((row) => row.kind === 'header');
    assert.deepEqual(heads.map((h) => [h.group, h.tomorrow, h.divider]), [['day', true, false], ['week', false, true]], today);
    assert.deepEqual([heads[1].rangeStart, heads[1].rangeEnd], [Model.addDays(today, 2), Model.addDays(today, 7)], today);
    assert.equal(Model.upcomingHeading(heads[0], formatter('en'), catalog('en')).title, 'Tomorrow');
  }
});

test('upcoming headings and trailing text, in English and Norwegian', () => {
  const today = '2026-11-16'; // Monday
  const t = (id, date) => task(id, id, 'p', { due: due(date) });
  const snapshot = snapshotWith([t('tue', '2026-11-17'), t('wed', '2026-11-18T09:00:00'), t('nw', '2026-11-23T09:00:00'),
    t('nw2', '2026-11-26'), t('end', '2026-11-30'), t('dec', '2026-12-01T09:00:00'), t('jan', '2027-01-05')]);
  const rows = Model.rows(Model.index(snapshot), 'upcoming', today, { weekStart: MONDAY });
  const headings = (lang) => rows.filter((row) => row.kind === 'header').map((row) => Model.upcomingHeading(row, formatter(lang), catalog(lang)));
  assert.deepEqual(headings('en'), [
    { title: 'Tomorrow', sub: 'Tuesday 17 November' },
    { title: 'Wednesday', sub: '18 November' },
    { title: 'Next week', sub: '23–29 Nov' },
    { title: 'Later in November', sub: '' },
    { title: 'December', sub: '' },
    { title: 'January 2027', sub: '' },
  ]);
  assert.deepEqual(headings('nb'), [
    { title: 'I morgen', sub: 'tirsdag 17. november' },
    { title: 'Onsdag', sub: '18. november' },
    { title: 'Neste uke', sub: '23.–29. nov.' },
    { title: 'Senere i november', sub: '' },
    { title: 'Desember', sub: '' },
    { title: 'Januar 2027', sub: '' },
  ]);
  // Next week across a month end.
  const crossing = Model.rows(Model.index(snapshotWith([t('x', '2026-12-01')])), 'upcoming', '2026-11-25', { weekStart: MONDAY });
  assert.equal(Model.upcomingHeading(crossing[0], formatter('nb'), catalog('nb')).sub, '30. nov.–6. des.');
  assert.equal(Model.upcomingHeading(crossing[0], formatter('en'), catalog('en')).sub, '30 Nov–6 Dec');
  const trail = (id, lang) => Model.trailingDay(rows.find((row) => row.id === id), formatter(lang), catalog(lang));
  assert.deepEqual(['tue', 'wed', 'nw', 'nw2', 'dec', 'jan'].map((id) => trail(id, 'nb')), ['', '', 'man.', 'tor.', 'tir. 1.', 'tir. 5.']);
  assert.deepEqual(['nw', 'dec'].map((id) => trail(id, 'en')), ['Mon', 'Tue 1']);
  assert.equal(rows.find((row) => row.id === 'nw').dueTime, '09:00');
  assert.equal(rows.find((row) => row.id === 'nw2').dueTime, '');
  // Other views have no extra trailing text.
  assert.equal(Model.trailingDay(Model.rows(Model.index(snapshot), 'inbox', today)[0] || { trail: '' }, formatter('en'), catalog('en')), '');
});

test('the upcoming count is tomorrow through seven days from today', () => {
  const t = (id, date) => task(id, id, 'p', { due: due(date) });
  const counts = Model.counts(Model.index(snapshotWith([t('a', '2026-11-16'), t('b', '2026-11-17'), t('c', '2026-11-23'), t('d', '2026-11-24')])), '2026-11-16');
  assert.equal(counts.week, 2);
});

test('inbox: Todoist order, subtasks right after their parent, one indent step', () => {
  const rows = Model.rows(model(), 'inbox', TODAY);
  assert.deepEqual(kinds(rows), ['t6', 't7', 't8', 't9']);
  assert.deepEqual(rows.map((row) => row.depth), [0, 0, 1, 0]);
  assert.deepEqual(rows.map((row) => row.detail), [true, false, false, true], 'a detail line only with something in it');
  assert.equal(rows[0].showProject, false, 'no project in the Inbox');
  assert.equal(rows[0].dateKind, 'today', 'the Inbox shows dates');
  const deep = snapshotWith([
    task('c', 'grandchild', 'in', { parent_id: 'b', child_order: 1 }),
    task('b', 'child', 'in', { parent_id: 'a', child_order: 1 }),
    task('x', 'second root', 'in', { child_order: 2 }),
    task('a', 'root', 'in', { child_order: 1 }),
    task('o', 'orphan: its parent is closed', 'in', { parent_id: 'gone', child_order: 3 }),
  ]);
  const deepRows = Model.rows(Model.index(deep), 'inbox', TODAY);
  assert.deepEqual(kinds(deepRows), ['a', 'b', 'c', 'x', 'o']);
  assert.deepEqual(deepRows.map((row) => row.depth), [0, 1, 1, 0, 0]);
});

test('a project: tasks without a section first, then each section with a header', () => {
  const rows = Model.rows(model(), 'project', TODAY, { projectId: 'work' });
  assert.deepEqual(kinds(rows), ['t1', 't15', 'header:Review', 't4', 'header:Ops', 't3', 't12', 't14']);
  assert.equal(rows[2].count, 1);
  assert.equal(rows[3].showProject, false);
  assert.deepEqual(Model.rows(model(), 'project', TODAY, { projectId: 'nope' }), []);
});

test('counts: inbox, left today, overdue, this week, per project; hidden ones leave', () => {
  const m = model();
  const counted = Model.counts(m, TODAY);
  // counts.projects has no prototype (ids are ordinary keys): compare a copy.
  assert.deepEqual(Object.assign({}, counted, { projects: Object.assign({}, counted.projects) }), {
    inbox: 4, today: 6, overdue: 2, week: 3,
    projects: { work: 6, home: 3, inbox: 4, launch: 1, reading: 1 },
  });
  const hidden = Model.counts(m, TODAY, { hidden: { t1: true, t7: true } });
  assert.equal(hidden.today, 5);
  assert.equal(hidden.overdue, 1);
  assert.equal(hidden.inbox, 3);
  assert.deepEqual(taskIds(Model.rows(m, 'today', TODAY, { hidden: { t1: true } })).slice(0, 1), ['t2']);
  const struck = Model.rows(m, 'today', TODAY, { struck: { t1: true } });
  assert.equal(struck[1].struck, true);
  assert.equal(struck[2].struck, false);
});

test('the rail: every project but the Inbox, children under their parent', () => {
  const rail = Model.railProjects(model(), Model.counts(model(), TODAY).projects);
  assert.deepEqual(rail.map((p) => [p.id, p.depth, p.count, p.role]), [
    ['work', 0, 6, 'accent'], ['launch', 1, 1, 'warning'], ['home', 0, 3, 'success'], ['reading', 0, 1, 'accent'],
  ]);
});

test('colours: each Todoist name maps to a theme role; unknown names are muted', () => {
  const table = {
    berry_red: 'error', red: 'error', orange: 'warning', yellow: 'warning', olive_green: 'success',
    lime_green: 'success', green: 'success', mint_green: 'success', teal: 'info', sky_blue: 'info',
    light_blue: 'info', blue: 'accent', grape: 'accent', violet: 'accent', lavender: 'accent',
    magenta: 'error', salmon: 'warning', charcoal: 'muted', grey: 'muted', taupe: 'muted',
    neon: 'muted', '': 'muted', constructor: 'muted', __proto__x: 'muted',
  };
  for (const [name, role] of Object.entries(table)) assert.equal(Model.colorRole(name), role, name);
  assert.deepEqual([4, 3, 2, 1, 7].map(Model.priorityRole), ['error', 'warning', 'accent', 'muted', 'muted']);
});

test('search: text, project name and labels, every word, case-insensitive, grouped by project', () => {
  const m = model();
  const search = (query) => kinds(Model.rows(m, 'search', TODAY, { query }));
  assert.deepEqual(search('the'), [
    'header:Inbox', 't7', 't8', 't9',
    'header:Work', 't1', 't15', 't3', 't14',
    'header:Launch', 't10',
    'header:Home', 't2', 't5', 't11',
  ]);
  assert.deepEqual(search('READING'), ['header:Reading list', 't13']);
  assert.deepEqual(search('@code'), ['header:Work', 't4']);
  assert.deepEqual(search('errand parcel'), ['header:Inbox', 't9']);
  assert.deepEqual(search('finance'), ['header:Work', 't1'], 'a link\'s text is searched, not its URL');
  assert.deepEqual(search('example.com'), []);
  assert.deepEqual(search('   '), []);
  const rows = Model.rows(m, 'search', TODAY, { query: 'ask' });
  assert.equal(rows[1].depth, 0, 'flat');
  assert.equal(rows[1].showProject, true);
});

test('markdown: links show their text, other markers are dropped, words stay intact', () => {
  const table = [
    ['Read [the docs](https://example.com/a_(b)) now', 'Read the docs now'],
    ['**bold** and __also__', 'bold and also'],
    ['*it* and _it_', 'it and it'],
    ['~~old~~ new', 'old new'],
    ['run `make test`', 'run make test'],
    ['snake_case_name and 2*3*4', 'snake_case_name and 2*3*4'],
    ['a * b * c', 'a * b * c'],
    ['![image](https://x/y.png) caption', 'image caption'],
    ['plain https://example.com', 'plain https://example.com'],
    ['', ''],
  ];
  for (const [input, expected] of table) assert.equal(Model.plainText(input), expected, input);
  assert.equal(Model.plainText(5), '');
});

test('web links: one place, ids encoded, nothing for a bad id', () => {
  assert.equal(Model.webUrl('today'), 'https://app.todoist.com/app/today');
  assert.equal(Model.webUrl('inbox'), 'https://app.todoist.com/app/inbox');
  assert.equal(Model.webUrl('upcoming'), 'https://app.todoist.com/app/upcoming');
  assert.equal(Model.webUrl('task', '6X7rM8997g3RQmvh'), 'https://app.todoist.com/app/task/6X7rM8997g3RQmvh');
  assert.equal(Model.webUrl('project', '../x'), '');
  assert.equal(Model.webUrl('project', 5), '');
  assert.equal(Model.webUrl('label', 'x'), '');
});

test('the index skips records QML could not show', () => {
  const m = Model.index({
    user: { inbox_project_id: 'in' },
    projects: [{ id: 'in', name: 'Inbox' }, { id: 'bad id', name: 'x' }, { id: 'p' }],
    tasks: [task('ok', 'fine', 'in'), task('t2', 'no project', 'p'), { id: 'x' }, null, task('t3', 'x', 'in', { priority: 9 })],
  });
  assert.deepEqual(Object.keys(m.projects), ['in']);
  assert.deepEqual(m.tasks.map((t) => t.id), ['ok', 't3']);
  assert.equal(m.tasks[1].priority, 1);
  assert.deepEqual(Model.index(null).tasks, []);
});

test('replies, messages and back-off', () => {
  assert.deepEqual(Model.parseReply('noise\n{"ok":true}\n'), { ok: true });
  for (const bad of ['', 'nope', '[1]', 'null']) assert.equal(Model.parseReply(bad), null, bad);
  assert.deepEqual(Model.messageParts('Todoist answered HTTP %1.\u001f503'), { key: 'Todoist answered HTTP %1.', values: ['503'] });
  assert.equal(Model.backoffSeconds(300, 0, 0), 300);
  assert.equal(Model.backoffSeconds(300, 1, 0), 600);
  assert.equal(Model.backoffSeconds(300, 3, 0), 1800);
  assert.equal(Model.backoffSeconds(300, 40, 0), 1800);
  assert.equal(Model.backoffSeconds(60, 0, 900), 900);
  assert.equal(Model.backoffSeconds(60, 0, 10 ** 9), 86400);
});

test('completions of unknown outcome are marked on their rows', () => {
  const rows = Model.rows(model(), 'today', TODAY, { unconfirmed: { t2: true } });
  const flag = (id) => rows.find((row) => row.id === id).unconfirmed;
  assert.equal(flag('t2'), true);
  assert.equal(flag('t1'), false);
  const search = Model.rows(model(), 'search', TODAY, { query: 'passport', unconfirmed: { t2: true } });
  assert.equal(search[1].unconfirmed, true);
});

test('an empty list never claims "nothing" when the snapshot was cut', () => {
  const table = [
    ['inbox', false, 'Inbox is empty'], ['today', false, 'Nothing left for today'],
    ['upcoming', false, 'Nothing planned'], ['project', false, 'No tasks'], ['search', false, 'No matching tasks'],
  ];
  for (const [view, truncated, text] of table) assert.equal(Model.emptyText(view, truncated), text, view);
  for (const view of ['inbox', 'today', 'upcoming', 'project', 'search'])
    assert.equal(Model.emptyText(view, true), Model.TRUNCATED_TEXT, view);
  assert.equal(Model.index(Object.assign(Fixtures.snapshot(TODAY), { truncated: true })).truncated, true);
  assert.equal(Model.index(Object.assign(Fixtures.snapshot(TODAY), { truncated: 'yes' })).truncated, false);
});

test('rate limits: Todoist\'s wait, a default without one, an add\'s warning too', () => {
  assert.equal(Model.retryDelayMs({ ok: false, code: 'RATE_LIMITED', retry_after: 30 }), 30000);
  assert.equal(Model.retryDelayMs({ ok: false, code: 'RATE_LIMITED' }), Model.DEFAULT_RETRY_SECONDS * 1000);
  assert.equal(Model.retryDelayMs({ ok: false, code: 'RATE_LIMITED', retry_after: 0 }), Model.DEFAULT_RETRY_SECONDS * 1000);
  assert.equal(Model.retryDelayMs({ ok: false, code: 'RATE_LIMITED', retry_after: 10 * 86400 }), 86400 * 1000);
  assert.equal(Model.retryDelayMs({ ok: true, added: 't1', stale: true, warning_code: 'RATE_LIMITED', retry_after: 12 }), 12000);
  assert.equal(Model.retryDelayMs({ ok: true, added: 't1', stale: true, warning_code: 'HTTP' }), 0);
  assert.equal(Model.retryDelayMs({ ok: false, code: 'NETWORK' }), 0);
  assert.equal(Model.retryDelayMs(null), 0);
});

test('fresh snapshots: a stale add reply confirms nothing', () => {
  assert.equal(Model.freshSnapshot({ ok: true, tasks: [] }), true);
  assert.equal(Model.freshSnapshot({ ok: true, added: 't1' }), true);
  assert.equal(Model.freshSnapshot({ ok: true, added: 't1', stale: true }), false);
  assert.equal(Model.freshSnapshot({ ok: false }), false);
  assert.equal(Model.freshSnapshot(null), false);
});

// ---- autocomplete in the add field --------------------------------------------
const suggestModel = () => Model.index(Object.assign(Fixtures.snapshot(TODAY), {
  projects: Fixtures.snapshot(TODAY).projects.concat([
    { id: 'pw', name: 'Work trips', color: 'teal', parent_id: null, child_order: 9, inbox: false },
    { id: 'hw', name: 'Homework', color: 'red', parent_id: null, child_order: 10, inbox: false },
    { id: 'no', name: 'Norsk høst', color: 'grape', parent_id: null, child_order: 11, inbox: false },
  ]),
  labels: [
    { id: 'L1', name: 'office', color: 'blue', item_order: 1 },
    { id: 'L2', name: 'Waiting on', color: 'red', item_order: 2 },
    { id: 'L3', name: 'Høst', color: 'green', item_order: 3 },
    { id: 'bad id', name: 'x' },
  ],
}));
const names = (result) => (result ? result.items.map((item) => item.name) : null);

test('suggestions: a trigger at the start or after whitespace, up to the caret', () => {
  const m = suggestModel();
  const table = [
    // [text, caret (default: end), kind, start, end, query]
    ['#', undefined, 'project', 0, 1, ''],
    ['Buy milk #Wo', undefined, 'project', 9, 12, 'Wo'],
    ['Buy\t@off', undefined, 'label', 4, 8, 'off'],
    ['Call #Wo later', 8, 'project', 5, 8, 'Wo'],
    // The caret inside the word: the query stops at it, the word ends at its end.
    ['Call #Work later', 7, 'project', 5, 10, 'W'],
    ['Fly #Work\\ tr', undefined, 'project', 4, 13, 'Work tr'],
  ];
  for (const [text, caret, kind, start, end, query] of table) {
    const r = Model.suggestions(m, text, caret === undefined ? text.length : caret);
    assert.ok(r, text);
    assert.deepEqual([r.kind, r.start, r.end, r.query], [kind, start, end, query], text);
  }
  for (const [text, caret] of [['email#1', 7], ['C#', 2], ['C# books', 8], ['Buy #Work ', 10], ['plain', 5], ['', 0], ['a@b', 3]])
    assert.equal(Model.suggestions(m, text, caret), null, text);
});

test('suggestions: prefix matches first, then substring, by name, at most 6', () => {
  const m = suggestModel();
  assert.deepEqual(names(Model.suggestions(m, '#wo', 3)), ['Work', 'Work trips', 'Homework']);
  assert.deepEqual(names(Model.suggestions(m, '#', 1)), ['Home', 'Homework', 'Inbox', 'Launch', 'Norsk høst', 'Reading list']);
  assert.equal(Model.suggestions(m, '#', 1).items.length, 6);
  assert.deepEqual(names(Model.suggestions(m, '#HØST', 5)), ['Norsk høst'], 'Unicode, case-insensitive');
  assert.deepEqual(Model.suggestions(m, '#zzz', 4).items, [], 'no match: no items');
  const work = Model.suggestions(m, '#ork', 4).items.find((item) => item.name === 'Work');
  assert.deepEqual([work.matchStart, work.matchLength, work.role, work.id], [1, 3, 'accent', 'work']);
  // The Inbox is a project too; archived ones aren't in the snapshot at all.
  assert.deepEqual(names(Model.suggestions(m, '#inb', 4)), ['Inbox']);
  // Archived ones never show (the helper leaves them out; the index too).
  const archived = Model.index({ projects: [{ id: 'a', name: 'Archive me', is_archived: true }, { id: 'b', name: 'Active' }] });
  assert.deepEqual(names(Model.suggestions(archived, '#a', 2)), ['Active']);
});

test('labels: personal ones and the names on open tasks, without duplicates', () => {
  const m = suggestModel();
  assert.deepEqual(m.labels.map((l) => l.name), ['code', 'errand', 'Høst', 'office', 'Waiting on']);
  assert.deepEqual(m.labels.map((l) => l.personal), [false, false, true, true, true]);
  assert.deepEqual(names(Model.suggestions(m, 'Pay @o', 6)), ['office', 'code', 'Waiting on']);
  assert.deepEqual(names(Model.suggestions(m, '@E', 2)), ['errand', 'code', 'office']);
  assert.deepEqual(names(Model.suggestions(m, '@høst', 5)), ['Høst']);
});

test('applying a suggestion: the word replaced, spaces escaped, one space, caret after it', () => {
  const project = (name) => ({ kind: 'project', name });
  const label = (name) => ({ kind: 'label', name });
  const table = [
    ['Buy milk #Wo', 9, 12, project('Work'), 'Buy milk #Work ', 15],
    ['#', 0, 1, project('Work trips'), '#Work\\ trips ', 13],
    ['Call #Wo later', 5, 8, project('Work'), 'Call #Work later', 11],
    ['Pay @wa', 4, 7, label('Waiting on'), 'Pay @Waiting\\ on ', 17],
    ['@h', 0, 2, label('Høst'), '@Høst ', 6],
  ];
  for (const [text, start, end, item, out, caret] of table)
    assert.deepEqual(Model.applySuggestion(text, start, end, item), { text: out, caret }, text);
  // The result triggers nothing more: the next word is empty.
  const after = Model.applySuggestion('Buy #Wo', 4, 7, project('Work'));
  assert.equal(Model.suggestions(suggestModel(), after.text, after.caret), null);
});

// ---- sections and assignees -------------------------------------------------------
const peopleModel = () => {
  const base = Fixtures.snapshot(TODAY);
  return Model.index(Object.assign(base, {
    projects: base.projects.concat([{ id: 'pw', name: 'Work trips', color: 'teal', parent_id: null, child_order: 9, inbox: false, shared: true }]),
    // The user (Ada, "1") isn't listed for Work trips: added anyway.
    project_collaborators: Object.assign({}, base.project_collaborators, { pw: ['7'] }),
  }));
};

test('/ suggests the sections of the last #project before it', () => {
  const m = peopleModel();
  const table = [
    // [text, caret (default end), kind, names]
    ['#Work /', undefined, 'section', ['Ops', 'Review']],
    ['#Work /re', undefined, 'section', ['Review']],
    ['#work /', undefined, 'section', ['Ops', 'Review']],
    ['#Launch #Work /o', undefined, 'section', ['Ops']],
    ['#Work /Re later #Launch', 9, 'section', ['Review']],
    ['Call #Home now /', undefined, 'section', []],
    ['#Work\\ trips /', undefined, 'section', []],
  ];
  for (const [text, caret, kind, expected] of table) {
    const r = Model.suggestions(m, text, caret === undefined ? text.length : caret);
    assert.ok(r, text);
    assert.equal(r.kind, kind, text);
    assert.deepEqual(names(r), expected, text);
  }
  for (const text of ['/', 'Buy milk /x', '#Nope /', 'a/b', 'https://x/y', '#Work a/b'])
    assert.equal(Model.suggestions(m, text, text.length), null, text);
  const r = Model.suggestions(m, '#Work /re', 9);
  assert.deepEqual([r.start, r.end, r.query], [6, 9, 're']);
});

test('+ suggests the people of a shared #project, the user included', () => {
  const m = peopleModel();
  const r = Model.suggestions(m, 'Plan #Launch +', 14);
  assert.equal(r.kind, 'assignee');
  assert.deepEqual(names(r), ['Ada Lovelace', 'Bo Ek', 'Cy Moreno']);
  assert.equal(r.items[1].email, 'bo@example.com');
  assert.deepEqual(names(Model.suggestions(m, '#Launch +bo', 11)), ['Bo Ek']);
  assert.deepEqual(names(Model.suggestions(m, '#Launch +MOR', 12)), ['Cy Moreno']);
  assert.deepEqual(names(Model.suggestions(m, '#Work\\ trips +', 14)), ['Ada Lovelace', 'Bo Ek'], 'escaped project name; the user added');
  for (const text of ['+', 'Buy +x', '#Home +', '#Work +', 'a+b'])
    assert.equal(Model.suggestions(m, text, text.length), null, text);
});

test('inserting a section or an assignee: escaped, one space, caret after it', () => {
  assert.deepEqual(Model.applySuggestion('#Work /re', 6, 9, { kind: 'section', name: 'Review' }), { text: '#Work /Review ', caret: 14 });
  assert.deepEqual(Model.applySuggestion('#Work /n', 6, 8, { kind: 'section', name: 'Next up' }), { text: '#Work /Next\\ up ', caret: 16 });
  assert.deepEqual(Model.applySuggestion('#Launch +b', 8, 10, { kind: 'assignee', name: 'Bo Ek' }), { text: '#Launch +Bo\\ Ek ', caret: 16 });
});

// ---- the open command ----------------------------------------------------------------
const URL = 'https://app.todoist.com/app/today';
test('the open command: split on spaces, {url} replaced or the link appended', () => {
  const table = [
    ['', ['xdg-open', URL]],
    ['omarchy-launch-or-focus-webapp Todoist {url}', ['omarchy-launch-or-focus-webapp', 'Todoist', URL]],
    ['firefox --new-window', ['firefox', '--new-window', URL]],
    ['  /usr/bin/chromium   --app={url}  ', ['/usr/bin/chromium', '--app={url}', URL]],
    ['open {url} --then {url}', ['open', URL, '--then', URL]],
  ];
  for (const [command, argv] of table) assert.deepEqual(Model.openArgv(command, URL), argv, command);
});

test('names and ids like constructor, __proto__ and toString are ordinary', () => {
  const snapshot = JSON.parse(JSON.stringify({
    user: { id: '1', full_name: 'Ada', inbox_project_id: 'in' },
    projects: [
      { id: 'in', name: 'Inbox', inbox: true },
      { id: 'constructor', name: 'constructor', shared: true },
      { id: 'toString', name: '__proto__' },
    ],
    sections: [{ id: 'hasOwnProperty', project_id: 'constructor', name: 'toString', section_order: 1 }],
    labels: [{ id: 'L1', name: 'constructor' }],
    tasks: [
      task('valueOf', 'one', 'constructor', { labels: ['__proto__', 'toString'], section_id: 'hasOwnProperty', due: due(TODAY) }),
      task('t2', 'two', 'toString', { parent_id: 'valueOf' }),
    ],
    collaborators: [{ id: '1', full_name: 'Ada', email: 'a@x' }, { id: '__proto__', full_name: 'toString', email: 't@x' }],
    project_collaborators: { constructor: ['1', '__proto__'] },
  }));
  const m = Model.index(snapshot);
  assert.deepEqual(Object.keys(m.projects).sort(), ['constructor', 'in', 'toString']);
  assert.equal(m.byId.valueOf.text, 'one');
  assert.deepEqual(m.labels.map((l) => l.name), ['__proto__', 'constructor', 'toString']);
  assert.deepEqual(names(Model.suggestions(m, '#con', 4)), ['constructor']);
  assert.deepEqual(names(Model.suggestions(m, '#__', 3)), ['__proto__']);
  assert.deepEqual(names(Model.suggestions(m, '@to', 3)), ['toString', '__proto__', 'constructor']);
  assert.deepEqual(names(Model.suggestions(m, '@__', 3)), ['__proto__']);
  assert.deepEqual(names(Model.suggestions(m, '#constructor /', 14)), ['toString']);
  assert.deepEqual(names(Model.suggestions(m, '#constructor +', 14)), ['Ada', 'toString']);
  const counts = Model.counts(m, TODAY);
  assert.equal(counts.projects.constructor, 1);
  assert.equal(counts.projects.toString, 1);
  // Maps of ids (hidden, struck) only hold what is in them.
  const rows = Model.rows(m, 'project', TODAY, { projectId: 'constructor', hidden: {}, struck: {}, unconfirmed: {} });
  assert.deepEqual(rows.filter((r) => r.kind === 'task').map((r) => [r.id, r.struck, r.unconfirmed]), [['valueOf', false, false]]);
  assert.equal(Model.has({}, 'constructor'), false);
  assert.equal(Model.has({ constructor: true }, 'constructor'), true);
  assert.equal(Model.has(null, 'x'), false);
});

test('a project is assignable when shared or when two or more people are active in it', () => {
  const base = (projects, members) => Model.index({
    user: { id: '1', full_name: 'Ada', email: 'ada@x', inbox_project_id: 'in' },
    projects: [{ id: 'in', name: 'Inbox', inbox: true }].concat(projects),
    collaborators: [{ id: '1', full_name: 'Ada', email: 'ada@x' }, { id: '2', full_name: 'Bo', email: 'bo@x' }],
    project_collaborators: members,
  });
  // A team project: shared false from Todoist, two active people.
  const team = base([{ id: 'w', name: 'Team', shared: false }], { w: ['1', '2'] });
  assert.deepEqual(names(Model.suggestions(team, '#Team +', 7)), ['Ada', 'Bo']);
  // Only the user: nobody else to assign.
  const solo = base([{ id: 'w', name: 'Team', shared: false }], { w: ['1'] });
  assert.equal(Model.suggestions(solo, '#Team +', 7), null);
  const none = base([{ id: 'w', name: 'Team', shared: false }], {});
  assert.equal(Model.suggestions(none, '#Team +', 7), null);
  // shared true is enough (the user is added).
  const shared = base([{ id: 'w', name: 'Team', shared: true }], {});
  assert.deepEqual(names(Model.suggestions(shared, '#Team +', 7)), ['Ada']);
});

// ---- the detail line ---------------------------------------------------------------
const detailModel = () => Model.index({
  user: { id: '1', full_name: 'Ada Lovelace', inbox_project_id: 'in' },
  projects: [{ id: 'in', name: 'Inbox', inbox: true }, { id: 'g', name: 'Gjøremål', color: 'green' }],
  collaborators: [{ id: '1', full_name: 'Ada Lovelace', email: 'a@x' }, { id: '7', full_name: 'Bo Ek', email: 'b@x' }],
  project_collaborators: { g: ['1', '7'] },
  tasks: [
    task('mine', 'Gjøre ting', 'g', { due: due(TODAY, true), labels: ['hjem'], responsible_uid: '7' }),
    task('late', 'Late', 'g', { due: due('2026-11-14'), responsible_uid: '1' }),
    task('stranger', 'Stranger', 'g', { due: due(TODAY), responsible_uid: '99' }),
    task('in1', 'Inbox one', 'in', { due: due('2026-11-23') }),
    task('next', 'Next', 'g', { due: due('2026-11-17T09:00:00') }),
  ],
});
// The parts the line shows, in order.
const parts = (row) => [
  row.dateKind && `date:${row.dateKind}`,
  row.showProject && `project:${row.projectName}`,
  row.labels.length && `labels:${row.labels.join(',')}`,
  row.assignee && `assignee:${row.assignee}`,
  row.recurring && 'recurring',
].filter(Boolean);
const partsOf = (view, options) => {
  const out = {};
  for (const row of Model.rows(detailModel(), view, TODAY, options || {})) if (row.kind === 'task') out[row.id] = parts(row);
  return out;
};

test('detail parts: Today shows the project, labels, the assignee (not you) and recurring', () => {
  const today = partsOf('today');
  assert.deepEqual(today.mine, ['project:Gjøremål', 'labels:hjem', 'assignee:Bo', 'recurring']);
  assert.deepEqual(today.late, ['date:weekday', 'project:Gjøremål'], 'overdue: the date; assigned to you: no name');
  assert.deepEqual(today.stranger, ['project:Gjøremål'], 'an unknown person: nothing');
  assert.deepEqual(today.in1, undefined);
});

test('detail parts: no project in its own view or in the Inbox; Upcoming leaves the date to its groups', () => {
  assert.deepEqual(partsOf('project', { projectId: 'g' }).mine, ['date:today', 'labels:hjem', 'assignee:Bo', 'recurring']);
  assert.deepEqual(partsOf('inbox').in1, ['date:date']);
  const upcoming = partsOf('upcoming', { weekStart: 1 });
  assert.deepEqual(upcoming.next, ['project:Gjøremål']);
  assert.deepEqual(upcoming.in1, ['project:Inbox']);
  assert.deepEqual(partsOf('search', { query: 'ting' }).mine, ['date:today', 'project:Gjøremål', 'labels:hjem', 'assignee:Bo', 'recurring']);
});

test('detail dates: relative words, the weekday within a week, else "man. 23. nov." (the year when not this one)', () => {
  const row = (day) => ({ kind: 'task', dueDay: day, dateKind: Model.dayKind(day, '2026-11-02') });
  const nb = (day) => Model.detailDate(row(day), formatter('nb'), catalog('nb'), '2026-11-02');
  const en = (day) => Model.detailDate(row(day), formatter('en'), catalog('en'), '2026-11-02');
  assert.equal(nb('2026-11-02'), 'I dag');
  assert.equal(nb('2026-11-01'), 'I går');
  assert.equal(nb('2026-11-03'), 'I morgen');
  assert.equal(nb('2026-11-06'), 'fredag');
  assert.equal(nb('2026-11-23'), 'man. 23. nov.');
  assert.equal(en('2026-11-23'), 'Mon 23 Nov');
  assert.equal(nb('2027-01-05'), 'tir. 5. jan. 2027');
  assert.equal(nb('2026-10-01'), 'tor. 1. okt.');
  assert.equal(Model.detailDate({ kind: 'task', dueDay: '', dateKind: '' }, formatter('nb'), catalog('nb'), '2026-11-02'), '');
});

// ---- tasks assigned to others -------------------------------------------------------
test('tasks assigned to others: hidden from Today, Upcoming and the counts; never from projects or search', () => {
  const m = Model.index({
    user: { id: '1', full_name: 'Ada', inbox_project_id: 'in' },
    projects: [{ id: 'in', name: 'Inbox', inbox: true }, { id: 'g', name: 'Team', shared: true }],
    tasks: [
      task('mine', 'mine', 'g', { due: due(TODAY), responsible_uid: '1' }),
      task('free', 'free', 'g', { due: due(TODAY) }),
      task('theirs', 'theirs', 'g', { due: due(TODAY), responsible_uid: '7' }),
      task('late', 'late', 'g', { due: due('2026-11-10'), responsible_uid: '7' }),
      task('soon', 'soon', 'g', { due: due('2026-11-17'), responsible_uid: '7' }),
      task('soon2', 'soon2', 'g', { due: due('2026-11-18') }),
    ],
  });
  const ids = (view, hideOthers, extra) =>
    Model.rows(m, view, TODAY, Object.assign({ hideOthers, weekStart: 1, projectId: 'g', query: 'o', overdueOpen: true }, extra || {}))
      .filter((r) => r.kind === 'task').map((r) => r.id).sort();
  const table = [
    // [view, hide, expected]
    ['today', true, ['free', 'mine']],
    ['today', false, ['free', 'late', 'mine', 'theirs']],
    ['upcoming', true, ['soon2']],
    ['upcoming', false, ['late', 'soon', 'soon2']],
    ['project', true, ['free', 'late', 'mine', 'soon', 'soon2', 'theirs']],
    ['project', false, ['free', 'late', 'mine', 'soon', 'soon2', 'theirs']],
    ['search', true, ['soon', 'soon2']],
    ['search', false, ['soon', 'soon2']],
  ];
  for (const [view, hide, expected] of table) assert.deepEqual(ids(view, hide), expected, `${view} hide=${hide}`);
  // The Upcoming fold counts only what it would show.
  const fold = Model.rows(m, 'upcoming', TODAY, { hideOthers: true, weekStart: 1 }).find((r) => r.kind === 'fold');
  assert.equal(fold, undefined, 'the only overdue task is someone else\'s');
  const hidden = Model.counts(m, TODAY, { hideOthers: true });
  const shown = Model.counts(m, TODAY, { hideOthers: false });
  assert.deepEqual([hidden.today, hidden.overdue, hidden.week, hidden.projects.g], [2, 0, 1, 6]);
  assert.deepEqual([shown.today, shown.overdue, shown.week, shown.projects.g], [4, 1, 2, 6]);
  assert.equal(Model.othersTask(m, m.byId.theirs), true);
  assert.equal(Model.othersTask(m, m.byId.mine), false);
  assert.equal(Model.othersTask(m, m.byId.free), false);
});

test('the index keeps what the editor needs: the raw content, the date in words, the deadline, cut labels', () => {
  const m = model(
    snapshotWith([
      task('a', 'Read **this** [doc](https://x.example)', 'p', { due: due('2026-11-17', false, 'tomorrow'), deadline: '2026-11-20', labels: ['x'], labels_truncated: true }),
      task('b', 'Plain', 'p', { deadline: '2026-02-30' }),
    ]),
  );
  const a = m.byId.a;
  assert.equal(a.text, 'Read this doc');
  assert.equal(a.content, 'Read **this** [doc](https://x.example)');
  assert.equal(a.dueString, 'tomorrow');
  assert.equal(a.deadline, '2026-11-20');
  assert.equal(a.labelsTruncated, true);
  // A deadline that isn't a real day is dropped; no cut marker without the flag.
  assert.equal(m.byId.b.deadline, '');
  assert.equal(m.byId.b.labelsTruncated, false);
  assert.equal(m.byId.b.dueString, '');
});

test('Quick Add runs: tokens coloured by kind, dates and plain words not', () => {
  const colors = { project: 'P', section: 'S', assignee: 'A', label: 'L', priority: 'U', reminder: 'R', deadline: 'D', description: 'M' };
  const shown = (text) => Model.quickAddRuns(text, colors).map((run) => [run.text, run.color || '']);
  assert.deepEqual(shown('Call Bob tomorrow 9am'), [], 'no tokens: no runs (plain text)');
  assert.deepEqual(shown('Buy #Home\\ Stuff /Shop +Bo @errand p1 !30m {friday} next week // get oat milk'), [
    ['Buy ', ''],
    ['#Home\\ Stuff', 'P'],
    [' ', ''],
    ['/Shop', 'S'],
    [' ', ''],
    ['+Bo', 'A'],
    [' ', ''],
    ['@errand', 'L'],
    [' ', ''],
    ['p1', 'U'],
    [' ', ''],
    ['!30m', 'R'],
    [' ', ''],
    ['{friday}', 'D'],
    [' next week ', ''],
    ['// get oat milk', 'M'],
  ]);
  // The runs always join to the text.
  for (const text of ['a #b c', '#x', 'x // y', '{open', 'p4 p5 p1x', 'C#sharp email#1 +Bo'])
    assert.equal(Model.quickAddRuns(text, colors).map((run) => run.text).join('') || text, text, text);
  // + is a person only after a #project; p4 is the default; C# isn't a project.
  assert.deepEqual(shown('+Bo p4 C# x'), []);
  assert.deepEqual(shown('#Work +Bo').map((r) => r[1]), ['P', '', 'A']);
  // An unclosed { and a lone // aren't tokens; tokens stop at the description.
  assert.deepEqual(shown('{soon'), []);
  assert.deepEqual(shown('a // #not p1').map((r) => r[1]), ['', 'M']);
  // Over Todoist's 500 characters nothing is coloured.
  assert.deepEqual(shown('#a ' + 'x'.repeat(500)), []);
});

test('the add placeholder says where the task goes', () => {
  const t = (key, values) => (values || []).reduce((text, value, i) => text.replace(`%${i + 1}`, value), key);
  const format = (date, pattern) => (pattern === 'dddd' ? ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'][date.getDay()] : `${date.getDate()} ${['November', 'December'][date.getMonth() - 10]}`);
  assert.equal(Model.addPlaceholder('inbox', '', TODAY, '', format, t), 'Add a task to the Inbox…');
  assert.equal(Model.addPlaceholder('today', TODAY, TODAY, '', format, t), 'Add a task for today…');
  assert.equal(Model.addPlaceholder('upcoming', '2026-11-19', TODAY, '', format, t), 'Add a task for Thursday 19 November…');
  assert.equal(Model.addPlaceholder('project', '', TODAY, 'Work', format, t), 'Add a task to Work…');
  // Search and the Week view add like the Inbox (no default).
  assert.equal(Model.addPlaceholder('week', '', TODAY, '', format, t), 'Add a task to the Inbox…');
  for (const key of Model.PLACEHOLDER_KEYS) assert.ok(key.endsWith('…'), key);
});

test('the editor date in the panel words', () => {
  const t = (key) => key;
  const format = (date, pattern) => (pattern === 'dddd' ? 'Thursday' : `${pattern}:${date.getDate()}`);
  const m = model();
  assert.equal(Model.dueWords(m.byId.t3, format, t, TODAY), 'Today 09:30');
  assert.equal(Model.dueWords(m.byId.t10, format, t, TODAY), 'Tomorrow 10:00');
  assert.equal(Model.dueWords(m.byId.t12, format, t, TODAY), 'Thursday 15:00');
  assert.equal(Model.dueWords(m.byId.t7, format, t, TODAY), '');
});

test('the Week view: overdue, today, tomorrow and seven days after, by day', () => {
  const m = model(
    snapshotWith([
      task('old', 'Old', 'p', { due: due('2026-11-10') }),
      task('late', 'Late', 'p', { due: due('2026-11-14') }),
      task('now', 'Now', 'p', { due: due('2026-11-16T09:00:00') }),
      task('allday', 'All day', 'p', { due: due('2026-11-16') }),
      task('tom', 'Tomorrow', 'in', { due: due('2026-11-17') }),
      task('d2', 'In two days', 'p', { due: due('2026-11-18T08:00:00') }),
      task('d2b', 'Also in two', 'p', { due: due('2026-11-18') }),
      task('d8', 'Last day', 'p', { due: due('2026-11-24') }),
      task('d9', 'Too far', 'p', { due: due('2026-11-25') }),
      task('none', 'Undated', 'p'),
      task('theirs', 'Theirs', 'p', { due: due('2026-11-16'), responsible_uid: '9' }),
      task('sent', 'Sent', 'p', { due: due('2026-11-16') }),
    ]),
  );
  const cols = Model.weekColumns(m, TODAY, { hideOthers: true, hidden: { sent: true }, struck: { now: true } });
  const ids = (col) => col.entries.map((e) => (e.kind === 'day' ? `day:${e.dayKey}` : e.id));
  assert.deepEqual(cols.map((c) => c.key), ['overdue', 'today', 'tomorrow', 'later']);
  assert.deepEqual(ids(cols[0]), ['old', 'late']);
  assert.deepEqual(ids(cols[1]), ['now', 'allday'], 'timed first; others hidden; sent left out');
  assert.deepEqual(ids(cols[2]), ['tom']);
  assert.deepEqual(ids(cols[3]), ['day:2026-11-18', 'd2', 'd2b', 'day:2026-11-24', 'd8']);
  // Cards: the time, the project, struck; an overdue card says its date.
  const now = cols[1].entries[0];
  assert.equal(now.dueTime, '09:00');
  assert.equal(now.showProject, true);
  assert.equal(now.projectName, 'Project');
  assert.equal(now.struck, true);
  assert.equal(cols[0].entries[0].overdue, true);
  assert.equal(cols[0].entries[0].dateKind, 'weekday');
  // The indices, computed once: each card's place among the tasks, each card's entry.
  assert.deepEqual(cols[3].entries.map((e) => e.card), [-1, 0, 1, -1, 2]);
  assert.deepEqual(cols[3].cards, [1, 2, 4]);
  assert.deepEqual(cols[0].cards, [0, 1]);
  // Show: someone else's task is in Today too.
  assert.ok(ids(Model.weekColumns(m, TODAY, { hideOthers: false })[1]).includes('theirs'));
});

test('Ctrl+arrows move a day, never before today, never a recurring task', () => {
  const m = model(
    snapshotWith([
      task('a', 'A', 'p', { due: due('2026-11-18') }),
      task('b', 'B', 'p', { due: due('2026-11-16') }),
      task('c', 'C', 'p', { due: due('2026-11-12') }),
      task('r', 'R', 'p', { due: due('2026-11-18', true) }),
      task('n', 'N', 'p'),
    ]),
  );
  assert.equal(Model.shiftedDay(m.byId.a, 1, TODAY), '2026-11-19');
  assert.equal(Model.shiftedDay(m.byId.a, -1, TODAY), '2026-11-17');
  assert.equal(Model.shiftedDay(m.byId.b, -1, TODAY), '', 'today stays today');
  assert.equal(Model.shiftedDay(m.byId.b, 1, TODAY), '2026-11-17');
  assert.equal(Model.shiftedDay(m.byId.c, 1, TODAY), TODAY, 'an overdue task lands on today');
  assert.equal(Model.shiftedDay(m.byId.c, -1, TODAY), TODAY);
  assert.equal(Model.shiftedDay(m.byId.r, 1, TODAY), '');
  assert.equal(Model.shiftedDay(m.byId.n, 1, TODAY), '');
});
