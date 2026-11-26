# Foamy Todoist

An Omarchy bar plugin for Todoist: the tasks left today in the bar, and a
panel with your Inbox, Today, Upcoming and (in the Wide size) each of
your projects. Add tasks with Todoist's own Quick Add syntax,
complete them with a click or Space, and change a task's text, date,
deadline, project, priority, labels and description in the panel.

![Foamy Todoist: the Today view with the Inbox, Today and Upcoming tabs, overdue tasks, and + and Search in the band](preview.png)

The bar shows the Todoist mark and, in the bar's urgent colour, the number
of tasks left today (overdue plus due today), like Foamy Zendesk's count.
Nothing left today, or **Show in the bar: Icon only**, leaves just the mark;
signed out, the mark stands alone. The tooltip says how many are left and how
many of them are overdue.

## The panel

Two sizes (**Size** in Settings), both the popup under the bar:

- **Small**: 420 px. A row of tabs under the band picks **Inbox**,
  **Today** or **Upcoming**, with their counts (Today's in red while
  something is overdue). It is as tall as its list, up to 70% of the
  screen.
- **Wide**: no tabs. A rail on the left lists the views (with **Week** after
  Upcoming), then **My projects** (sub-projects indented one step) with
  their open tasks; the list is beside it, and a pane on the right shows
  the selected task's details (a click on it, or the keys resting on it)
  or, with none selected, an overview of the view (see "The overview").
  The popup is always 880 px, with or without a selection, in the Week
  view and on its settings page (whose sections keep the 560 px column,
  centred), so it never changes width while open. Its height holds while
  it is open too: at least 12 rows, and never lower than the tallest it has
  been since it opened (a longer view or task grows it once; a shorter one
  leaves room at the bottom), up to 70% of the screen (the list scrolls
  inside). Closing the panel lets the height go. Where the
  screen has no room for 880 px beside the popup's margins, it opens Small
  instead.

The band at the top holds the Todoist mark, the title, the current view and
its count, and three buttons: **+** (add a task, `a`), **Search** (`/`) and
⋯ (**Open in Todoist** opens the current view in the browser; **Settings**
is last). Nothing has the cursor when the panel opens.

- **Inbox**: the Inbox project in Todoist's order, subtasks under their
  parent, sections with a header.
- **Today**: **Overdue** (oldest first), then today's tasks: those with a
  time by time, then the rest in Todoist's Today order and by priority.
- **Upcoming**: a folded **Overdue** row (→, Enter or a click opens it),
  then one group per day up to the end of this week, headed by the weekday
  and, muted, the date (**Tomorrow** Tuesday 17 November, **Wednesday** 18
  November), then **Next week** (with its dates, 23–29 Nov),
  **Later in November** (the rest of this month), then one group per month
  ("December", "January 2027": the year only when it isn't this year). The
  week starts on the day your language's locale starts it (Monday in
  Norwegian). The later groups have a hairline above them and their count on
  the right; their tasks show the weekday (and, after next week, the date)
  before the time. Today's sections show their counts on the right too. The band counts the tasks of the next seven days. A task
  added in Upcoming gets the day of the day group the cursor was last in,
  else tomorrow.
- **A project** (Wide): its tasks without a section first, then each
  section.
- **Week** (Wide): four columns, **Overdue**, **Today**, **Tomorrow** and
  **Later** (the seven days after tomorrow, each day under a small
  heading). A card shows the task, its time and its project. ↑/↓ move in a
  column, ←/→ across (← from the first column goes to the rail), Space
  completes, `t` moves the task to tomorrow, Ctrl+← and Ctrl+→ move it a
  day earlier or later (never before today; recurring tasks stay, as with
  `t`). A moved card goes to its new column at once; the move is sent as
  a move in a list is (see "Moving"), and moving it back to its day
  cancels it. Enter, `e` or a click opens the details beside the board,
  which keeps its four columns, narrower (titles on up to three lines); Esc
  or the pane's Close closes them. Small shows Today instead, and so does
  **Open on: Last view**.

Each row has a ring in the priority's colour (p1 red, p2 orange, p3 accent,
p4 grey), the task (Markdown links show their text), and a line with what
the view doesn't already say, in this order: the date ("Yesterday", a
weekday within the coming week, else "Mon 23 Nov" in your language, so
last Friday never reads like next Friday; an overdue date is red with a
warning mark; none in Today's Today section or in Upcoming, which groups
by day), the deadline (a target mark and its day, red once it is due), the
project (its # muted; in every view but that project's own), `@labels`, the
person it is assigned to when that isn't you (first name), and a repeat
icon for recurring tasks. The date, deadline, person and repeat mark show
whole; the project and then the labels are cut with "…" when the line is
full. A due time shows on the right: today, a time that has passed is red
and the next one ahead is bright. The ring and the time stand on the
task's first line. A heading's count stands beside its word (after a date
range, at the row's end).

In Small the band's line leaves the view's name to the tabs: Today says the
date first ("Thu 26 Nov · 6 left · 2 overdue"), the Inbox and Upcoming
their counts.

**Completing**: click the ring or press Space. The task stays, struck
through, with **Undo**; four seconds after the last completion every
pending one is sent to Todoist in one request (at once when the panel
closes). Undo only takes it back here, so nothing is sent. If Todoist
refuses a completion the task comes back and the line under the band says
why. When the request fails as a whole (no answer, the network), Todoist may
or may not have done it, so those tasks show dimmed and can't be completed
or moved again until the next refresh, which starts at once. A recurring
task moves to its next date, as in Todoist.

**Moving** to another day: the row under the cursor shows two buttons in
its time's place: **Tomorrow** (`t`) and a calendar (`d`) with **Today**,
**Tomorrow**, **Next week** (the first day of your locale's next week) and
**No date**. Today's **Overdue** heading has **Move to today** for all its
tasks (`T` on an overdue row). A moved task keeps its time (a 14:00 task moved to tomorrow is due
tomorrow at 14:00). Like a completion, the row stays where it is, dimmed,
with its new day in the accent colour and **Undo**; the move is sent with
the completions four seconds after the last change (at once when the panel
closes), and a refusal brings the task back with the reason on the line
under the band. A recurring task isn't moved: its rule decides its dates,
so the line says to open it and change the date there (in its own words).

**Adding**: click **+** or press `a` anywhere: a field grows out of the
button across the band (the band keeps its height, and nothing moves under
it). Its placeholder says where the task goes: "Add a task to the Inbox…",
"for today…", for Upcoming's day, or to the project you are looking at;
that date or project applies when the text gives none. In the Week view
the task goes to the day of the column the cursor was last in: today from
Overdue and Today, tomorrow from Tomorrow, the card's day from Later, and
today until the cursor has been on the board (the placeholder names the
day). The Quick Add parts
show in colour as you type: `#project`, `/section` and `+person` in the
accent colour, `@labels` tinted toward it, `p1`–`p3` and `!reminders` in
the urgent colour, `{deadline}` and ` // description` muted; dates are left
for Todoist to read and aren't coloured. While the field is open the footer
shows its keys:

- **Enter** does what **After adding a task** says. **Close the panel**
  (the default) sends the task and closes the field and the panel. **Keep
  the field open** sends it and keeps the caret in the field, which empties
  once Todoist has the task. You can type the next task meanwhile: when
  Todoist answers, only the sent text leaves the field.
- **Shift+Enter** does the other one.
- **Esc** clears the text, and on an empty field closes it (the field
  shrinks back into **+**).

The task appears when Todoist has answered (a spinner in the field shows
meanwhile). An error shows under the band and keeps the text. When the task
was sent but no answer came back (a timeout, a lost connection), Todoist may
have added it: the line says so, the text stays, and the list refreshes at
once, so you can check before sending it again. An empty field also closes
when it loses the keys (a click on a tab, a task, ↓ into the list), but not
for its own right-click menu, so the menu's Paste lands in it; one with
text stays open. Text you've typed is never thrown away by moving around: it
stays when you switch views, Tab doesn't leave a field with text in it (Tab
from an empty field goes to the next panel), and when the panel closes, also
after Enter closed it before Todoist answered, the draft is kept for this
session and comes back, with the caret at its end and the error if the add
failed, the next time the panel opens. Adding the task or clearing it with
Esc ends the draft. A suggestion that would make the text longer than 500
characters isn't put in (the line under the band says so). A paste the
field can't take (over 16 KiB, not plain text, or no answer from the
clipboard within two seconds) changes nothing, and the line says why. At
most 500 characters. The text goes to Todoist's Quick Add (see below).

**Suggestions**: typing `#` at the start of a word lists your projects (the
Inbox too), `@` your labels (your personal ones and the shared labels on
open tasks). The list drops from the band and narrows as you type: names
that start with what you typed first, then names that contain it, at most
six. ↓/↑ pick one, Enter or Tab (or a click) puts it in, as `#Name` or
`@name` with spaces written `\ ` the way Quick Add reads them, followed by
a space. After a `#project`, `/` lists that project's sections (`/Name`),
and in a project you share `+` lists the people in it, you included, with
their email beside the name (`+Full\ Name`). A project counts as shared
when Todoist says so or when two or more people are active in it (team and
workspace projects come marked unshared). Without a `#project` before
them, `/` and `+` suggest nothing; `+` neither in a project only you are in.
The Quick Add docs say how to write project names with spaces (`\ `), not
labels, sections or people; the plugin escapes them the same way, which is
not verified against Todoist yet. Esc closes only the list. With the list
closed, Enter adds the task as before; so does Enter when the word is already
the highlighted entry in full (`#home` for Home), while Tab still puts it
in. The footer shows the list's keys while it is open. Search never shows
suggestions.

**Search** (the button, or `/`): the same field grows out of **Search** and
searches every open task by text, project name and labels; a word that
starts with `@` matches labels only (a label whose name starts with it;
write a space in a label's name as `\ `, as in Quick Add). Until you type,
the open view stays as it was. The results then replace the list, grouped
by project (the project's name heads its results, so the rows leave it
out), with the matched part of each title in bold; in Small the tab row
says how many tasks were found. When nothing matches, the list says so and
offers **Add as a task**, which puts what you typed in the add field
(not when search put an add draft aside). Esc clears the text, then leaves
search; the field's × leaves it at once. Leaving search (Esc, ×, another
view) puts back an add draft you had started before it, the caret at its
end; without one, the field closes.

**The overview** (Wide): with no task selected, the pane sums up the
view. Parts with nothing to show are left out (a zero, **When** for an
empty list); a click on a part (or Tab to it and Enter) acts on it. An
empty list's line stands in the middle of the list.

- **Today**: the date, how many tasks are left today and how many are
  overdue (only when any are). With nothing left or overdue, **Tomorrow**
  with its count and its first task instead (a click selects it). **Next** (the next task with a time still ahead today, and how
  far ahead), and **Today's times**: the hours from 08 to 18 (wider when a
  task is outside them), each task with a time as a block at its time, and
  a red line at now; under it, how many tasks have no time. Tasks at the
  same time share the width, three side by side at most: the rest show
  as one "+N more" block. A block or Next selects that task ("+N more"
  the first of its tasks, in the list beside the others).
- **A project**: **Sections** with their task counts ("(No section)" for
  the tasks without one) and its sub-projects: a section scrolls the list
  to it, a sub-project opens it. **When**: one bar of overdue, today, this
  week (to the end of the calendar week), later and no date, with a
  legend. **Labels**: the labels on its tasks, the most used first; a
  label searches for it (`@label`). A long label's name is shortened with
  "…" (in full when you point at it).
- **Inbox** and **search**: When and Labels, as for a project.
- **Upcoming**: the next seven days as columns, a bar each by its number
  of tasks; the day a new task goes to is lit (tomorrow, or the day you
  picked). A day scrolls the list to it. **Next deadline**: the nearest
  deadline from today on (selects its task), then how many tasks have no
  date (Upcoming doesn't list them).

A list that continues past the card's edge fades out at that edge.

**Editing**: a click on a task, Enter or `e` opens it in the editor. In
Small the editor takes the panel's place, like the settings page:
**Back** (or Esc, or ← on Back) returns to the list with the task under the
cursor. Its band says "Saving…" while a change is sent. In Wide it is
the details pane on the right (the left in right-to-left languages), which
shows the selected task (the one the keys or a click moved to; pointing at
a row doesn't change it). While it shows a task, the task keys (Space,
Enter, `e`, `t`, `d`, `T`, Ctrl+O, and Ctrl+←/→ in the Week view) act on
it, also with the pointer on another row (`d` then opens the pane's own
Date menu); after an arrow key they act on the cursor's row, which the pane
then shows. Its header row shows the task's project (and
section), **Open in Todoist** and **Close** (as Esc in the list). `e` or a
click on a part puts the caret there, Tab moves through the parts (the
header's two buttons last), and Esc gives the keys back to the list.
While a change is sent, the footer says "Saving…" in place of "Updated …",
then "Saved" for two seconds. A click on the list's space that isn't a row
(below the last row, a heading, the Week view's empty column space), or
Esc in the list, clears the selection: no row is selected and the pane
shows the overview again (beside the Week view it closes); what you typed in
the pane is saved first.
A task completed or deleted elsewhere closes the pane too. A click on
empty space anywhere in the panel takes the keys from a text field, which
saves as when you leave it.

The editor reads like the task, as Todoist's task view does: the ring and
the title, the description under it, then the task's **Project**, **Date**,
**Deadline**, **Priority** and **Labels**, one row each: the icon under the
ring, the value in line with the title, a small caption at the row's end.
An empty row says what a click adds ("Add deadline"). Each part is edited
where it is. Each property row is one click target, as in Todoist: a click
anywhere in it, or Enter on it (one Tab stop each), changes it.

- The **title** and the **description** look like text; a click (or Tab)
  makes them fields. The description is read from Todoist when the editor
  opens the task ("Loading…" meanwhile; a failed read says why, with
  **Retry**). One that is longer than the editor takes (16 384 characters)
  is shown, not edited: open it in Todoist.
- **Date**: a click on the row (or Enter on it) opens the days a row's
  calendar has (see "Moving") and **Type a date…**; a recurring task opens
  the field at once. From the keys a menu starts on the task's current
  choice, so Enter keeps it.
- **Date** (Type a date…) and **Deadline**: a one-line field. The date is
  written as in Todoist ("tomorrow 9am",
  "every Monday") and Todoist reads it; the field starts with Todoist's
  own words for the date (a repeating task's rule). A deadline is
  `YYYY-MM-DD`. Enter saves, Esc cancels; an empty field removes the date
  or deadline.
  The calendar icon has the date's colour (overdue, today, tomorrow, this
  week).
- **Project** (and section), **Priority** (P1 to P4, flags in the rows'
  colours) and **Labels** (× takes one off; a click elsewhere in the row,
  marked **+** after the labels, adds one of your personal labels) open a
  menu and save when you pick. A label too long for the row is cut, and
  keeps its ×.
- A text field saves when it loses the keys, or on Enter (Ctrl+Enter in
  the description); Esc in it drops what you typed there. Each save sends
  only the part that changed. Leaving the task (another task, Back, another
  view or size, closing the panel) saves what you typed first; a change
  that can't be sent then, such as a deadline that isn't a day, is said on
  the list's error line. A save Todoist refuses shows why under the part,
  with **Retry**, and keeps your text; so does a paste the field can't
  take, without **Retry**. Only what you typed is sent: a field
  you haven't changed follows the task when it changes in Todoist (also
  while it has the caret); one you changed keeps your text, and saving it
  replaces Todoist's.
- A task with more labels than the panel keeps (50) has its labels shown,
  not edited.
- The **ring** beside the title completes the task. **Open in Todoist** is
  an icon in the page's band, or in Wide in the pane's header.
  Completing the task (here, or with its row's ring or Space) saves what
  you typed first. A task completed or deleted elsewhere meanwhile: the
  page says it is no longer in Todoist.

Ctrl+O on a task opens it in Todoist.

The footer has a **Todoist** button on the left that opens the current
view in Todoist (with the open command, see Settings); when that fails, the
footer says so until a launch works. On the right it shows when the tasks
were last updated and **Refresh**. When a
refresh fails the tasks stay as they were, the footer keeps the time they
are from, and the line under the band says what failed. When Todoist asks
to slow down, no refresh, add or change is sent until the time it gave has
passed; adds and changes asked for meanwhile fail at once and say so. At
most 20 requests wait in line; more are refused with "Too many changes are
waiting". A very large account (over 20 000 open tasks, 2 000 projects or
5 000 sections) shows only part of it, and a muted line under the band
says so (an empty view then says that too, not "Nothing planned").

## Quick Add syntax

The text you add goes to Todoist's own Quick Add, which reads it the way the
Todoist apps do: `#Project`, `/Section`, `@label`, `p1` to `p4`, dates in
plain words in your account's language ("tomorrow 9am", "every Monday"),
`{deadline}`, `!reminder` (`!30m`), `+assignee` in a shared project, and
` // description` at the end. The view's date (today in Today, the day
the placeholder names in Upcoming) applies only when the text gives no date, and the
project's view moves the task there only when the text names no project: a
`#` at the start or after a space, followed by a non-space
(`Buy milk #Inbox` stays in the Inbox; `C#` and `email#1` don't count).

## Keyboard

One cursor for the keys and the pointer. Where the keys moved it, it has a
thin accent border; the selected task (the one the Wide pane shows) has an
accent tint and a bar at its start.

| Key | Where | Does |
|---|---|---|
| Alt+1, Alt+2, Alt+3 | anywhere, also while typing | Inbox, Today, Upcoming |
| 1, 2, 3 | the list | the same |
| ↓ | nothing selected | the first row |
| a | anywhere (signed in) | open the add field |
| Enter, Shift+Enter | the add field | add the task; close the panel or keep the field open, as **After adding a task** says (Shift: the other) |
| Enter | the search field | go to the results |
| ↓ | the field | the first row |
| Esc | the field | clear the text; when empty close the field (and leave search) |
| ↓ ↑, Enter or Tab, Esc | the suggestion list | pick, put it in, close the list (Enter on a word that already is the entry: add the task) |
| ↑ ↓ j k | the list | move; ↑ on the first row goes to the tabs (the rail), ↑ from there to ⋯, Search and + |
| Space | a row | complete (again, or on a moved row: undo) |
| Enter, e | a row | open the task in the editor (Wide: the caret in the details pane) |
| Ctrl+O | a row | open the task in Todoist |
| t | a row | move to tomorrow, keeping the time (not for recurring tasks) |
| d | a row | the menu of days: Today, Tomorrow, Next week, No date |
| T | an Overdue row in Today | move all of Overdue to today, as **Move to today** |
| / | the list | search |
| ← → | the tabs | pick a view (Enter or Space shows it) |
| ↑ ↓, Enter | the rail (Wide) | pick a view or project; ← from the list goes to the rail |
| ↑ ↓ ← → | the Week view | move in a column, across columns |
| Ctrl+← Ctrl+→ | the Week view | move the task a day earlier or later |
| Enter, Space | a value in the editor | change it (a menu, or the date field) |
| Esc | the editor's field | drop the change; with none, back to the list (the date field: close it) |
| Tab, Shift+Tab | the list (Wide) | into the details pane (the task's fields, or the overview's parts); with neither, the next or previous panel |
| Enter, Space | a part of the overview | what a click does |
| Esc | the overview | the keys back to the list |
| r, s | the list | refresh, Settings |
| Esc | the list | close (Wide: close the details pane first; in a list that clears the selection) |
| Tab, Shift+Tab | the list (Small), or an empty field | the next or previous panel (in a field with text: nothing) |

## Settings

Open them from the ⋯ menu (signed out: the gear in its place), with `s`,
or by right-clicking the bar icon.

- **Account**: signed out, the section says where the API token is in
  Todoist (Settings → Integrations → Developer; **Open Todoist settings**
  beside the field's label goes there); paste it in the field and press
  **Save token** beside it. The token is checked with Todoist before
  it is stored. Signed in, the page shows who, and **Sign out**. When the
  stored token can't be used (for example the keyring holds a value that
  isn't a token), the page shows why, the token field and **Sign out**. A
  stored token that Todoist refuses keeps the page signed in; the list says
  why. While the list has no tasks to show, it offers **Open settings**
  when Todoist refuses the token or the keyring holds a value that isn't
  one, and **Retry** for other failures, such as a locked keyring.
- **Size**: Small (default) or Wide (see "The panel"). A **Large** saved by
  an earlier version opens as Wide.
- **After adding a task**: Close the panel (default) or Keep the field
  open: what Enter in the add field does; Shift+Enter does the other.
- **Open on**: Today, Inbox, Upcoming or Last view (kept until the shell
  restarts).
- **Tasks assigned to others**: Hide (default) or Show. A task is someone
  else's when it is assigned to a person other than you (unassigned tasks are
  yours). Hidden, they stay out of Today, Upcoming and the Inbox, the bar
  number and its tooltip, and the Inbox/Today/Upcoming counts. A project
  view, search and the projects' counts in the rail always show every task.
- **Open command**: what opens Todoist links (the footer button, Ctrl+O on
  a task, **Open in Todoist**). Empty (**Browser (default)**) uses
  `xdg-open`. Otherwise, for example `omarchy-launch-or-focus-webapp
  Todoist {url}`: the command is split on spaces and run without a shell
  (quotes and pipes aren't supported), `{url}` is replaced with the link,
  and without it the link is added at the end. It must start with a command
  name or an absolute path, at most 300 characters. It runs in its own
  session, so what it opens stays when the shell restarts. Only
  `https://app.todoist.com/` links are ever opened.
- **Show in the bar**: Tasks left today or Icon only.
- **Refresh every**: 1 to 30 minutes (5 by default). The panel also
  refreshes when it opens and the data is older than 30 seconds. After a
  failure the wait doubles, up to 30 minutes, and never ends before
  Todoist's own retry time when it asks to slow down.

IPC (`omarchy-shell foamy.todoist <function>`): `toggle` (the panel),
`add` (opens the panel with the add field open and the caret in it) and
`refresh`. To open the panel or the add field with keys, bind them in
Hyprland, for example in `~/.config/hypr/bindings.conf` (pick your own
keys in place of `MODS` and `KEY`):

```ini
bindd = MODS, KEY, Todoist, exec, omarchy-shell foamy.todoist toggle
bindd = MODS SHIFT, KEY, Add a Todoist task, exec, omarchy-shell foamy.todoist add
```

## Privacy

- The API token lives in your keyring (Secret Service, through
  `secret-tool`, as "Foamy Todoist API token"). It is never written to a
  file, a log or the settings, and never passed on a command line.
- `$XDG_CACHE_HOME/foamy-todoist/cache.json` (else
  `~/.cache/foamy-todoist/`, owner-only) keeps the open tasks, projects,
  sections, your personal labels, the names and emails of the people you
  share projects with (for `+` suggestions), your name, email and Inbox id, and
  Todoist's sync token, so a refresh only fetches what changed. Signing out
  removes it. Descriptions are not kept: the editor reads the shown task's
  description from Todoist and holds only that one, in memory, while it
  shows the task.
- The only server contacted is `api.todoist.com`. Opening a task or view
  hands an `https://app.todoist.com/app/…` link to your browser.

## Languages

English and Norwegian (`i18n/en.json`, `i18n/no.json`), following the
shell's language. Dates, weekdays and months use the locale, and so does the
first day of the week in Upcoming. Every text the panel shows is a catalog
key, including the helper's errors; `tests/i18n.test.cjs` checks that both
catalogs cover everything, with matching placeholders and no unused entries.

## Install

Requires Omarchy 4.5.

```sh
omarchy plugin add https://github.com/foamrider/foamy-todoist.git --enable
```

To remove it, sign out first (that removes the token from the keyring and
the cache), then run `omarchy plugin remove foamy.todoist`.

## Verifying the helper binaries

`bin/x86_64/foamy-todoist-helper` and `bin/aarch64/foamy-todoist-helper`
are compiled from the Rust source in this repository: `native/`, the shared
crate in `kit/rust/`, the dependencies locked in `Cargo.lock` and the
toolchain pinned in `rust-toolchain.toml`, with the build tool in
`kit/native/`. The build is reproducible. `native/native.pin` records the
toolchain, a hash of every build input (`source`) and the SHA-256 of each
binary. [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) lists the
third-party code linked into the binaries (crates, the Rust standard
library, musl, LLVM's libunwind) with the license texts and copyright
notices it ships; the build writes it and the verification below
regenerates and compares it.

**CI.** The [Verify native helpers](https://github.com/foamrider/foamy-todoist/actions/workflows/verify-native.yml)
workflow rebuilds both binaries on a GitHub-hosted runner for every push,
compares them byte for byte with `bin/`, and attests the rebuilt files. To
check the committed files against that attestation (GitHub CLI):

```sh
gh attestation verify bin/x86_64/foamy-todoist-helper --repo foamrider/foamy-todoist \
  --signer-workflow foamrider/foamy-todoist/.github/workflows/verify-native.yml \
  --deny-self-hosted-runners
gh attestation verify bin/aarch64/foamy-todoist-helper --repo foamrider/foamy-todoist \
  --signer-workflow foamrider/foamy-todoist/.github/workflows/verify-native.yml \
  --deny-self-hosted-runners
```

Add `--source-digest <commit>` to require a particular commit.

**Yourself.** You need `rustup`, Python 3.11 or newer and `file`. From a
checkout of this repository at the commit you want to check:

```sh
rustup toolchain install "$(awk '$1 == "toolchain" { print $2 }' native/native.pin)" \
  --profile minimal --target x86_64-unknown-linux-musl,aarch64-unknown-linux-musl
kit/native/build-native.sh . --verify
```

It builds both binaries from scratch in `~/.cache/foamy-native/` (nothing is
written to the checkout), compares them byte for byte with `bin/`, checks
that the kit files are unmodified, that `native.pin` matches the source and
that `THIRD_PARTY_NOTICES.md` equals a fresh generation, and ends with
`verify OK (<binary>, <toolchain>, both arches reproducible)`.

## License

Licensed under [MIT](LICENSE). Omarchy and Lucide notices are in
[kit/LICENSE-OMARCHY](kit/LICENSE-OMARCHY) and [kit/LICENSE-LUCIDE](kit/LICENSE-LUCIDE).
Todoist is a trademark of Doist Inc.; this plugin is not affiliated with or
endorsed by Doist.

Provided **as is**, without warranty or guaranteed support. Use at your own risk.

## Validation

```sh
mise install            # once: the linters and node that mise.toml pins
tests/validate.sh       # kit-check, omarchy-plugin-validate, linters, formatters,
                        # the helper's tests and tests/suite.sh (node, i18n, runtime)
tests/validate.sh --ci  # what GitHub's runner can do: no Quickshell or Omarchy host
kit/native/build-native.sh . --test     # fmt, clippy, cargo test
kit/native/build-native.sh .            # rebuild bin/<arch>/ and native/native.pin
kit/native/build-native.sh . --verify   # byte-identical clean rebuild
python3 ../foamy-kit/preview/render.py . --out /tmp/foamy-todoist-preview   # add --theme light
```

The helper's tests run the real binary against a Todoist stand-in on
loopback (`FOAMY_TODOIST_BASE_URL`) and a fake `secret-tool`, in temporary
HOME and XDG directories. The runtime test loads the real panel and store
offscreen with a stand-in helper. Nothing touches a real account or keyring.
The previews and tests use the sample tasks in `preview/Fixtures.js`.

Shared components are copied from foamy-kit and pinned by `foamy-kit.lock`.
Change the kit source and sync; never edit its stamped copies here.
