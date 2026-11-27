"""Run the real plugin, store and UI in foamy-kit's isolated offscreen shell.

The helper is a stand-in (TodoStore.helperCommand): a shell script that logs
each call with its standard input to $FOAMY_OUT/calls.log and answers with
$FOAMY_OUT/reply-<command>.json (after $FOAMY_OUT/slow-<command> seconds;
with $FOAMY_OUT/exit-<command> as its exit status instead, when that file
is not empty). While $FOAMY_OUT/hold-<command> is not empty and holds the
text it held when the call came, it holds its reply (the scene's shell.hold,
shell.pass and shell.release) and lists the hold in $FOAMY_OUT/held.log.
Nothing reaches Todoist or a keyring.

  python3 tests/runtime.py

The host is Omarchy 4.5, the installed /usr/share/omarchy/shell
(FOAMY_HOST_45 picks another 4.5 tree).
"""

import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

plugin = Path(__file__).resolve().parents[1]
# FOAMY_KIT, else the sibling checkout, else the usual one.
kit = Path(
    os.environ.get("FOAMY_KIT")
    or next(
        (p for p in (plugin.parent / "foamy-kit", Path.home() / "GitHub/Personal/foamy-kit") if p.is_dir()),
        plugin.parent / "foamy-kit",
    )
)
os.environ.setdefault("FOAMY_HOST_45", "/usr/share/omarchy/shell")
sys.path.insert(0, str(kit / "preview"))
import harness  # noqa: E402
import hostenv  # noqa: E402

FAKE_HELPER = r"""
cmd=$1
out=$FOAMY_OUT
input=$(cat)
printf '%s %s\n' "$cmd" "$input" >>"$out/calls.log"
# A held reply waits for the scene to release it, at most 25 s (the store's
# own deadline is 30 s), so a run that never releases still ends. The hold
# file's text is a ticket: a new one (shell.pass) lets the call held now
# answer and holds the next one; an empty file lets every call answer. The
# store runs one call at a time, so the next one reads the new ticket.
if [ -s "$out/hold-$cmd" ]; then
  ticket=$(cat "$out/hold-$cmd")
  printf '%s\n' "$cmd" >>"$out/held.log"
  limit=$(($(date +%s) + 25))
  while [ -s "$out/hold-$cmd" ] && [ "$(cat "$out/hold-$cmd")" = "$ticket" ]; do
    if [ "$(date +%s)" -ge "$limit" ]; then
      printf '%s\n' "$cmd" >>"$out/hold-expired.log"
      exit 1
    fi
    sleep 0.05
  done
fi
if [ -s "$out/slow-$cmd" ]; then sleep "$(cat "$out/slow-$cmd")"; fi
if [ -s "$out/exit-$cmd" ]; then exit "$(cat "$out/exit-$cmd")"; fi
cat "$out/reply-$cmd.json"
"""

SHELL = r"""
import QtQuick
import QtQuick.Controls as Controls
import QtTest
import Quickshell
import qs.Commons as Commons
import Quickshell.Io
import "harness"
import "plugin" as Plugin
import "plugin/kit" as Kit
import "plugin/preview/Fixtures.js" as Fixtures
import "plugin/Model.js" as Model
ShellRoot {
  id: shell
  property int step: 0
  property bool finished: false
  property int frames: 0
  property int drawTarget: 0
  property var entry: ({})
  property int callsBefore: 0
  // Wall-clock times (ms) of a key and of the description read it led to:
  // timers run on the real clock, so a later read never means a shorter wait.
  property real keyAt: 0
  property real readAt: 0
  property int openedBefore: 0
  property int queuedAdds: 0
  property var ipcPanel: null
  property string expectedUrl: ""
  property string ringTask: ""
  // The task the pane's typed text belongs to, and the text.
  property string paneFrom: ""
  property string paneText: ""
  // The popup's margin before a step narrows its room.
  property int savedMargin: 0
  // Wide's list before the pane opened: its width and x in the view.
  property var listBox: []
  property bool othersChecked: false
  // Set when step 41's clicks away from the empty add field are done: on
  // the way, the view and the field pass through what gate 42 waits for.
  property bool clickedAway: false
  // The store's wall clock: moved by setting `clock.at`, which (like a real
  // clock) notifies nothing, so only the store's own checks see it.
  property var clock: ({ at: new Date(2026, 10, 18, 12, 0, 0) })
  readonly property string unknownText: "Todoist didn't answer. The task may have been added: check the list before adding it again."
  // switchPanel calls from the popup's view.
  property int switches: 0
  Connections {
    target: one ? one.popup.bodyItem : null
    ignoreUnknownSignals: true
    function onSwitchPanel() { shell.switches++; }
  }
  // Every launch the stand-in openers saw: their argv, the program by its name.
  FileView { id: openLog; path: shell.out + "/opened.log"; blockAllReads: true; printErrors: false }
  function opened() {
    openLog.reload();
    var text = openLog.text();
    return text ? text.split("\n").filter(function(line) { return line !== ""; }).map(function(line) { return line.split("\t"); }) : [];
  }
  property int lateAdd: -1
  property int afterAdd: -1
  // The bar instances; tests unload them to check nothing polls without one.
  property bool panelsAlive: true
  readonly property var one: oneLoader.item
  readonly property var two: twoLoader.item
  // Every add that settled: {request, ok, message}.
  property var settled: []
  readonly property string capText: "Too many changes are waiting. Try again in a moment."
  readonly property string truncatedText: "Showing part of your tasks: the account has more than this panel keeps"
  readonly property string out: Quickshell.env("FOAMY_OUT")
  // A fixed Wednesday: Upcoming's groups depend on the weekday.
  readonly property string today: "2026-11-18"
  // A label as long as Todoist allows (60 characters).
  // One word with no break opportunity (no hyphens): the tooltip must still wrap it.
  readonly property string longLabel: "Alabelnamewithnobreakopportunitylongenoughtooverflowthechip"
  TestEvent { id: ev }
  FoamyWait { id: wait }
  // A fixture file, written and read back. A FileView skips a write of the
  // text it holds, and it may not have read a new path yet, so it reads the
  // file first. Quickshell's atomic write also fails now and then on this
  // host ("Atomic commit failed", about one run in five; the old file
  // stays). A fixture write is safe to repeat: at most three writes, else
  // the run fails.
  FileView { id: writer; blockAllReads: true; blockWrites: true; printErrors: false }
  function writeFile(path, text) {
    writer.path = path;
    for (var attempt = 0; ; attempt++) {
      writer.reload();
      if (writer.text() === text) return true;
      if (attempt === 3) return check(false, "could not write " + path + " (it holds " + JSON.stringify(writer.text()) + ")");
      if (attempt > 0) console.log("FOAMY NOTE write " + attempt + " of " + path + " did not land");
      writer.setText(text);
    }
  }
  function put(name, text) { shell.writeFile(shell.out + "/" + name, text); }
  // The Omarchy language picker's file (the kit's translations follow it).
  function pickLanguage(code) { shell.writeFile(Quickshell.env("OMARCHY_LANGUAGE_FILE"), code + "\n"); }
  // The add error at the top of the list: "" when it shows whole
  // (wrapped, not elided, the list's width but its insets); else what is wrong.
  function addErrorLayout(view, text) {
    var line = shell.find(view, "errorLine");
    var list = shell.find(view, "listArea");
    var off = [];
    if (!line.visible || line.text !== text) off.push("the line reads " + JSON.stringify(line.text) + " (visible " + line.visible + ")");
    if (line.truncated) off.push("elided");
    if (line.width + 1 < list.width - (Kit.FoamyStyle.gapLarge * 2 + Kit.FoamyStyle.rowPadding)) off.push("width " + line.width + " of " + list.width);
    if (line.contentWidth > line.width + 1) off.push("text " + line.contentWidth + " wider than " + line.width);
    if (line.lineCount < 2) off.push("one line (" + line.lineCount + "): not wrapped");
    return off.join("; ");
  }
  FileView { id: callLog; path: shell.out + "/calls.log"; blockAllReads: true; printErrors: false }
  function calls(command) {
    callLog.reload();
    var text = callLog.text();
    var all = text ? text.split("\n").filter(function(line) { return line !== ""; }) : [];
    return command ? all.filter(function(line) { return line.split(" ")[0] === command; }) : all;
  }
  // Held replies of the stand-in helper: hold(command) makes its next
  // calls wait until release(command); held(command) is true once one of
  // them waits (held.log lists each hold as it starts). pass(command) lets
  // the call held now answer and holds the next one: held() turns true
  // again once that one waits.
  property var holdsAt: ({})
  property int tickets: 0
  FileView { id: holdLog; path: shell.out + "/held.log"; blockAllReads: true; printErrors: false }
  function holds(command) {
    holdLog.reload();
    var text = holdLog.text();
    return text ? text.split("\n").filter(function(line) { return line === command; }).length : 0;
  }
  function hold(command) {
    var at = Object.assign({}, shell.holdsAt);
    at[command] = shell.holds(command);
    shell.holdsAt = at;
    shell.put("hold-" + command, "1");
  }
  function held(command) { return shell.holds(command) > shell.holdsAt[command]; }
  function pass(command) {
    var at = Object.assign({}, shell.holdsAt);
    at[command] = shell.holds(command);
    shell.holdsAt = at;
    shell.tickets++;
    shell.put("hold-" + command, "ticket " + shell.tickets);
  }
  function release(command) { shell.put("hold-" + command, ""); }
  // The snapshot with some tasks' fields changed ({id: {field: value}}).
  // The visible items under `item` whose text has Todoist's markup in it.
  function markupTexts(item) {
    var found = [];
    var walk = function(at) {
      if (!at.visible) return;
      if (typeof at.text === "string" && at.textFormat !== undefined && (at.text.indexOf("<b>") >= 0 || at.text.indexOf("<i>") >= 0)) found.push(at);
      for (var child of at.children) walk(child);
    };
    walk(item);
    return found;
  }
  function snapshotWith(changes, drop) {
    var reply = shell.snapshot(drop);
    reply.tasks = reply.tasks.map(function(task) { return changes[task.id] ? Object.assign({}, task, changes[task.id]) : task; });
    return reply;
  }
  // The bar instance that leads (and owns IPC).
  function leader() {
    return one && one.member.isLeader ? one : two;
  }
  // Every text the editor shows (Text items that are visible and not
  // empty; the fields' own text is not a Text item), in tree order.
  function visibleTexts(item) {
    var out = [];
    var walk = function(at) {
      if (!at.visible) return;
      if (typeof at.text === "string" && at.elide !== undefined && at.lineCount !== undefined && at.text !== "" && at.opacity > 0) out.push(at.text);
      for (var child of at.children) walk(child);
    };
    walk(item);
    return out;
  }
  // A property section's value row text (its words), "" when hidden.
  function valueText(editor, name) {
    var row = shell.find(editor, name);
    return row && row.visible ? row.text : "";
  }
  // The popup's card under its bar button: "" when the host placed it
  // there (`width` wide, centred on the button, clamped to the margins, just
  // below the bar); else what is off.
  function popupPlacement(panel, width) {
    var popup = panel.popup;
    var button = popup.anchorItem;
    var origin = popup.cardOrigin;
    var centre = button.mapToItem(popup.anchorWindow.contentItem, 0, 0).x + button.width / 2;
    var x = Math.round(Math.max(popup.margin, Math.min(centre - width / 2, popup.screenW - width - popup.margin)));
    var off = [];
    if (button.objectName !== "todoistButton") off.push("anchored to " + button);
    if (popup.contentWidth !== width || Math.abs(popup.cardItem.width - width) > 1) off.push("width " + popup.contentWidth + "/" + popup.cardItem.width + ", not " + width);
    if (origin.x !== x) off.push("x " + origin.x + ", not " + x);
    if (origin.y !== Math.round(popup.barThickness + popup.gap)) off.push("y " + origin.y + ", not under the bar");
    return off.join("; ");
  }
  function snapshot(drop) {
    var reply = Fixtures.snapshot(shell.today);
    reply.tasks = reply.tasks.concat(Fixtures.upcomingExtras(shell.today));
    // Nobody else's tasks unless a step assigns one (they'd be hidden).
    reply.tasks = reply.tasks.map(function(task) { return Object.assign({}, task, { responsible_uid: null }); });
    reply.ok = true;
    reply.synced_at = new Date().toISOString();
    reply.tasks = reply.tasks.filter(function(task) { return (drop || []).indexOf(task.id) < 0; });
    return reply;
  }
  // The editor's apply requests since `from`, as their update commands.
  function updatesSince(from) {
    return shell.calls("apply").slice(from).map(function(line) { return JSON.parse(line.slice("apply ".length)).commands[0]; });
  }
  // A save reply for t4 with these fields (the helper reads it as it answers).
  function t4Reply(fields) {
    shell.put("reply-apply.json", JSON.stringify(Object.assign(shell.snapshotWith({ t4: fields }), { results: { t4: "ok" } })));
  }
  // Two saves of one field before the first reply (both held, then the
  // first passed while the second waits): each reply is matched to its own
  // request, and each edit builds on the one in flight. Then `done`.
  function racingSaves(view, done) {
    var store = Plugin.TodoStore;
    var editor = view.editor;
    var from = shell.calls("apply").length;
    shell.hold("apply");
    shell.t4Reply({ content: "One", priority: 4, labels: ["code", "calls"] });
    editor.contentField.focusInput();
    editor.contentField.selectAll();
    for (var c1 of "One") ev.keyClickChar(c1, Qt.NoModifier, -1);
    ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
    for (var c2 of " Two") ev.keyClickChar(c2, Qt.NoModifier, -1);
    ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
    if (!check(Object.keys(editor.pending).length === 2, "two saves of the text in flight")) return;
    shell.passFirst("apply", function(ok) {
      // The first reply: Todoist has "One"; the newer text stays, still tracked.
      var left = Object.keys(editor.pending).length;
      if (!check(ok && left === 1 && store.model.byId.t4.content === "One" && editor.contentField.text === "One Two" && editor.newest("content") > 0, "the first reply kept the newer text (" + JSON.stringify([left, editor.contentField.text]) + ")")) return;
      shell.t4Reply({ content: "One Two", priority: 4, labels: ["code", "calls"] });
      shell.release("apply");
      wait.waitFor(function() { return Object.keys(editor.pending).length === 0 && !store.busy; }, 15000, function(ok2) {
        var sent = shell.updatesSince(from).map(function(command) { return command.content; });
        if (!check(ok2 && JSON.stringify(sent) === JSON.stringify(["One", "One Two"]) && editor.contentField.text === "One Two" && editor.errorOf("content") === "" && !editor.dirty("content"), "both replies: the field shows the newest (" + JSON.stringify([sent, editor.contentField.text]) + ")")) return;
        // Leaving the field sends nothing more.
        editor.openField("deadline");
        if (!check(shell.calls("apply").length === from + 2, "the next blur sent nothing")) return;
        // Two labels removed before the first reply: the second keeps the first off.
        var from2 = shell.calls("apply").length;
        shell.hold("apply");
        shell.t4Reply({ content: "One Two", priority: 4, labels: ["calls"] });
        // The chip's × by the pointer: it removes the label, the section's menu stays shut.
        var codeX = shell.find(shell.find(editor, "label-code"), "removeLabel");
        ev.mouseClick(codeX, codeX.width / 2, codeX.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
        if (!check(!editor.menu.opened, "the × didn't open the label menu")) return;
        if (!check(shell.find(editor, "label-code") === null && shell.find(editor, "label-calls") !== null, "the chips show the list in flight")) return;
        shell.find(shell.find(editor, "label-calls"), "removeLabel").clicked();
        shell.passFirst("apply", function(ok3) {
          var left3 = Object.keys(editor.pending).length;
          if (!check(ok3 && left3 === 1 && shell.find(editor, "label-code") === null && shell.find(editor, "label-calls") === null, "the first reply didn't bring a label back (" + left3 + " saves in flight)")) return;
          shell.t4Reply({ content: "One Two", priority: 4, labels: [] });
          shell.release("apply");
          wait.waitFor(function() { return Object.keys(editor.pending).length === 0 && !store.busy; }, 15000, function(ok4) {
            var lists = shell.updatesSince(from2).map(function(command) { return command.labels; });
            if (!check(ok4 && JSON.stringify(lists) === JSON.stringify([["calls"], []]) && store.model.byId.t4.labels.length === 0, "each removal built on the one in flight (" + JSON.stringify(lists) + ")")) return;
            done();
          });
        });
      });
    });
  }
  // The first held call of `command` answers while the next one waits:
  // then(ok) once that next call is held. The store starts it only after
  // it has handled the first reply. ok is false when that took over 15 s.
  function passFirst(command, then) {
    wait.waitFor(function() { return shell.held(command); }, 15000, function(held) {
      if (!check(held, "a " + command + " call is held")) return;
      shell.pass(command);
      wait.waitFor(function() { return shell.held(command); }, 15000, then);
    });
  }
  // A field's baseline comes from what Todoist confirmed and the saves in
  // flight. t4 holds "One Two" before and after. Then `done`.
  function baselineSaves(view, done) {
    var store = Plugin.TodoStore;
    var editor = view.editor;
    var from = shell.calls("apply").length;
    // Only a trailing space added: nothing to send; the field shows the
    // task's text again and follows Todoist (untouched).
    editor.contentField.focusInput();
    editor.contentField.cursorPosition = editor.contentField.text.length;
    ev.keyClickChar(" ", Qt.NoModifier, -1);
    editor.openField("deadline");
    if (!check(shell.calls("apply").length === from && editor.contentField.text === "One Two" && !editor.touched("content"), "a space at the end is no change; the field shows the task (" + JSON.stringify(editor.contentField.text) + ")")) return;
    var t4 = { content: "One Two", priority: 4, labels: [] };
    store.snapshot = shell.snapshotWith({ t4: Object.assign({}, t4, { content: "Renamed elsewhere" }) });
    if (!check(editor.contentField.text === "Renamed elsewhere", "after the no-op save the field follows Todoist (" + JSON.stringify(editor.contentField.text) + ")")) return;
    store.snapshot = shell.snapshotWith({ t4: t4 });
    if (!check(editor.contentField.text === "One Two" && !editor.touched("content"), "and back")) return;
    // Sent B, then C, edited back to B, both refused: B differs from what
    // Todoist holds, so it stays a change and the next blur sends it.
    shell.put("slow-apply", "0.6");
    shell.put("reply-apply.json", JSON.stringify(Object.assign(shell.snapshotWith({ t4: t4 }), { results: { t4: { code: "HTTP", error: "Todoist answered HTTP %1.\u001f500" } } })));
    editor.contentField.focusInput();
    for (var draft of ["Bee", "Cee", "Bee"]) {
      editor.contentField.selectAll();
      for (var c of draft) ev.keyClickChar(c, Qt.NoModifier, -1);
      if (Object.keys(editor.pending).length < 2) ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
    }
    if (!check(Object.keys(editor.pending).length === 2, "two saves in flight, a third draft typed")) return;
    wait.waitFor(function() { return Object.keys(editor.pending).length === 0 && !store.busy; }, 15000, function(ok) {
      if (!check(ok && editor.contentField.text === "Bee" && editor.errorOf("content") !== "" && editor.dirty("content"), "both refused: the draft stays a change (" + JSON.stringify([editor.contentField.text, editor.errorOf("content"), editor.dirty("content")]) + ")")) return;
      shell.put("slow-apply", "");
      shell.t4Reply(Object.assign({}, t4, { content: "Bee" }));
      var from2 = shell.calls("apply").length;
      editor.openField("deadline");
      wait.waitFor(function() { return Object.keys(editor.pending).length === 0 && !store.busy && shell.calls("apply").length === from2 + 1; }, 15000, function(ok2) {
        var sent = shell.updatesSince(from2).map(function(command) { return command.content; });
        if (!check(ok2 && JSON.stringify(sent) === JSON.stringify(["Bee"]) && editor.contentField.text === "Bee" && editor.errorOf("content") === "", "the blur sent the kept draft (" + JSON.stringify([sent, editor.contentField.text]) + ")")) return;
        // Back to "One Two" for the steps after.
        shell.t4Reply(t4);
        editor.contentField.focusInput();
        editor.contentField.selectAll();
        for (var c2 of "One Two") ev.keyClickChar(c2, Qt.NoModifier, -1);
        ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
        wait.waitFor(function() { return Object.keys(editor.pending).length === 0 && !store.busy; }, 15000, function(ok3) {
          if (!check(ok3 && store.model.byId.t4.content === "One Two" && editor.contentField.text === "One Two", "t4 is One Two again")) return;
          done();
        });
      });
    });
  }
  // Typed in the pane, then the task completed without leaving the field
  // (`how`: the editor's ring beside the title, or the row's ring): the
  // typed text is saved first, ahead of the completion in the queue. Then
  // `done`.
  function draftThenComplete(view, how, done) {
    var store = Plugin.TodoStore;
    var editor = view.editor;
    var id = view.paneTask;
    var text = store.model.byId[id].content + " " + how;
    var change = {};
    change[id] = { content: text };
    var results = {};
    results[id] = "ok";
    // One reply for both calls: the task stays (as a recurring one would).
    shell.put("reply-apply.json", JSON.stringify(Object.assign(shell.snapshotWith(change), { results: results })));
    var from = shell.calls("apply").length;
    editor.contentField.focusInput();
    editor.contentField.cursorPosition = editor.contentField.text.length;
    for (var c of " " + how) ev.keyClickChar(c, Qt.NoModifier, -1);
    if (how === "title ring") {
      // The ring takes no keys: the field keeps them, as with the mouse.
      ev.mouseClick(editor.ring, editor.ring.width / 2, editor.ring.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
    } else {
      var ring = shell.find(shell.builtRows(view).find(function(r) { return r.entry.id === id; }), "ring");
      ev.mouseClick(ring, ring.width / 2, ring.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
    }
    var jobs = [store.current].concat(store.queue).filter(function(job) { return !!job; });
    if (!check(store.struck[id] === true && jobs.length === 1 && jobs[0].extra.update === id, how + ": completed, the typed text queued first (" + JSON.stringify(jobs.map(function(job) { return job.extra; })) + ")")) return;
    store.flushCompletions();
    wait.waitFor(function() { return shell.calls("apply").length === from + 2 && !store.busy && !editor.saving; }, 15000, function(ok) {
      var sent = shell.updatesSince(from);
      if (!check(ok && JSON.stringify(sent) === JSON.stringify([{ op: "update", id: id, content: text }, { op: "close", id: id }]), how + ": the text, then the completion (" + JSON.stringify(sent) + ")")) return;
      done();
    });
  }
  // The editor's context menus (Small's page, t7 open): a one-line field
  // that saves and closes when its edit ends, and the description, which
  // saves; back to the list, then done().
  function editorMenus(view, done) {
    view.openTask("t7", true);
    wait.waitFor(function() { var d = Plugin.TodoStore.description; return view.pageShown && view.editor.taskId === "t7" && d.id === "t7" && d.state === "ready" && view.editor.descriptionField.enabled; }, 15000, function(ok) {
      if (!check(ok, "t7 open in the editor, its description read")) return;
      var ed = view.editor;
      shell.contextPaste(ed, [
        { name: "dueField", open: "due" },
        { name: "descriptionField", open: "" }
      ], function() {
        shell.editorRefusedPastes(ed, function() {
          shell.menuLeave(ed, function() {
            view.editor.back();
            done();
          });
        });
      });
    });
  }
  // A paste each of the editor's text fields refuses: why shows under the
  // field, without Retry (nothing was sent). Then done().
  function editorRefusedPastes(ed, done) {
    var fields = [
      { name: "the title", field: ed.contentField, line: "contentError", focus: function() { ed.contentField.focusInput(); } },
      { name: "the description", field: ed.descriptionField, line: "descriptionError", focus: function() { ed.descriptionField.focusInput(); } },
      { name: "the Date field", field: ed.dueField, line: "section-due", focus: function() { ed.openField("due"); } },
      { name: "the Deadline field", field: ed.deadlineField, line: "section-deadline", focus: function() { ed.openField("deadline"); } }
    ];
    var next = function(i) {
      if (i === fields.length) { done(); return; }
      var f = fields[i];
      var part = function(name) { return function() { return shell.find(shell.find(ed, f.line), name); }; };
      f.focus();
      shell.refusedPaste(f.name, f.field, part("fieldErrorText"), part("fieldRetry"), function() { next(i + 1); });
    };
    next(0);
  }
  // In the pane, the description of a task without one refuses a paste;
  // then another task without a description shows (the field's text stays
  // ""): the line under it is clear. Then the pane is back on the first
  // row, and done().
  function pasteStaysWithItsTask(view, done) {
    var store = Plugin.TodoStore;
    var ed = view.editor;
    var part = function(name) { return function() { return shell.find(shell.find(ed, "descriptionError"), name); }; };
    var show = function(i, then) {
      var id = view.rows[view.stops[i]].id;
      shell.put("reply-task.json", JSON.stringify({ ok: true, task: { id: id, description: "", truncated: false } }));
      view.goTo(view.firstRowStop + i);
      wait.waitFor(function() { var d = store.description; return view.paneTask === id && d.id === id && d.state === "ready" && ed.descriptionField.enabled; }, 15000, function(ok) {
        if (!check(ok && ed.descriptionField.text === "", "row " + i + " in the pane, without a description (" + JSON.stringify([view.paneTask, store.description]) + ")")) return;
        then();
      });
    };
    show(2, function() {
      ed.descriptionField.focusInput();
      shell.refusedPaste("the pane's description", ed.descriptionField, part("fieldErrorText"), part("fieldRetry"), function() {
        show(3, function() {
          if (!check(!part("fieldErrorText")().visible, "the refused paste's message stayed with its task (" + part("fieldErrorText")().text + ")")) return;
          view.goTo(view.firstRowStop);
          done();
        });
      });
    });
  }
  // A paste the field (which has the keys) refuses, as the kit refuses a
  // clipboard of more than 16 KiB (the stand-in's "large"): Ctrl+V changes
  // nothing, and line(), the error line that belongs to the field, says
  // why in the panel's words; retry(), when given, is that line's Retry,
  // which a refused paste doesn't offer. Then the clipboard reads "folder"
  // again and done().
  function refusedPaste(name, field, line, retry, done) {
    var clipboard = Quickshell.env("TEST_CLIPBOARD_STATE");
    if (!shell.writeFile(clipboard, "large")) return;
    var before = field.text;
    ev.keyClick(Qt.Key_V, Qt.ControlModifier, -1);
    if (!check(field.pasteRunning, name + ": Ctrl+V started a paste")) return;
    wait.waitFor(function() { return !field.pasteRunning; }, 15000, function(ended) {
      var shown = line();
      var why = Kit.FoamyI18n.t("Clipboard text is too large or contains invalid characters.");
      var offered = retry ? retry().visible : false;
      if (!check(ended && field.text === before && shown.visible && shown.text === why && !offered, name + ": a refused paste changes nothing and its line says why, without Retry (" + JSON.stringify([ended, field.pasteError, field.text === before, shown.visible, shown.text, offered]) + ")")) return;
      if (!shell.writeFile(clipboard, "normal")) return;
      done();
    });
  }
  // A right-click on an editor field opens its context menu: the menu takes
  // the keys, but the field stays open and nothing is saved; the menu's
  // Paste lands in it (the stand-in clipboard reads "folder"); Esc drops it.
  function contextPaste(ed, fields, done) {
    if (!fields.length) { done(); return; }
    var f = fields[0];
    var field = ed[f.name];
    if (f.open) ed.openField(f.open); else field.focusInput();
    field.cursorPosition = field.text.length;
    var before = field.text;
    var calls = shell.calls("apply").length;
    var editor = field.editorItem;
    var menu = editor.Controls.ContextMenu.menu;
    var still = function() { return field.visible && (!f.open || ed.opened === f.open) && Object.keys(ed.pending).length === 0 && shell.calls("apply").length === calls; };
    // The opened field is laid out by the next frame: click what is drawn.
    shell.afterFrame(field, function() {
    ev.mouseClick(editor, editor.width / 2, editor.height / 2, Qt.RightButton, Qt.NoModifier, -1);
    wait.waitFor(function() { return menu.opened; }, 5000, function(ok) {
      if (!check(ok && !field.inputActiveFocus && still(), f.name + ": the context menu has the keys, the field stays open, nothing saved (" + JSON.stringify([ok, field.visible, ed.opened, Object.keys(ed.pending)]) + ")")) return;
      var paste = null;
      for (var i = 0; i < menu.count; i++)
        if (menu.itemAt(i) && menu.itemAt(i).text === "Paste") paste = menu.itemAt(i);
      if (!check(paste && paste.enabled, f.name + ": the menu has Paste")) return;
      ev.mouseClick(paste, paste.width / 2, paste.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      wait.waitFor(function() { return !menu.visible && !field.pasteRunning && field.text !== before; }, 10000, function(pasted) {
        if (!check(pasted && field.text === before + "folder" && field.inputActiveFocus && still(), f.name + ": the menu's Paste landed in the open field, nothing saved (" + JSON.stringify([field.text, field.pasteError, ed.opened, Object.keys(ed.pending)]) + ")")) return;
        ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
        if (!check(field.text === before && shell.calls("apply").length === calls && (!f.open || ed.opened === ""), f.name + ": Esc dropped the paste, nothing sent (" + JSON.stringify([field.text, ed.opened]) + ")")) return;
        shell.contextPaste(ed, fields.slice(1), done);
      });
    });
    });
  }
  // Calls `then` once the first bar's popup is hidden, so that the next
  // open() opens it again instead of finding it still on its way out.
  function afterClose(then) {
    wait.waitFor(function() { return !one.popup.visible; }, 5000, function(ok) { if (check(ok, "the popup closed")) then(); });
  }
  // The rail's counts in the plain tone (not the urgent one): how many,
  // how many on the selected row, and those under 4.5:1 on their row's
  // fill ([name, ratio]).
  function railCounts(view) {
    var counts = shell.findAll(shell.find(view, "rail"), "railCount").filter(function(count) { return count.visible && count.text !== "" && !count.parent.parent.modelData.urgent; });
    var P = Kit.FoamyPalette;
    return {
      counts: counts.length,
      selected: counts.filter(function(count) { return count.parent.parent.selected; }).length,
      low: counts.map(function(count) {
        var surface = count.parent.parent.selected ? Qt.tint(P.background, P.selectedFill) : P.background;
        return [count.parent.parent.modelData.text, P.contrastRatio(count.color, surface)];
      }).filter(function(pair) { return pair[1] < 4.5; })
    };
  }
  // An item's tooltip (a popup: in its data, not its children).
  function tipOf(item, name) {
    for (var i = 0; i < item.data.length; i++)
      if (item.data[i].objectName === name) return item.data[i];
    return null;
  }
  // Two colours that show the same (computed tints differ below 8 bits,
  // which Qt.colorEqual tells apart).
  function sameColor(a, b) { return String(a) === String(b); }
  // The contrast of a check mark on its ring's fill (the ring's colour
  // over the popup's background).
  function checkContrast(ringMark, mark) {
    var P = Kit.FoamyPalette;
    return P.contrastRatio(mark.color, Qt.tint(P.background, ringMark.color));
  }
  // A ring's look: "" when its border is `width` px and its fill `fill`
  // (alpha); else what it is.
  function ringIs(ringMark, width, fill) {
    return Math.abs(ringMark.border.width - width) < 0.01 && Math.abs(ringMark.color.a - fill) < 0.01 ? "" : "border " + ringMark.border.width + ", fill " + ringMark.color.a.toFixed(2);
  }
  // A list row's ring tells the priority apart by more than its hue: p1 2 px
  // filled .40, p2 and p3 1.5 px .12, p4 1 px empty. Completed, the ring is
  // filled with its colour and each check reads on it (4.5:1). "" or what
  // is off.
  function ringLooks() {
    var looks = [[4, "error", 2, 0.4], [3, "warning", 1.5, 0.12], [2, "accent", 1.5, 0.12], [1, "muted", 1, 0]];
    var off = [];
    for (var look of looks) {
      probeRow.entry = shell.probeEntry({ priority: look[0], priorityRole: look[1] });
      var ring = shell.find(probeRow, "ringMark");
      var at = shell.ringIs(ring, look[2], look[3]);
      if (at !== "") off.push("p" + (5 - look[0]) + ": " + at);
      probeRow.entry = shell.probeEntry({ priority: look[0], priorityRole: look[1], struck: true });
      var mark = shell.find(probeRow, "ringCheck");
      var done = shell.find(probeRow, "ringMark");
      var ratio = shell.checkContrast(done, mark);
      if (!mark.visible || ratio < 4.5) off.push("p" + (5 - look[0]) + " completed: the check " + (mark.visible ? ratio.toFixed(2) + ":1" : "hidden"));
      if (done.color.a < 0.995 || !shell.sameColor(Qt.rgba(done.color.r, done.color.g, done.color.b, 1), done.border.color)) off.push("p" + (5 - look[0]) + " completed: the fill " + done.color + ", the ring " + done.border.color);
    }
    probeRow.entry = shell.probeEntry({});
    return off.join("; ");
  }
  // A heading too long for its row ends with "…" beside its count, its
  // whole text on hover; a short one shows whole, no tooltip. Today's
  // Overdue heading's Move to today names its key on hover. Then done().
  function headingLooks(view, done) {
    var long = "A section with a name much too long to fit beside its count in this row";
    probeRow.entry = { kind: "header", key: "header:long", title: long, count: 12, projectRole: "accent" };
    var title = shell.find(probeRow, "headerTitle");
    var count = shell.find(probeRow, "headerCountInline");
    var tip = shell.tipOf(title, "headerTitleTip");
    // The Row lays its parts out by the next frame.
    shell.afterFrame(probeRow, function() {
    var countEnd = count.mapToItem(probeRow, 0, 0).x + count.width;
    if (!check(title.truncated && title.text === long && count.visible && count.text === "12" && count.mapToItem(probeRow, 0, 0).x >= title.mapToItem(probeRow, 0, 0).x + title.width && countEnd <= probeRow.width - probeRow.contentInset + 0.5, "a long heading elides before its count (" + JSON.stringify([title.truncated, title.width, count.x, countEnd, probeRow.width]) + ")")) return;
    // The count reads (4.5:1 on the list).
    var ratio = Kit.FoamyPalette.contrastRatio(count.color, Kit.FoamyPalette.background);
    if (!check(ratio >= 4.5, "a heading's count reads: " + ratio.toFixed(2) + ":1")) return;
    ev.mouseMove(title, title.width / 2, title.height / 2, -1, Qt.NoButton, Qt.NoModifier);
    wait.waitFor(function() { return tip.visible; }, 5000, function(shown) {
      if (!check(shown && tip.text === long, "hover on the cut heading shows it whole (" + tip.text + ")")) return;
      ev.mouseMove(frameProbe, 1, 1, -1, Qt.NoButton, Qt.NoModifier);
      probeRow.entry = { kind: "header", key: "header:short", title: "Review", count: 2, projectRole: "accent" };
      ev.mouseMove(title, title.width / 2, title.height / 2, -1, Qt.NoButton, Qt.NoModifier);
      if (!check(!title.truncated && title.width === title.implicitWidth && !tip.visible, "a short heading shows whole, no tooltip (" + JSON.stringify([title.truncated, title.width, title.implicitWidth, tip.visible]) + ")")) return;
      ev.mouseMove(frameProbe, 1, 1, -1, Qt.NoButton, Qt.NoModifier);
      // A heading that just fits beside its mark and its count (as laid
      // out) shows whole.
      var line = title.parent;
      var headerMark = shell.find(probeRow, "headerMark");
      var fits = "Planning the next quarter with the whole team and everyone else involved in it";
      var n = fits.length;
      var room = function() { return line.width - headerMark.width - count.width - 2 * line.spacing - 1; };
      for (; n > 1; n--) {
        probeRow.entry = { kind: "header", key: "header:fit", title: fits.slice(0, n), count: 12, projectRole: "accent" };
        if (title.implicitWidth <= room()) break;
      }
      shell.afterFrame(probeRow, function() {
      if (!check(headerMark.visible && title.implicitWidth > room() - 2 * headerMark.width && !title.truncated && title.width === title.implicitWidth, "a heading that fits shows whole (" + JSON.stringify([title.text, title.truncated, title.width, title.implicitWidth, room()]) + ")")) return;
      // A 200-character name: its tooltip wraps within the row, with
      // spaces and without.
      var tipFits = function(name, then) {
        probeRow.entry = { kind: "header", key: "header:" + name.length + name.charAt(1), title: name, count: 3, projectRole: "accent" };
        ev.mouseMove(title, title.width / 2, title.height / 2, -1, Qt.NoButton, Qt.NoModifier);
        wait.waitFor(function() { return tip.visible && tip.contentItem && tip.width > 0; }, 5000, function(shown) {
          var text = tip.contentItem;
          var off = !shown ? "no tooltip" : tip.text !== name ? "its text " + tip.text : tip.width > probeRow.width + 0.5 ? tip.width + " wide" : text.contentWidth > text.width - text.leftPadding - text.rightPadding + 0.5 ? "its text " + text.contentWidth + " wide in " + text.width : text.lineCount < 2 ? "one line" : "";
          ev.mouseMove(frameProbe, 1, 1, -1, Qt.NoButton, Qt.NoModifier);
          if (!check(off === "", "a " + name.length + "-character heading's tooltip fits the " + probeRow.width + " px row (" + off + ")")) return;
          then();
        });
      };
      var words = Array(41).join("Name ").slice(0, 200);
      tipFits(words, function() {
      tipFits(Array(201).join("x"), function() {
      probeRow.entry = shell.probeEntry({});
      var overdue = view.list.contentItem.children.find(function(r) { return r.hasOwnProperty("entry") && r.visible && r.entry && r.entry.kind === "header" && r.entry.moveAll === true; });
      if (!check(!!overdue, "Today shows the Overdue heading")) return;
      var move = shell.find(overdue, "moveAllToToday");
      var moveTip = shell.tipOf(move, "moveAllTip");
      if (!check(move.visible && !moveTip.visible, "Move to today shows, no tooltip yet")) return;
      // It names Shift+T only where the key would act: the cursor on a
      // task under Overdue.
      var overdueTask = view.rows.find(function(r) { return r.kind === "task" && view.overdueRow(r); });
      var todayTask = view.rows.find(function(r) { return r.kind === "task" && !view.overdueRow(r); });
      if (!check(!!overdueTask && !!todayTask, "Today has an overdue task and one for today")) return;
      view.cursor.index = -1;
      ev.mouseMove(move, move.width / 2, move.height / 2, -1, Qt.NoButton, Qt.NoModifier);
      wait.waitFor(function() { return moveTip.visible; }, 5000, function(hovered) {
        if (!check(hovered && moveTip.text === "Move to today", "no cursor: Move to today names no key (" + moveTip.text + ")")) return;
        view.cursor.index = view.stopOf(todayTask.id);
        if (!check(view.cursor.index >= 0 && moveTip.text === "Move to today", "the cursor on a task for today: no key (" + moveTip.text + ")")) return;
        view.cursor.index = view.stopOf(overdueTask.id);
        if (!check(view.cursor.index >= 0 && moveTip.text === "Move to today (T)", "the cursor on an overdue task: Move to today names its key (" + moveTip.text + ")")) return;
        view.cursor.index = -1;
        ev.mouseMove(view.band, 10, 10, -1, Qt.NoButton, Qt.NoModifier);
        done();
      });
      });
      });
      });
    });
    });
  }
  property bool headingsChecked: false
  // The pane's task completed from the pane's ring: the ring has the
  // completed look (its check reads on the fill), the title is struck in
  // the muted tone, and the header says Completed with Undo, as the row
  // shows it. The header's Undo, the ring again, and Undo with the keys
  // bring it back in the pane and the row. The card keeps its height
  // throughout, and nothing is sent. Then done().
  function paneCompleted(view, done) {
    var store = Plugin.TodoStore;
    var ed = view.editor;
    var id = view.paneTask;
    var card = one.popup.cardItem;
    var height = card.height;
    var apply = shell.calls("apply").length;
    var ring = shell.find(ed.ring, "editRingMark");
    var mark = shell.find(ed.ring, "editRingCheck");
    var header = shell.find(ed, "paneHeader");
    var undo = shell.find(header, "paneUndo");
    var said = shell.find(header, "paneCompleted");
    var row = function() { return shell.builtRows(view).find(function(r) { return r.entry.id === id; }); };
    var titleColor = function() { return ed.titleRendered ? shell.find(ed, "editTitleText").color : ed.contentField.color; };
    // "" when the pane and the row show the task completed (done) or not.
    var looks = function(completed) {
      var off = [];
      var r = row();
      if (Model.has(store.struck, id) !== completed) off.push("struck " + !completed);
      if (completed && (!mark.visible || ring.color.a < 0.995 || shell.checkContrast(ring, mark) < 4.5)) off.push("the ring (" + [mark.visible, ring.color.a.toFixed(2), shell.checkContrast(ring, mark).toFixed(2)] + ")");
      if (!completed && ring.color.a > 0.995) off.push("the ring still filled");
      if (ed.contentField.font.strikeout !== completed || shell.sameColor(titleColor(), Kit.FoamyPalette.mutedText) !== completed) off.push("the title (strikeout " + ed.contentField.font.strikeout + ", " + titleColor() + ")");
      if (said.visible !== completed || undo.visible !== completed || (completed && (said.text !== "Completed" || undo.label !== "Undo"))) off.push("the header (" + [said.visible, said.text, undo.visible] + ")");
      if (!r || shell.find(r, "undo").visible !== completed || shell.find(r, "taskText").font.strikeout !== completed) off.push("the row");
      if (Math.abs(card.height - height) > 0.5) off.push("the card " + card.height + " high, was " + height);
      return off.join(", ");
    };
    if (!check(looks(false) === "", "the pane's task before: " + looks(false))) return;
    var clickRing = function() { ev.mouseClick(ed.ring, ed.ring.width / 2, ed.ring.height / 2, Qt.LeftButton, Qt.NoModifier, -1); };
    clickRing();
    shell.afterFrame(card, function() {
      if (!check(looks(true) === "", "completed from the pane's ring: " + looks(true))) return;
      ev.mouseClick(undo, undo.width / 2, undo.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      shell.afterFrame(card, function() {
        if (!check(looks(false) === "", "the header's Undo: back in the pane and the row: " + looks(false))) return;
        clickRing();
        if (!check(looks(true) === "", "completed again: " + looks(true))) return;
        clickRing();
        shell.afterFrame(card, function() {
          if (!check(looks(false) === "", "the ring again undoes: " + looks(false))) return;
          // With the keys: Tab reaches the header's Undo; Space on it
          // undoes, and Undo hides: the ring has the keys then.
          clickRing();
          if (!check(undo.activeFocusOnTab, "the header's Undo takes the keys")) return;
          undo.forceActiveFocus();
          ev.keyClick(Qt.Key_Space, Qt.NoModifier, -1);
          shell.afterFrame(card, function() {
            if (!check(looks(false) === "", "Space on Undo: back: " + looks(false))) return;
            if (!check(ed.ring.activeFocus, "Undo used with the keys: the ring has them (" + (one.popup.cardItem.Window.window ? one.popup.cardItem.Window.window.activeFocusItem : "") + ")")) return;
            if (!check(shell.calls("apply").length === apply && !store.pending, "nothing was sent")) return;
            shell.paneSent(view, function() {
              view.focusList();
              done();
            });
          });
        });
      });
    });
  }
  // The pane's task once its completion was sent (the apply call held, the
  // Undo time over): still completed, no Undo, the ring inert. The call
  // fails as a whole: unconfirmed, a plain inert ring and "Checking with
  // Todoist…" where "Completed" stood. The card keeps its height. The sync
  // after it (held, then the snapshot as it stands) brings the task back
  // open. Then done().
  function paneSent(view, done) {
    var store = Plugin.TodoStore;
    var ed = view.editor;
    var id = view.paneTask;
    var card = one.popup.cardItem;
    var height = card.height;
    var ring = shell.find(ed.ring, "editRingMark");
    var mark = shell.find(ed.ring, "editRingCheck");
    var header = shell.find(ed, "paneHeader");
    var undo = shell.find(header, "paneUndo");
    var said = shell.find(header, "paneCompleted");
    var clickRing = function() { ev.mouseClick(ed.ring, ed.ring.width / 2, ed.ring.height / 2, Qt.LeftButton, Qt.NoModifier, -1); };
    // "" when the pane shows the task sent ("sending") or unconfirmed.
    var looks = function(state) {
      var off = [];
      var sent = state === "sending";
      if (sent && (!mark.visible || ring.color.a < 0.995 || shell.checkContrast(ring, mark) < 4.5)) off.push("the ring (" + [mark.visible, ring.color.a.toFixed(2), shell.checkContrast(ring, mark).toFixed(2)] + ")");
      if (!sent && (mark.visible || shell.ringIs(ring, 1, 0) !== "")) off.push("the ring (check " + mark.visible + ", " + shell.ringIs(ring, 1, 0) + ")");
      if (ed.contentField.font.strikeout !== sent) off.push("the title (strikeout " + ed.contentField.font.strikeout + ")");
      var says = sent ? "Completed" : "Checking with Todoist…";
      if (!said.visible || said.text !== says || undo.visible) off.push("the header (" + [said.visible, said.text, undo.visible] + ")");
      if (Math.abs(card.height - height) > 0.5) off.push("the card " + card.height + " high, was " + height);
      return off.join(", ");
    };
    shell.put("reply-apply.json", JSON.stringify({ ok: false, code: "NETWORK", error: "Can't reach Todoist. Check your connection." }));
    shell.put("reply-sync.json", JSON.stringify(store.snapshot));
    shell.hold("apply");
    shell.hold("sync");
    clickRing();
    // The Undo time ends.
    store.flushCompletions();
    wait.waitFor(function() { return shell.held("apply"); }, 15000, function(ok) {
      if (!check(ok && Model.has(store.sending, id) && view.paneShown, "the completion is on its way, the pane shows the task")) return;
      shell.afterFrame(card, function() {
        if (!check(looks("sending") === "", "sent: the pane shows it completed: " + looks("sending"))) return;
        clickRing();
        if (!check(!Model.has(store.struck, id) && Model.has(store.sending, id) && view.paneShown, "a click on the sent task's ring does nothing")) return;
        shell.release("apply");
        wait.waitFor(function() { return Model.has(store.unconfirmed, id) && shell.held("sync"); }, 15000, function(ok2) {
          if (!check(ok2 && view.paneShown, "the apply failed: unconfirmed, the sync after it held")) return;
          shell.afterFrame(card, function() {
            if (!check(looks("unconfirmed") === "", "unconfirmed: " + looks("unconfirmed"))) return;
            clickRing();
            if (!check(!Model.has(store.struck, id) && store.queue.length === 0, "a click on the unconfirmed task's ring does nothing")) return;
            shell.release("sync");
            wait.waitFor(function() { return !store.busy && !Model.has(store.unconfirmed, id); }, 15000, function(ok3) {
              if (!check(ok3 && view.paneShown && ed.completion === "" && !said.visible, "the sync: open again in the pane")) return;
              store.error = "";
              done();
            });
          });
        });
      });
    });
  }
  // The bar buttons, both monitors'.
  function barButtons() {
    return [one, two].map(function(panel) { return panel.children.find(function(item) { return item.objectName === "todoistButton"; }); });
  }
  readonly property string unseenText: "Todoist: your last task may not have been added. Open the panel to see why."
  // "" when no bar button shows the unseen add (its mark or its tooltip);
  // else which do.
  function unseenShown() {
    var buttons = shell.barButtons();
    return [one, two].map(function(panel, i) {
      return panel.barContent.addMark.visible || buttons[i].tooltipText === shell.unseenText ? "bar " + (i + 1) + " (" + buttons[i].tooltipText + ")" : "";
    }).filter(function(text) { return text !== ""; }).join(", ");
  }
  // The add mark lies on the button, which kept `widths`: "" or what is off.
  function markPlacement(widths) {
    var buttons = shell.barButtons();
    return [one, two].map(function(panel, i) {
      var mark = panel.barContent.addMark;
      var at = mark.mapToItem(buttons[i], 0, 0);
      var off = [];
      if (!mark.visible) off.push("no mark");
      if (buttons[i].tooltipText !== shell.unseenText) off.push("tooltip " + JSON.stringify(buttons[i].tooltipText));
      if (Math.abs(buttons[i].width - widths[i]) > 0.5) off.push("width " + buttons[i].width + ", was " + widths[i]);
      if (at.x < 0 || at.y < 0 || at.x + mark.width > buttons[i].width + 0.5 || at.y + mark.height > buttons[i].height + 0.5) off.push("the mark at " + at.x + "," + at.y + " off the " + buttons[i].width + "x" + buttons[i].height + " button");
      return off.length ? "bar " + (i + 1) + ": " + off.join(", ") : "";
    }).filter(function(text) { return text !== ""; }).join("; ");
  }
  // A failed add after "Close the panel" (the default): the draft and why
  // wait in the closed popup, and every bar button says so (a mark on the
  // icon, the tooltip), in a horizontal and a vertical bar, at the width
  // it had. The mark goes only once a view shows the field with why: not
  // on Settings (a right-click), and a failure that comes while a popup
  // shows Settings marks the bars too. The other monitor's popup opens
  // with the draft and why. Then the first popup is open again, its field
  // open, and done().
  function unseenAdd(view, done) {
    var store = Plugin.TodoStore;
    var widths = shell.barButtons().map(function(button) { return button.width; });
    var other = null;
    var reason = "Todoist answered HTTP 400.";
    // The parts in order, last first: each ends by starting the next.
    var dropped = function() {
      // Esc drops the draft and why; closed, nothing comes back.
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      two.close();
      wait.waitFor(function() { return !two.popup.visible; }, 5000, function(ok) {
        if (!check(ok && store.addDraft === "" && store.addError === "" && shell.unseenShown() === "", "dropped: no draft, no mark (" + shell.unseenShown() + ")")) return;
        one.open();
        wait.waitFor(function() { return one.opened && view.active; }, 10000, function(ok2) {
          if (!check(ok2, "the first popup again")) return;
          // A reason nobody has seen (its draft set aside by a search) is
          // not dropped by the search's typing, by Esc on the query or by
          // a view change; and the mark never outlives its reason.
          view.startSearch();
          view.searchDraft = "Kept";
          store.addDraft = "Kept";
          store.addError = reason;
          store.addUnseen = true;
          ev.keyClickChar("q", Qt.NoModifier, -1);
          if (!check(view.searching && store.addError === reason && store.addUnseen, "typing in search keeps an unseen reason (" + JSON.stringify([store.addError, store.addUnseen]) + ")")) return;
          ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
          if (!check(view.searching && view.field.text === "" && store.addError === reason && store.addUnseen, "Esc on the query keeps it too (" + JSON.stringify([store.addError, store.addUnseen]) + ")")) return;
          view.setView("inbox");
          if (!check(store.addError === reason, "a view change keeps an unseen reason (" + JSON.stringify(store.addError) + ")")) return;
          store.addError = "";
          if (!check(!store.addUnseen, "no reason left: no mark")) return;
          store.addDraft = "";
          view.setView("today");
          // The draft the view change brought back to the field goes too.
          view.field.text = "";
          view.fieldOpen = false;
          view.focusList();
          // No draft set aside (a search from an empty field): the search's
          // typing ends an earlier add's reason, as typing always did.
          view.startSearch();
          store.addError = reason;
          store.addUnseen = true;
          ev.keyClickChar("q", Qt.NoModifier, -1);
          if (!check(view.searching && view.searchDraft === "" && store.addError === "" && !store.addUnseen, "a search with no draft set aside: typing ends the reason and the mark (" + JSON.stringify([store.addError, store.addUnseen]) + ")")) return;
          view.leaveSearch();
          view.openAdd();
          done();
        });
      });
    };
    var refusedOnSettings = function() {
      // Refused while that popup shows Settings, then closed from there:
      // never seen, so the bars say so until it opens on the list.
      ev.keyClick(Qt.Key_Return, Qt.ShiftModifier, -1);
      other.settingsRequested();
      wait.waitFor(function() { return !store.addPending && !store.busy; }, 15000, function(ok) {
        if (!check(ok && other.editingSettings && store.addError === reason && shell.markPlacement(widths) === "", "refused while Settings shows: the mark (" + shell.markPlacement(widths) + ")")) return;
        two.close();
        wait.waitFor(function() { return !two.popup.visible; }, 5000, function(ok2) {
          if (!check(ok2 && store.addDraft === "Water plants" && shell.markPlacement(widths) === "", "closed from Settings: the mark stays (" + JSON.stringify([store.addDraft, store.addError]) + "; " + shell.markPlacement(widths) + ")")) return;
          two.open();
          wait.waitFor(function() { return two.opened && other.active && other.fieldFocused && shell.find(other, "errorLine").visible; }, 10000, function(ok3) {
            if (!check(ok3 && shell.unseenShown() === "", "opened on the list with the draft and why: the mark goes (" + shell.unseenShown() + ")")) return;
            dropped();
          });
        });
      });
    };
    var otherMonitor = function() {
      two.open();
      wait.waitFor(function() { var v = two.popup.bodyItem; return two.opened && v && v.active && v.fieldFocused; }, 10000, function(ok) {
        other = two.popup.bodyItem;
        var line = other ? shell.find(other, "errorLine") : null;
        if (!check(ok && other.field.text === "Water plants" && line.visible && line.text === reason, "the other monitor's popup shows the draft and why (" + JSON.stringify([other && other.field.text, line && line.text]) + ")")) return;
        if (!check(shell.unseenShown() === "", "shown: the mark and the tooltip text are gone: " + shell.unseenShown())) return;
        // Sent again from there, the field kept open: refused again,
        // seen in the open popup, so no bar shows it.
        ev.keyClick(Qt.Key_Return, Qt.ShiftModifier, -1);
        wait.waitFor(function() { return !store.addPending && !store.busy && two.opened; }, 15000, function(ok2) {
          if (!check(ok2 && store.addError === reason && store.addDraft !== "" && shell.unseenShown() === "", "refused with the popup open: no mark (" + JSON.stringify([store.addError, store.addDraft]) + "; " + shell.unseenShown() + ")")) return;
          refusedOnSettings();
        });
      });
    };
    var rightClick = function() {
      // A right-click opens the popup on Settings: the draft and why are
      // out of sight, so the mark stays; back to the list (the field with
      // why), it goes.
      var first = shell.barButtons()[0];
      ev.mouseClick(first, first.width / 2, first.height / 2, Qt.RightButton, Qt.NoModifier, -1);
      wait.waitFor(function() { return one.opened && view.active && view.editingSettings; }, 10000, function(ok) {
        if (!check(ok, "a right-click opened Settings")) return;
        // The draft's field opens a call later (prepare).
        shell.afterFrame(frameProbe, function() {
          if (!check(view.fieldOpen && shell.markPlacement(widths) === "", "on Settings the mark stays: " + shell.markPlacement(widths))) return;
          view.settingsClosed();
          wait.waitFor(function() { return !view.editingSettings && shell.find(view, "errorLine").visible; }, 10000, function(ok2) {
            if (!check(ok2 && view.field.text === "Water plants" && shell.unseenShown() === "", "back to the list, the draft and why shown: the mark goes (" + shell.unseenShown() + ")")) return;
            one.close();
            wait.waitFor(function() { return !one.popup.visible; }, 5000, function(ok3) {
              if (!check(ok3 && store.addDraft === "Water plants" && store.addError === reason && shell.unseenShown() === "", "closed again: seen, no mark (" + shell.unseenShown() + ")")) return;
              otherMonitor();
            });
          });
        });
      });
    };
    shell.put("slow-add", "");
    shell.put("reply-add.json", JSON.stringify({ ok: false, code: "HTTP", error: "Todoist answered HTTP %1.\u001f400" }));
    view.openAdd();
    wait.waitFor(function() { return view.fieldFocused; }, 10000, function(ok) {
      if (!check(ok, "the field for an add that fails after closing")) return;
      for (var c of "Water plants") ev.keyClickChar(c, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
      if (!check(!one.opened && store.addPending, "Enter sent it and closed the panel")) return;
      wait.waitFor(function() { return !store.addPending && !store.busy; }, 15000, function(ok2) {
        if (!check(ok2 && store.addDraft === "Water plants" && store.addError === reason, "refused: the draft and why wait (" + JSON.stringify([store.addDraft, store.addError]) + ")")) return;
        var off = shell.markPlacement(widths);
        if (!check(off === "", "a horizontal bar shows the unseen add: " + off)) return;
        bar.position = "left";
        shell.afterFrame(frameProbe, function() {
          var upright = shell.barButtons().map(function(button) { return button.width; });
          var offUpright = shell.markPlacement(upright);
          bar.position = "top";
          if (!check(offUpright === "", "a vertical bar shows it too: " + offUpright)) return;
          shell.afterFrame(frameProbe, function() {
            if (!check(shell.markPlacement(widths) === "", "the horizontal bar again: " + shell.markPlacement(widths))) return;
            rightClick();
          });
        });
      });
    });
  }
  property bool unseenChecked: false
  // Calls `then` once `item`'s window has drawn a frame (layouts done).
  function afterFrame(item, then) {
    var window = item.Window.window;
    var fired = false;
    var fire = function() {
      if (fired) return;
      fired = true;
      window.frameSwapped.disconnect(fire);
      then();
    };
    window.frameSwapped.connect(fire);
    window.update();
  }
  // From the Date field's menu, a press on the title: the edit ends there
  // (the untouched field closes, nothing to send), the title has the keys.
  function menuLeave(ed, done) {
    ed.openField("due");
    var editor = ed.dueField.editorItem;
    var menu = editor.Controls.ContextMenu.menu;
    var calls = shell.calls("apply").length;
    shell.afterFrame(ed.dueField, function() {
    ev.mouseClick(editor, editor.width / 2, editor.height / 2, Qt.RightButton, Qt.NoModifier, -1);
    wait.waitFor(function() { return menu.opened; }, 5000, function(ok) {
      if (!check(ok && ed.opened === "due", "the Date field's menu is open")) return;
      var title = ed.contentField.editorItem;
      var menuLeft = menu.contentItem.mapToItem(title, 0, 0).x;
      ev.mouseClick(title, menuLeft > 12 ? 6 : title.width - 6, title.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      wait.waitFor(function() { return !menu.visible && ed.opened === ""; }, 5000, function(left) {
        if (!check(left && ed.contentField.inputActiveFocus && shell.calls("apply").length === calls, "a press on the title from the menu closed the Date field (" + JSON.stringify([menu.visible, ed.opened]) + ")")) return;
        done();
      });
    });
    });
  }
  // Every choice on the settings page while the widget has no bar entry,
  // so the settings queue refuses each pick: a click opens the list, ↓ (↑
  // from the last option) and Enter pick another option. The choice shows
  // the saved value again at once, beside the error, and nothing is saved.
  // The Open command first: a click in the field, a command typed, Enter;
  // the field shows the saved command again by the next frame. Then the
  // bar entry is back, the error goes, and done().
  function refusedPicks(view, done) {
    var page = view.settingsPage;
    var keys = ["panelWidth", "afterAdd", "openOn", "othersTasks", "barCount", "refreshSeconds"];
    var noEntry = "Settings can't be saved: this widget has no bar entry.";
    var saves = bar.saved.length;
    one.moduleName = "";
    var next = function(i) {
      if (i === keys.length) {
        one.moduleName = "foamy.todoist";
        // The saved value again: nothing to write, and the error goes.
        one.prefs.save("afterAdd", one.prefs.value("afterAdd"));
        if (!check(view.settingsError === "" && bar.saved.length === saves, "the bar entry back: no error, nothing saved (" + view.settingsError + ")")) return;
        done();
        return;
      }
      var dropdown = shell.find(page, keys[i]);
      var saved = dropdown.value;
      var values = dropdown.options.map(function(option) { return dropdown.optionValue(option); });
      var at = values.indexOf(saved);
      var down = at + 1 < values.length;
      var picked = values[down ? at + 1 : at - 1];
      var trigger = dropdown.triggerItem;
      ev.mouseClick(trigger, trigger.width / 2, trigger.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      wait.waitFor(function() { return dropdown.popupOpen; }, 5000, function(opened) {
        if (!check(opened && at >= 0, keys[i] + ": a click opened the list on the saved value " + saved)) return;
        ev.keyClick(down ? Qt.Key_Down : Qt.Key_Up, Qt.NoModifier, -1);
        ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
        if (!check(dropdown.shownValue === saved && dropdown.currentLabel() === dropdown.optionLabel(dropdown.options[at]) && view.settingsError === noEntry && bar.saved.length === saves, keys[i] + ": a refused pick of " + picked + " shows the saved value again at once (" + JSON.stringify([dropdown.shownValue, dropdown.currentLabel(), view.settingsError, bar.saved.length - saves]) + ")")) return;
        wait.waitFor(function() { return !dropdown.popupOpen; }, 5000, function(closed) {
          if (!check(closed, keys[i] + ": the list closed")) return;
          shell.afterFrame(page, function() { next(i + 1); });
        });
      });
    };
    var command = shell.find(page, "openCommand");
    var editor = command.field.editorItem;
    var savedCommand = command.value;
    // The page is laid out by the next frame: click what is drawn. It gives
    // Back the keys in a deferred call (focusBack), which under load can
    // come after a click made sooner and take the keys from the field.
    wait.waitFor(function() { return page.backTarget.activeFocus; }, 5000, function(opened) {
    if (!check(opened, "the settings page gave Back the keys")) return;
    shell.afterFrame(page, function() {
      ev.mouseClick(editor, editor.width / 2, editor.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      wait.waitFor(function() { return command.field.inputActiveFocus; }, 5000, function(focused) {
        if (!check(focused, "a click put the keys in the Open command field (" + JSON.stringify([one.popup.drawnHeight, one.popup.contentHeight, editor.mapToItem(null, 0, 0).y, editor.height, String(editor.Window.activeFocusItem)]) + ")")) return;
        for (var c of "todoist-open {url}") ev.keyClickChar(c, Qt.NoModifier, -1);
        ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
        // What the next drawn frame shows.
        shell.afterFrame(page, function() {
          if (!check(command.field.text === savedCommand && !command.editing && view.settingsError === noEntry && bar.saved.length === saves, "a refused Open command shows the saved command " + JSON.stringify(savedCommand) + " again at once (" + JSON.stringify([command.field.text, command.editing, view.settingsError, bar.saved.length - saves]) + ")")) return;
          next(0);
        });
      });
    });
    });
  }
  // A right-click on the empty add field opens its menu, which takes the
  // keys. That isn't the end of the edit: the field stays open, the menu's
  // Paste lands in it (the stand-in clipboard reads "folder"), and Esc
  // clears it with the keys still in the field. The menu again, and a
  // click on the Inbox tab beside it: the menu and the empty field close,
  // the view switches, + doesn't get the cursor. Then the field opens
  // again, with the keys, and done().
  function emptyFieldMenu(view, done) {
    var field = view.field;
    var editor = field.editorItem;
    var menu = editor.Controls.ContextMenu.menu;
    var adds = shell.calls("add").length;
    // Grown all the way, so the click lands on the drawn field.
    wait.waitFor(function() { return view.band.fieldProgress === 1; }, 5000, function(grown) {
      if (!check(grown && view.adding && field.text === "", "the empty add field is open")) return;
      shell.afterFrame(field, function() {
        ev.mouseClick(editor, editor.width / 2, editor.height / 2, Qt.RightButton, Qt.NoModifier, -1);
        wait.waitFor(function() { return menu.opened; }, 5000, function(opened) {
          if (!check(opened && !field.inputActiveFocus && view.adding && field.visible, "the empty add field stays open while its menu has the keys (" + JSON.stringify([opened, field.inputActiveFocus, view.fieldOpen]) + ")")) return;
          var paste = null;
          for (var i = 0; i < menu.count; i++)
            if (menu.itemAt(i) && menu.itemAt(i).text === "Paste") paste = menu.itemAt(i);
          if (!check(paste && paste.enabled, "the add field's menu has Paste")) return;
          ev.mouseClick(paste, paste.width / 2, paste.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
          wait.waitFor(function() { return !menu.visible && !field.pasteRunning && field.text !== ""; }, 10000, function(pasted) {
            if (!check(pasted && field.text === "folder" && view.adding && view.fieldFocused && shell.calls("add").length === adds, "the menu's Paste landed in the open add field, nothing added (" + JSON.stringify([field.text, field.pasteError, view.fieldOpen, view.fieldFocused]) + ")")) return;
            ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
            if (!check(field.text === "" && view.adding && view.fieldFocused, "Esc cleared the paste, the empty field keeps the keys")) return;
            ev.mouseClick(editor, editor.width / 2, editor.height / 2, Qt.RightButton, Qt.NoModifier, -1);
            wait.waitFor(function() { return menu.opened; }, 5000, function(again) {
              if (!check(again && !field.inputActiveFocus && view.adding && view.view === "today", "the menu is open again over the empty field, in Today")) return;
              var tab = shell.find(shell.find(view, "viewSwitch"), "foamyTab0");
              // Beside the menu: its left edge, in the tab's coordinates.
              var x = Math.min(tab.width / 2, menu.contentItem.mapToItem(tab, 0, 0).x - 4);
              if (!check(x > 0, "the Inbox tab shows beside the menu (" + x + ")")) return;
              ev.mouseClick(tab, x, tab.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
              wait.waitFor(function() { return !menu.visible && !view.fieldOpen && view.view === "inbox"; }, 5000, function(left) {
                if (!check(left && !view.fieldFocused && view.cursor.index !== view.addStop, "a click on a tab beside the open menu closed the menu and the empty field and switched the view (" + JSON.stringify([menu.visible, view.fieldOpen, view.view, view.fieldFocused, view.cursor.index]) + ")")) return;
                view.openAdd();
                wait.waitFor(function() { return view.fieldFocused && view.band.fieldProgress === 1; }, 5000, function(reopened) {
                  if (!check(reopened, "the add field open again, with the keys")) return;
                  done();
                });
              });
            });
          });
        });
      });
    });
  }
  // The keys once Settings hides (the page has them): Esc on Settings goes
  // back to the list, and the next Esc closes the popup. Then Settings
  // again (s), the popup closes on it and opens again on the list: the
  // first Esc closes it. Then done(), the popup closed.
  function keysAfterSettings(view, done) {
    ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
    if (!check(!view.editingSettings && one.opened, "Esc on Settings went back to the list")) return;
    // The keys move in a deferred call: one drawn frame later.
    shell.afterFrame(view, function() {
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(!one.opened, "after going back from Settings, Esc closed the popup")) return;
      shell.afterClose(function() {
        one.open();
        wait.waitFor(function() { return one.opened && view.active; }, 5000, function(opened) {
          if (!check(opened, "the popup opened again")) return;
          view.cursor.emitTextKey(view, "s");
          wait.waitFor(function() { return view.editingSettings && view.settingsPage.activeFocus; }, 5000, function(shown) {
            if (!check(shown, "s opened Settings, with the keys")) return;
            one.close();
            shell.afterClose(function() {
              one.open();
              wait.waitFor(function() { return one.opened && view.active && !view.editingSettings; }, 5000, function(again) {
                if (!check(again, "the popup closed on Settings opened again on the list")) return;
                shell.afterFrame(view, function() {
                  ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
                  if (!check(!one.opened, "closed on Settings and opened again, the first Esc closed the popup")) return;
                  shell.afterClose(done);
                });
              });
            });
          });
        });
      });
    });
  }
  function check(ok, message) {
    if (!ok && !shell.finished) { shell.finished = true; console.log("FOAMY FAIL " + message); Qt.quit(); }
    return ok;
  }
  // The settings page's sections as drawn, top to bottom: their titles.
  function settingsSections(page) {
    var names = ["accountSection", "panelSection", "openCommandSection", "barSection", "refreshSection", "signedInSection"];
    return names.map(function(name) { return shell.find(page, name); }).filter(function(section) { return section && section.visible; }).sort(function(a, b) {
      return a.mapToItem(page, 0, 0).y - b.mapToItem(page, 0, 0).y;
    }).map(function(section) { return section.title; });
  }
  // Every visible item under `item` named `name`.
  function findAll(item, name) {
    var out = [];
    var walk = function(at) {
      if (!at.visible) return;
      if (at.objectName === name) out.push(at);
      for (var child of at.children) walk(child);
    };
    if (item) walk(item);
    return out;
  }
  // Wide, mirrored (right to left): "" when the rail is at the card's right
  // edge with its labels and rows readable in it (text right-aligned, left
  // of its icon), the list beside it as wide as the rest (less the pane)
  // with its task rows inside it (text left of the ring), the pane on the
  // far left and the Week columns from the right in reading order; else
  // what is off. Call it with the card's width settled.
  function rtlLayout(view) {
    var off = [];
    var box = function(item) { var at = item.mapToItem(view, 0, 0); return { left: at.x, right: at.x + item.width, width: item.width }; };
    var inside = function(inner, outer) { return inner.left >= outer.left - 0.5 && inner.right <= outer.right + 0.5; };
    var border = Kit.FoamyStyle.borderWidth;
    if (!view.LayoutMirroring.enabled) off.push("not mirrored");
    var card = { left: 0, right: view.width };
    var rail = shell.find(view, "rail");
    var area = shell.find(view, "listArea");
    var railBox = box(rail);
    var areaBox = box(area);
    if (!rail.visible || Math.abs(railBox.right - card.right) > 0.5) off.push("rail " + JSON.stringify(railBox) + " not at the right edge of " + card.right);
    if (Math.abs(areaBox.right - (railBox.left - border)) > 0.5) off.push("list " + JSON.stringify(areaBox) + " not beside the rail");
    var paneSpace = view.paneOpen ? view.paneWidth + border : 0;
    if (Math.abs(areaBox.width - (card.right - railBox.width - border - paneSpace)) > 0.5) off.push("list width " + areaBox.width + " in " + card.right);
    if (!inside(areaBox, card)) off.push("list " + JSON.stringify(areaBox) + " outside the card");
    var labels = shell.findAll(rail, "railLabel");
    var texts = shell.findAll(rail, "railText");
    if (labels.length < 1 || texts.length < 5) off.push(labels.length + " rail labels, " + texts.length + " rail rows");
    for (var label of labels) {
      var lb = box(label);
      if (!inside(lb, railBox) || lb.left < railBox.left + railBox.width / 2) off.push("rail label " + label.text + " at " + JSON.stringify(lb));
    }
    for (var text of texts) {
      var tb = box(text);
      var ib = box(shell.find(text.parent, "railIcon"));
      if (tb.width < 20 || !inside(tb, railBox) || tb.right > ib.left + 0.5 || text.effectiveHorizontalAlignment !== Text.AlignRight) off.push("rail row " + text.text + " at " + JSON.stringify([tb, ib.left, text.effectiveHorizontalAlignment]));
    }
    if (!view.weekShown) {
      var list = shell.find(view, "taskList");
      var rows = shell.findAll(list.contentItem, "taskText").filter(function(item) { var y = item.mapToItem(list, 0, 0).y; return y >= 0 && y + item.height <= list.height; });
      if (rows.length < 3) off.push(rows.length + " task rows in view");
      for (var row of rows) {
        var rb = box(row);
        var ring = box(shell.find(row.parent.parent, "ringMark"));
        if (rb.width < 20 || !inside(rb, areaBox) || !inside(ring, areaBox) || rb.right > ring.left + 0.5 || row.effectiveHorizontalAlignment !== Text.AlignRight) off.push("task row " + row.text + " at " + JSON.stringify([rb, ring.left]));
      }
    } else {
      var keys = ["overdue", "today", "tomorrow", "later"].map(function(key) { return box(shell.find(view, "weekColumn-" + key)); });
      for (var k = 0; k < keys.length; k++)
        if (!inside(keys[k], areaBox) || (k > 0 && keys[k].right > keys[k - 1].left + 0.5)) off.push("Week columns " + JSON.stringify(keys));
    }
    if (view.paneShown || view.overviewShown) {
      var pane = box(view.paneShown ? view.editor : shell.find(view, "overview"));
      if (!inside(pane, card) || pane.left > 0.5 || Math.abs(pane.right + border - areaBox.left) > 0.5) off.push("pane " + JSON.stringify(pane) + " not on the far left");
    }
    // The pane's header and property rows mirror: each icon to the right
    // of its words, the header's buttons at the left.
    if (view.paneShown) {
      var mirroredRow = function(name) {
        var section = shell.find(view.editor, name);
        var words = shell.find(section, "valueText");
        var icon = words ? words.parent.children.find(function(item) { return item !== words && item.name !== undefined; }) : null;
        if (!words || !icon || box(words).right > box(icon).left + 0.5) off.push(name + " not mirrored " + JSON.stringify([words ? box(words) : null, icon ? box(icon) : null]));
      };
      mirroredRow("section-place");
      mirroredRow("section-priority");
      var header = shell.find(view.editor, "paneHeader");
      var place = box(shell.find(header, "paneHeaderPlace"));
      var close = box(shell.find(header, "paneClose"));
      if (close.right > place.left + 0.5) off.push("pane header not mirrored " + JSON.stringify([place, close]));
    }
    return off.join("; ");
  }
  function find(item, name) {
    if (!item) return null;
    if (item.objectName === name) return item;
    for (var child of item.children) { var hit = find(child, name); if (hit) return hit; }
    return null;
  }
  // The task rows the list has built, and those with the cursor.
  // A property section's click target (its caption and value).
  function sectionBox(editor, name) {
    return shell.find(shell.find(editor, name), "sectionBox");
  }
  // The section whose click target has the keys ("" for none).
  function focusedSection(editor) {
    var focused = editor.Window.window.activeFocusItem;
    if (focused && focused.objectName === "sectionBox")
      for (var at = focused; at; at = at.parent)
        if (String(at.objectName).indexOf("section-") === 0) return at.objectName;
    return focused ? String(focused.objectName) : "";
  }
  // The built header rows of the list (between groups).
  function builtHeaders(view) {
    return view.list.contentItem.children.filter(function(item) { return item.hasOwnProperty("entry") && item.visible && item.entry.kind === "header"; });
  }
  // Wide, a list: task A in the pane, then the pointer on row B (the
  // cursor goes there, the pane stays). The task keys act on A, the task
  // being read: Space, d, t, e and Ctrl+O. After an arrow key they act on
  // the cursor's row again (the pane follows it). Then `done`, A in the
  // pane again and nothing changed.
  function paneKeys(view, done) {
    var store = Plugin.TodoStore;
    var editor = view.editor;
    view.focusList();
    view.goTo(view.firstRowStop);
    var a = view.cursorRow();
    var bStop = view.firstRowStop + 1;
    var b = view.rows[view.stops[1]];
    var c = view.rows[view.stops[2]];
    if (!check(a.kind === "task" && b.kind === "task" && c.kind === "task" && !a.recurring && view.paneTask === a.id, "three task rows, the first in the pane (" + JSON.stringify([a.id, b.id, c.id, view.paneTask]) + ")")) return;
    var rowB = shell.builtRows(view).find(function(r) { return r.entry.id === b.id; });
    var surfaceB = shell.find(rowB, "taskSurface");
    ev.mouseMove(surfaceB, surfaceB.width * 0.4, surfaceB.height / 2, -1, Qt.NoButton, Qt.NoModifier);
    if (!check(view.cursor.index === bStop && !view.cursor.byKeys && view.paneTask === a.id, "the pointer on " + b.id + ": the cursor there, the pane on " + a.id + " (" + JSON.stringify([view.cursor.index, view.cursor.byKeys, view.paneTask]) + ")")) return;
    // The pointed row's actions don't name keys that act on another task.
    var tips = function(row) { return [shell.find(row, "tomorrowAction").tooltipText, shell.find(row, "dateAction").tooltipText]; };
    if (!check(shell.find(rowB, "rowActions").visible && JSON.stringify(tips(rowB)) === JSON.stringify(["Tomorrow", "Date"]), "the pointed row's actions name no keys (" + JSON.stringify(tips(rowB)) + ")")) return;
    ev.keyClick(Qt.Key_Space, Qt.NoModifier, -1);
    if (!check(store.struck[a.id] === true && !Model.has(store.struck, b.id), "Space completed the pane's task, not the pointed row (" + JSON.stringify(store.struck) + ")")) return;
    ev.keyClick(Qt.Key_Space, Qt.NoModifier, -1);
    if (!check(!Model.has(store.struck, a.id) && !store.pending, "Space again undid it")) return;
    view.cursor.emitTextKey(view, "t");
    if (!check(store.moves[a.id] === Model.addDays(shell.today, 1) && Object.keys(store.moves).length === 1, "t moved the pane's task to tomorrow (" + JSON.stringify(store.moves) + ")")) return;
    store.undo(a.id);
    view.cursor.emitTextKey(view, "d");
    if (!check(editor.menu.opened && editor.taskId === a.id && !view.dateMenuItem.opened, "d opened the pane's own Date menu, on its task (" + JSON.stringify([editor.menu.opened, editor.taskId, view.dateMenuItem.opened]) + ")")) return;
    editor.menu.close();
    view.focusList();
    view.cursor.emitTextKey(view, "e");
    shell.afterFrame(view, function() {
      if (!check(editor.contentField.inputActiveFocus && view.paneTask === a.id && editor.taskId === a.id, "e put the caret in the pane's task")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(!view.blocked && view.cursor.index === bStop && !view.cursor.byKeys, "Esc: the keys back, the cursor still on the pointed row")) return;
      shell.openedBefore = shell.opened().length;
      ev.keyClick(Qt.Key_O, Qt.ControlModifier, -1);
      wait.waitFor(function() { return shell.opened().length > shell.openedBefore && !store.launchRunning; }, 15000, function(ok) {
        var launched = shell.opened().slice(shell.openedBefore);
        if (!check(ok && launched.length === 1 && launched[0].indexOf(Model.webUrl("task", a.id)) >= 0, "Ctrl+O opened the pane's task (" + JSON.stringify(launched) + ")")) return;
        // ↓ moves from the cursor; the pane follows, and the keys act there.
        shell.put("reply-task.json", JSON.stringify({ ok: true, task: { id: c.id, description: "", truncated: false } }));
        ev.keyClick(Qt.Key_Down, Qt.NoModifier, -1);
        if (!check(view.cursorRow().id === c.id && view.paneTask === c.id && view.cursor.byKeys, "↓ from the pointed row: the next row, in the pane (" + view.paneTask + ")")) return;
        var rowC = shell.builtRows(view).find(function(r) { return r.entry.id === c.id; });
        if (!check(JSON.stringify(tips(rowC)) === JSON.stringify(["Tomorrow (t)", "Date (d)"]), "the keys' row: its actions name their keys (" + JSON.stringify(tips(rowC)) + ")")) return;
        ev.keyClick(Qt.Key_Space, Qt.NoModifier, -1);
        if (!check(store.struck[c.id] === true && !Model.has(store.struck, a.id) && !Model.has(store.struck, b.id), "after ↓, Space completed the cursor's row (" + JSON.stringify(store.struck) + ")")) return;
        ev.keyClick(Qt.Key_Space, Qt.NoModifier, -1);
        wait.waitFor(function() { var d = store.description; return d.id === c.id && d.state === "ready"; }, 15000, function(read) {
          if (!check(read && !store.pending && Object.keys(store.moves).length === 0, "undone, " + c.id + "'s description read")) return;
          shell.paneKeysFar(view, function() {
            shell.put("reply-task.json", JSON.stringify({ ok: true, task: { id: a.id, description: "", truncated: false } }));
            view.goTo(view.firstRowStop);
            wait.waitFor(function() { var d = store.description; return view.paneTask === a.id && d.id === a.id && d.state === "ready"; }, 15000, function(back) {
              if (check(back, a.id + " in the pane again")) done();
            });
          });
        });
      });
    });
  }
  // The Week view with its pane open on t4, the pointer on t6: Space and
  // Ctrl+→ act on t4. Then `done`, the pane closed and nothing changed.
  // The pane's task far down a long list, its row not built, the pointer
  // on the first row: d and Space act on the pane's task (d opens the
  // pane's own Date menu: there is no row to open one on). While its
  // completion is on its way the keys act on the
  // cursor's row. → on the pointed row has nowhere to go: the keys have the
  // cursor then, and the pane shows that row. Then `done`, the fixture's
  // list back.
  function paneKeysFar(view, done) {
    var store = Plugin.TodoStore;
    var far = shell.snapshot();
    for (var i = 0; i < 40; i++)
      far.tasks.push(Fixtures.task("far" + i, "Far " + i, "home", { due: Fixtures.due(shell.today), child_order: 300 + i }));
    store.snapshot = far;
    // The row the list has for a task now (null: not built, or put aside for reuse).
    var built = function(id) { return view.list.itemAtIndex(view.rows.findIndex(function(r) { return r.id === id; })); };
    var pointAtFirst = function() {
      view.list.positionViewAtIndex(0, ListView.Beginning);
      view.list.forceLayout();
      var first = built(view.rows[view.stops[0]].id);
      var surface = shell.find(first, "taskSurface");
      // Away and back, so the move is one the row sees.
      ev.mouseMove(view.band, 10, 10, -1, Qt.NoButton, Qt.NoModifier);
      ev.mouseMove(surface, surface.width * 0.4, surface.height / 2, -1, Qt.NoButton, Qt.NoModifier);
      return first.entry.id;
    };
    shell.put("reply-task.json", JSON.stringify({ ok: true, task: { id: "far39", description: "", truncated: false } }));
    shell.afterFrame(view, function() {
      view.focusList();
      view.goTo(view.stopOf("far39"));
      wait.waitFor(function() { var d = store.description; return view.paneTask === "far39" && d.id === "far39" && d.state === "ready"; }, 15000, function(shown) {
        if (!check(shown, "far39 in the pane")) return;
        var first = pointAtFirst();
        if (!check(!built("far39") && view.cursor.index === view.firstRowStop && !view.cursor.byKeys && view.paneTask === "far39", "the pointer on the first row, far39's row not built, the pane on far39 (" + JSON.stringify([!!built("far39"), view.cursor.index, view.cursor.byKeys, view.paneTask]) + ")")) return;
        view.cursor.emitTextKey(view, "d");
        if (!check(view.editor.menu.opened && view.editor.taskId === "far39" && !view.dateMenuItem.opened && !built("far39"), "d with far39's row not built: the pane's own Date menu (" + JSON.stringify([view.editor.menu.opened, view.editor.taskId, view.dateMenuItem.opened]) + ")")) return;
        view.editor.menu.close();
        view.focusList();
        pointAtFirst();
        if (!check(!built("far39") && view.paneTask === "far39" && !view.cursor.byKeys, "the pointer on the first row again")) return;
        ev.keyClick(Qt.Key_Space, Qt.NoModifier, -1);
        if (!check(store.struck.far39 === true && Object.keys(store.struck).length === 1, "Space: far39 struck, no other row (" + JSON.stringify(store.struck) + ")")) return;
        ev.keyClick(Qt.Key_Space, Qt.NoModifier, -1);
        if (!check(!Model.has(store.struck, "far39") && !store.pending, "Space again undid it")) return;
        // Its completion on its way (hidden, no task to act on): Space is
        // the pointed row's.
        first = pointAtFirst();
        store.sending = { far39: true };
        ev.keyClick(Qt.Key_Space, Qt.NoModifier, -1);
        if (!check(store.struck[first] === true && Object.keys(store.struck).length === 1, "far39 on its way: Space completed the pointed row (" + JSON.stringify(store.struck) + ")")) return;
        ev.keyClick(Qt.Key_Space, Qt.NoModifier, -1);
        store.sending = ({});
        if (!check(!store.pending, "undone")) return;
        // → has nowhere to go from a task row.
        first = pointAtFirst();
        shell.put("reply-task.json", JSON.stringify({ ok: true, task: { id: first, description: "", truncated: false } }));
        ev.keyClick(Qt.Key_Right, Qt.NoModifier, -1);
        if (!check(view.cursor.byKeys && view.cursorRow().id === first && view.paneTask === first, "→ on the pointed row: the keys have the cursor, the pane shows it (" + JSON.stringify([view.cursor.byKeys, view.paneTask]) + ")")) return;
        wait.waitFor(function() { var d = store.description; return d.id === first && d.state === "ready"; }, 15000, function(read) {
          if (!check(read, first + "'s description read")) return;
          store.snapshot = shell.snapshot();
          shell.afterFrame(view, done);
        });
      });
    });
  }
  function weekPaneKeys(view, done) {
    var store = Plugin.TodoStore;
    shell.put("reply-task.json", JSON.stringify({ ok: true, task: { id: "t4", description: "", truncated: false } }));
    view.focusList();
    view.weekPlace(1, 1);
    view.goTo(view.firstRowStop);
    ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
    ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
    if (!check(view.weekPaneOpen && view.paneTask === "t4" && !view.blocked, "Enter opened the pane on t4 (" + view.paneTask + ")")) return;
    var card = shell.find(view.week, "card-t6");
    ev.mouseMove(card, card.width / 2, card.height / 2, -1, Qt.NoButton, Qt.NoModifier);
    if (!check(view.cursorRow() && view.cursorRow().id === "t6" && !view.cursor.byKeys && view.paneTask === "t4", "the pointer on t6: the cursor there, the pane on t4 (" + JSON.stringify([view.cursorRow() && view.cursorRow().id, view.cursor.byKeys, view.paneTask]) + ")")) return;
    // Beside the pane the cards are narrow: no move actions there (they
    // would cover the date), neither on the pointer's card nor the pane's.
    if (!check(!shell.find(card, "moveActions").visible && !shell.find(shell.find(view.week, "card-t4"), "moveActions").visible, "beside the pane no card shows move actions")) return;
    ev.keyClick(Qt.Key_Space, Qt.NoModifier, -1);
    if (!check(store.struck.t4 === true && !Model.has(store.struck, "t6"), "Week: Space completed the pane's card (" + JSON.stringify(store.struck) + ")")) return;
    ev.keyClick(Qt.Key_Space, Qt.NoModifier, -1);
    ev.keyClick(Qt.Key_Right, Qt.ControlModifier, -1);
    if (!check(!Model.has(store.struck, "t4") && store.moves.t4 === Model.addDays(shell.today, 1) && !Model.has(store.moves, "t6"), "Week: Ctrl+→ moved the pane's card (" + JSON.stringify(store.moves) + ")")) return;
    store.undo("t4");
    wait.waitFor(function() { var d = store.description; return d.id === "t4" && d.state === "ready"; }, 15000, function(read) {
      if (!check(read && !store.pending, "t4's description read, nothing pending")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(!view.weekPaneOpen, "Esc closed the week's pane")) return;
      // The pane closed: once the board is wide again, the pointer on t6
      // shows its card's move actions, and they move the card they are on.
      var wideCard = function() { var c = shell.find(view.week, "card-t6"); return !view.week.narrow && !!c && c.width > 150; };
      wait.waitFor(wideCard, 5000, function(wide) {
        var card6 = shell.find(view.week, "card-t6");
        if (!check(wide, "the board is wide again (" + (card6 ? card6.width : -1) + ")")) return;
        ev.mouseMove(view.band, 10, 10, -1, Qt.NoButton, Qt.NoModifier);
        ev.mouseMove(card6, card6.width / 2, card6.height / 2, -1, Qt.NoButton, Qt.NoModifier);
        var later6 = shell.find(card6, "moveLater");
        if (!check(view.cursorRow() && view.cursorRow().id === "t6" && shell.find(card6, "moveActions").visible && !shell.find(shell.find(view.week, "card-t4"), "moveActions").visible, "the pointer's card shows its move actions (" + JSON.stringify([view.cursorRow() && view.cursorRow().id, shell.find(card6, "moveActions").visible]) + ")")) return;
        ev.mouseClick(later6, later6.width / 2, later6.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
        if (!check(store.moves.t6 === Model.addDays(shell.today, 1) && Object.keys(store.moves).length === 1, "a day later moved the card it is on (" + JSON.stringify([store.moves, store.error]) + ")")) return;
        store.undo("t6");
        shell.afterFrame(view, function() {
        // A card due today has no day earlier: only "A day later" shows.
        var point = function(id) { var c = shell.find(view.week, "card-" + id); ev.mouseMove(view.band, 10, 10, -1, Qt.NoButton, Qt.NoModifier); ev.mouseMove(c, c.width / 2, c.height / 2, -1, Qt.NoButton, Qt.NoModifier); return c; };
        var today6 = point("t6");
        if (!check(shell.find(today6, "moveActions").visible && !shell.find(today6, "moveEarlier").visible && shell.find(today6, "moveLater").visible && shell.find(today6, "moveLater").tip.indexOf("A day later") === 0, "a card due today: no A day earlier (" + JSON.stringify([shell.find(today6, "moveEarlier").visible, shell.find(today6, "moveLater").visible, shell.find(today6, "moveLater").tip]) + ")")) return;
        // An overdue card: one action, named for what it does.
        var card2 = point("t2");
        if (!check(shell.find(card2, "moveActions").visible && !shell.find(card2, "moveEarlier").visible && shell.find(card2, "moveLater").tip.indexOf("Move to today") === 0, "an overdue card: only Move to today (" + JSON.stringify([shell.find(card2, "moveEarlier").visible, shell.find(card2, "moveLater").tip]) + ")")) return;
        // A card due tomorrow: both.
        var tomorrowId = view.weekColumns[2].entries[view.weekColumns[2].cards[0]].id;
        var cardT = point(tomorrowId);
        if (!check(shell.find(cardT, "moveEarlier").visible && shell.find(cardT, "moveLater").visible && shell.find(cardT, "moveEarlier").tip.indexOf("A day earlier") === 0, "a card due tomorrow: both actions (" + shell.find(cardT, "moveEarlier").tip + ")")) return;
        // An overdue card with a long date and a time: the actions would
        // cover the time, so they don't show; the date and time show whole.
        store.snapshot = shell.snapshotWith({ t2: { due: Fixtures.due("2025-11-17T09:30:00") } });
        shell.afterFrame(view, function() {
        var long2 = point("t2");
        var time2 = shell.find(long2, "cardTime");
        var text2 = shell.find(long2, "cardText");
        if (!check(view.cursorRow() && view.cursorRow().id === "t2" && time2.visible && time2.text === "09:30" && !shell.find(long2, "moveActions").visible && time2.mapToItem(text2, 0, 0).x + time2.width <= text2.width + 0.5, "a long date with a time: no move actions over it, the time whole (" + JSON.stringify([shell.find(long2, "cardDate").text, time2.text, shell.find(long2, "moveActions").visible]) + ")")) return;
        store.snapshot = shell.snapshot();
        // The pointer off the board, so it points at no card from here on.
        ev.mouseMove(view.band, 10, 10, -1, Qt.NoButton, Qt.NoModifier);
        shell.afterFrame(view, function() {
        // The keys on t4: its actions' tooltips name them. The card keeps
        // its height and its text's place while they show.
        var card4 = shell.find(view.week, "card-t4");
        var place4 = function() { return [card4.height, shell.find(card4, "cardText").mapToItem(card4, 0, 0).x, shell.find(card4, "cardTime").mapToItem(card4, 0, 0).x]; };
        view.weekPlace(1, 2);
        shell.afterFrame(view, function() {
          var without = place4();
          view.weekPlace(1, 1);
          view.cursor.byKeys = true;
          shell.afterFrame(view, function() {
            if (!check(shell.find(card4, "moveActions").visible && shell.find(card4, "moveLater").tip === "A day later (Ctrl+→)" && shell.find(card4, "moveEarlier").tip === "A day earlier (Ctrl+←)", "the keys' card: its actions name Ctrl+←/→ (" + shell.find(card4, "moveLater").tip + ")")) return;
            if (!check(JSON.stringify(place4()) === JSON.stringify(without), "the actions change neither the card's height nor its text's place (" + JSON.stringify([without, place4()]) + ")")) return;
            // A repeating task: the actions refuse it as Ctrl+→ does, with the same reason.
            view.weekPlace(1, 0);
            ev.keyClick(Qt.Key_Right, Qt.ControlModifier, -1);
            var byKeys = store.error;
            store.error = "";
            shell.afterFrame(view, function() {
              var later3 = shell.find(shell.find(view.week, "card-t3"), "moveLater");
              ev.mouseClick(later3, later3.width / 2, later3.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
              if (!check(byKeys !== "" && store.error === byKeys && !Model.has(store.moves, "t3"), "a repeating card's action refuses as Ctrl+→ does (" + JSON.stringify([byKeys, store.error]) + ")")) return;
              store.error = "";
              done();
            });
          });
        });
            });
        });
        });
      });
    });
  }
  // The Week view: `a` adds for the day of the column the cursor is in
  // (`cases`: [what, column, card or -1 for no cursor, day, placeholder]),
  // each sent with Shift+Enter (the field stays) and answered before the
  // next. Then `done`.
  function weekAdds(view, cases, done) {
    if (!cases.length) { done(); return; }
    var store = Plugin.TodoStore;
    var c = cases[0];
    view.focusList();
    if (c[2] >= 0) {
      view.weekPlace(c[1], c[2]);
      view.goTo(view.firstRowStop);
    } else
      view.clearSelection();
    view.cursor.emitTextKey(view, "a");
    if (!check(view.fieldFocused && view.field.placeholderText === c[4], c[0] + ": the placeholder (" + view.field.placeholderText + ")")) return;
    var before = shell.calls("add").length;
    for (var ch of "Week " + c[0]) ev.keyClickChar(ch, Qt.NoModifier, -1);
    ev.keyClick(Qt.Key_Return, Qt.ShiftModifier, -1);
    wait.waitFor(function() { return shell.calls("add").length === before + 1 && !store.addPending && !store.busy; }, 15000, function(ok) {
      var sent = ok ? JSON.parse(shell.calls("add").pop().slice("add ".length)) : null;
      if (!check(sent && sent.text === "Week " + c[0] && sent.due_date === c[3], c[0] + ": added for " + c[3] + " (" + JSON.stringify(sent) + ")")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(!view.fieldOpen, c[0] + ": Esc closed the empty field")) return;
      shell.weekAdds(view, cases.slice(1), done);
    });
  }
  // Wide: a click on the pane's empty space takes the keys from its title
  // (the typed text saved) and keeps the selection; a click on the list's
  // space that isn't a row (below the rows, a heading, the top margin)
  // clears it: no row, no cursor, the pane on the overview and the card at
  // 880 still, the band's Search again, the pane's draft saved first.
  // Then `done`.
  function listSpace(view, done) {
    var store = Plugin.TodoStore;
    var editor = view.editor;
    view.goTo(view.firstRowStop);
    var id = view.paneTask;
    var typed = function(suffix) {
      var text = store.model.byId[id].content + suffix;
      var change = {};
      change[id] = { content: text };
      var results = {};
      results[id] = "ok";
      shell.put("reply-apply.json", JSON.stringify(Object.assign(shell.snapshotWith(change), { results: results })));
      editor.contentField.focusInput();
      editor.contentField.cursorPosition = editor.contentField.text.length;
      for (var c of suffix) ev.keyClickChar(c, Qt.NoModifier, -1);
      return text;
    };
    // The pane's header at its top, the title a gap under it.
    var headTop = shell.find(editor, "editorHead").mapToItem(view, 0, 0).y;
    var paneHeader = shell.find(editor, "paneHeader");
    var headerTop = paneHeader.mapToItem(view, 0, 0).y;
    var paneTop = editor.mapToItem(view, 0, 0).y;
    if (!check(paneHeader.visible && Math.abs(headerTop - paneTop) <= 1 && Math.abs(headTop - paneTop - paneHeader.height - Kit.FoamyStyle.gap) <= 1, "the pane's header at its top, the title under it (" + JSON.stringify([headTop, headerTop, paneTop, paneHeader.height]) + ")")) return;
    var footerStatus = shell.find(view, "foamyFooterStatus");
    var updatedText = footerStatus.text;
    if (!check(updatedText.indexOf("Updated") === 0 && !editor.savedShown, "the footer says how fresh the list is (" + updatedText + ")")) return;
    var from = shell.calls("apply").length;
    var first = typed(" here");
    var stop = view.cursor.index;
    // The pane header's empty space: nothing there takes a click.
    ev.mouseClick(editor, editor.width / 2, 4, Qt.LeftButton, Qt.NoModifier, -1);
    if (!check(!editor.contentField.inputActiveFocus && !view.blocked && view.paneTask === id && view.cursor.index === stop && editor.task !== null, "a click in the pane's empty space took the keys, kept the selection")) return;
    if (!check(editor.saving && footerStatus.text === "Saving…" && !view.footer.statusError, "the footer says Saving… while it runs (" + footerStatus.text + ")")) return;
    // An add draft left open (the field without the keys): the save's
    // status takes the key hints' place, and they come back after it.
    var hintsRow = shell.find(view, "keyHints");
    view.fieldOpen = true;
    if (!check(view.adding && footerStatus.text === "Saving…" && !hintsRow.visible, "with an add draft open, Saving… in the hints' place (" + JSON.stringify([footerStatus.text, hintsRow.visible]) + ")")) return;
    view.fieldOpen = false;
    wait.waitFor(function() { return shell.calls("apply").length === from + 1 && !store.busy && !editor.saving; }, 15000, function(ok) {
      if (!check(ok && store.model.byId[id].content === first, "and saved the typed text (" + JSON.stringify(shell.updatesSince(from)) + ")")) return;
      // "Saved" for a moment (the timer's run), then the freshness line again.
      if (!check(footerStatus.text === "Saved" && editor.savedTimer.running, "then Saved (" + footerStatus.text + ")")) return;
      editor.savedTimer.stop();
      if (!check(footerStatus.text.indexOf("Updated") === 0, "and the freshness line when its moment ends (" + footerStatus.text + ")")) return;
      var second = typed(" there");
      var list = view.list;
      var below = list.contentHeight - list.contentY;
      if (!check(below < list.height - 12, "the list has room below its rows (" + JSON.stringify([list.contentHeight, list.height]) + ")")) return;
      ev.mouseClick(list, list.width / 2, below + 8, Qt.LeftButton, Qt.NoModifier, -1);
      var actions = function() { return JSON.stringify(view.band.shownTrailing.map(function(item) { return item.objectName; })); };
      if (!check(view.paneTask === "" && view.cursor.index === -1 && shell.highlighted(view).length === 0 && editor.taskId === "" && !editor.visible && view.overviewShown && shell.find(view, "overview").visible && one.cardWidth === 880 && !view.blocked, "a click below the rows cleared the selection, the pane shows the overview (" + JSON.stringify([view.paneTask, view.cursor.index, one.cardWidth]) + ")")) return;
      // The band lays its buttons out again on the next turn of the event loop.
      wait.waitFor(function() { return actions() === JSON.stringify(["addAction", "searchAction"]) && shell.calls("apply").length === from + 2 && !store.busy; }, 15000, function(ok2) {
        if (!check(ok2 && store.model.byId[id].content === second && shell.popupPlacement(one, 880) === "", "no task in the pane: the band has Search again, the card 880 still; the pane's draft was saved first (" + actions() + ", " + JSON.stringify(shell.updatesSince(from)) + ", " + shell.popupPlacement(one, 880) + ")")) return;
        // A heading between groups, and the list's top margin: the same.
        var headers = shell.builtHeaders(view);
        if (!check(headers.length > 0, "the list has a heading")) return;
        view.goTo(view.firstRowStop);
        ev.mouseClick(headers[0], headers[0].width / 2, headers[0].height / 2, Qt.LeftButton, Qt.NoModifier, -1);
        if (!check(view.paneTask === "" && view.cursor.index === -1, "a click on a heading cleared the selection")) return;
        view.goTo(view.firstRowStop);
        var area = shell.find(view, "listArea");
        ev.mouseClick(area, area.width / 2, 2, Qt.LeftButton, Qt.NoModifier, -1);
        if (!check(view.paneTask === "" && view.cursor.index === -1, "a click on the list's top margin cleared the selection")) return;
        // A click on a row selects it: the pane shows it, the card keeps its width.
        var clicked = shell.builtRows(view)[1];
        var clickedSurface = shell.find(clicked, "taskSurface");
        ev.mouseClick(clickedSurface, clickedSurface.width * 0.3, clickedSurface.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
        if (!check(view.paneTask === clicked.entry.id && editor.visible && !view.overviewShown && one.cardWidth === 880 && one.popup.contentWidth === 880, "a click on a row: the pane on it, the card 880 (" + JSON.stringify([view.paneTask, one.cardWidth]) + ")")) return;
        // Esc in the list: the selection clears first (the pane shows the
        // overview again), then a second Esc would close the popup.
        view.focusList();
        ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
        if (!check(one.opened && view.paneTask === "" && view.cursor.index === -1 && !editor.visible && view.overviewShown && one.cardWidth === 880, "Esc in the list cleared the selection, the overview is back, the popup stays (" + JSON.stringify([one.opened, view.paneTask, one.cardWidth]) + ")")) return;
        // A row still selects.
        view.goTo(view.firstRowStop);
        if (!check(view.paneTask !== "" && view.editor.task !== null, "the keys select a row again")) return;
        done();
      });
    });
  }
  // Wide's pane with no task selected: each view's overview, and what its
  // parts do (Today, 12:00 on the store's clock). `view` is open on Today
  // with nothing selected; it ends that way. Then `done`.
  function overviewChecks(view, done) {
    var store = Plugin.TodoStore;
    var pane = shell.find(view, "overview");
    var part = function(name) { return shell.find(pane, name); };
    var shown = function(name) { var item = part(name); return !!item && item.visible; };
    var click = function(item) { ev.mouseClick(item, item.width / 2, item.height / 2, Qt.LeftButton, Qt.NoModifier, -1); };
    var wideStill = function() { return one.cardWidth === 880 && one.popup.contentWidth === 880; };
    // Whether `texts` holds `wanted` in this order.
    var inOrder = function(texts, wanted) { var at = 0; for (var text of texts) if (text === wanted[at]) at++; return at === wanted.length; };
    // The project stage's snapshot (more tasks than fit), for the later stages.
    var many = null;
    // The list's header at its top (after a part scrolled it there).
    var headerOnTop = function(test) {
      var header = shell.builtHeaders(view).find(function(h) { return test(h.entry); });
      return !!header && view.list.contentY > 0 && Math.abs(header.mapToItem(view.list, 0, 0).y) < 1;
    };
    // Each stage runs after a frame: the overview's layout is placed then.
    var stages = [function() {
      // Nothing left or overdue today.
      var clear = shell.snapshot();
      clear.tasks = clear.tasks.filter(function(task) { return !task.due || task.due.date.slice(0, 10) > shell.today; });
      store.snapshot = clear;
      return true;
    }, function() {
      // Tomorrow in the figures' place, no zero; the list's line in the
      // middle of its column.
      var clearTexts = shell.visibleTexts(pane);
      var tomorrowCount = pane.summary.tomorrow.count;
      var stateBox = shell.find(view, "stateBox");
      var listArea = shell.find(view, "listArea");
      if (!check(view.rows.length === 0 && tomorrowCount > 0 && !shown("overviewFigures") && shown("overviewTomorrow") && clearTexts.indexOf("Tomorrow · " + tomorrowCount + " tasks") >= 0 && clearTexts.indexOf(pane.summary.tomorrow.first.text) >= 0 && clearTexts.indexOf("0") < 0 && Math.abs(stateBox.y + stateBox.height / 2 - listArea.height / 2) <= 1, "nothing left today: tomorrow, no zero, the line centred (" + JSON.stringify([clearTexts, stateBox.y, stateBox.height, listArea.height]) + ")")) return false;
      // Tomorrow's first task opens in the pane.
      var first = pane.summary.tomorrow.first.id;
      click(part("tomorrowTask"));
      if (!check(view.paneTask === first && view.editor.visible, "tomorrow's task in the pane (" + view.paneTask + ")")) return false;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      view.clearSelection();
      store.snapshot = shell.snapshot();
      return true;
    }, function() {
      // Today: the date, the figures, Next, the timeline, the untimed count.
      var todayTexts = shell.visibleTexts(pane);
      if (!check(pane.visible && pane.summary.kind === "today" && inOrder(todayTexts, ["Wednesday 18 November", "4", "due today", "·", "2", "overdue", "Next", "Review pull request #482", "14:00 · in 2 h", "Today's times", "09:30 Stand-up with the platform team", "14:00 Review pull request #482", "2 tasks without a time"]) && todayTexts.indexOf("with a time") < 0, "Today's overview (" + JSON.stringify(todayTexts) + ")")) return false;
      // The figures on one line, in other words than the band's "left":
      // together they are its number.
      var figureLine = shell.visibleTexts(part("overviewFigures")).join(" ");
      if (!check(figureLine === "4 due today · 2 overdue" && view.band.meta.indexOf("6 left") >= 0 && figureLine.indexOf("left") < 0, "one line of figures that add up to the band's (" + JSON.stringify([figureLine, view.band.meta]) + ")")) return false;
      // The hours from the first block's (09) to the end of the last (15).
      var timeline = part("timeline");
      var hourRows = timeline.children.filter(function(item) { return /^(hour|fold)-/.test(item.objectName); }).map(function(item) { return item.objectName; });
      if (!check(JSON.stringify(hourRows) === JSON.stringify(["hour-9", "hour-10", "hour-11", "hour-12", "hour-13", "hour-14"]), "the hours come from the tasks (" + JSON.stringify(hourRows) + ")")) return false;
      // Now: a 1 px line in the text tone under the blocks, its time in
      // the hours' column in place of the hour it covers.
      var nowLabel = part("nowLabel");
      var nowRule = part("nowRule");
      var nowAt = part("nowLine");
      var under = timeline.children.indexOf(nowAt) < timeline.children.indexOf(part("block-t3")) && nowAt.z <= part("block-t3").z;
      if (!check(nowLabel.visible && nowLabel.text === "12:00" && nowRule.height === 1 && Qt.colorEqual(nowRule.color, Kit.FoamyPalette.text) && under && !shell.find(part("hour-12"), "hourLabel").visible && shell.find(part("hour-11"), "hourLabel").visible, "the now line: 12:00 in the hours' column, 1 px, the text tone, under the blocks (" + JSON.stringify([nowLabel.text, nowRule.height, String(nowRule.color), under]) + ")")) return false;
      // A task that started (09:30) and is still open keeps full strength,
      // with its accent bar.
      var startedBar = shell.find(part("block-t3"), "blockBar");
      var startedText = shell.find(part("block-t3"), "blockText");
      if (!check(Qt.colorEqual(startedBar.color, Kit.FoamyPalette.accent) && Qt.colorEqual(startedText.color, Kit.FoamyPalette.text) && Qt.colorEqual(part("block-t3").rest, part("block-t4").rest), "a started open task keeps full strength (" + JSON.stringify([String(startedBar.color), String(startedText.color)]) + ")")) return false;
      // The first line level with the list's first heading (Overdue).
      var dateTop = part("overviewDate").mapToItem(view, 0, 0).y;
      var firstHeading = shell.find(shell.builtHeaders(view)[0], "headerTitle");
      var headingTop = firstHeading.mapToItem(view, 0, 0).y;
      if (!check(firstHeading.text === "Overdue" && Math.abs(dateTop - headingTop) <= 1, "the date level with the list's first heading (" + JSON.stringify([dateTop, headingTop]) + ")")) return false;
      var block3 = part("block-t3");
      var block4 = part("block-t4");
      var nowLine = part("nowLine");
      if (!check(nowLine.visible && block3.y < nowLine.y && nowLine.y < block4.y && part("timeline").height > block4.y + block4.height, "the now line between 09:30 and 14:00 (" + JSON.stringify([block3.y, nowLine.y, block4.y]) + ")")) return false;
      // Hover lights a part.
      ev.mouseMove(block4, block4.width / 2, block4.height / 2, -1, Qt.NoButton, Qt.NoModifier);
      if (!check(block4.lit && !block3.lit, "hover lights a block")) return false;
      // A block: its task selected (the pane shows it, the cursor on its row).
      click(block3);
      if (!check(view.paneTask === "t3" && view.editor.visible && !pane.visible && view.cursorRow() && view.cursorRow().id === "t3" && wideStill(), "a timeline block selected its task (" + JSON.stringify([view.paneTask, view.cursorRow() && view.cursorRow().id]) + ")")) return false;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(view.paneTask === "" && pane.visible && wideStill(), "Esc: the overview again")) return false;
      // A crowded hour (t3 at 09:30 and a hundred at 10:00) and a task at
      // 23:59 (its hour cut at midnight).
      var crowded = shell.snapshot();
      for (var c = 0; c < 100; c++)
        crowded.tasks.push(Fixtures.task("c" + (c < 10 ? "0" : "") + c, "Crowd " + c, "home", { due: Fixtures.due(shell.today + "T10:00:00") }));
      crowded.tasks.push(Fixtures.task("late", "Last call", "home", { due: Fixtures.due(shell.today + "T23:59:00") }));
      store.snapshot = crowded;
      return settled;
    }, function() {
      // Every drawn block is big enough to click, inside the timeline; the
      // crowd keeps three lanes, the rest summed up in the last.
      var timeline = part("timeline");
      var drawn = timeline.children.filter(function(item) { return /^(block|more)-/.test(item.objectName); });
      var sizes = drawn.map(function(item) { return [item.objectName, Math.round(item.width), Math.round(item.height)]; });
      if (!check(JSON.stringify(drawn.map(function(item) { return item.objectName; })) === JSON.stringify(["block-t3", "block-c00", "more-c01", "block-t4", "block-late"]), "the crowd in three lanes (" + JSON.stringify(sizes) + ")")) return false;
      if (!check(drawn.every(function(item) { return item.width >= Kit.FoamyStyle.controlHeight && item.height >= Kit.FoamyStyle.iconSize + Kit.FoamyStyle.gapSmall && item.y + item.height <= timeline.height && item.x >= 0 && item.x + item.width <= timeline.width + 1; }), "each block big enough to click (" + JSON.stringify(sizes) + ")")) return false;
      var more = part("more-c01");
      if (!check(shell.visibleTexts(more).indexOf("+99 more") >= 0 && more.Accessible.name === "10:00 +99 more", "the rest summed up: +99 more (" + JSON.stringify(shell.visibleTexts(more)) + ")")) return false;
      // A block that shares its row's width keeps its title, not its time
      // (a screen reader still hears it); one alone keeps both.
      var shared = part("block-c00");
      if (!check(JSON.stringify(shell.visibleTexts(shared)) === JSON.stringify(["Crowd 0"]) && shared.Accessible.name === "10:00 Crowd 0" && JSON.stringify(shell.visibleTexts(part("block-t4"))) === JSON.stringify(["14:00 Review pull request #482"]), "a shared row drops the time (" + JSON.stringify([shell.visibleTexts(shared), shell.visibleTexts(part("block-t4"))]) + ")")) return false;
      // 23:59: the empty hours 18 to 22 fold into one dashed row.
      var crowdRows = timeline.children.filter(function(item) { return /^(hour|fold)-/.test(item.objectName); }).map(function(item) { return item.objectName; });
      var fold = part("fold-18");
      if (!check(JSON.stringify(crowdRows.slice(-3)) === JSON.stringify(["hour-17", "fold-18", "hour-23"]) && shell.find(fold, "hourLabel").text === "18–22", "the evening folds into 18–22 (" + JSON.stringify(crowdRows) + ")")) return false;
      // 23:59, scrolled into view: a click selects it.
      var late = part("block-late");
      pane.reveal(late);
      click(late);
      if (!check(view.paneTask === "late" && view.editor.visible && view.cursorRow() && view.cursorRow().id === "late", "a click on the 23:59 block selected it (" + view.paneTask + ")")) return false;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      return check(view.paneTask === "" && pane.visible, "Esc: the overview again");
    }, function() {
      // "+99 more": its first task selected, the list at it.
      var more = part("more-c01");
      pane.reveal(more);
      click(more);
      if (!check(view.paneTask === "c01" && view.cursorRow() && view.cursorRow().id === "c01", "a click on +99 more selected its first task (" + view.paneTask + ")")) return false;
      view.clearSelection();
      // A short pane, today's timed tasks past (no Next): the first block
      // is far down (the timeline has two hours, 09 and 10).
      store.snapshot = shell.snapshot(["t4"]);
      pane.height = Kit.FoamyStyle.rowHeight * 3;
      view.focusList();
      return true;
    }, function() {
      if (!check(!shown("overviewNext") && pane.scroll.contentHeight > pane.scroll.height * 1.5, "a short pane with no Next (" + JSON.stringify([pane.scroll.contentHeight, pane.scroll.height]) + ")")) return false;
      // Tab: the keys on the first block, and it shows.
      ev.keyClick(Qt.Key_Tab, Qt.NoModifier, -1);
      var first = part("block-t3");
      var top = first.mapToItem(pane.scroll, 0, 0).y;
      if (!check(first.activeFocus && top >= 0 && top + first.height <= pane.scroll.height, "Tab: the first block has the keys, inside the view (" + JSON.stringify([top, first.height, pane.scroll.height, pane.scroll.contentY]) + ")")) return false;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      pane.height = Qt.binding(function() { return view.editor.height; });
      store.snapshot = shell.snapshot();
      pane.scroll.contentY = 0;
      return check(!pane.activeFocus && Math.abs(pane.height - view.editor.height) < 1, "Esc: the keys back to the list, the pane's height again");
    }, function() {
      // Tab: the keys on Next (the first stop), then the timeline; Esc gives
      // them back; Enter on Next selects its task.
      ev.keyClick(Qt.Key_Tab, Qt.NoModifier, -1);
      if (!check(part("nextTask").activeFocus && view.blocked, "Tab: the keys on Next")) return false;
      ev.keyClick(Qt.Key_Tab, Qt.NoModifier, -1);
      if (!check(part("block-t3").activeFocus, "Tab: the first block")) return false;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(!pane.activeFocus && !view.blocked && one.opened, "Esc: the keys back to the list")) return false;
      ev.keyClick(Qt.Key_Tab, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
      if (!check(view.paneTask === "t4" && view.editor.visible && !view.blocked && view.cursorRow().id === "t4", "Enter on Next selected t4, the keys with the list")) return false;
      view.clearSelection();
      // A project (with more tasks than fit, so the list can scroll).
      many = shell.snapshot();
      for (var i = 0; i < 30; i++) {
        many.tasks.push(Fixtures.task("w" + i, "Work item " + i, "work", { section_id: "s-review", child_order: 100 + i }));
        many.tasks.push(Fixtures.task("m" + i, "Later item " + i, "home", { due: Fixtures.due(Fixtures.shift(shell.today, 3)), child_order: 100 + i }));
      }
      store.snapshot = many;
      view.setView("project", "work");
      return true;
    }, function() {
      var workTexts = shell.visibleTexts(pane);
      if (!check(pane.summary.kind === "list" && inOrder(workTexts, ["Sections", "(No section)", "2", "Review", "31", "Ops", "3", "Launch", "1", "When", "1 overdue", "2 today", "Labels", "@code", "@office"]) && shown("subproject-launch"), "the project's overview (" + JSON.stringify(workTexts) + ")")) return false;
      click(part("section-s-review"));
      if (!check(headerOnTop(function(entry) { return entry.title === "Review"; }), "a section: the list at its heading (" + JSON.stringify([view.list.contentY, view.list.contentHeight]) + ")")) return false;
      click(part("section-none"));
      if (!check(view.list.contentY === 0, "(No section): the list at its top")) return false;
      // A label: the list searched for it (the label only).
      click(part("labelChip-office"));
      if (!check(view.searching && view.query === "@office" && view.field.text === "@office" && JSON.stringify(view.rows.filter(function(r) { return r.kind === "task"; }).map(function(r) { return r.id; })) === JSON.stringify(["t1"]) && pane.visible && pane.summary.kind === "list" && !shown("overviewSections") && wideStill(), "a label searched @office (" + JSON.stringify([view.query, view.rows.length]) + ")")) return false;
      view.leaveSearch();
      return true;
    }, function() {
      click(part("subproject-launch"));
      if (!check(view.view === "project" && view.projectId === "launch" && pane.visible, "a sub-project opened it")) return false;
      // The Inbox: no Sections part.
      view.setView("inbox");
      if (!check(pane.visible && !shown("overviewSections") && shown("overviewWhen") && shown("labelChip-errand"), "the Inbox's overview")) return false;
      // A label of 60 characters.
      var longLabel = store.snapshot;
      longLabel = JSON.parse(JSON.stringify(longLabel));
      longLabel.tasks.push(Fixtures.task("lng", "Long label", "inbox", { labels: [shell.longLabel] }));
      store.snapshot = longLabel;
      return true;
    }, function() {
      // Its chip at most the part's width: the name elided, the count
      // shown, the full name as the tooltip and the accessible name.
      var chip = part("labelChip-" + shell.longLabel);
      var name = shell.find(chip, "chipName");
      var count = shell.find(chip, "chipCount");
      var tip = chip.tip;
      var flow = chip.parent;
      var countEnd = count.mapToItem(chip, 0, 0).x + count.width;
      if (!check(chip.visible && chip.width <= flow.width && chip.x >= 0 && chip.x + chip.width <= flow.width + 1 && name.truncated && count.visible && count.text === "1" && countEnd <= chip.width && count.mapToItem(chip, 0, 0).x >= name.mapToItem(chip, 0, 0).x + name.width, "the long label's chip fits, its count shows (" + JSON.stringify([chip.width, flow.width, name.width, countEnd]) + ")")) return false;
      if (!check(chip.Accessible.name === "@" + shell.longLabel && tip.text === "@" + shell.longLabel && !tip.visible, "the full name as the accessible name and the tooltip")) return false;
      ev.mouseMove(chip, chip.width / 2, chip.height / 2, -1, Qt.NoButton, Qt.NoModifier);
      // The tooltip shows after its delay.
      return [function() { return chip.hovered && tip.visible; }, "hover shows the tooltip"];
    }, function() {
      // The whole name inside the tooltip, wrapped though it is one word.
      var longChip = part("labelChip-" + shell.longLabel);
      var tipText = longChip.tip.contentItem;
      if (!check(tipText.contentWidth <= tipText.width + 1 && tipText.lineCount > 1 && longChip.tip.width <= view.paneWidth + 1, "the tooltip wraps the one-word name inside it (" + JSON.stringify([tipText.contentWidth, tipText.width, tipText.lineCount, longChip.tip.width]) + ")")) return false;
      // A short name: whole, no tooltip.
      var errand = part("labelChip-errand");
      ev.mouseMove(errand, errand.width / 2, errand.height / 2, -1, Qt.NoButton, Qt.NoModifier);
      if (!check(!shell.find(errand, "chipName").truncated && !errand.tip.visible, "a short label: whole, no tooltip")) return false;
      ev.mouseMove(view.band, 10, 10, -1, Qt.NoButton, Qt.NoModifier);
      store.snapshot = many;
      view.setView("upcoming");
      return true;
    }, function() {
      // Upcoming: tomorrow lit; a day lights and scrolls the list to it.
      // Its day names stand alone: a capital, also in Norwegian, where the
      // locale writes them in lower case.
      var dayNames = function() { return ["19", "20", "21"].map(function(d) { return shell.visibleTexts(part("day-2026-11-" + d)).slice(-1)[0]; }); };
      if (!check(JSON.stringify(dayNames()) === JSON.stringify(["Thu", "Fri", "Sat"]), "Upcoming's day names (" + JSON.stringify(dayNames()) + ")")) return false;
      shell.pickLanguage("no");
      return [function() { return dayNames()[0] !== "Thu"; }, "the overview in Norwegian"];
    }, function() {
      var norwegianDays = shell.visibleTexts(part("day-2026-11-19")).slice(-1)[0];
      if (!check(norwegianDays === "Tor.", "Norwegian day names start with a capital (" + norwegianDays + ")")) return false;
      shell.pickLanguage("en");
      return [function() { return shell.visibleTexts(part("day-2026-11-19")).slice(-1)[0] === "Thu"; }, "the overview in English again"];
    }, function() {
      var upTexts = shell.visibleTexts(pane);
      var day19 = part("day-2026-11-19");
      var day21 = part("day-2026-11-21");
      if (!check(pane.summary.kind === "upcoming" && day19.current && !day21.current && part("day-2026-11-25") !== null && inOrder(upTexts, ["Next 7 days", "2", "0", "31", "Next deadline", "Send the quarterly report to Finance", "Saturday · in 3 days", "35 tasks have no date and don't show here"]), "Upcoming's overview (" + JSON.stringify(upTexts) + ")")) return false;
      click(day21);
      if (!check(view.upcomingDay === "2026-11-21" && day21.current && !day19.current && headerOnTop(function(entry) { return entry.dayKey === "2026-11-21"; }), "a day: lit, the list at its heading (" + view.upcomingDay + ")")) return false;
      // The next deadline: its task, overdue, so Overdue unfolds for its row.
      click(part("deadlineTask"));
      if (!check(view.paneTask === "t1" && view.overdueOpen && view.cursorRow() && view.cursorRow().id === "t1" && view.editor.visible, "the next deadline selected t1, Overdue open")) return false;
      view.clearSelection();
      // Search: When and Labels of the results; none at all: the zero.
      view.startSearch();
      view.field.text = "parcel";
      view.query = "parcel";
      if (!check(pane.visible && !shown("overviewSections") && shown("labelChip-errand"), "search's overview")) return false;
      view.field.text = "zzzz";
      view.query = "zzzz";
      var noneTexts = shell.visibleTexts(pane);
      if (!check(JSON.stringify(noneTexts) === JSON.stringify([]) && !shown("overviewWhen"), "no results: When is left out, no zero (" + JSON.stringify(noneTexts) + ")")) return false;
      view.leaveSearch();
      store.snapshot = shell.snapshot();
      view.setView("today");
      view.clearSelection();
      view.focusList();
      ev.mouseMove(view.band, 10, 10, -1, Qt.NoButton, Qt.NoModifier);
      return check(pane.visible && wideStill(), "Today's overview again, 880 throughout");
    }];
    // A stage returns true to go on, or [condition, what] to go on once
    // the condition holds.
    var run = function() {
      if (!stages.length) { done(); return; }
      var stage = stages.shift();
      shell.afterFrame(view, function() {
        var next = stage();
        if (Array.isArray(next))
          wait.waitFor(next[0], 5000, function(ok) { if (check(ok, next[1])) run(); });
        else if (next)
          run();
      });
    };
    // The card grows or shrinks to new content in an animation.
    var settled = [function() { return Math.abs(one.popup.drawnHeight - one.popup.contentHeight) < 1; }, "the card's height settled"];
    run();
  }
  function builtRows(view) {
    return view.list.contentItem.children.filter(function(item) { return item.hasOwnProperty("entry") && item.visible && item.isTask; });
  }
  function highlighted(view) {
    return shell.builtRows(view).filter(function(row) { return row.hasCursor; });
  }
  FloatingWindow {
    implicitWidth: 1920; implicitHeight: 1080
    ScreenSim { }
    Item {
      id: frameProbe
      Connections {
        target: frameProbe.Window.window
        function onFrameSwapped() {
          shell.frames++;
          if (shell.frames < shell.drawTarget) frameProbe.Window.window.update();
        }
      }
    }
    Loader {
      id: oneLoader
      active: shell.panelsAlive
      x: 1400; y: 4; width: 60; height: 26
      sourceComponent: Plugin.Panel { settings: shell.entry }
      onLoaded: { item.bar = bar; item.moduleName = "foamy.todoist"; }
    }
    Loader {
      id: twoLoader
      active: shell.panelsAlive
      x: 1470; y: 4; width: 60; height: 26
      sourceComponent: Plugin.Panel { settings: shell.entry }
      onLoaded: { item.bar = bar; item.moduleName = "foamy.todoist"; }
    }
    // A row on its own, to give it one entry after another (as a reused
    // delegate gets them). In the window, away from the bars' popups, so
    // the pointer can hover it.
    Plugin.TaskRow {
      id: probeRow
      x: 0; y: 1000
      width: 400
      height: 42
      entry: shell.probeEntry({})
    }
  }
  function probeEntry(extra) {
    return Object.assign({ kind: "task", key: "task:p", id: "p", text: "Gjøre ting", priority: 1, priorityRole: "muted", depth: 0,
      dueDay: "", dueTime: "", dateKind: "", overdue: false, recurring: false, showProject: false, projectName: "", projectRole: "muted",
      labels: [], struck: false, unconfirmed: false, assignee: "", detail: false }, extra);
  }
  MockBar {
    id: bar
    onSavedChanged: if (saved.length) shell.entry = saved[saved.length - 1].settings
  }
  Component.onCompleted: {
    var store = Plugin.TodoStore;
    store.helperCommand = function(args) {
      return ["sh", "-c", Quickshell.env("FAKE_HELPER"), "fake-helper"].concat(args);
    };
    store.now = function() { return new Date(shell.clock.at.getTime()); };
    store.updateToday();
    shell.advance();
  }
  Connections {
    target: Plugin.TodoStore
    function onAddFinished(request, ok, message) { shell.settled = shell.settled.concat([{ request: request, ok: ok, message: message }]); }
    function onDescriptionChanged() {
      var d = Plugin.TodoStore.description;
      if (d.state === "loading" && d.id === "t1" && shell.readAt === 0) shell.readAt = Date.now();
    }
  }
  function gate(n) {
    var store = Plugin.TodoStore;
    var view = one ? one.popup.bodyItem : null;
    switch (n) {
    case 0: return [function() { return store.account === "signed_out" && !store.busy; }, 15000, "the first status"];
    case 1: return [function() { return one.popup.bodyItem !== null; }, 10000, "the popup opened"];
    case 2: return [function() { return store.signedIn && store.syncing && shell.held("sync"); }, 15000, "signed in, the first sync held"];
    case 3: return [function() { return store.loaded && !store.busy; }, 15000, "the first sync"];
    // Reopened, the list first builds the rows of its closed height; the
    // rest come when the popup's own window lays it out, which can be
    // after the frames advance() waits for (another window's).
    case 4: return [function() { return view && view.active && shell.builtRows(view).length >= 6; }, 10000, "the reopened popup built its today rows"];
    case 5: return [function() { return view.fieldFocused && view.band.fieldProgress === 1; }, 10000, "the field has the keys, grown"];
    case 6: return [function() { return view.fieldFocused; }, 10000, "a opened the field"];
    case 9: return [function() { return shell.calls("apply").length === 1 && !store.busy && Object.keys(store.sending).length === 0; }, 15000, "the completion was sent when the undo window ended"];
    case 10: return [function() { return shell.calls("apply").length >= 2 && !store.busy; }, 15000, "the move to tomorrow was sent"];
    case 12: return [function() { return view.view === "upcoming" && view.list.count > 0; }, 10000, "Upcoming shown"];
    case 13: return [function() { return view.fieldFocused; }, 10000, "the field opened in Upcoming"];
    case 15: return [function() { return shell.calls("add").length === shell.callsBefore + 1 && !view.addBusy && !store.busy; }, 15000, "the add from the field"];
    case 17: return [function() { var opened = shell.ipcPanel && shell.ipcPanel.popup.bodyItem; return opened && opened.active && opened.fieldFocused; }, 10000, "the popup opened by IPC add"];
    case 18: return [function() { return store.error !== "" && !store.busy; }, 15000, "the failed sync"];
    case 19: return [function() { return one.wide && view.wide && one.popup.contentWidth === one.cardWidth; }, 10000, "the wide setting, the card's width settled"];
    case 20: return [function() { return store.model.truncated && !store.busy; }, 15000, "a truncated snapshot"];
    case 21: return [function() { return !!store.unconfirmed && store.unconfirmed.t2 === true && store.syncing && shell.held("sync"); }, 15000, "a failed completion is unconfirmed while the sync is held"];
    case 22: return [function() { return !store.busy && !store.unconfirmed.t2; }, 15000, "the sync after the failed completion"];
    case 23: return [function() { return view && !view.addBusy && store.retryUntil > Date.now(); }, 15000, "the rate-limited add"];
    case 24: return [function() { return !store.busy && !view.addBusy && Object.keys(store.sending).length === 0; }, 5000, "the jobs refused while rate limited settled"];
    case 25: return [function() { return store.account === "signed_out" && !store.busy && !view.addBusy; }, 20000, "signed out with a full queue"];
    case 26: return [function() { return !store.tokenBusy && store.tokenError !== ""; }, 15000, "the refused token"];
    case 27: return [function() { return store.signedIn && store.loaded && !store.busy; }, 15000, "signed in again"];
    case 28: return [function() { return shell.calls("add").length >= 1 && !view.addBusy && !store.busy; }, 15000, "an add after signing in again"];
    case 29: return [function() { return one === null && two === null && !store.polling && shell.held("sync"); }, 15000, "the bars gone, the sync held"];
    case 30: return [function() { return one !== null && two !== null && Kit.FoamyShared.memberCount("todoist") === 2; }, 10000, "the bar is back"];
    case 31: return [function() { return view && view.active; }, 10000, "the popup for autocomplete"];
    case 32: return [function() { return view.fieldFocused && view.band.fieldProgress === 1; }, 10000, "the add field for autocomplete, grown"];
    case 33: return [function() { return shell.calls("add").length === shell.callsBefore + 1 && !view.addBusy && !store.busy; }, 15000, "the add after autocomplete"];
    case 34: return [function() { return view.fieldFocused; }, 10000, "the add field for sections and people"];
    case 35: return [function() { return shell.opened().length === 1 && !store.launchRunning; }, 15000, "the footer opened Todoist"];
    case 36: return [function() { return shell.opened().length === 2 && !store.launchRunning; }, 15000, "Ctrl+O opened a task with the open command"];
    case 37: return [function() { return shell.opened().length === 3 && !store.launchRunning; }, 15000, "Open in Todoist with the command, the link appended"];
    case 38: return [function() { return store.launchError !== "" && !store.launchRunning; }, 15000, "a launch that failed"];
    case 39: return [function() { return store.launchError === "" && shell.opened().length === 5 && !store.launchRunning; }, 15000, "the next launch worked"];
    case 40: return [function() { return store.openCommand === "" && one.wide === false && view && view.active && !view.wide && shell.calls("apply").length === shell.callsBefore + 1 && !store.busy; }, 10000, "the standard popup again, the completion sent"];
    case 41: return [function() { return view.fieldFocused; }, 10000, "the empty field, to click away from"];
    case 42: return [function() { return shell.clickedAway && view.view === "inbox" && view.fieldFocused; }, 10000, "the empty field again, in the Inbox"];
    case 43: return [function() { return view.fieldFocused; }, 10000, "the field for search and drafts"];
    case 44: return [function() { var v = one.popup.bodyItem; return one.opened && v && v.active && v.fieldFocused; }, 10000, "the reopened popup with the draft"];
    case 45: return [function() { var v = one.popup.bodyItem; return one.opened && v && v.active; }, 10000, "the reopened popup after Esc"];
    case 46: return [function() { return view.fieldFocused; }, 10000, "the field for a draft before search"];
    case 48: return [function() { return view.view === "today" && shell.builtRows(view).length >= 4; }, 10000, "Today again, on reused rows"];
    case 49: return [function() { return shell.headingsChecked && view.fieldFocused; }, 15000, "the headings checked, the field for an add that ends after closing"];
    case 50: return [function() { return !view.addBusy && !one.opened; }, 15000, "the add's reply, the popup closed"];
    case 51: return [function() { return one.opened && view.active; }, 10000, "the reopened popup"];
    case 52: return [function() { return shell.unseenChecked && view.fieldFocused; }, 15000, "the unseen failed add checked, the field for an add edited after submitting"];
    case 53: return [function() { return !view.addBusy && !one.opened; }, 15000, "the second add's reply"];
    case 54: return [function() { return one.opened && view.active && view.fieldFocused; }, 10000, "the reopened popup with the edit"];
    case 55: return [function() { return !view.addBusy && !store.busy && shell.calls("sync").length > shell.callsBefore; }, 15000, "an add with an unknown outcome, then a sync"];
    case 56: return [function() { return Kit.FoamyI18n.language === "no" && view.fieldFocused; }, 10000, "Norwegian"];
    case 57: return [function() { return !view.addBusy && !store.busy && shell.calls("add").length > shell.callsBefore; }, 15000, "the add with an unknown outcome in Norwegian"];
    case 58: return [function() { return shell.othersChecked && store.othersTasks === "hide" && Kit.FoamyI18n.language === "en"; }, 10000, "the setting shown, then back to hide"];
    case 59: return [function() { return view.fieldFocused; }, 10000, "the field for an add across two monitors"];
    case 60: return [function() { var v = two.popup.bodyItem; return two.opened && v && v.active && v.fieldFocused && shell.held("add"); }, 10000, "the other monitor's popup with the draft, the add held"];
    case 61: return [function() { var v = two.popup.bodyItem; return !store.busy && !v.addBusy && shell.calls("add").length > shell.callsBefore; }, 15000, "the add from the first monitor answered"];
    case 62: return [function() { return !store.busy; }, 15000, "the sync of the poll after midnight"];
    case 63: return [function() { return !store.busy && shell.calls("sync").length > shell.callsBefore; }, 15000, "a sync reply after another midnight"];
    case 65: return [function() { var v = one.popup.bodyItem; return one.opened && v && v.active && v.pref("afterAdd") === "keep"; }, 10000, "the popup with Keep the field open"];
    case 66: return [function() { return view.fieldFocused && view.band.fieldProgress === 1; }, 10000, "the add field (keep)"];
    case 67: return [function() { return shell.calls("add").length === shell.callsBefore + 1 && !view.addBusy && !store.busy; }, 15000, "the add with Enter (keep)"];
    case 68: return [function() { return shell.calls("add").length === shell.callsBefore + 6 && !store.addPending && !store.busy; }, 20000, "the add with Shift+Enter (keep)"];
    case 69: return [function() { return one.opened && view && view.active && view.pref("afterAdd") === "close" && shell.builtRows(view).some(function(r) { return r.entry.id === "t4"; }); }, 10000, "the popup for the editor"];
    case 70: return [function() { return view.pageShown && store.description.state === "ready" && store.description.id === "t4"; }, 15000, "the editor page with the description"];
    case 71: return [function() { return shell.calls("apply").length === shell.callsBefore + 1 && !store.busy && !view.editor.saving; }, 15000, "the text saved"];
    case 72: return [function() { return shell.calls("apply").length === shell.callsBefore + 2 && !store.busy && !view.editor.saving; }, 15000, "the refused date"];
    case 73: return [function() { return shell.calls("apply").length === shell.callsBefore + 3 && !store.busy && !view.editor.saving; }, 15000, "the date sent again"];
    case 74: return [function() { return shell.calls("apply").length === shell.callsBefore + 4 && !store.busy && !view.editor.saving; }, 15000, "the priority saved"];
    case 75: return [function() { return view.pageShown && store.description.state === "error"; }, 15000, "the failed description read"];
    case 76: return [function() { return store.description.state === "ready"; }, 15000, "the description read again"];
    case 77: return [function() { return store.current !== null && store.current.command === "task" && shell.held("task"); }, 15000, "the description read is held"];
    case 78: return [function() { return !store.busy; }, 15000, "the late reply came"];
    case 79: return [function() { return store.description.state === "ready" && store.description.id === "t7"; }, 15000, "t7's description"];
    case 80: return [function() { return view.active && !view.wide && !view.pageShown; }, 20000, "Small's list again"];
    case 81: return [function() { return one.size === "wide"; }, 40000, "a saved large: Wide"];
    case 82: return [function() { var v = one.popup.bodyItem; return one.opened && v && v.active && v.size === "wide" && one.popup.heightLive && Math.abs(one.popup.cardItem.width - 880) < 1; }, 10000, "the Wide popup, settled"];
    case 83: return [function() { return store.description.state === "ready" && store.description.id === "t1" && one.popup.contentWidth === 880 && Math.abs(one.popup.cardItem.width - 880) < 1; }, 15000, "the pane's description"];
    case 84: return [function() { var v = one.popup.bodyItem; return v.editor.contentField.inputActiveFocus && store.description.state === "ready" && store.description.id === v.paneTask && shell.opened().length > shell.openedBefore && !store.launchRunning; }, 10000, "e put the caret in the pane, the description read, Open launched"];
    case 85: return [function() { return shell.calls("apply").length === shell.callsBefore + 1 && !store.busy; }, 15000, "the pane's text saved as the selection moved"];
    case 86: return [function() { return one.popup.bodyItem.weekShown && shell.calls("apply").length === shell.callsBefore + 1 && !store.busy && one.popup.contentWidth === one.cardWidth; }, 20000, "the pane's text saved as the view changed, the card's width settled"];
    case 87: return [function() { return shell.calls("apply").length === shell.callsBefore + 1 && !store.busy; }, 15000, "Ctrl+→ sent"];
    case 88: return [function() { return one.popup.bodyItem.editor.contentField.inputActiveFocus && store.description.id === "t2" && store.description.state === "ready" && Math.abs(one.popup.drawnHeight - one.popup.contentHeight) < 1; }, 10000, "the caret in the week's pane, its description read, the card's height settled"];
    case 89: return [function() { return !one.opened && !one.popup.visible; }, 10000, "the Wide popup closed"];
    case 90: return [function() { var v = one.popup.bodyItem; return one.opened && v.active && Kit.FoamyI18n.language === "no" && v.paneTask === "t1" && store.description.id === "t1" && store.description.state === "ready"; }, 15000, "Wide again, in Norwegian"];
    case 91: return [function() { return shell.calls("apply").length === shell.callsBefore + 1 && !store.busy && Kit.FoamyI18n.language === "en"; }, 15000, "the pane's text saved as the popup closed"];
    case 92: return [function() { var v = one.popup.bodyItem; return one.opened && v.active && Kit.FoamyI18n.rightToLeft && v.size === "wide" && v.rows.length > 0 && one.popup.contentWidth === 880; }, 15000, "Wide in Arabic"];
    case 93: return [function() { return one.popup.bodyItem.paneShown; }, 10000, "Arabic: a task in the pane"];
    case 94: return [function() { return one.popup.bodyItem.weekShown; }, 10000, "Arabic: the Week view"];
    case 95: return [function() { return !one.popup.visible && Kit.FoamyI18n.language === "en" && !Kit.FoamyI18n.rightToLeft; }, 10000, "the Arabic popup closed, English again"];
    case 96: return [function() { var v = one.popup.bodyItem; return one.opened && v.active && v.size === "wide" && one.popup.heightLive; }, 10000, "the Wide popup"];
    case 97: return [function() { var l = shell.leader(); var v = l.popup.bodyItem; return l.opened && v && v.active && v.size === "wide" && Math.abs(l.popup.cardItem.width - 880) < 1; }, 10000, "the Wide popup from IPC"];
    case 98: return [function() { var l = shell.leader(); var v = l.popup.bodyItem; return v.fieldFocused && v.band.fieldProgress === 1 && l.popup.heightLive; }, 10000, "IPC add in the open Wide popup"];
    case 99: return [function() { return one.size === "standard" && one.prefs.value("openOn") === "last" && one.prefs.value("panelWidth") === "standard"; }, 10000, "Small, Open on: Last view"];
    case 100: return [function() { var v = one.popup.bodyItem; return one.opened && v && v.active; }, 10000, "the popup on the last view"];
    case 101: return [function() { return one.prefs.value("openOn") === "today" && !store.busy && store.signedIn && store.loaded; }, 15000, "Open on: Today again, signed in and idle, before a held sync"];
    case 102: return [function() { return store.current !== null && store.current.command === "sync" && shell.held("sync"); }, 15000, "the sync is held"];
    case 103: return [function() { return store.current !== null && store.current.command === "token-clear" && shell.held("token-clear"); }, 15000, "the old sync's reply came, the sign-out is held"];
    case 104: return [function() { return store.account === "signed_out" && !store.busy; }, 15000, "signed out"];
    case 105: return [function() { return store.signedIn && store.loaded && !store.busy; }, 15000, "signed in again after the sign-out"];
    case 106: return [function() { return store.account === "signed_out" && !store.busy; }, 15000, "a SIGNED_OUT reply signed out"];
    case 107: return [function() { var v = one.popup.bodyItem; return one.opened && v && v.active; }, 10000, "the popup while signed out elsewhere"];
    case 108: return [function() { return store.account === "error" && !store.busy && shell.calls("status").length === shell.callsBefore + 2; }, 15000, "Retry checked the account again, which refused the stored value"];
    case 109: return [function() { return store.account === "signed_out" && !store.busy && !store.tokenBusy; }, 15000, "signed out from the account error"];
    case 110: return [function() { return store.signedIn && store.current !== null && store.current.command === "sync" && shell.held("sync"); }, 15000, "a token stored with a warning, its sync held"];
    case 111: return [function() { return store.signedIn && store.loaded && !store.busy; }, 15000, "signed in again after the SIGNED_OUT reply"];
    case 112: return [function() { return !store.tokenBusy && store.tokenError !== "" && store.signedIn && store.loaded && !store.busy; }, 15000, "a sign-out the keyring refused"];
    case 113: return [function() { return store.error === "Todoist didn't answer in time." && !store.busy; }, 15000, "a sync that timed out"];
    case 114: return [function() { return store.error === "The Todoist helper failed." && !store.busy; }, 15000, "a sync with a reply that isn't JSON"];
    case 115: return [function() { return store.error === "" && store.loaded && !store.busy; }, 15000, "a good sync again"];
    case 116: return [function() { return one.prefs.value("barCount") === "today"; }, 10000, "the bar count back on"];
    case 117: return [function() { var v = one.popup.bodyItem; return one.opened && v && v.active && shell.builtRows(v).some(function(r) { return r.entry.id === "t3"; }); }, 10000, "the popup with marked-up task text"];
    case 118: return [function() { var v = one.popup.bodyItem; return v && v.editor.visible && v.editor.taskId === "t3" && store.description.state === "ready" && store.description.id === "t3"; }, 10000, "the marked-up task on its page"];
    case 119: return [function() { var v = one.popup.bodyItem; return one.size === "wide" && one.opened && v && v.active && v.size === "wide" && v.rows.length > 0; }, 40000, "Wide again, for the moves' edges"];
    case 120: return [function() { return !Model.has(store.movesSent, "t1") && shell.calls("sync").length > shell.callsBefore; }, 15000, "the failed move settled, a sync after it"];
    case 121: return [function() { return store.account === "unavailable"; }, 15000, "the helper unavailable"];
    }
    return null;
  }
  // Two frames, so layouts and deferred calls of the last step are done,
  // then the next step's gate, then the step.
  function advance() {
    if (shell.finished) return;
    if (!frameProbe.Window.window) {
      wait.waitFor(function() { return frameProbe.Window.window; }, 10000, function(ok) { if (check(ok, "the window exists")) shell.advance(); });
      return;
    }
    shell.drawTarget = shell.frames + 2;
    // Keys go to the active window (the panel's focus needs it).
    frameProbe.Window.window.requestActivate();
    frameProbe.Window.window.update();
    wait.waitFor(function() { return shell.frames >= shell.drawTarget; }, 10000, function(ok) {
      if (!check(ok, "step " + shell.step + ": frames were drawn")) return;
      var gate = shell.gate(shell.step) || [function() { return true; }, 0, ""];
      wait.waitFor(gate[0], gate[1], function(ready) {
        var store = Plugin.TodoStore;
        if (!check(ready, "step " + shell.step + ": " + gate[2] + ": not true after " + gate[1] + " ms (account " + store.account + ": " + store.accountError + "; error " + store.error + "; calls " + JSON.stringify(shell.calls()) + ")")) return;
        shell.run();
        shell.advance();
      });
    });
  }
  function run() {
    var store = Plugin.TodoStore;
    var view = one ? one.popup.bodyItem : null;
    var button = one ? one.children.find(function(item) { return item.objectName === "todoistButton"; }) : null;
    switch (shell.step++) {
    case 0:
      // Signed out: the bar is the icon alone.
      if (!check(Kit.FoamyShared.memberCount("todoist") === 2, "two monitor instances share the store")) return;
      if (!check(!one.barContent.countLabel.visible && button.tooltipText === "Todoist: not signed in", "no count while signed out (" + button.tooltipText + ")")) return;
      if (!check(!store.polling, "nothing polls while signed out")) return;
      // Todoist sends a fixed-zone due date in UTC with six fraction
      // digits: the panel's own JavaScript engine (not node's) must read it,
      // in local time.
      var utc = Model.dueOf({ date: "2026-11-18T23:30:00.000000Z" });
      var utcAt = new Date(Date.UTC(2026, 10, 18, 23, 30));
      // In a zone at UTC+0 a date read as local time looks right too.
      if (!check(utcAt.getTimezoneOffset() !== 0, "the run's time zone is not UTC (TZ " + Quickshell.env("TZ") + ")")) return;
      if (!check(utc !== null && utc.day === Model.dayKey(utcAt) && utc.minutes === utcAt.getHours() * 60 + utcAt.getMinutes(), "Qt's engine reads Todoist's UTC due dates (" + JSON.stringify(utc) + ")")) return;
      one.open();
      break;
    case 1:
      if (!check(shell.find(view, "stateText").text === "Add your Todoist API token in Settings", "signed out: the line (" + shell.find(view, "stateText").text + ")")) return;
      var open = shell.find(view, "stateButton");
      if (!check(open.visible && open.text === "Open settings", "signed out: Open settings")) return;
      if (!check(!view.field.visible && !view.footer.visible, "no field or footer while signed out")) return;
      if (!check(!view.band.menuButton.visible, "signed out: no ⋯ menu (nothing to open in Todoist)")) return;
      // The gear in its place is the same stop: Enter opens Settings.
      view.goTo(view.menuStop);
      view.activate(false);
      if (!check(view.editingSettings, "signed out: Enter on the gear opens Settings")) return;
      view.settingsClosed();
      if (!check(!view.editingSettings, "Back from Settings")) return;
      one.close();
      shell.put("reply-status.json", JSON.stringify({ ok: true, state: "signed_in", user: shell.snapshot().user }));
      shell.put("reply-sync.json", JSON.stringify(shell.snapshot()));
      shell.hold("sync");
      store.check();
      break;
    case 2:
      // The first sync answers once the popup has opened (the view asks
      // for a refresh as it turns active), so the open comes during it.
      one.open();
      wait.waitFor(function() { var v = one.popup.bodyItem; return v && v.active; }, 10000, function(opened) {
        if (!check(opened && store.syncing && shell.held("sync"), "the popup opened during the first sync")) return;
        shell.release("sync");
      });
      break;
    case 3:
      // The first sync was still running when the popup opened.
      if (!check(shell.calls("sync").length === 1, "one sync after signing in (" + JSON.stringify(shell.calls()) + ")")) return;
      one.close();
      shell.afterClose(function() { one.open(); });
      break;
    case 4:
      // Reopened: no field, no cursor; the band has +, Search and ⋯ (Settings in it).
      if (!check(!view.fieldFocused && !view.fieldOpen && view.cursor.index === -1 && !view.blocked, "nothing has the cursor on open (" + view.cursor.index + ")")) return;
      if (!check(shell.highlighted(view).length === 0, "no row highlight on open")) return;
      var actions = view.band.shownTrailing.map(function(item) { return item.objectName; });
      if (!check(JSON.stringify(actions) === JSON.stringify(["addAction", "searchAction"]) && view.band.settingsInMenu && view.band.menuButton.visible, "the band: +, Search, ⋯ (" + JSON.stringify(actions) + ", Settings in the menu " + view.band.settingsInMenu + ")")) return;
      var plus = shell.find(view.band, "addAction");
      // The icon-only + is named for a screen reader by its tooltip.
      if (!check(plus.Accessible.name === "Add a task", "+ is named Add a task (" + plus.Accessible.name + ")")) return;
      // Small: the tab names the view; the line starts with the date.
      if (!check(view.band.meta === "Wed 18 Nov · 6 left · 2 overdue", "the band's meta (" + view.band.meta + ")")) return;
      // Rows: the ring and the time on the title's line; an overdue date
      // with its warning mark and as a date (not a weekday); the deadline on
      // the line; the hash in the muted tone; today's times by tone.
      var rowById = function(id) { return shell.builtRows(view).find(function(r) { return r.entry.id === id; }); };
      var lateRow = rowById("t1");
      var ringOf = function(r) { var m = shell.find(r, "ringMark"); return m.mapToItem(r, 0, m.height / 2).y; };
      var titleOf = function(r) { var t = shell.find(r, "taskText"); return t.mapToItem(r, 0, t.height / 2).y; };
      if (!check(shell.find(lateRow, "taskDetail").visible && Math.abs(ringOf(lateRow) - titleOf(lateRow)) <= 1, "a two-line row: the ring on the title's line (" + JSON.stringify([ringOf(lateRow), titleOf(lateRow)]) + ")")) return;
      if (!check(shell.find(lateRow, "taskLateMark").visible && shell.find(lateRow, "taskDate").text === "Mon 16 Nov" && shell.find(lateRow, "taskDeadlineText").text === "Saturday", "overdue: the mark and the date; the deadline's day (" + JSON.stringify([shell.find(lateRow, "taskDate").text, shell.find(lateRow, "taskDeadlineText").text]) + ")")) return;
      var timed = rowById("t4");
      var timeTone = timed.entry.dueMinutes <= view.nowMinutes ? "late" : view.nextTimedId === "t4" ? "next" : "later";
      var timeLabel = shell.find(timed, "taskTime");
      if (!check(timed.timeTone === timeTone && Math.abs(timeLabel.mapToItem(timed, 0, timeLabel.height / 2).y - titleOf(timed)) <= 1, "14:00: its tone (" + timed.timeTone + ") and on the title's line")) return;
      // One number, as in foamy-zendesk: left today, in the bar's urgent colour.
      var count = one.barContent.countLabel;
      if (!check(count.visible && count.text === "6" && Qt.colorEqual(count.color, bar.urgent) && count.font.family === button.fontFamily, "the bar: 6 in the urgent colour (" + count.text + ", " + count.color + ", " + count.font.family + ")")) return;
      var texts = one.barContent.children.filter(function(item) { return item.visible && item.hasOwnProperty("text"); });
      if (!check(texts.length === 1, "no separate overdue number in the bar (" + texts.length + ")")) return;
      if (!check(button.tooltipText === "Todoist: 6 left today, 2 overdue", "the tooltip (" + button.tooltipText + ")")) return;
      // Nothing left today: the bar shows the mark alone, no "0".
      var full = store.snapshot;
      store.snapshot = Object.assign({}, full, { tasks: [] });
      if (!check(store.counts.today === 0 && one.barContent.countLabel.visible === false, "no count in the bar when nothing is left")) return;
      var emptyTabs = shell.find(view, "viewSwitch").model;
      if (!check(emptyTabs[0].count === -1 && emptyTabs[1].count === -1, "no 0 in the tabs either (" + emptyTabs[0].count + ", " + emptyTabs[1].count + ")")) return;
      store.snapshot = full;
      if (!check(one.barContent.countLabel.visible && one.barContent.countLabel.text === "6", "the count is back")) return;
      // A vertical bar has no room for the number: the mark alone.
      bar.position = "left";
      if (!check(!one.barContent.countLabel.visible, "no number on a vertical bar")) return;
      bar.position = "top";
      if (!check(one.barContent.countLabel.visible, "the number again on a horizontal bar")) return;
      var tabs = shell.find(view, "viewSwitch");
      if (!check(tabs.model[0].count === 4 && tabs.model[1].count === 6 && tabs.model[1].countUrgent === true, "the tabs' counts")) return;
      // ↓ from nothing: the first row; ↑: the tabs; ←, Enter: Inbox.
      view.moveRequested(0, 1);
      if (!check(view.cursor.index === view.firstRowStop && shell.highlighted(view).length === 1, "↓ lands on the first row (" + view.cursor.index + ")")) return;
      view.moveRequested(0, -1);
      if (!check(view.cursor.index === view.switchStop && tabs.hasCursor, "↑ from the first row reaches the tabs (" + view.cursor.index + ")")) return;
      view.moveRequested(-1, 0);
      view.returnRequested();
      view.activateRequested();
      if (!check(view.view === "inbox", "← and Enter on the tabs show Inbox (" + view.view + ")")) return;
      view.moveRequested(1, 0);
      view.activateRequested();
      if (!check(view.view === "today", "→ and Space show Today again (" + view.view + ")")) return;
      // ↑ from the tabs: ⋯, Search, +; Enter on +: the band field opens.
      view.moveRequested(0, -1);
      if (!check(view.cursor.index === view.menuStop && view.band.menuButton.hasCursor, "↑ from the tabs: ⋯ (" + view.cursor.index + ")")) return;
      view.moveRequested(0, -1);
      view.moveRequested(0, -1);
      if (!check(view.cursor.index === view.addStop && plus.hasCursor, "then Search, then + (" + view.cursor.index + ")")) return;
      view.returnRequested();
      view.activateRequested();
      break;
    case 5:
      if (!check(view.fieldOpen && view.band.fieldOpen && view.blocked && !view.band.buttonsActive, "Enter opened the band field, with the keys; the buttons are inert")) return;
      if (!check(view.field.placeholderText === "Add a task for today…", "the placeholder says where it goes (" + view.field.placeholderText + ")")) return;
      if (!check(view.field.font.pixelSize === Kit.FoamyStyle.font.title, "the field's text is the band title's size (" + view.field.font.pixelSize + ")")) return;
      // The footer shows the keys.
      var hints = shell.find(view, "keyHints");
      var hintTexts = [0, 1, 2].map(function(i) { return shell.find(hints, "keyHint" + i).label; });
      if (!check(hints.visible && JSON.stringify(hintTexts) === JSON.stringify(["add and close", "add, keep typing", "cancel"]) && !shell.find(view, "openTodoist").visible && !view.footer.refreshButton.visible, "the footer's keys while adding (" + JSON.stringify(hintTexts) + ")")) return;
      // Quick Add tokens in colour (dates not).
      for (var ch of "Buy #Home p1 tomorrow") ev.keyClickChar(ch, Qt.NoModifier, -1);
      var runs = view.field.runs;
      if (!check(view.field.runsShown && runs.length === 5 && runs[4].text === " tomorrow" && runs[4].color === undefined && runs[1].text === "#Home" && Qt.colorEqual(runs[1].color, view.tokenColors.project) && runs[3].text === "p1" && Qt.colorEqual(runs[3].color, view.tokenColors.priority) && runs[2].color === undefined, "the tokens are coloured (" + JSON.stringify(runs.map(function(r) { return r.text; })) + ")")) return;
      if (!check(shell.find(view, "suggestions").visible === false, "no list after a finished word")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(view.field.text === "" && view.fieldOpen && view.fieldFocused, "Esc with text clears it, the field stays")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(!view.fieldOpen && view.cursor.index === view.addStop && shell.find(view.band, "addAction").hasCursor && !view.blocked && one.opened && view.band.buttonsActive, "Esc when empty closes the field, the cursor on +")) return;
      // a: the field again, from anywhere.
      view.cursor.index = view.firstRowStop + 1;
      view.cursor.emitTextKey(view, "a");
      break;
    case 6:
      if (!check(view.fieldOpen && view.fieldFocused, "a opened the field")) return;
      // ↓ from an empty field: it closes (blur), the first row has the cursor.
      ev.keyClick(Qt.Key_Down, Qt.NoModifier, -1);
      if (!check(!view.fieldFocused && !view.fieldOpen && view.cursor.index === view.firstRowStop, "↓ closed the empty field and moved to the first row (" + view.cursor.index + ")")) return;
      var lit = shell.highlighted(view);
      if (!check(lit.length === 1 && lit[0].entry.id === "t1", "the first row has the cursor")) return;
      if (!check(!view.blocked, "the catcher has the keys again")) return;
      // Space: complete, the row stays struck with Undo.
      view.activateRequested();
      break;
    case 7:
      if (!check(store.struck.t1 === true && shell.highlighted(view)[0].struck && shell.find(shell.highlighted(view)[0], "undo").visible, "t1 is struck, with Undo")) return;
      // Space again: undone, nothing was sent.
      view.activateRequested();
      break;
    case 8:
      if (!check(!store.struck.t1 && shell.calls("apply").length === 0, "undo cancelled the completion; nothing sent")) return;
      shell.put("reply-apply.json", JSON.stringify(Object.assign(shell.snapshot(["t1"]), { results: { t1: "ok" } })));
      view.activateRequested();
      break;
    case 9:
      // One apply call with the close, after the undo window.
      var sent = shell.calls("apply")[0];
      var input = JSON.parse(sent.slice("apply ".length));
      if (!check(JSON.stringify(input) === JSON.stringify({ commands: [{ op: "close", id: "t1" }] }), "the apply call closes t1 (" + sent + ")")) return;
      if (!check(!view.rows.some(function(row) { return row.id === "t1"; }) && store.counts.today === 5, "t1 left the list and the count")) return;
      if (!check(view.cursor.index === view.firstRowStop && shell.highlighted(view)[0].entry.id === "t2", "the cursor moved to the next row")) return;
      // t: a recurring task stays, and the error line says why; another
      // one moves to tomorrow: it stays in place, shows Tomorrow and Undo,
      // and goes when the undo window ends.
      view.cursor.index = view.firstRowStop + 1;
      if (!check(shell.highlighted(view)[0].entry.recurring, "the second row is recurring")) return;
      view.cursor.emitTextKey(view, "t");
      if (!check(Object.keys(store.moves).length === 0 && store.error === "A repeating task can't be moved here: open it to change its date.", "t on a repeating task: not moved, the line says why (" + store.error + ")")) return;
      store.error = "";
      view.cursor.index = view.firstRowStop;
      view.cursor.emitTextKey(view, "t");
      var movedRow = shell.highlighted(view)[0];
      if (!check(movedRow.entry.id === "t2" && movedRow.moved && store.moves.t2 === Model.addDays(shell.today, 1) && shell.find(movedRow, "taskDate").text === "Tomorrow" && shell.find(movedRow, "undo").visible && shell.calls("apply").length === 1, "t: the row stays, says Tomorrow, with Undo; nothing sent yet")) return;
      break;
    case 10:
      var moves = shell.calls("apply");
      var due = JSON.parse(moves[1].slice("apply ".length));
      if (!check(moves.length === 2 && JSON.stringify(due) === JSON.stringify({ commands: [{ op: "due", id: "t2", date: Model.addDays(shell.today, 1) }] }), "t moved only t2, to tomorrow (" + JSON.stringify(moves) + ")")) return;
      // Alt+2 from the list and from the field: Today.
      view.setView("inbox");
      view.cursor.emitTextKey(view, "2", Qt.AltModifier);
      break;
    case 11:
      if (!check(view.view === "today", "Alt+2 in the list shows Today (" + view.view + ")")) return;
      view.setView("upcoming");
      break;
    case 12:
      // Upcoming, Wednesday 18 November: days to the end of the week, then
      // next week, later in November, December, January 2027.
      if (!check(view.band.meta === "3 tasks in the next 7 days", "the band's meta (" + view.band.meta + ")")) return;
      var heads = view.rows.filter(function(row) { return row.kind === "header"; });
      var built = function(key) { return view.list.contentItem.children.find(function(item) { return item.hasOwnProperty("entry") && item.visible && item.entry && item.entry.key === key; }); };
      var text = function(item, name) { var found = shell.find(item, name); return found && found.visible ? found.text : ""; };
      // The count stands beside its word, or after a date range at the end.
      var shown = function(head) { var item = built(head.key); return item ? [text(item, "headerTitle"), text(item, "headerSub"), text(item, "headerCount") + text(item, "headerCountInline"), shell.find(item, "headerDivider").visible] : null; };
      var countBeside = function(head) { var item = built(head.key); return !!item && !shell.find(item, "headerCount").visible && shell.find(item, "headerCountInline").visible && shell.find(item, "headerCountInline").mapToItem(item, 0, 0).x < item.width / 2; };
      var sunday = view.weekStart === 0;
      var expected = [
        ["Tomorrow", "Thursday 19 November", "", false],
        ["Saturday", "21 November", "", false],
        ["Next week", sunday ? "22–28 Nov" : "23–29 Nov", "1", true],
        ["Later in November", "", "1", true],
        ["December", "", "1", true],
        ["January 2027", "", "1", true],
      ];
      for (var k = 0; k < heads.length; k++) {
        view.list.positionViewAtIndex(view.rows.indexOf(heads[k]), ListView.Contain);
        view.list.forceLayout();
        if (!check(JSON.stringify(shown(heads[k])) === JSON.stringify(expected[k]), "heading " + k + " (" + JSON.stringify(shown(heads[k])) + ")")) return;
        if (expected[k][2] !== "" && !check(countBeside(heads[k]) === (expected[k][1] === ""), "heading " + k + ": the count beside its word unless a date range follows")) return;
      }
      // Trailing: weekday next week; weekday and date later; the time in mono.
      var trailOf = function(id) {
        view.list.positionViewAtIndex(view.rows.findIndex(function(row) { return row.id === id; }), ListView.Contain);
        view.list.forceLayout();
        var item = built("task:" + id);
        return [text(item, "taskTrailDay"), text(item, "taskTime")];
      };
      if (!check(JSON.stringify(trailOf("t13")) === JSON.stringify(["Fri", ""]) && JSON.stringify(trailOf("u2")) === JSON.stringify(["Mon 7", "10:30"]) && JSON.stringify(trailOf("t10")) === JSON.stringify(["", "10:00"]), "trailing day and time (" + JSON.stringify([trailOf("t13"), trailOf("u2"), trailOf("t10")]) + ")")) return;
      // The add date: the day group the cursor was last in, else tomorrow.
      var stopOf = function(id) { return view.stopOfRow[view.rows.findIndex(function(row) { return row.id === id; })]; };
      view.cursor.index = stopOf("t12");
      if (!check(view.addDay === "2026-11-21", "a Saturday task: add for Saturday (" + view.addDay + ")")) return;
      view.goTo(view.addStop);
      if (!check(view.addDay === "2026-11-21", "the add row keeps that day")) return;
      view.cursor.index = stopOf("t13");
      if (!check(view.addDay === "2026-11-19", "a next-week task: add for tomorrow (" + view.addDay + ")")) return;
      // The add field takes the cursor and keeps the day (it used to reset to tomorrow).
      view.cursor.index = stopOf("t12");
      view.openAdd();
      if (!check(view.adding && view.cursor.index === -1 && view.addDay === "2026-11-21" && view.field.placeholderText === "Add a task for Saturday 21 November…", "the add field keeps Saturday (" + view.field.placeholderText + ")")) return;
      view.closeField();
      view.clearSelection();
      if (!check(view.addDay === "2026-11-19", "the selection cleared: tomorrow (" + view.addDay + ")")) return;
      view.list.positionViewAtBeginning();
      view.openAdd();
      break;
    case 13:
      if (!check(view.fieldFocused && view.field.placeholderText === "Add a task for Thursday 19 November…", "Upcoming adds for tomorrow (" + view.field.placeholderText + ")")) return;
      ev.keyClick(Qt.Key_2, Qt.AltModifier, -1);
      break;
    case 14:
      if (!check(view.view === "today" && view.fieldFocused, "Alt+2 while typing shows Today and keeps the caret (" + view.view + ")")) return;
      shell.callsBefore = shell.calls("add").length;
      // A paste the band's field refuses: the line under the band says why.
      shell.refusedPaste("the band's field", view.field, function() { return shell.find(view, "errorLine"); }, null, function() {
        // Shift+Enter (with "Close the panel") adds and keeps the field open for the next task.
        shell.put("reply-add.json", JSON.stringify(Object.assign(shell.snapshot(), { added: "t1" })));
        for (var m of "Milk") ev.keyClickChar(m, Qt.NoModifier, -1);
        ev.keyClick(Qt.Key_Return, Qt.ShiftModifier, -1);
      });
      break;
    case 15:
      if (!check(view.fieldOpen && view.fieldFocused && view.field.text === "" && view.addError === "", "after an add the field stays open, focused and empty (" + view.addError + ")")) return;
      // With text, leaving the field keeps it open.
      ev.keyClickChar("x", Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Down, Qt.NoModifier, -1);
      break;
    case 16:
      if (!check(view.fieldOpen && !view.fieldFocused && view.field.text === "x", "a field with text stays open when it loses the keys")) return;
      view.field.text = "";
      view.closeField();
      // Search: "/" from the list opens the slot as a search field.
      view.cursor.index = view.firstRowStop;
      view.focusList();
      var viewRows = JSON.stringify(view.rows.map(function(row) { return row.key; }));
      var listBefore = view.listHeight;
      view.cursor.emitTextKey(view, "/");
      // Nothing typed yet: the view stays, its tab selected, the card as tall.
      if (!check(view.searching && !view.searchActive && JSON.stringify(view.rows.map(function(row) { return row.key; })) === viewRows && shell.find(view, "viewSwitch").value === view.view && view.listHeight === listBefore, "search opened: the view's rows and tab stay")) return;
      for (var c of "parcel") ev.keyClickChar(c, Qt.NoModifier, -1);
      if (!check(view.searching && view.fieldOpen && view.query === "parcel", "typing searches in the slot (" + view.query + ")")) return;
      var found = view.rows.map(function(row) { return row.kind === "task" ? row.id : row.title; });
      if (!check(JSON.stringify(found) === JSON.stringify(["Inbox", "t9"]), "search finds the parcel, grouped by project (" + JSON.stringify(found) + ")")) return;
      // The results: no tab selected, their count, the match bold in the
      // title, and a card never shorter than when search started.
      var parcelRow = shell.builtRows(view).find(function(r) { return r.entry.id === "t9"; });
      var parcelRuns = shell.find(parcelRow, "taskTextRuns");
      var boldRuns = parcelRuns.children.filter(function(run) { return run.text !== undefined && run.font.weight === Font.DemiBold; }).map(function(run) { return run.text; });
      var searchCount = shell.find(view, "searchCount");
      if (!check(shell.find(view, "viewSwitch").value === "" && searchCount.visible && searchCount.text === "1 task" && parcelRuns.visible && !shell.find(parcelRow, "taskText").visible && JSON.stringify(boldRuns) === JSON.stringify(["parcel"]) && view.listHeight === listBefore, "results: the count, the match bold, the card as tall (" + JSON.stringify([searchCount.text, boldRuns, view.listHeight, listBefore]) + ")")) return;
      // No match: why, and the query as a new task.
      for (var z of "zz") ev.keyClickChar(z, Qt.NoModifier, -1);
      var stateText = shell.find(view, "stateText");
      var addQuery = shell.find(view, "stateButton");
      if (!check(view.rows.length === 0 && stateText.text === "No open task matches “parcelzz”" && addQuery.visible && addQuery.text === "Add as a task" && view.listHeight === listBefore, "no match: why, Add as a task (" + JSON.stringify([stateText.text, addQuery.text]) + ")")) return;
      // The column places the new button at its next polish: now, for the click.
      shell.find(view, "stateBox").forceLayout();
      ev.mouseClick(addQuery, addQuery.width / 2, addQuery.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      if (!check(!view.searching && view.adding && view.fieldFocused && view.field.text === "parcelzz" && view.field.cursorPosition === 8, "Add as a task: the query in the add field (" + JSON.stringify(view.field.text) + ")")) return;
      view.field.text = "";
      view.closeField();
      // The field's × leaves search.
      view.startSearch();
      for (var c2 of "parcel") ev.keyClickChar(c2, Qt.NoModifier, -1);
      var searchClose = shell.find(view, "searchClose");
      ev.mouseClick(searchClose, searchClose.width / 2, searchClose.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      if (!check(!view.searching && !view.fieldOpen && view.query === "" && JSON.stringify(view.rows.map(function(row) { return row.key; })) === viewRows, "the field's × left search, the view's rows back")) return;
      view.cursor.index = view.firstRowStop;
      view.focusList();
      view.cursor.emitTextKey(view, "/");
      for (var c3 of "parcel") ev.keyClickChar(c3, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(view.searching && view.field.text === "", "Esc with text clears it")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(!view.searching && !view.fieldOpen && view.cursor.index === view.searchStop && one.opened, "Esc when empty leaves search, the cursor on Search")) return;
      // A long list: Small grows past the old 13 rows, up to the popup's
      // cap (70% of the screen); the rows fade out at an edge where the
      // list continues.
      var longList = shell.snapshot();
      for (var li = 0; li < 40; li++)
        longList.tasks.push(Fixtures.task("l" + li, "Long " + li, "home", { due: Fixtures.due(shell.today), child_order: 200 + li }));
      store.snapshot = longList;
      var smallList = view.list;
      var fadeTop = shell.find(view, "listFadeTop");
      var fadeBottom = shell.find(view, "listFadeBottom");
      if (!check(view.listHeight > Kit.FoamyStyle.rowHeight * 13 && one.popup.contentHeight <= Math.round(one.popup.screenH * 0.7) && fadeBottom.visible && !fadeTop.visible, "a long list: taller than 13 rows, under the cap, a fade at the bottom (" + JSON.stringify([view.listHeight, one.popup.contentHeight, one.popup.screenH]) + ")")) return;
      // Twice: the first pass builds the last rows, which corrects the
      // list's estimated height.
      smallList.positionViewAtEnd();
      smallList.forceLayout();
      smallList.positionViewAtEnd();
      if (!check(fadeTop.visible && !fadeBottom.visible, "scrolled to the end: the fade at the top only (" + JSON.stringify([smallList.contentY, smallList.contentHeight, smallList.height, smallList.originY, smallList.atYEnd]) + ")")) return;
      smallList.positionViewAtBeginning();
      store.snapshot = shell.snapshot();
      // Moving without typing. The cursor row shows Tomorrow and the menu
      // of days in its time's place (not on a repeating task).
      view.setView("today");
      // A new rows array rebuilds the delegates: lay them out, then look.
      var rowOf = function(id) { view.list.forceLayout(); return shell.builtRows(view).find(function(r) { return r.entry.id === id; }); };
      view.goTo(view.stopOf("t4"));
      var t4Row = rowOf("t4");
      var tomorrowAction = shell.find(t4Row, "tomorrowAction");
      if (!check(shell.find(t4Row, "rowActions").visible && tomorrowAction.visible && !shell.find(t4Row, "taskTime").visible, "the cursor row: Tomorrow and the date menu in the time's place")) return;
      view.goTo(view.stopOf("t3"));
      if (!check(!shell.find(rowOf("t3"), "rowActions").visible, "a repeating task has no actions")) return;
      view.goTo(view.stopOf("t4"));
      ev.mouseClick(tomorrowAction, tomorrowAction.width / 2, tomorrowAction.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      t4Row = rowOf("t4");
      if (!check(store.moves.t4 === Model.addDays(shell.today, 1) && shell.find(t4Row, "taskDate").text === "Tomorrow 14:00" && shell.find(t4Row, "undo").visible && !shell.find(t4Row, "rowActions").visible, "Tomorrow: the row says Tomorrow 14:00, with Undo (" + JSON.stringify([store.moves, shell.find(t4Row, "taskDate").text, shell.find(t4Row, "undo").visible, shell.find(t4Row, "rowActions").visible, t4Row.entry.id]) + ")")) return;
      var t4Undo = shell.find(t4Row, "undo");
      ev.mouseClick(t4Undo, t4Undo.width / 2, t4Undo.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      t4Row = rowOf("t4");
      if (!check(Object.keys(store.moves).length === 0 && !store.pending && shell.find(t4Row, "rowActions").visible && !shell.find(t4Row, "undo").visible, "Undo: the move is gone, nothing waits, the actions are back")) return;
      // The menu of days (a click on the row's calendar): in the card, its
      // picks move the task; d opens it from the keys.
      view.goTo(view.stopOf("t4"));
      var dateAction = shell.find(t4Row, "dateAction");
      ev.mouseClick(dateAction, dateAction.width / 2, dateAction.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      var dayMenu = view.dateMenuItem;
      if (!check(dayMenu.opened && dayMenu.overlayItem.parent === one.popup.cardItem && JSON.stringify(dayMenu.entries.filter(function(e) { return !e.separator; }).map(function(e) { return e.text; })) === JSON.stringify(["Today", "Tomorrow", "Next week", "No date"]) && view.blocked, "the date menu: in the card, Today, Tomorrow, Next week, No date")) return;
      dayMenu.activate(dayMenu.entries.findIndex(function(e) { return e.text === "No date"; }));
      t4Row = rowOf("t4");
      if (!check(!dayMenu.opened && store.moves.t4 === "" && shell.find(t4Row, "taskDate").text === "No date", "No date: the row says so, undoable")) return;
      store.undo("t4");
      view.focusList();
      view.cursor.emitTextKey(view, "d");
      if (!check(dayMenu.opened && dayMenu.currentIndex === 0, "d opens the menu from the keys")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      // T on an Overdue row: as the heading's Move to today; elsewhere nothing.
      view.goTo(view.stopOf("t4"));
      view.cursor.emitTextKey(view, "T", Qt.ShiftModifier);
      if (!check(Object.keys(store.moves).length === 0, "T on a row due today does nothing (" + JSON.stringify(store.moves) + ")")) return;
      view.goTo(view.stopOf("t2"));
      view.cursor.emitTextKey(view, "T");
      if (!check(Object.keys(store.moves).length === 0, "T without Shift (Caps Lock) does nothing (" + JSON.stringify(store.moves) + ")")) return;
      ev.keyClickChar("T", Qt.ShiftModifier, -1);
      if (!check(store.moves.t1 === shell.today && store.moves.t2 === shell.today && Object.keys(store.moves).length === 2, "Shift+T on an Overdue row: both overdue tasks (" + JSON.stringify(store.moves) + ")")) return;
      store.undo("t1");
      store.undo("t2");
      // A moved row still stands under Overdue: T there moves the others.
      store.moveToTomorrow("t2");
      ev.keyClickChar("T", Qt.ShiftModifier, -1);
      if (!check(store.moves.t1 === shell.today && store.moves.t2 === Model.addDays(shell.today, 1) && Object.keys(store.moves).length === 2, "Shift+T on a moved row under Overdue: the other overdue task (" + JSON.stringify(store.moves) + ")")) return;
      store.undo("t1");
      store.undo("t2");
      // Overdue's Move to today: its tasks, each with Undo.
      var moveAll = shell.find(view, "moveAllToToday");
      if (!check(moveAll.visible, "Today's Overdue heading offers Move to today")) return;
      ev.mouseClick(moveAll, moveAll.width / 2, moveAll.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      if (!check(store.moves.t1 === shell.today && store.moves.t2 === shell.today && Object.keys(store.moves).length === 2, "Move to today: both overdue tasks (" + JSON.stringify(store.moves) + ")")) return;
      store.move("t4", Model.addDays(shell.today, 1));
      // The undo window ends: one apply call, the time kept.
      shell.put("reply-apply.json", JSON.stringify(Object.assign(shell.snapshot(), { results: { t1: "ok", t2: "ok", t4: "ok" } })));
      store.flushCompletions();
      var moveJob = [store.current].concat(store.queue).find(function(job) { return !!job && job.command === "apply"; });
      var moveInput = moveJob ? JSON.parse(moveJob.input) : null;
      var t4Raw = shell.snapshot().tasks.find(function(t) { return t.id === "t4"; }).due.date;
      if (!check(moveInput && JSON.stringify(moveInput.commands) === JSON.stringify([{ op: "due", id: "t1", date: shell.today }, { op: "due", id: "t2", date: shell.today }, { op: "due", id: "t4", date: Model.addDays(shell.today, 1) + t4Raw.slice(10) }]) && t4Raw.length > 10, "the moves go in one call; t4 keeps its time (" + (moveJob ? moveJob.input : "none") + ")")) return;
      // IPC add: the popup opens with the field open and focused.
      one.close();
      shell.afterClose(function() {
        // One handler per shell: the leading monitor's instance.
        var handler = one.data.concat(two.data).find(function(item) { return item.target === "foamy.todoist" && item.enabled && typeof item.add === "function"; });
        shell.ipcPanel = one.data.indexOf(handler) >= 0 ? one : two;
        handler.add();
      });
      break;
    case 17:
      var ipcView = shell.ipcPanel.popup.bodyItem;
      if (!check(shell.ipcPanel.opened && ipcView.fieldOpen && ipcView.fieldFocused && !ipcView.searching, "IPC add opened the field, focused")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(!ipcView.fieldOpen, "Esc closed it")) return;
      shell.ipcPanel.close();
      one.open();
      // A sync that fails keeps the data and says why.
      shell.put("reply-sync.json", JSON.stringify({ ok: false, code: "NETWORK", error: "Can't reach Todoist. Check your connection." }));
      shell.callsBefore = shell.calls("sync").length;
      store.sync();
      break;
    case 18:
      var line = shell.find(view, "errorLine");
      if (!check(line.visible && line.text === "Can't reach Todoist. Check your connection.", "the error line says what failed (" + line.text + ")")) return;
      if (!check(store.loaded && view.rows.length > 0 && view.footer.status.indexOf("Updated") === 0, "the cached tasks stay, with the old Updated time (" + view.footer.status + ")")) return;
      if (!check(store.failures === 1, "one failure counted")) return;
      one.prefs.save("panelWidth", "wide");
      break;
    case 19:
      if (!check(view.width > 540 && shell.find(view, "rail").visible, "wide: the rail shows (" + view.width + ")")) return;
      if (!check(!view.band.fieldShown && !shell.find(view, "viewSwitch").visible, "wide: the title row in the band, no tabs")) return;
      if (!check(shell.find(view, "rail-week") !== null, "wide: Week in the rail")) return;
      // No task selected: the pane shows the overview; the card is 880
      // under the button.
      if (!check(one.wideWidth === 880 && view.overviewShown && shell.find(view, "overview").visible && !view.editor.visible && view.paneTask === "" && shell.popupPlacement(one, 880) === "", "wide, no task: the overview in the pane, the card 880 under the button (" + shell.popupPlacement(one, 880) + ")")) return;
      if (!check(shell.find(view, "rail-work") !== null && shell.find(view, "rail-launch") !== null, "wide: the projects are in the rail")) return;
      // A snapshot the helper had to cut: a muted line says so.
      shell.put("reply-sync.json", JSON.stringify(Object.assign(shell.snapshot(), { truncated: true })));
      store.sync();
      break;
    case 20:
      var cut = shell.find(view, "truncatedLine");
      if (!check(cut.visible && cut.text === shell.truncatedText, "the truncated line shows (" + cut.text + ")")) return;
      if (!check(!shell.find(view, "errorLine").visible, "it is not an error")) return;
      view.startSearch();
      view.field.text = "zzzz";
      view.query = "zzzz";
      if (!check(shell.find(view, "stateText").text === shell.truncatedText, "an empty search doesn't claim nothing matches (" + shell.find(view, "stateText").text + ")")) return;
      view.leaveSearch();
      // A completion whose apply call fails as a whole: unknown, so unconfirmed until a snapshot.
      shell.put("reply-sync.json", JSON.stringify(shell.snapshot()));
      shell.hold("sync");
      shell.put("reply-apply.json", JSON.stringify({ ok: false, code: "NETWORK", error: "Can't reach Todoist. Check your connection." }));
      shell.callsBefore = shell.calls("sync").length;
      view.setView("today");
      store.complete("t2");
      store.flushCompletions();
      break;
    case 21:
      var row = view.rows.find(function(r) { return r.id === "t2"; });
      if (!check(row && row.unconfirmed, "t2 is shown, marked unconfirmed")) return;
      // It reads whole, not dimmed: the title in the secondary tone, a
      // plain 1 px ring, a refresh mark in the time's place that says why.
      var pendingRow = shell.builtRows(view).find(function(r) { return r.entry.id === "t2"; });
      var pendingSurface = shell.find(pendingRow, "taskSurface");
      var pendingTitle = shell.find(pendingRow, "taskText");
      var pendingRing = shell.find(pendingRow, "ringMark");
      var checking = shell.find(pendingRow, "taskChecking");
      if (!check(pendingRow.opacity === 1 && pendingSurface.opacity === 1 && shell.find(pendingRow, "taskDetail").opacity === 1, "the unconfirmed row isn't dimmed (" + [pendingRow.opacity, pendingSurface.opacity] + ")")) return;
      if (!check(shell.sameColor(pendingTitle.color, Kit.FoamyPalette.secondaryText) && shell.ringIs(pendingRing, 1, 0) === "", "its title in the secondary tone, a plain ring (" + pendingTitle.color + " vs " + Kit.FoamyPalette.secondaryText + ", " + shell.ringIs(pendingRing, 1, 0) + ")")) return;
      // It can't complete: no pointing hand over its ring.
      if (!check(shell.find(pendingRow, "ring").cursorShape === Qt.ArrowCursor, "the unconfirmed ring has the plain cursor (" + shell.find(pendingRow, "ring").cursorShape + ")")) return;
      var checkingTip = shell.tipOf(checking, "taskCheckingTip");
      var checkingEnd = checking.mapToItem(pendingSurface, 0, 0).x + checking.width;
      if (!check(checking.visible && checking.name === "refresh-cw" && checkingEnd <= pendingSurface.width && checking.mapToItem(pendingSurface, 0, 0).x > pendingTitle.mapToItem(pendingSurface, 0, 0).x + pendingTitle.width, "the refresh mark in the trailing slot")) return;
      ev.mouseMove(checking, checking.width / 2, checking.height / 2, -1, Qt.NoButton, Qt.NoModifier);
      // The sync stays held (gate 22 waits for it) until this is done.
      wait.waitFor(function() { return checkingTip.visible; }, 5000, function(hovered) {
        if (!check(hovered && checkingTip.text === "Checking with Todoist…", "its tooltip says why (" + checkingTip.text + ")")) return;
        ev.mouseMove(view.band, 10, 10, -1, Qt.NoButton, Qt.NoModifier);
        store.complete("t2");
        store.moveToTomorrow("t2");
        if (!check(!store.struck.t2 && store.queue.length === 0, "an unconfirmed task can't be completed or moved again")) return;
        shell.release("sync");
      });
      break;
    case 22:
      if (!check(shell.calls("sync").length === shell.callsBefore + 1, "a sync followed the failed completion")) return;
      // Rate limited: an add records Todoist's retry time.
      shell.put("reply-add.json", JSON.stringify({ ok: false, code: "RATE_LIMITED", error: "Todoist is limiting requests. Try again in %1 seconds.\u001f60", retry_after: 60 }));
      view.field.text = "Rate me";
      view.submit(true);
      break;
    case 23:
      if (!check(view.addError === "Todoist is limiting requests. Try again in 60 seconds.", "the add says so (" + view.addError + ")")) return;
      // Until then no sync, add or change starts a helper.
      shell.callsBefore = shell.calls().length;
      store.sync();
      view.submit(true);
      store.complete("t4");
      store.flushCompletions();
      break;
    case 24:
      if (!check(shell.calls().length === shell.callsBefore, "nothing ran while rate limited (" + JSON.stringify(shell.calls().slice(shell.callsBefore)) + ")")) return;
      if (!check(view.addError.indexOf("Todoist is limiting requests.") === 0 && view.field.text === "Rate me", "the second add failed at once, text kept (" + view.addError + ")")) return;
      var back = view.rows.find(function(r) { return r.id === "t4"; });
      if (!check(back && !back.struck && store.error.indexOf("Todoist is limiting requests.") === 0, "the completion came back, with the error line (" + store.error + ")")) return;
      // A move to tomorrow refused while rate limited says why too.
      store.error = "";
      store.moveToTomorrow("t6");
      store.flushCompletions();
      store.next();
      if (!check(store.queue.length === 0 && store.error.indexOf("Todoist is limiting requests.") === 0, "a refused move to tomorrow says why (" + store.error + ")")) return;
      store.error = "";
      store.retryUntil = 0;
      // A full queue, a repeated t, then sign-out: every add settles. The
      // sync is one of the queued jobs: sign-out drops it before it starts.
      shell.put("reply-add.json", JSON.stringify(Object.assign(shell.snapshot(), { added: "t1" })));
      shell.put("reply-token-clear.json", JSON.stringify({ ok: true, state: "signed_out", user: null }));
      shell.settled = [];
      shell.callsBefore = shell.calls("add").length;
      store.sync();
      store.moveToTomorrow("t6");
      store.moveToTomorrow("t6");
      store.flushCompletions();
      view.field.text = "Queued";
      view.submit(true);
      for (var i = 0; i < 25; i++) store.add("Task " + i, "", "");
      var dues = store.queue.filter(function(job) { return job.command === "apply" && job.input.indexOf('"id":"t6"') >= 0; });
      if (!check(dues.length === 1, "a repeated t queued one change (" + dues.length + ")")) return;
      if (!check(store.queue.length === 20, "the queue holds 20 jobs (" + store.queue.length + ")")) return;
      shell.queuedAdds = store.queue.filter(function(job) { return job.command === "add"; }).length;
      store.signOut();
      break;
    case 25:
      var capped = shell.settled.filter(function(s) { return !s.ok && s.message === shell.capText; });
      var dropped = shell.settled.filter(function(s) { return !s.ok && s.message === ""; });
      if (!check(capped.length === 26 - shell.queuedAdds && dropped.length === shell.queuedAdds && shell.settled.length === 26, "every add settled: " + (26 - shell.queuedAdds) + " over the cap, " + shell.queuedAdds + " dropped at sign-out (" + capped.length + ", " + dropped.length + ", " + shell.settled.length + ")")) return;
      if (!check(shell.calls("add").length === shell.callsBefore && view.field.text === "Queued", "none ran; the field kept its text")) return;
      // The token form keeps a refused token for fixing; nothing keeps it in memory.
      view.settingsRequested();
      var page = view.settingsPage;
      // Signed out, in the order of the steps: where the token is, then the
      // field (it says what goes in it) with Save token beside it.
      var openTodoist = shell.find(page, "openTodoistSettings");
      var saveToken = shell.find(page, "saveTokenButton");
      var tokenTop = page.tokenField.mapToItem(page, 0, 0).y;
      if (!check(openTodoist.visible && openTodoist.mapToItem(page, 0, 0).y < tokenTop && Math.abs(saveToken.mapToItem(page, 0, 0).y + saveToken.height / 2 - (tokenTop + page.tokenField.height / 2)) <= 1 && page.tokenField.placeholderText === "Paste your API token" && shell.find(page, "accountSection").description !== "", "signed out: Open Todoist settings, then the field with Save token beside it")) return;
      // Signed out, the account's steps come first.
      if (!check(JSON.stringify(shell.settingsSections(page)) === JSON.stringify(["Account", "Panel", "Open command", "Bar", "Refresh"]), "signed out: the sections, Account first (" + JSON.stringify(shell.settingsSections(page)) + ")")) return;
      // Typed like a user: a masked field ignores an assigned text. Later,
      // so the settings page has already taken focus (its own callLater),
      // as it has by the time a user clicks the field.
      shell.put("reply-token-set.json", JSON.stringify({ ok: false, code: "INVALID_TOKEN", error: "Todoist didn't accept the API token." }));
      Qt.callLater(function() {
        page.tokenField.focusInput();
        for (var t of "wrong-token") ev.keyClickChar(t, Qt.NoModifier, -1);
        if (!check(page.tokenField.secretText === "wrong-token" && page.tokenField.text === "\u2022".repeat(11), "the token field shows dots only (" + page.tokenField.text.length + " dots, " + page.tokenField.secretText.length + " secret)")) return;
        page.saveToken();
      });
      break;
    case 26:
      if (!check(store.helperInput === "", "the token isn't kept after it was written (" + store.helperInput.length + " characters)")) return;
      if (!check(view.settingsPage.tokenField.secretText === "wrong-token", "a refused token stays in the field")) return;
      var tokenPage = view.settingsPage;
      // A paste the token field refuses: its line says why, in place of
      // the refused token's error.
      tokenPage.tokenField.focusInput();
      shell.refusedPaste("the token field", tokenPage.tokenField, function() { return shell.find(tokenPage, "tokenError"); }, null, function() {
        shell.put("reply-token-set.json", JSON.stringify({ ok: true, state: "signed_in", user: shell.snapshot().user }));
        tokenPage.tokenField.clear();
        tokenPage.tokenField.focusInput();
        for (var r of "right-token") ev.keyClickChar(r, Qt.NoModifier, -1);
        tokenPage.saveToken();
      });
      break;
    case 27:
      if (!check(view.settingsPage.tokenField.secretText === "" && view.settingsPage.tokenField.text === "" && store.helperInput === "", "a stored token leaves the field and memory")) return;
      view.settingsClosed();
      view.field.text = "After sign-in";
      view.submit(true);
      if (!check(view.addBusy, "an add runs again")) return;
      break;
    case 28:
      if (!check(view.field.text === "" && view.addError === "", "the add after signing in again worked (" + view.addError + ")")) return;
      // A reply after the last bar went: nothing restarts the poll. The
      // sync is held until the bars are gone.
      one.close();
      shell.hold("sync");
      store.sync();
      shell.panelsAlive = false;
      break;
    case 29:
      shell.release("sync");
      wait.waitFor(function() { return !store.busy; }, 15000, function(answered) {
        if (!check(answered, "the held sync answered after the bars went")) return;
        if (!check(!store.polling && !store.poll.running, "no poll without a bar (" + store.poll.running + ")")) return;
        shell.callsBefore = shell.calls().length;
        store.refreshIfStale(0);
        shell.panelsAlive = true;
      });
      break;
    case 30:
      if (!check(shell.calls().length === shell.callsBefore && !store.busy, "no refresh ran without a bar")) return;
      // Autocomplete: projects after #, labels after @.
      shell.put("reply-add.json", JSON.stringify(Object.assign(shell.snapshot(), { added: "t1" })));
      one.open();
      break;
    case 31:
      view.openAdd();
      break;
    case 32:
      var list = shell.find(view, "suggestions");
      var shown = function() { return list.visible ? view.suggest.items.map(function(item) { return item.name; }) : []; };
      shell.callsBefore = shell.calls("add").length;
      ev.keyClickChar("#", Qt.NoModifier, -1);
      if (!check(list.visible && JSON.stringify(shown()) === JSON.stringify(["Home", "Inbox", "Launch", "Reading list", "Work"]), "# lists the projects (" + JSON.stringify(shown()) + ")")) return;
      if (!check(shell.find(list, "suggestion-Home").hasCursor, "the first one is highlighted")) return;
      ev.keyClickChar("o", Qt.NoModifier, -1);
      if (!check(JSON.stringify(shown()) === JSON.stringify(["Home", "Inbox", "Work"]), "typing narrows it (" + JSON.stringify(shown()) + ")")) return;
      // ↓ then Enter: inserted, not added.
      ev.keyClick(Qt.Key_Down, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
      if (!check(view.field.text === "#Inbox " && view.field.cursorPosition === 7 && !list.visible && view.fieldFocused && !view.addBusy, "↓ Enter inserts #Inbox (" + JSON.stringify(view.field.text) + ")")) return;
      // @: the labels; Tab inserts, and doesn't switch panels.
      for (var ch of "@of") ev.keyClickChar(ch, Qt.NoModifier, -1);
      if (!check(JSON.stringify(shown()) === JSON.stringify(["office"]), "@ lists the labels (" + JSON.stringify(shown()) + ")")) return;
      ev.keyClick(Qt.Key_Tab, Qt.NoModifier, -1);
      if (!check(view.field.text === "#Inbox @office " && one.opened && view.fieldFocused, "Tab inserts @office (" + JSON.stringify(view.field.text) + ")")) return;
      // Esc closes only the list; the next Esc clears as before.
      for (var h of "#Ho") ev.keyClickChar(h, Qt.NoModifier, -1);
      if (!check(list.visible, "#Ho shows the list")) return;
      // While it shows, the footer says what its keys do.
      var listHints = function() {
        var row = shell.find(view, "keyHints");
        if (!row.visible) return [];
        return row.hints.map(function(unused, i) {
          var hint = shell.find(row, "keyHint" + i);
          var caps = hint.children.filter(function(item) { return item.visible && item.hasOwnProperty("radius"); }).map(function(cap) { return cap.text; });
          return caps.concat([hint.label]).join(" ");
        });
      };
      if (!check(JSON.stringify(listHints()) === JSON.stringify(["↵ Tab insert", "Esc close the list"]), "the footer: the list's keys, Enter and Tab as one hint (" + JSON.stringify(listHints()) + ")")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(!list.visible && view.field.text === "#Inbox @office #Ho" && view.fieldOpen && view.fieldFocused, "Esc closed only the list")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(view.field.text === "" && view.fieldOpen, "the next Esc cleared the text")) return;
      // No match: no list.
      for (var z of "#zzz") ev.keyClickChar(z, Qt.NoModifier, -1);
      if (!check(!list.visible, "no match, no list")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      // A click inserts; the field keeps the keys.
      for (var l of "#La") ev.keyClickChar(l, Qt.NoModifier, -1);
      var row = shell.find(list, "suggestion-Launch");
      ev.mouseClick(row, row.width / 2, row.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      if (!check(view.field.text === "#Launch " && view.fieldFocused && !list.visible, "a click inserts #Launch (" + JSON.stringify(view.field.text) + ")")) return;
      // A project typed in full (another case): the list shows it, the
      // footer says Enter adds, and Enter adds (Shift: and the field stays).
      for (var hm of "x #home") ev.keyClickChar(hm, Qt.NoModifier, -1);
      if (!check(list.visible && shell.find(list, "suggestion-Home").hasCursor && JSON.stringify(listHints()) === JSON.stringify(["↵ add and close", "Tab insert", "Esc close the list"]), "#home typed in full: Home highlighted, the footer says Enter adds (" + JSON.stringify(listHints()) + ")")) return;
      ev.keyClick(Qt.Key_Return, Qt.ShiftModifier, -1);
      if (!check(view.field.text === "#Launch x #home" && view.addBusy, "Shift+Enter added it as typed (" + JSON.stringify(view.field.text) + ")")) return;
      break;
    case 33:
      if (!check(JSON.parse(shell.calls("add").pop().slice("add ".length)).text === "#Launch x #home", "Enter on a project typed in full added the text")) return;
      // Search never suggests.
      view.startSearch();
      ev.keyClickChar("#", Qt.NoModifier, -1);
      if (!check(view.searching && !shell.find(view, "suggestions").visible, "no list in search")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      view.openAdd();
      break;
    case 34:
      // /: the sections of the #project before it.
      var list = shell.find(view, "suggestions");
      for (var a of "#Work /re") ev.keyClickChar(a, Qt.NoModifier, -1);
      if (!check(list.visible && JSON.stringify(view.suggest.items.map(function(i) { return i.name; })) === JSON.stringify(["Review"]), "/ lists Work's sections")) return;
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
      if (!check(view.field.text === "#Work /Review " && !view.addBusy, "Enter inserts /Review (" + JSON.stringify(view.field.text) + ")")) return;
      // +: the people of a shared #project, the email beside the name.
      view.field.text = "";
      for (var b of "#Launch +b") ev.keyClickChar(b, Qt.NoModifier, -1);
      var bo = shell.find(list, "suggestion-Bo Ek");
      if (!check(list.visible && bo && shell.find(bo, "suggestionDetail").text === "bo@example.com", "+ lists Launch's people with their email")) return;
      ev.keyClick(Qt.Key_Tab, Qt.NoModifier, -1);
      if (!check(view.field.text === "#Launch +Bo\\ Ek ", "Tab inserts +Bo\\ Ek (" + JSON.stringify(view.field.text) + ")")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      // The footer's Todoist button: a cursor stop; Enter opens the view in the browser.
      var button = shell.find(view, "openTodoist");
      view.cursor.index = view.openStop;
      if (!check(button.visible && button.hasCursor && button.label === "Todoist", "the footer button has the cursor")) return;
      shell.expectedUrl = Model.webUrl(view.view, view.projectId);
      view.returnRequested();
      view.activateRequested();
      break;
    case 35:
      if (!check(JSON.stringify(shell.opened()[0]) === JSON.stringify(["xdg-open", shell.expectedUrl]), "the default opens the link with xdg-open (" + JSON.stringify(shell.opened()) + ")")) return;
      // A command: {url} replaced, used for Ctrl+O on a task.
      one.prefs.save("openCommand", "todoist-open --app {url} --flag");
      wait.waitFor(function() { return store.openCommand === "todoist-open --app {url} --flag"; }, 5000, function(ok) {
        if (!check(ok, "the open command was saved")) return;
        view.focusList();
        view.cursor.index = view.firstRowStop;
        shell.expectedUrl = Model.webUrl("task", view.cursorRow().id);
        ev.keyClick(Qt.Key_O, Qt.ControlModifier, -1);
      });
      break;
    case 36:
      if (!check(JSON.stringify(shell.opened()[1]) === JSON.stringify(["todoist-open", "--app", shell.expectedUrl, "--flag"]), "{url} replaced (" + JSON.stringify(shell.opened()) + ")")) return;
      // Without {url}: appended; Open in Todoist in the menu uses it too.
      one.prefs.save("openCommand", "todoist-open --new");
      wait.waitFor(function() { return store.openCommand === "todoist-open --new"; }, 5000, function(ok) {
        if (!check(ok, "the second command was saved")) return;
        shell.expectedUrl = Model.webUrl(view.view, view.projectId);
        var item = Array.prototype.find.call(view.band.menuItems, function(i) { return i.objectName === "openInTodoist"; });
        item.triggered();
      });
      break;
    case 37:
      if (!check(JSON.stringify(shell.opened()[2]) === JSON.stringify(["todoist-open", "--new", shell.expectedUrl]), "the link appended (" + JSON.stringify(shell.opened()) + ")")) return;
      // A launch that fails shows in the footer.
      shell.put("open-fail", "3");
      var footerButton = shell.find(view, "openTodoist");
      ev.mouseClick(footerButton, footerButton.width / 2, footerButton.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      break;
    case 38:
      if (!check(view.footer.status === "Can't open Todoist" && view.footer.statusError, "the footer says the launch failed (" + view.footer.status + ")")) return;
      shell.put("open-fail", "");
      var again = shell.find(view, "openTodoist");
      ev.mouseClick(again, again.width / 2, again.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      break;
    case 39:
      if (!check(!view.footer.statusError && view.footer.status.indexOf("Updated") === 0, "the next success clears it (" + view.footer.status + ")")) return;
      // One IPC target per shell (the leading bar's): it offers toggle, add
      // and refresh, the calls a keybinding or another tool makes.
      var targets = one.data.concat(two.data).filter(function(item) { return item.target === "foamy.todoist" && item.enabled; });
      var target = targets[0];
      if (!check(targets.length === 1 && typeof target.toggle === "function" && typeof target.add === "function" && typeof target.refresh === "function", "one IPC target with toggle, add and refresh (" + targets.length + " enabled)")) return;
      // Wide: ← on a row goes to the rail, → from the rail back to the rows.
      view.goTo(view.firstRowStop);
      view.moveRequested(-1, 0);
      if (!check(view.cursor.index === view.railStop, "← on a row goes to the rail (wide)")) return;
      view.moveRequested(1, 0);
      if (!check(view.cursor.index === view.firstRowStop, "→ from the rail goes to the rows (wide)")) return;
      one.prefs.save("openCommand", "");
      one.prefs.save("panelWidth", "standard");
      // A task completed, then the popup closed inside the undo window:
      // the completion goes at once, not when the window would have ended.
      view.goTo(view.firstRowStop);
      shell.ringTask = view.cursorRow().id;
      var closeResults = {};
      closeResults[shell.ringTask] = "ok";
      shell.put("reply-apply.json", JSON.stringify(Object.assign(shell.snapshot(), { results: closeResults })));
      shell.callsBefore = shell.calls("apply").length;
      view.activateRequested();
      if (!check(store.struck[shell.ringTask] === true && store.undoWindow.running, "Space struck " + shell.ringTask + ", its undo window runs")) return;
      one.close();
      if (!check(!store.undoWindow.running && store.sending[shell.ringTask] === true && Object.keys(store.struck).length === 0, "closing sent the completion at once (" + JSON.stringify([store.undoWindow.running, store.sending, store.struck]) + ")")) return;
      shell.afterClose(function() { one.open(); });
      break;
    case 40:
      var closeSent = JSON.parse(shell.calls("apply")[shell.callsBefore].slice("apply ".length));
      if (!check(JSON.stringify(closeSent) === JSON.stringify({ commands: [{ op: "close", id: shell.ringTask }] }), "the close sent on closing (" + JSON.stringify(closeSent) + ")")) return;
      // Small: ← and → on a row do nothing.
      view.goTo(view.firstRowStop);
      view.moveRequested(1, 0);
      view.moveRequested(-1, 0);
      if (!check(view.cursor.index === view.firstRowStop, "← → on a row stay (small)")) return;
      view.openAdd();
      break;
    case 41:
      // The empty field's own right-click menu keeps it open; a click on a
      // tab beside the open menu closes both. Then a click on a tab while
      // the empty field has the keys: it closes, the view switches, and +
      // doesn't get the cursor.
      view.setView("today");
      shell.emptyFieldMenu(view, function() {
        view.setView("today");
        var tab = shell.find(shell.find(view, "viewSwitch"), "foamyTab0");
        ev.mouseClick(tab, tab.width / 2, tab.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
        if (!check(view.view === "inbox" && !view.fieldOpen && !view.fieldFocused && view.cursor.index !== view.addStop, "a tab click closed the empty field (" + view.view + ", " + view.fieldOpen + ", cursor " + view.cursor.index + ")")) return;
        view.openAdd();
        shell.clickedAway = true;
      });
      break;
    case 42:
      // A click on a ring: the field closes too.
      var ring = shell.find(shell.builtRows(view)[0], "ring");
      shell.ringTask = shell.builtRows(view)[0].entry.id;
      ev.mouseClick(ring, ring.width / 2, ring.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      if (!check(!view.fieldOpen && !view.fieldFocused && store.struck[shell.ringTask] === true, "a ring click closed the empty field")) return;
      store.undo(shell.ringTask);
      view.openAdd();
      break;
    case 43:
      // A view switch leaves search: the query never becomes a draft.
      view.closeField();
      view.startSearch();
      for (var q of "par") ev.keyClickChar(q, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_2, Qt.AltModifier, -1);
      if (!check(view.view === "today" && !view.searching && view.query === "" && view.field.text === "", "Alt+2 left search, no draft (" + JSON.stringify(view.field.text) + ")")) return;
      // A real draft stays across a view switch.
      view.openAdd();
      for (var d of "Draft") ev.keyClickChar(d, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_1, Qt.AltModifier, -1);
      if (!check(view.view === "inbox" && view.fieldOpen && view.field.text === "Draft", "the add draft stays across Alt+1")) return;
      // A suggestion that would make the task too long isn't put in.
      var long = "x".repeat(494) + " #Wo";
      view.field.text = long;
      view.field.cursorPosition = long.length;
      view.field.textEdited();
      if (!check(shell.find(view, "suggestions").visible, "the list shows near the limit")) return;
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
      if (!check(view.field.text === long && view.addError === "The task is too long for this suggestion" && !view.addBusy, "too long: not inserted, said so (" + view.addError + ")")) return;
      // The list closes so the error line under the band can be seen.
      var tooLong = shell.find(view, "errorLine");
      if (!check(!shell.find(view, "suggestions").visible && tooLong.visible && tooLong.text === view.addError, "the error line is visible")) return;
      // Tab with text: nothing happens; the text stays.
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      view.field.text = "Keep me";
      view.field.cursorPosition = 7;
      shell.switches = 0;
      ev.keyClick(Qt.Key_Tab, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Backtab, Qt.ShiftModifier, -1);
      if (!check(shell.switches === 0 && view.field.text === "Keep me" && view.fieldFocused && one.opened, "Tab with text did nothing (" + shell.switches + ")")) return;
      // The draft outlives the popup: reopened, the field has it, with the keys.
      one.close();
      shell.afterClose(function() {
        // Typed, never sent: the bar shows nothing.
        if (!check(shell.unseenShown() === "", "a draft never sent marks no bar: " + shell.unseenShown())) return;
        one.open();
      });
      break;
    case 44:
      var back = one.popup.bodyItem;
      if (!check(back.fieldOpen && back.field.text === "Keep me" && back.field.cursorPosition === 7, "the draft is back (" + JSON.stringify(back.field.text) + ")")) return;
      // Esc clears it; then it's gone for good.
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(back.field.text === "", "Esc cleared the draft")) return;
      // Tab in the empty field switches panels.
      shell.switches = 0;
      ev.keyClick(Qt.Key_Tab, Qt.NoModifier, -1);
      if (!check(shell.switches === 1, "Tab in an empty field switches panels (" + shell.switches + ")")) return;
      one.close();
      shell.afterClose(function() { one.open(); });
      break;
    case 45:
      var again = one.popup.bodyItem;
      if (!check(!again.fieldOpen && again.field.text === "", "no draft after Esc cleared it")) return;
      again.openAdd();
      break;
    case 46:
      // A draft started before a search comes back when the search ends:
      // Esc on the empty search, a view switch, a click on a tab. (The
      // band's buttons are inert while its field is open.)
      var leaves = [
        function() { ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1); ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1); },
        function() { ev.keyClick(Qt.Key_2, Qt.AltModifier, -1); },
        function() { var tab = shell.find(shell.find(view, "viewSwitch"), "foamyTab0"); ev.mouseClick(tab, tab.width / 2, tab.height / 2, Qt.LeftButton, Qt.NoModifier, -1); },
      ];
      for (var k of "Keep") ev.keyClickChar(k, Qt.NoModifier, -1);
      for (var n = 0; n < leaves.length; n++) {
        view.startSearch();
        if (!check(view.searching && view.field.text === "", "search " + n + " starts empty")) return;
        ev.keyClickChar("x", Qt.NoModifier, -1);
        leaves[n]();
        if (!check(!view.searching && view.fieldOpen && view.fieldFocused && view.field.text === "Keep" && view.field.cursorPosition === 4, "leave " + n + ": the draft is back (" + JSON.stringify(view.field.text) + ", " + view.fieldOpen + ", " + view.fieldFocused + ")")) return;
      }
      // Without a draft, leaving search goes back to the Add row.
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      view.startSearch();
      ev.keyClickChar("z", Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(!view.searching && !view.fieldOpen && view.field.text === "" && view.cursor.index === view.searchStop && view.band.buttonsActive, "no draft: the field closes, the cursor on Search")) return;
      // The Inbox has one-line rows; Today then reuses them for two-line ones.
      view.setView("inbox");
      break;
    case 47:
      var oneLine = shell.builtRows(view).find(function(r) { return r.entry.id === "t7"; });
      if (!check(oneLine && !oneLine.entry.detail, "t7 is a one-line row in the Inbox")) return;
      view.setView("today");
      break;
    case 48:
      // A row that had no detail line shows one when its next task has only a project.
      probeRow.entry = shell.probeEntry({ showProject: true, projectName: "Gjøremål", projectRole: "success", detail: true });
      if (!check(shell.find(probeRow, "taskDetail").visible && shell.find(probeRow, "taskProject").visible && shell.find(probeRow, "taskProject").text === "Gjøremål", "a row reused for a project-only task shows the project")) return;
      probeRow.entry = shell.probeEntry({ recurring: true, detail: true });
      if (!check(shell.find(probeRow, "taskDetail").visible && shell.find(probeRow, "taskRepeat").visible, "and the repeat icon alone")) return;
      if (!check(shell.ringLooks() === "", "the rings by priority: " + shell.ringLooks())) return;
      // Today shows the project of a task in another project, also on a reused row.
      for (var r of shell.builtRows(view)) {
        var project = shell.find(r, "taskProject");
        if (!check(r.entry.showProject && shell.find(r, "taskDetail").visible && project.visible && project.text === r.entry.projectName && project.text !== "", "Today: " + r.entry.id + " shows its project (" + project.text + ", detail " + shell.find(r, "taskDetail").visible + ")")) return;
      }
      shell.headingLooks(view, function() {
        // An add whose reply comes after the popup closed leaves no draft.
        shell.put("reply-add.json", JSON.stringify(Object.assign(shell.snapshot(), { added: "t1" })));
        shell.put("slow-add", "1.5");
        view.openAdd();
        shell.headingsChecked = true;
      });
      break;
    case 49:
      // Enter ("Close the panel", the default): sent, the field and the panel close.
      for (var m of "Milk soon") ev.keyClickChar(m, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
      if (!check(view.addBusy && !one.opened && !view.fieldOpen && store.addDraft === "Milk soon", "Enter sent it and closed the panel, the text the draft meanwhile (" + one.opened + ", " + JSON.stringify(store.addDraft) + ")")) return;
      break;
    case 50:
      if (!check(store.addDraft === "", "the added text isn't a draft (" + JSON.stringify(store.addDraft) + ")")) return;
      if (!check(shell.unseenShown() === "", "an add that worked marks no bar: " + shell.unseenShown())) return;
      one.open();
      break;
    case 51:
      if (!check(!view.fieldOpen && view.field.text === "", "reopened without a draft (" + JSON.stringify(view.field.text) + ")")) return;
      shell.unseenAdd(view, function() {
        // The next steps' add answers after the popup closed.
        shell.put("reply-add.json", JSON.stringify(Object.assign(shell.snapshot(), { added: "t1" })));
        shell.put("slow-add", "1.5");
        shell.unseenChecked = true;
      });
      break;
    case 52:
      // Typed on after submitting: once added, what was typed after the
      // sent text stays the draft (as in the field), without its space.
      for (var e of "Eggs") ev.keyClickChar(e, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Return, Qt.ShiftModifier, -1);
      for (var h of " and ham") ev.keyClickChar(h, Qt.NoModifier, -1);
      one.close();
      break;
    case 53:
      if (!check(store.addDraft === "and ham", "what was typed after the added text stays the draft (" + JSON.stringify(store.addDraft) + ")")) return;
      // Added, with typing after it: not a failed add.
      if (!check(shell.unseenShown() === "", "the draft after an add that worked marks no bar: " + shell.unseenShown())) return;
      one.open();
      break;
    case 54:
      if (!check(view.field.text === "and ham", "the typed-after text is back (" + JSON.stringify(view.field.text) + ")")) return;
      // Quick Add sent, no answer: the task may exist. Say so, keep the text, sync.
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      shell.put("slow-add", "");
      shell.put("reply-add.json", JSON.stringify({ ok: false, code: "UNKNOWN_OUTCOME", error: shell.unknownText }));
      shell.callsBefore = shell.calls("sync").length;
      for (var b of "Call Bob") ev.keyClickChar(b, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Return, Qt.ShiftModifier, -1);
      break;
    case 55:
      var line = shell.find(view, "errorLine");
      if (!check(line.visible && line.text === shell.unknownText, "the warning shows under the band (" + line.text + ")")) return;
      if (!check(view.field.text === "Call Bob" && view.fieldOpen, "the text is kept")) return;
      // Failed with the popup open: seen, so the bar shows nothing.
      if (!check(shell.unseenShown() === "", "a failure the open popup shows marks no bar: " + shell.unseenShown())) return;
      // The whole message shows, wrapped at the top of the list.
      if (!check(shell.addErrorLayout(view, shell.unknownText) === "", "the add error at standard width: " + shell.addErrorLayout(view, shell.unknownText))) return;
      shell.pickLanguage("no");
      break;
    case 56:
      // The same in Norwegian (a longer text): sent again, as the field still holds it.
      shell.callsBefore = shell.calls("add").length;
      ev.keyClick(Qt.Key_Return, Qt.ShiftModifier, -1);
      break;
    case 57:
      // Small's band line starts with the day, capitalised as the rows' dates.
      var bandLine = view.band.meta;
      if (!check(view.view === "today" && /^Ons\. /.test(bandLine), "Norwegian: the band's line starts with a capital (" + bandLine + ")")) return;
      var norwegian = Kit.FoamyI18n.t(shell.unknownText);
      if (!check(norwegian !== shell.unknownText, "a Norwegian text (" + norwegian + ")")) return;
      if (!check(shell.addErrorLayout(view, norwegian) === "", "the add error in Norwegian: " + shell.addErrorLayout(view, norwegian))) return;
      shell.pickLanguage("en");
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      // Tasks assigned to others: hidden by default, shown by the setting at
      // once (no sync), in the rows and the bar number.
      view.setView("today");
      var assigned = shell.snapshot();
      assigned.tasks = assigned.tasks.map(function(task) { return task.id === "t3" ? Object.assign({}, task, { responsible_uid: "7" }) : task; });
      store.snapshot = assigned;
      var count = one.barContent.countLabel;
      var hiddenCount = Number(count.text);
      if (!check(store.othersTasks === "hide" && !view.rows.some(function(row) { return row.id === "t3"; }), "hidden by default")) return;
      shell.callsBefore = shell.calls("sync").length;
      one.prefs.save("othersTasks", "show");
      wait.waitFor(function() { return store.othersTasks === "show"; }, 5000, function(ok) {
        if (!check(ok, "the setting was saved")) return;
        if (!check(view.rows.some(function(row) { return row.id === "t3"; }) && Number(count.text) === hiddenCount + 1, "shown: the row and one more in the bar (" + count.text + " vs " + hiddenCount + ")")) return;
        if (!check(shell.calls("sync").length === shell.callsBefore && !store.busy, "no sync for it")) return;
        one.prefs.save("othersTasks", "hide");
        shell.othersChecked = true;
      });
      break;
    case 58:
      if (!check(!view.rows.some(function(row) { return row.id === "t3"; }), "hidden again")) return;
      // An add in flight is the shell's, not the popup's: sent on one
      // monitor, the popup closed, the other monitor's popup opened before
      // the reply shows the text as being added (no second add on Enter),
      // and drops it once added. The add is held until then.
      shell.put("reply-add.json", JSON.stringify(Object.assign(shell.snapshot(), { added: "t1" })));
      shell.hold("add");
      shell.callsBefore = shell.calls("add").length;
      view.openAdd();
      break;
    case 59:
      for (var k of "Buy milk") ev.keyClickChar(k, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
      if (!check(view.addBusy, "the add runs")) return;
      one.close();
      two.open();
      break;
    case 60:
      var other = two.popup.bodyItem;
      if (!check(other.field.text === "Buy milk", "the other popup has the text (" + JSON.stringify(other.field.text) + ")")) return;
      if (!check(other.addBusy && shell.find(other, "addSpinner").visible, "and shows it being added")) return;
      // Typed on after the sent text there (the next task).
      for (var k13 of " and eggs") ev.keyClickChar(k13, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
      shell.release("add");
      break;
    case 61:
      var second = two.popup.bodyItem;
      if (!check(shell.calls("add").length === shell.callsBefore + 1, "Enter on the other monitor added nothing more (" + JSON.stringify(shell.calls("add")) + ")")) return;
      // Typed after the text the first monitor sent: it leaves the field,
      // so Enter there doesn't add it twice.
      if (!check(second.field.text === "and eggs" && store.addDraft === "", "added: the sent text is gone, the next task stays (" + JSON.stringify(second.field.text) + ", draft " + JSON.stringify(store.addDraft) + ")")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      two.close();
      // A suspend across midnight: the clock moves on, the midnight timer
      // hasn't fired. The poll's next tick finds the new day.
      var barCount = one.barContent.countLabel;
      if (!check(store.today === shell.today && barCount.visible && Number(barCount.text) === 6, "6 left on the 18th (" + barCount.text + ")")) return;
      shell.clock.at = new Date(2026, 10, 19, 0, 30, 0);
      if (!check(store.today === shell.today, "no timer has fired")) return;
      store.poll.triggered();
      if (!check(store.today === "2026-11-19" && Number(barCount.text) === 8, "the poll tick: the 19th, 8 left (" + store.today + ", " + barCount.text + ")")) return;
      break;
    case 62:
      // Another midnight; a sync reply arrives (no poll tick).
      shell.clock.at = new Date(2026, 10, 21, 0, 30, 0);
      shell.callsBefore = shell.calls("sync").length;
      store.sync();
      break;
    case 63:
      var later = one.barContent.countLabel;
      if (!check(store.today === "2026-11-21" && Number(later.text) === 9, "the sync reply: the 21st, 9 left (" + store.today + ", " + later.text + ")")) return;
      shell.clock.at = new Date(2026, 10, 18, 12, 0, 0);
      store.updateToday();
      one.close();
      break;
    case 64:
      // Enter and Shift+Enter with "Keep the field open".
      shell.put("reply-add.json", JSON.stringify(Object.assign(shell.snapshot(), { added: "t1" })));
      one.prefs.save("afterAdd", "keep");
      wait.waitFor(function() { return one.prefs.value("afterAdd") === "keep"; }, 5000, function(ok) {
        if (check(ok, "afterAdd saved")) one.open();
      });
      break;
    case 65:
      view.openAdd();
      break;
    case 66:
      var keepHints = shell.find(view, "keyHints");
      var keepTexts = [0, 1, 2].map(function(i) { return shell.find(keepHints, "keyHint" + i).label; });
      if (!check(JSON.stringify(keepTexts) === JSON.stringify(["add, keep typing", "add and close", "cancel"]), "the keys follow the setting (" + JSON.stringify(keepTexts) + ")")) return;
      shell.callsBefore = shell.calls("add").length;
      for (var k1 of "Keep one") ev.keyClickChar(k1, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
      if (!check(one.opened && view.fieldOpen && view.addBusy, "Enter (keep): sent, the panel stays")) return;
      // The next task typed before Todoist answers (the field takes keys
      // while the add is on its way; Enter waits for it).
      for (var k3 of "Next") ev.keyClickChar(k3, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
      if (!check(view.field.text === "Keep oneNext" && view.addBusy && store.pendingAddText === "Keep one", "typed on while busy, Enter sent nothing more (" + JSON.stringify([view.field.text, store.pendingAddText]) + ")")) return;
      break;
    case 67:
      if (!check(one.opened && view.fieldOpen && view.fieldFocused && view.field.text === "Next" && view.field.cursorPosition === 4, "the sent text left the field, the next task stays, the caret at its end (" + JSON.stringify([view.field.text, view.field.cursorPosition]) + ")")) return;
      // Typed on, then search before Todoist answers: the put-aside draft
      // loses the sent text and the spaces after it, and comes back so.
      view.field.selectAll();
      for (var k5 of "Third") ev.keyClickChar(k5, Qt.NoModifier, -1);
      // The reply held until the search's edits below are done.
      shell.hold("add");
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
      for (var k6 of "  Fourth") ev.keyClickChar(k6, Qt.NoModifier, -1);
      // A click away from the field (it stays open with its text), then /.
      view.leaveField();
      view.cursor.emitTextKey(view, "/");
      if (!check(view.searching && view.searchDraft === "Third  Fourth" && view.addBusy, "Search put the draft aside while the add is on its way (" + JSON.stringify(view.searchDraft) + ")")) return;
      // A query typed and cleared with Esc: the draft set aside is still
      // "typed after" the text on its way.
      view.field.focusInput();
      ev.keyClickChar("z", Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(view.searching && view.field.text === "" && view.searchDraft === "Third  Fourth" && view.addBusy && store.sentKept, "Esc cleared the query, the draft still typed after the sent text (" + JSON.stringify([view.field.text, view.searchDraft, store.sentKept]) + ")")) return;
      shell.release("add");
      wait.waitFor(function() { return !view.addBusy && !store.busy; }, 15000, function(added) {
        if (!check(added && shell.calls("add").length === shell.callsBefore + 2 && view.searchDraft === "Fourth", "added: the put-aside draft without the sent text (" + JSON.stringify(view.searchDraft) + ")")) return;
        ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
        if (!check(!view.searching && view.field.text === "Fourth" && view.field.cursorPosition === 6 && view.fieldFocused, "Esc: the draft back in the field (" + JSON.stringify(view.field.text) + ")")) return;
        // A draft typed afresh that starts like the sent text isn't
        // "typed after it": it stays whole. The caret keeps its place
        // in text typed after the sent one.
        view.field.selectAll();
        for (var k7 of "Buy milk") ev.keyClickChar(k7, Qt.NoModifier, -1);
        // Held: each synthetic key runs the event loop, so a quick reply
        // could come while the next text is typed.
        shell.hold("add");
        ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
        view.field.selectAll();
        for (var k8 of "Buy milkshakes") ev.keyClickChar(k8, Qt.NoModifier, -1);
        if (!check(view.addBusy && store.pendingAddText === "Buy milk", "a draft typed afresh while the add is on its way")) return;
        shell.release("add");
        wait.waitFor(function() { return !view.addBusy && !store.busy; }, 15000, function(afresh) {
          if (!check(afresh && view.field.text === "Buy milkshakes", "a draft typed afresh stays whole (" + JSON.stringify(view.field.text) + ")")) return;
          view.field.selectAll();
          for (var k9 of "Fifth") ev.keyClickChar(k9, Qt.NoModifier, -1);
          ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
          for (var k10 of " Sixth") ev.keyClickChar(k10, Qt.NoModifier, -1);
          ev.keyClick(Qt.Key_Left, Qt.NoModifier, -1);
          ev.keyClick(Qt.Key_Left, Qt.NoModifier, -1);
          wait.waitFor(function() { return !view.addBusy && !store.busy; }, 15000, function(kept) {
            if (!check(kept && view.field.text === "Sixth" && view.field.cursorPosition === 3, "the caret keeps its place in what stays (" + JSON.stringify([view.field.text, view.field.cursorPosition]) + ")")) return;
            // Typed afresh, then the popup closed before the reply: the
            // draft (the store's, not the field's) stays whole too.
            view.field.selectAll();
            for (var k11 of "Buy milk") ev.keyClickChar(k11, Qt.NoModifier, -1);
            ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
            view.field.selectAll();
            for (var k12 of "Buy milkshakes") ev.keyClickChar(k12, Qt.NoModifier, -1);
            one.close();
            if (!check(view.addBusy && store.addDraft === "Buy milkshakes", "closed with a draft typed afresh while the add is on its way (" + JSON.stringify(store.addDraft) + ")")) return;
            wait.waitFor(function() { return !view.addBusy && !store.busy; }, 15000, function(closedAfresh) {
              if (!check(closedAfresh && store.addDraft === "Buy milkshakes", "added after closing: the draft typed afresh stays whole (" + JSON.stringify(store.addDraft) + ")")) return;
              one.open();
              wait.waitFor(function() { return one.opened && view.active && view.fieldFocused; }, 10000, function(reopened) {
                if (!check(reopened && view.field.text === "Buy milkshakes", "reopened: the whole draft is back (" + JSON.stringify(view.field.text) + ")")) return;
                view.field.selectAll();
                for (var k2 of "Close two") ev.keyClickChar(k2, Qt.NoModifier, -1);
                ev.keyClick(Qt.Key_Return, Qt.ShiftModifier, -1);
                check(!one.opened && store.addDraft === "Close two", "Shift+Enter (keep): sent, the panel closes");
              });
            });
          });
        });
      });
      break;
    case 68:
      if (!check(store.addDraft === "" && store.addError === "", "added: no draft left (" + JSON.stringify(store.addDraft) + ")")) return;
      one.prefs.save("afterAdd", "close");
      shell.put("reply-task.json", JSON.stringify({ ok: true, task: { id: "t4", description: "Check the tests\nthen merge", truncated: false } }));
      wait.waitFor(function() { return one.prefs.value("afterAdd") === "close"; }, 5000, function(ok) {
        if (check(ok, "afterAdd back")) one.open();
      });
      break;
    case 69:
      // The editor page (Small): a click on a task opens it, not Todoist.
      var t4row = shell.builtRows(view).find(function(r) { return r.entry.id === "t4"; });
      var t4surface = shell.find(t4row, "taskSurface");
      shell.openedBefore = shell.opened().length;
      shell.callsBefore = shell.calls("task").length;
      ev.mouseClick(t4surface, t4surface.width * 0.6, t4surface.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      if (!check(view.pageShown && view.editingTask === "t4", "a click opens the task on the editor page")) return;
      break;
    case 70:
      var editor = view.editor;
      if (!check(shell.opened().length === shell.openedBefore, "nothing opened in Todoist")) return;
      if (!check(!view.band.visible && editor.visible && shell.find(editor, "editorBand").compactTitle === "Work › Review" && !view.footer.visible, "the page: the task's place as the title, no band, no footer (" + shell.find(editor, "editorBand").compactTitle + ")")) return;
      if (!check(shell.calls("task").length === shell.callsBefore + 1 && JSON.parse(shell.calls("task").pop().slice("task ".length)).id === "t4", "the description is read with the task command")) return;
      if (!check(editor.contentField.text === "Review **pull request** #482" && editor.descriptionField.text === "Check the tests\nthen merge" && editor.descriptionField.enabled, "the fields hold the task: the raw text, the description (" + JSON.stringify([editor.contentField.text, editor.descriptionField.text]) + ")")) return;
      if (!check(shell.valueText(editor, "dueRow") === "Today 14:00" && !editor.dueField.visible, "the date in the panel's words, the field closed (" + shell.valueText(editor, "dueRow") + ")")) return;
      if (!check(editor.dueField.text === "today 14:00", "the Date field holds Todoist's words for it (" + JSON.stringify(editor.dueField.text) + ")")) return;
      if (!check(shell.valueText(editor, "editPriority") === "P3", "P3 is the task's priority (the API's 2)")) return;
      // It reads like the task: the title, each value with its caption at
      // the row's end, an empty row saying what a click adds, no help text
      // and no form buttons (the description is a field).
      var shown = shell.visibleTexts(editor);
      var expected = ["Work › Review", "Review pull request #482", "Project", "Work › Review", "Date", "Today 14:00", "Add deadline", "Priority", "P3", "Labels", "@code"];
      if (!check(JSON.stringify(shown) === JSON.stringify(expected), "the page shows the task, no help text (" + JSON.stringify(shown) + ")")) return;
      // At rest the title reads as the list shows it, in the field's place
      // and font; the field holds Todoist's raw text under it.
      var title = editor.contentField;
      var titleText = shell.find(editor, "editTitleText");
      var atRest = function() { return titleText.visible && Qt.colorEqual(title.color, "transparent"); };
      if (!check(atRest() && titleText.text === "Review pull request #482" && titleText.text === store.model.byId.t4.text && title.text === "Review **pull request** #482", "at rest: the title as the list shows it (" + JSON.stringify([titleText.text, title.text]) + ")")) return;
      if (!check(Math.abs(titleText.mapToItem(editor, 0, 0).y - title.mapToItem(editor, 0, 0).y) < 1 && Math.abs(titleText.height - title.height) < 1 && titleText.leftPadding === title.leftPadding && titleText.font.pixelSize === title.font.pixelSize && titleText.font.weight === title.font.weight, "in the field's place and font")) return;
      // A click on it: the raw text, the caret in it; leaving: rendered
      // again (nothing sent); Shift+Tab back: the raw text.
      var applyBefore = shell.calls("apply").length;
      ev.mouseClick(titleText, titleText.width / 3, titleText.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      if (!check(title.inputActiveFocus && !atRest() && Qt.colorEqual(title.color, title.foreground) && title.cursorPosition > 0 && title.cursorPosition <= title.text.length, "a click: the raw text with the caret (" + title.cursorPosition + ")")) return;
      ev.keyClick(Qt.Key_Tab, Qt.NoModifier, -1);
      if (!check(editor.descriptionField.inputActiveFocus && atRest() && titleText.text === "Review pull request #482" && shell.calls("apply").length === applyBefore, "Tab away: rendered again, nothing sent")) return;
      ev.keyClick(Qt.Key_Tab, Qt.ShiftModifier, -1);
      if (!check(title.inputActiveFocus && !atRest(), "Shift+Tab back: the raw text")) return;
      // A save refused at once (a line break): the raw text, without the
      // keys too; Esc drops it, and leaving shows it rendered.
      title.text = "Review **pull request**\n#482";
      ev.keyClick(Qt.Key_Tab, Qt.NoModifier, -1);
      if (!check(!title.inputActiveFocus && editor.errorOf("content") !== "" && shell.find(editor, "contentError").visible && !atRest(), "a refused title: the raw text with its error")) return;
      ev.keyClick(Qt.Key_Tab, Qt.ShiftModifier, -1);
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Tab, Qt.NoModifier, -1);
      if (!check(title.text === "Review **pull request** #482" && editor.errorOf("content") === "" && atRest() && view.pageShown, "Esc dropped it; rendered again")) return;
      // A change not saved (the field holds it without the keys): the raw text.
      title.text = "Review **it**";
      if (!check(editor.touched("content") && !atRest(), "an unsaved change: the raw text")) return;
      editor.revert("content");
      if (!check(atRest() && shell.calls("apply").length === applyBefore, "reverted: rendered, nothing sent")) return;
      // The task text: only it is sent.
      shell.put("reply-apply.json", JSON.stringify(Object.assign(shell.snapshotWith({ t4: { content: "Review the **PR**" } }), { results: { t4: "ok" } })));
      shell.callsBefore = shell.calls("apply").length;
      editor.contentField.focusInput();
      editor.contentField.selectAll();
      for (var e1 of "Review the **PR**") ev.keyClickChar(e1, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
      if (!check(editor.saving && shell.find(editor, "editorBand").saving, "Saving… while it runs")) return;
      if (!check(title.inputActiveFocus && !atRest(), "Enter keeps the keys: the raw text")) return;
      // Leaving while it saves: what the field holds, rendered (Todoist
      // still has the old title).
      ev.keyClick(Qt.Key_Tab, Qt.NoModifier, -1);
      if (!check(editor.saving && atRest() && titleText.text === "Review the PR" && store.model.byId.t4.content === "Review **pull request** #482", "left while it saves: the field's text, rendered (" + titleText.text + ")")) return;
      break;
    case 71:
      var editor1 = view.editor;
      var sent1 = JSON.parse(shell.calls("apply").pop().slice("apply ".length));
      if (!check(JSON.stringify(sent1) === JSON.stringify({ commands: [{ op: "update", id: "t4", content: "Review the **PR**" }] }), "only the text was sent (" + JSON.stringify(sent1) + ")")) return;
      if (!check(editor1.contentField.text === "Review the **PR**" && store.model.byId.t4.content === "Review the **PR**" && shell.find(editor1, "editTitleText").text === "Review the PR" && editor1.errorOf("content") === "" && !editor1.saving, "saved: the field shows Todoist's value")) return;
      // No deadline: the row says "Add deadline" (no caption); a click
      // opens a one-line field. A deadline that isn't a day: said at once,
      // nothing sent, the field stays open; Esc drops it and closes the field.
      var deadlineSection = shell.find(editor1, "section-deadline");
      var deadlineEmpty = shell.find(deadlineSection, "sectionEmpty");
      var deadlineBox = shell.find(deadlineSection, "sectionBox");
      if (!check(deadlineEmpty.visible && deadlineEmpty.text === "Add deadline" && !shell.find(deadlineSection, "sectionCaption").visible && deadlineBox.Accessible.name === "Add deadline" && shell.valueText(editor1, "deadlineRow") === "" && !editor1.deadlineField.visible, "no deadline: the row says Add deadline")) return;
      // The row is one click target, as in Todoist: the pointer over its
      // words lights all of it, a click there opens the field.
      ev.mouseMove(deadlineEmpty, 4, deadlineEmpty.height / 2, -1, Qt.NoButton, Qt.NoModifier);
      if (!check(deadlineBox.lit && !shell.sectionBox(editor1, "section-due").lit, "hover lights the whole section, alone")) return;
      ev.mouseClick(deadlineEmpty, 4, deadlineEmpty.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      if (!check(editor1.deadlineField.visible && editor1.deadlineField.inputActiveFocus && !deadlineEmpty.visible && !deadlineBox.lit, "a click on the row opened the deadline field with the caret")) return;
      for (var d1 of "2026-02-30") ev.keyClickChar(d1, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
      var deadlineError = shell.find(deadlineSection, "fieldErrorText");
      if (!check(deadlineError.visible && deadlineError.text === "Enter a deadline as YYYY-MM-DD." && shell.calls("apply").length === shell.callsBefore + 1 && editor1.deadlineField.inputActiveFocus, "a bad deadline is caught before sending, the field open")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(editor1.deadlineField.text === "" && !deadlineError.visible && !editor1.deadlineField.visible && deadlineBox.activeFocus && view.pageShown, "Esc dropped the change, closed the field, the keys on its section")) return;
      // A save Todoist refuses: the error under the date, with Retry, the text kept.
      shell.put("reply-apply.json", JSON.stringify(Object.assign(shell.snapshotWith({ t4: { content: "Review the **PR**" } }), { results: { t4: { code: "HTTP", error: "Todoist answered HTTP %1.\u001f500" } } })));
      var dueRow1 = shell.find(editor1, "dueRow");
      // Date: a click opens the days (as the list's menu) and Type a date….
      ev.mouseClick(dueRow1, dueRow1.width / 2, dueRow1.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      var dueTexts = editor1.menu.entries.filter(function(e) { return !e.separator; }).map(function(e) { return e.text; });
      if (!check(editor1.menu.opened && JSON.stringify(dueTexts) === JSON.stringify(["Today", "Tomorrow", "Next week", "No date", "Type a date…"]), "the date row opens the days and Type a date… (" + JSON.stringify(dueTexts) + ")")) return;
      // Tomorrow: the row says so at once (the time kept); undone here.
      editor1.menu.activate(1);
      if (!check(!editor1.menu.opened && store.moves.t4 === Model.addDays(shell.today, 1) && shell.valueText(editor1, "dueRow") === "Tomorrow 14:00", "Tomorrow from the editor: the row says Tomorrow 14:00 (" + shell.valueText(editor1, "dueRow") + ")")) return;
      store.undo("t4");
      // From the keys a menu starts on the current choice: Enter twice
      // keeps P3 (it used to set P1).
      shell.sectionBox(editor1, "section-priority").forceActiveFocus();
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
      var priorityAt = editor1.menu.currentIndex;
      if (!check(editor1.menu.opened && priorityAt >= 0 && editor1.menu.entries[priorityAt].text === "P3", "Enter on Priority: the menu starts on P3 (" + priorityAt + ")")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      ev.mouseClick(dueRow1, dueRow1.width / 2, dueRow1.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      editor1.menu.activate(editor1.menu.entries.findIndex(function(e) { return e.text === "Type a date…"; }));
      if (!check(editor1.dueField.visible && editor1.dueField.inputActiveFocus && editor1.dueField.text === "today 14:00" && !dueRow1.visible, "Type a date… opened the field with Todoist's words")) return;
      editor1.dueField.selectAll();
      for (var n1 of "next monday") ev.keyClickChar(n1, Qt.NoModifier, -1);
      // Leaving the field saves it.
      ev.keyClick(Qt.Key_Tab, Qt.NoModifier, -1);
      break;
    case 72:
      var editor2 = view.editor;
      var sent2 = JSON.parse(shell.calls("apply").pop().slice("apply ".length));
      if (!check(JSON.stringify(sent2) === JSON.stringify({ commands: [{ op: "update", id: "t4", due_string: "next monday" }] }), "Tab out of the date saved it alone (" + JSON.stringify(sent2) + ")")) return;
      var dueBlock = shell.find(editor2, "section-due");
      if (!check(shell.find(dueBlock, "fieldErrorText").text === "Todoist answered HTTP 500." && shell.find(dueBlock, "fieldRetry").visible && editor2.dueField.text === "next monday", "refused: why, Retry, the text kept")) return;
      if (!check(!editor2.dueField.visible && shell.valueText(editor2, "dueRow") === "next monday", "the field closed; the row shows the kept text (" + shell.valueText(editor2, "dueRow") + ")")) return;
      if (!check(store.error === "", "the list's error line stays clear (" + store.error + ")")) return;
      shell.put("reply-apply.json", JSON.stringify(Object.assign(shell.snapshotWith({ t4: { content: "Review the **PR**", due: Fixtures.due("2026-11-23", false, "next monday") } }), { results: { t4: "ok" } })));
      shell.find(dueBlock, "fieldRetry").clicked();
      break;
    case 73:
      var editor3 = view.editor;
      if (!check(shell.calls("apply").length === shell.callsBefore + 3 && editor3.errorOf("due") === "" && editor3.dueField.text === "next monday" && shell.valueText(editor3, "dueRow") === "Monday", "Retry sent it again; saved (" + shell.valueText(editor3, "dueRow") + ")")) return;
      // Priority: Enter on its row opens the menu of the four; a pick sends
      // it alone (P1 is the API's 4).
      shell.put("reply-apply.json", JSON.stringify(Object.assign(shell.snapshotWith({ t4: { content: "Review the **PR**", priority: 4 } }), { results: { t4: "ok" } })));
      // One cursor stop per section, in order, then the label chips' ×.
      editor3.descriptionField.focusInput();
      var stops = [];
      for (var tab = 0; tab < 6; tab++) {
        ev.keyClick(Qt.Key_Tab, Qt.NoModifier, -1);
        stops.push(shell.focusedSection(editor3));
      }
      if (!check(JSON.stringify(stops) === JSON.stringify(["section-place", "section-due", "section-deadline", "section-priority", "section-labels", "removeLabel"]), "Tab: one stop per section (" + JSON.stringify(stops) + ")")) return;
      shell.sectionBox(editor3, "section-priority").forceActiveFocus();
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
      var levels = editor3.menu.entries.map(function(entry) { return entry.text + (entry.checked ? "*" : ""); });
      if (!check(editor3.menu.opened && editor3.menuOpen && JSON.stringify(levels) === JSON.stringify(["P1", "P2", "P3*", "P4"]), "Enter on the priority opens the four, P3 checked (" + JSON.stringify(levels) + ")")) return;
      editor3.menu.activate(0);
      break;
    case 74:
      var editor4 = view.editor;
      var sent4 = JSON.parse(shell.calls("apply").pop().slice("apply ".length));
      if (!check(JSON.stringify(sent4) === JSON.stringify({ commands: [{ op: "update", id: "t4", priority: 4 }] }) && shell.valueText(editor4, "editPriority") === "P1" && !editor4.menu.opened, "P1 sent alone (" + JSON.stringify(sent4) + ")")) return;
      // + at the Labels caption: the personal labels the task doesn't have; one picked sends the whole list.
      shell.put("reply-apply.json", JSON.stringify(Object.assign(shell.snapshotWith({ t4: { content: "Review the **PR**", priority: 4, labels: ["code", "calls"] } }), { results: { t4: "ok" } })));
      var plusLabel = shell.find(editor4, "addLabel");
      var labelsCaption = shell.find(shell.find(editor4, "section-labels"), "sectionCaption");
      ev.mouseClick(labelsCaption, 4, labelsCaption.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      var offered = editor4.menu.entries.map(function(entry) { return entry.text; });
      if (!check(plusLabel.visible && shell.sectionBox(editor4, "section-labels").Accessible.name === "Add label" && editor4.menu.opened && JSON.stringify(offered) === JSON.stringify(["calls", "errand", "office", "Waiting on"]), "+ offers the personal labels the task lacks (" + JSON.stringify(offered) + ")")) return;
      editor4.menu.activate(0);
      wait.waitFor(function() { return shell.calls("apply").length === shell.callsBefore + 5 && !store.busy && !editor4.saving; }, 15000, function(ok) {
        if (!check(ok, "the labels were saved")) return;
        var sentLabels = JSON.parse(shell.calls("apply").pop().slice("apply ".length));
        if (!check(JSON.stringify(sentLabels) === JSON.stringify({ commands: [{ op: "update", id: "t4", labels: ["code", "calls"] }] }) && shell.find(editor4, "label-calls") !== null, "the whole list was sent (" + JSON.stringify(sentLabels) + ")")) return;
        shell.racingSaves(view, function() {
        shell.baselineSaves(view, function() {
          // Typed, then Back (no Enter): saved as the page closes.
          var from3 = shell.calls("apply").length;
          shell.t4Reply({ content: "One Two Three", priority: 4, labels: [] });
          editor4.contentField.focusInput();
          editor4.contentField.cursorPosition = editor4.contentField.text.length;
          for (var c3 of " Three") ev.keyClickChar(c3, Qt.NoModifier, -1);
          ev.mouseClick(editor4.backButton, editor4.backButton.width / 2, editor4.backButton.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
          if (!check(!view.pageShown, "Back closed the page")) return;
          wait.waitFor(function() { return shell.calls("apply").length === from3 + 1 && !store.busy; }, 15000, function(ok5) {
            var backSent = shell.updatesSince(from3);
            if (!check(ok5 && JSON.stringify(backSent) === JSON.stringify([{ op: "update", id: "t4", content: "One Two Three" }]), "Back saved the typed text (" + JSON.stringify(backSent) + ")")) return;
            view.openTask("t4", false);
            wait.waitFor(function() { return view.pageShown && store.description.state === "ready" && editor4.contentField.text === "One Two Three"; }, 15000, function(ok6) {
              if (!check(ok6, "the page again, with the saved text")) return;
              // Esc in a field without a change: back to the list, t4 under the cursor.
              editor4.contentField.focusInput();
              ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
              var back4 = view.cursorRow();
              if (!check(!view.pageShown && back4 && back4.id === "t4" && view.band.visible && !view.blocked, "Esc went back, t4 selected (" + (back4 && back4.id) + ")")) return;
              if (!check(store.description.id === "", "the description went with the editor")) return;
              // Enter on the row: the page; a description read that fails says so, with Retry.
              shell.put("reply-task.json", JSON.stringify({ ok: false, code: "NETWORK", error: "Can't reach Todoist. Check your connection." }));
              view.returnRequested();
              view.activateRequested();
            });
          });
        });
        });
      });
      break;
    case 75:
      var editor5 = view.editor;
      var descBlock = shell.find(editor5, "descriptionError");
      if (!check(!editor5.descriptionField.enabled && shell.find(descBlock, "fieldErrorText").text === "Can't reach Todoist. Check your connection." && shell.find(descBlock, "fieldRetry").visible, "the failed read: disabled, why, Retry")) return;
      shell.put("reply-task.json", JSON.stringify({ ok: true, task: { id: "t4", description: "Retried", truncated: false } }));
      shell.find(descBlock, "fieldRetry").clicked();
      break;
    case 76:
      if (!check(view.editor.descriptionField.text === "Retried" && view.editor.descriptionField.enabled, "Retry read it")) return;
      // A reply that comes after its editor closed is dropped. The read is
      // held until the editor has closed.
      shell.hold("task");
      view.editor.back();
      view.openTask("t5", true);
      break;
    case 77:
      view.closeTask();
      if (!check(store.description.id === "" && store.description.state === "", "closed: no description")) return;
      shell.release("task");
      break;
    case 78:
      if (!check(store.description.id === "" && store.description.state === "", "the late reply was dropped (" + JSON.stringify(store.description) + ")")) return;
      shell.put("reply-task.json", JSON.stringify({ ok: true, task: { id: "t7", description: "Seven", truncated: false } }));
      view.openTask("t7", true);
      break;
    case 79:
      // A reply for an earlier request (another task) changes nothing.
      store.handle({ command: "task", input: "", extra: { describe: "t7", request: store.descriptionRequest - 1 }, generation: store.generation }, 0, JSON.stringify({ ok: true, task: { id: "t7", description: "stale" } }));
      if (!check(store.description.text === "Seven" && view.editor.descriptionField.text === "Seven", "an earlier request's reply is ignored")) return;
      // A cut description with CRLF line ends never saves itself on leaving.
      var whole = store.description;
      store.description = { id: "t7", state: "ready", text: "Line one\r\nLine two", truncated: true };
      view.editor.commit();
      if (!check(!view.editor.dirty("description") && Object.keys(view.editor.pending).length === 0, "a cut description is never saved")) return;
      // Untouched CRLF text is not a change either.
      store.description = { id: "t7", state: "ready", text: "Line one\r\nLine two", truncated: false };
      view.editor.descriptionField.text = "Line one\nLine two";
      if (!check(!view.editor.dirty("description"), "CRLF read back as LF is no change")) return;
      // Ctrl+Enter and leaving the field send no untouched CRLF description.
      view.editor.descriptionField.focusInput();
      ev.keyClick(Qt.Key_Return, Qt.ControlModifier, -1);
      view.editor.contentField.focusInput();
      if (!check(Object.keys(view.editor.pending).length === 0, "Ctrl+Enter and the blur sent no untouched CRLF description")) return;
      store.description = whole;
      view.editor.descriptionField.text = "Seven";
      // Changed in Todoist while a field has the keys: untouched, the field
      // follows and leaving it sends nothing; typed in, the typed text stays.
      var ed = view.editor;
      ed.contentField.focusInput();
      var elsewhere = { content: "Call the dentist today" };
      store.snapshot = shell.snapshotWith({ t7: elsewhere });
      if (!check(ed.contentField.inputActiveFocus && ed.contentField.text === "Call the dentist today", "the untouched field with the keys follows Todoist (" + JSON.stringify(ed.contentField.text) + ")")) return;
      ed.openField("due");
      elsewhere.due = Fixtures.due(shell.today, false, "today");
      store.snapshot = shell.snapshotWith({ t7: elsewhere });
      if (!check(ed.dueField.text === "today", "the date follows too (" + JSON.stringify(ed.dueField.text) + ")")) return;
      ed.openField("deadline");
      elsewhere.deadline = "2026-12-01";
      store.snapshot = shell.snapshotWith({ t7: elsewhere });
      if (!check(ed.deadlineField.text === "2026-12-01", "the deadline follows too (" + JSON.stringify(ed.deadlineField.text) + ")")) return;
      ed.descriptionField.focusInput();
      store.description = { id: "t7", state: "ready", text: "Seven, from elsewhere", truncated: false };
      if (!check(ed.descriptionField.text === "Seven, from elsewhere", "the description follows too (" + JSON.stringify(ed.descriptionField.text) + ")")) return;
      ed.contentField.focusInput();
      if (!check(Object.keys(ed.pending).length === 0 && !store.busy, "leaving the untouched fields sent nothing back")) return;
      ed.contentField.cursorPosition = ed.contentField.text.length;
      for (var t7c of " now") ev.keyClickChar(t7c, Qt.NoModifier, -1);
      store.snapshot = shell.snapshotWith({ t7: { content: "Call the dentist soon" } });
      if (!check(ed.contentField.text === "Call the dentist today now" && ed.dirty("content"), "the typed text stays over Todoist's (" + JSON.stringify(ed.contentField.text) + ")")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      store.snapshot = shell.snapshot();
      if (!check(ed.contentField.text === "Call the dentist" && ed.dueField.text === "" && ed.deadlineField.text === "" && Object.keys(ed.pending).length === 0, "Esc dropped it; the fields follow back (" + JSON.stringify([ed.contentField.text, ed.dueField.text, ed.deadlineField.text]) + ")")) return;
      store.description = whole;
      if (!check(ed.descriptionField.text === "Seven", "the description back")) return;
      // A picked choice that Todoist refuses: Retry sends the same pick again.
      shell.put("reply-apply.json", JSON.stringify(Object.assign(shell.snapshot(), { results: { t7: { code: "HTTP", error: "Todoist answered HTTP %1.\u001f502" } } })));
      shell.callsBefore = shell.calls("apply").length;
      var p2row = shell.find(view.editor, "editPriority");
      ev.mouseClick(p2row, p2row.width / 2, p2row.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      if (!check(view.editor.menu.opened, "a click on the priority opens its menu")) return;
      view.editor.menu.activate(1);
      var priorityBlock = shell.find(view.editor, "section-priority");
      wait.waitFor(function() { return shell.calls("apply").length === shell.callsBefore + 1 && !store.busy && !view.editor.saving; }, 15000, function(ok) {
        if (!check(ok && shell.find(priorityBlock, "fieldErrorText").text === "Todoist answered HTTP 502." && shell.find(priorityBlock, "fieldRetry").visible, "the refused pick: why, Retry")) return;
        shell.put("reply-apply.json", JSON.stringify(Object.assign(shell.snapshotWith({ t7: { priority: 3 } }), { results: { t7: "ok" } })));
        shell.find(priorityBlock, "fieldRetry").clicked();
        wait.waitFor(function() { return shell.calls("apply").length === shell.callsBefore + 2 && !store.busy && !view.editor.saving; }, 15000, function(ok2) {
          var again = JSON.parse(shell.calls("apply").pop().slice("apply ".length));
          if (!check(ok2 && JSON.stringify(again) === JSON.stringify({ commands: [{ op: "update", id: "t7", priority: 3 }] }) && !shell.find(priorityBlock, "fieldError").visible && shell.valueText(view.editor, "editPriority") === "P2", "Retry sent the pick again (" + JSON.stringify(again) + ")")) return;
          // The task goes from the snapshot: the page says so, Back stays.
          store.snapshot = shell.snapshot(["t7"]);
          var gone = shell.find(view.editor, "editorEmpty");
          if (!check(gone.visible && gone.text === "This task is no longer in Todoist." && view.editor.backButton.visible, "a task that went: said, Back stays")) return;
          view.editor.back();
          store.snapshot = shell.snapshot();
        });
      });
      break;
    case 80:
      // Small's page, laid out by the next drawn frame (the clicks below
      // go to what is drawn).
      view.openTask("t4", true);
      var pageEditor = view.editor;
      wait.waitFor(function() { return view.pageShown && pageEditor.taskId === "t4" && pageEditor.mode === "page"; }, 3000, function(shown) {
      if (!check(shown, "Small's page shows t4 (" + JSON.stringify([view.pageShown, pageEditor.taskId, pageEditor.mode]) + ")")) return;
      shell.afterFrame(pageEditor, function() {
      // The project: its row opens a menu of the projects and their
      // sections, the task's place checked; a pick saves the move alone.
      if (!check(shell.valueText(pageEditor, "editPlace") === "Work › Review", "the project row: Work › Review (" + shell.valueText(pageEditor, "editPlace") + ")")) return;
      var placeRow = shell.find(pageEditor, "editPlace");
      ev.mouseClick(placeRow, placeRow.width / 2, placeRow.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      var places = pageEditor.menu.entries.map(function(entry) { return entry.text + (entry.checked ? "*" : ""); });
      if (!check(pageEditor.menu.opened && JSON.stringify(places.slice(0, 4)) === JSON.stringify(["Inbox", "Work", "Work › Review*", "Work › Ops"]), "the project menu: projects and sections, the place checked (" + JSON.stringify(places) + ")")) return;
      shell.put("reply-apply.json", JSON.stringify(Object.assign(shell.snapshotWith({ t4: { section_id: "s-ops" } }), { results: { t4: "ok" } })));
      shell.callsBefore = shell.calls("apply").length;
      pageEditor.menu.activate(3);
      wait.waitFor(function() { return shell.calls("apply").length === shell.callsBefore + 1 && !store.busy && !pageEditor.saving; }, 15000, function(ok) {
        var moved = shell.updatesSince(shell.callsBefore);
        if (!check(ok && JSON.stringify(moved) === JSON.stringify([{ op: "update", id: "t4", section_id: "s-ops" }]) && shell.valueText(pageEditor, "editPlace") === "Work › Ops", "the pick moved it to Ops alone (" + JSON.stringify(moved) + ")")) return;
        // Open in Todoist: the band's icon opens the task.
        shell.openedBefore = shell.opened().length;
        var bandOpen = pageEditor.openButton;
        ev.mouseClick(bandOpen, bandOpen.width / 2, bandOpen.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
        wait.waitFor(function() { return shell.opened().length === shell.openedBefore + 1 && !store.launchRunning; }, 15000, function(ok2) {
          var launched = ok2 ? shell.opened()[shell.openedBefore] : [];
          if (!check(ok2 && launched.indexOf(Model.webUrl("task", "t4")) >= 0 && bandOpen.Accessible.name === "Open in Todoist", "the band's icon, named Open in Todoist, opened the task (" + JSON.stringify([launched, bandOpen.Accessible.name]) + ")")) return;
          // The ring beside the title completes the task and leaves the page.
          var ring = pageEditor.ring;
          if (!check(ring.Accessible.name === "Complete" && ring.activeFocusOnTab, "the ring is named and on the Tab path")) return;
          ev.mouseClick(ring, ring.width / 2, ring.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
          if (!check(store.struck.t4 === true && !view.pageShown, "the ring completed it, back to the list")) return;
          // Opened again while its Undo time runs: the page shows it
          // completed, its band offers Undo, which brings it back and stays.
          view.openTask("t4", false);
          shell.afterFrame(pageEditor, function() {
            var pageUndo = shell.find(pageEditor, "pageUndo");
            var pageMark = shell.find(pageEditor.ring, "editRingCheck");
            if (!check(view.pageShown && pageUndo.visible && pageUndo.label === "Undo" && pageMark.visible && pageEditor.contentField.font.strikeout, "the page of a completed task: struck, with Undo (" + JSON.stringify([view.pageShown, pageUndo.visible, pageMark.visible]) + ")")) return;
            ev.mouseClick(pageUndo, pageUndo.width / 2, pageUndo.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
            // Undone within its window: nothing is sent.
            if (!check(!store.struck.t4 && view.pageShown && !pageUndo.visible && !pageMark.visible && !pageEditor.contentField.font.strikeout && shell.calls("apply").length === shell.callsBefore + 1, "the page's Undo: back, still on the page, nothing sent")) return;
            pageEditor.back();
            // The size as a version before this one saved it: "large".
            shell.editorMenus(view, function() { shell.entry = Object.assign({}, shell.entry, { panelWidth: "large" }); });
          });
        });
      });
      });
      });
      break;
    case 81:
      // A saved "large" (the size Wide took over) reads as Wide: no error,
      // no stored problem, the settings page shows Wide, the entry as it was.
      if (!check(shell.entry.panelWidth === "large" && one.sizeSetting === "wide" && one.prefs.value("panelWidth") === "wide" && one.prefs.error === "" && JSON.stringify(one.prefs.storedProblems) === "{}" && shell.find(view.settingsPage, "panelWidth").value === "wide", "a saved large reads as Wide, quietly (" + JSON.stringify([shell.entry.panelWidth, one.prefs.error, one.prefs.storedProblems]) + ")")) return;
      // Wide: a click on the bar opens the popup under the button.
      shell.put("reply-task.json", JSON.stringify({ ok: true, task: { id: "t1", description: "One", truncated: false } }));
      // The popup's pointer over its band, as a user's on the bar: no row is
      // under it when Wide opens (only the keys move the cursor below).
      ev.mouseMove(view.band, 10, 10, -1, Qt.NoButton, Qt.NoModifier);
      one.close();
      ev.mouseClick(button, button.width / 2, button.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      break;
    case 82:
      var big = one.popup.bodyItem;
      // Nothing selected on open: 880 wide, the overview in the pane.
      if (!check(shell.popupPlacement(one, 880) === "", "the popup, 880 wide under the button (" + shell.popupPlacement(one, 880) + ")")) return;
      if (!check(one.popup.maxHeight === Math.round(one.popup.screenH * 0.7) && one.popup.cardItem.height <= one.popup.maxHeight + 1, "at most 70% of the screen high (" + JSON.stringify([one.popup.cardItem.height, one.popup.maxHeight]) + ")")) return;
      if (!check(big.size === "wide" && shell.find(big, "rail-week") !== null && big.band.visible && !big.editor.visible && big.overviewShown, "the band, the rail with Week, the overview in the pane")) return;
      shell.overviewChecks(big, function() {
        var area0 = shell.find(big, "listArea");
        shell.listBox = [area0.width, area0.mapToItem(big, 0, 0).x];
        shell.callsBefore = shell.calls("task").length;
        shell.readAt = 0;
        shell.keyAt = Date.now();
        ev.keyClick(Qt.Key_Down, Qt.NoModifier, -1);
        // The cursor may move on at once: the pane reads the description
        // only once the selection rests, so nothing is queued yet.
        if (!check(![store.current].concat(store.queue).some(function(job) { return !!job && job.command === "task"; }), "the pane waits for the selection to rest before it reads the description")) return;
        if (!check(big.cursorRow() && big.paneTask === big.cursorRow().id && big.editor.taskId === "t1" && !big.editor.descriptionField.enabled && big.editor.descriptionField.placeholderText === "Loading…", "↓: the pane shows the row, the description loading (" + big.paneTask + ")")) return;
        // The keys' cursor has the accent border; the selected row its bar.
        var keyRow = shell.highlighted(big)[0];
        var keySurface = shell.find(keyRow, "taskSurface");
        if (!check(big.cursor.byKeys && keySurface.byKeys && keySurface.borderTop > 0 && shell.find(keySurface, "foamyCurrentBar").visible, "↓: the keys' border and the selected row's bar")) return;
        big.cursor.hover(big.cursor.index);
        if (!check(!big.cursor.byKeys && !keySurface.byKeys, "hover: the pointer's cursor, no keys' border")) return;
        // The card stays 880: the list keeps its width and place, the
        // task's details in the overview's place beside it.
        if (!check(one.cardWidth === 880 && one.popup.contentWidth === 880 && big.editor.visible && !big.overviewShown && Math.abs(area0.width - shell.listBox[0]) < 1 && Math.abs(big.editor.x - (area0.x + area0.width + Kit.FoamyStyle.borderWidth)) < 1, "↓: the card stays 880, the list as it was (" + JSON.stringify([one.popup.contentWidth, area0.width, shell.listBox, big.editor.x]) + ")")) return;
      });
      break;
    case 83:
      var big1 = one.popup.bodyItem;
      var reads = shell.calls("task");
      if (!check(reads.length === shell.callsBefore + 1 && JSON.parse(reads[reads.length - 1].slice("task ".length)).id === "t1", "one description read where the cursor rested (" + JSON.stringify(reads.slice(shell.callsBefore)) + ")")) return;
      // Held ↓ repeats about every 30 ms: a read only after a real pause
      // keeps the rows it passes from each reading a description.
      if (!check(shell.readAt - shell.keyAt >= 250, "the read waited for the selection to rest (" + (shell.readAt - shell.keyAt) + " ms)")) return;
      // The rail's counts read (4.5:1).
      var railRead = shell.railCounts(big1);
      if (!check(railRead.counts > 1 && railRead.low.length === 0, "the rail's counts read (" + JSON.stringify(railRead) + ")")) return;
      var area1 = shell.find(big1, "listArea");
      if (!check(shell.popupPlacement(one, 880) === "" && Math.abs(area1.width - shell.listBox[0]) < 1 && Math.abs(area1.mapToItem(big1, 0, 0).x - shell.listBox[1]) < 1, "a task in the pane: 880 under the button, the list where it was in the card (" + shell.popupPlacement(one, 880) + ")")) return;
      // The band stays as it is (+, Search, ⋯); the pane has its own header:
      // the task's place, Open in Todoist and Close.
      var taskActions = big1.band.shownTrailing.map(function(item) { return item.objectName; });
      if (!check(JSON.stringify(taskActions) === JSON.stringify(["addAction", "searchAction"]) && big1.band.menuButton.visible, "the band: +, Search, ⋯ (" + JSON.stringify(taskActions) + ")")) return;
      big1.band.openMenu(false);
      var menuTexts = big1.band.menu.entries.filter(function(entry) { return !entry.separator; }).map(function(entry) { return entry.text; });
      if (!check(JSON.stringify(menuTexts) === JSON.stringify(["Open in Todoist", "Settings"]), "the ⋯ menu as without a task (" + JSON.stringify(menuTexts) + ")")) return;
      big1.band.closeMenu();
      big1.goTo(big1.searchStop);
      big1.activate(false);
      if (!check(big1.searching && big1.fieldFocused, "the band's second stop searches with a task in the pane")) return;
      big1.leaveSearch();
      var paneHeader = shell.find(big1.editor, "paneHeader");
      var paneOpen = shell.find(paneHeader, "paneOpen");
      var paneClose = shell.find(paneHeader, "paneClose");
      if (!check(paneHeader.visible && shell.find(paneHeader, "paneHeaderPlace").text === big1.editor.placeLabel && paneOpen.visible && paneOpen.tooltipText === "Open in Todoist" && paneOpen.Accessible.name === "Open in Todoist" && paneClose.visible && paneClose.tooltipText === "Close", "the pane's header: the place, Open and Close")) return;
      // The header's Open opens the pane's task.
      shell.openedBefore = shell.opened().length;
      ev.mouseClick(paneOpen, paneOpen.width / 2, paneOpen.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      big1.cursor.index = big1.firstRowStop;
      if (!check(big1.editor.descriptionField.text === "One" && big1.editor.contentField.text === store.model.byId.t1.content, "the pane: the task and its description")) return;
      // Hover lights a row; the pane stays. ↓ moves both.
      big1.cursor.hover(big1.firstRowStop + 2);
      if (!check(big1.paneTask === "t1", "hover doesn't move the pane")) return;
      big1.cursor.index = big1.firstRowStop;
      // The next task has a long description and many labels: the pane's
      // form is taller than its view.
      shell.put("reply-task.json", JSON.stringify({ ok: true, task: { id: big1.rows[big1.stops[1]].id, description: Array.from({ length: 60 }, function(_, i) { return "Step " + (i + 1); }).join("\n"), truncated: false } }));
      var tall = {};
      tall[big1.rows[big1.stops[1]].id] = { labels: Array.from({ length: 18 }, function(_, i) { return "label " + (i + 1); }) };
      store.snapshot = shell.snapshotWith(tall);
      ev.keyClick(Qt.Key_Down, Qt.NoModifier, -1);
      if (!check(big1.paneTask === big1.rows[big1.stops[1]].id && big1.paneTask !== "t1", "↓ moves the pane (" + big1.paneTask + ")")) return;
      // e: the caret in the pane.
      big1.cursor.emitTextKey(big1, "e");
      break;
    case 84:
      var big2 = one.popup.bodyItem;
      var launchedTask = shell.opened().slice(shell.openedBefore);
      if (!check(launchedTask.length === 1 && launchedTask[0].indexOf(Model.webUrl("task", "t1")) >= 0, "the pane's Open opened the pane's task once (" + JSON.stringify(launchedTask) + ")")) return;
      if (!check(big2.blocked, "the pane has the keys")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(!big2.blocked && !big2.editor.activeFocus && one.opened, "Esc gave the keys back to the list")) return;
      ev.keyClick(Qt.Key_Tab, Qt.NoModifier, -1);
      if (!check(big2.editor.contentField.inputActiveFocus, "Tab goes into the pane")) return;
      // Tab through the pane: each focused control scrolls into view; the
      // first field shows again after it.
      var paneScroll = shell.find(big2.editor, "editorScroll");
      var descriptionField = big2.editor.descriptionField;
      if (!check(descriptionField.height === descriptionField.implicitHeight && descriptionField.height > descriptionField.minimumHeight, "the description field grew with its text (" + JSON.stringify([descriptionField.height, descriptionField.implicitHeight]) + ")")) return;
      if (!check(paneScroll.contentHeight > paneScroll.height + 1, "the pane's form is taller than its view (" + JSON.stringify([paneScroll.contentHeight, paneScroll.height]) + ")")) return;
      var inPane = function(item) { var y = item.mapToItem(paneScroll, 0, 0).y; return y >= -1 && y + item.height <= paneScroll.height + 1; };
      // The last part: the last label's ×, below the fold.
      var lastPart = shell.find(shell.find(big2.editor, "label-label 18"), "removeLabel");
      for (var tabs = 0; tabs < 40 && !lastPart.activeFocus; tabs++) {
        ev.keyClick(Qt.Key_Tab, Qt.NoModifier, -1);
        // The description's inner editor is as tall as its text: its box is what shows.
        var focused = big2.editor.Window.window.activeFocusItem;
        if (focused === descriptionField.editorItem) focused = descriptionField;
        if (!check(focused && inPane(focused), "Tab " + (tabs + 1) + ": the focused control is in view (" + focused + " at " + (focused ? focused.mapToItem(paneScroll, 0, 0).y : "?") + " of " + paneScroll.height + ")")) return;
      }
      if (!check(lastPart.activeFocus && paneScroll.contentY > 0 && Object.keys(big2.editor.pending).length === 0 && !big2.editor.menu.opened, "Tab reached the last label's ×, the pane scrolled, nothing saved or opened (" + paneScroll.contentY + ")")) return;
      // The description scrolled to its end, then Tab away and Shift+Tab
      // back: the field and its caret stay in view (the inner editor is as
      // tall as its text, so it isn't what the pane scrolls to).
      descriptionField.focusInput();
      descriptionField.cursorPosition = descriptionField.length;
      ev.keyClick(Qt.Key_Tab, Qt.NoModifier, -1);
      if (!check(shell.sectionBox(big2.editor, "section-place").activeFocus, "Tab from the description to the project")) return;
      var paneY = paneScroll.contentY;
      ev.keyClick(Qt.Key_Tab, Qt.ShiftModifier, -1);
      var caret = descriptionField.editorItem.cursorRectangle;
      var caretY = descriptionField.editorItem.mapToItem(paneScroll, caret.x, caret.y).y;
      if (!check(descriptionField.inputActiveFocus && descriptionField.contentY > 0 && inPane(descriptionField) && caretY >= 0 && caretY + caret.height <= paneScroll.height && paneScroll.contentY === paneY, "Shift+Tab back: the scrolled description and its caret in view, the pane not moved (" + JSON.stringify([descriptionField.contentY, descriptionField.mapToItem(paneScroll, 0, 0).y, caretY, paneScroll.contentY, paneY, paneScroll.height]) + ")")) return;
      big2.editor.focusFirst();
      if (!check(big2.editor.contentField.cursorPosition === big2.editor.contentField.length && big2.editor.contentField.length > 0, "the first field: the caret after the title (" + big2.editor.contentField.cursorPosition + ")")) return;
      if (!check(big2.editor.contentField.inputActiveFocus && inPane(big2.editor.contentField) && paneScroll.contentY === 0, "the first field: the caret and the pane at the top (" + paneScroll.contentY + ")")) return;
      // Typed in the pane, then a click on another task (no Enter): the
      // text is saved for its own task first, and the keys go to the list.
      shell.paneFrom = big2.paneTask;
      shell.paneText = store.model.byId[shell.paneFrom].content + " now";
      var paneChange = {};
      paneChange[shell.paneFrom] = { content: shell.paneText };
      var paneResults = {};
      paneResults[shell.paneFrom] = "ok";
      shell.put("reply-apply.json", JSON.stringify(Object.assign(shell.snapshotWith(paneChange), { results: paneResults })));
      shell.callsBefore = shell.calls("apply").length;
      big2.editor.contentField.cursorPosition = big2.editor.contentField.text.length;
      for (var p1 of " now") ev.keyClickChar(p1, Qt.NoModifier, -1);
      var otherRow = shell.builtRows(big2).find(function(r) { return r.entry.id !== shell.paneFrom; });
      var otherSurface = shell.find(otherRow, "taskSurface");
      ev.mouseClick(otherSurface, otherSurface.width * 0.6, otherSurface.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      if (!check(big2.paneTask === otherRow.entry.id && big2.editor.contentField.text === store.model.byId[otherRow.entry.id].content && !big2.blocked && !big2.editor.activeFocus, "the click moved the pane, the keys back to the list (" + big2.paneTask + ", " + JSON.stringify(big2.editor.contentField.text) + ")")) return;
      break;
    case 85:
      var big5 = one.popup.bodyItem;
      var paneSent = shell.updatesSince(shell.callsBefore);
      if (!check(JSON.stringify(paneSent) === JSON.stringify([{ op: "update", id: shell.paneFrom, content: shell.paneText }]) && store.model.byId[shell.paneFrom].content === shell.paneText, "the typed text was saved for its own task (" + JSON.stringify(paneSent) + ")")) return;
      // A draft that can't be sent (a deadline that isn't a day), then
      // another task: the list's error line says why, nothing is sent.
      big5.editor.deadlineField.focusInput();
      // The task may already have a deadline, and a full field takes no
      // more keys: select it, so the typed day replaces it.
      ev.keyClick(Qt.Key_A, Qt.ControlModifier, -1);
      for (var d5 of "2026-02-30") ev.keyClickChar(d5, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
      if (!check(big5.editor.errorOf("deadline") === "Enter a deadline as YYYY-MM-DD.", "the bad deadline is caught in the pane")) return;
      var badFrom = big5.paneTask;
      var thirdRow = shell.builtRows(big5).find(function(r) { return r.entry.id !== badFrom; });
      var thirdSurface = shell.find(thirdRow, "taskSurface");
      ev.mouseClick(thirdSurface, thirdSurface.width * 0.6, thirdSurface.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      if (!check(big5.paneTask === thirdRow.entry.id && store.error === "Enter a deadline as YYYY-MM-DD." && shell.calls("apply").length === shell.callsBefore + 1, "the unsendable draft is said on the list's line (" + JSON.stringify(store.error) + ")")) return;
      store.error = "";
      ev.keyClick(Qt.Key_Tab, Qt.NoModifier, -1);
      if (!check(big5.editor.contentField.inputActiveFocus, "Tab into the pane again")) return;
      shell.draftThenComplete(big5, "title ring", function() {
      shell.draftThenComplete(big5, "ring", function() {
      shell.listSpace(big5, function() {
      shell.pasteStaysWithItsTask(big5, function() {
      shell.paneKeys(big5, function() {
      shell.paneCompleted(big5, function() {
      // Typed again, then the Week view from the rail: saved as the pane goes.
      big5.editor.contentField.focusInput();
      shell.paneFrom = big5.paneTask;
      shell.paneText = store.model.byId[shell.paneFrom].content + " too";
      var paneChange2 = {};
      paneChange2[shell.paneFrom] = { content: shell.paneText };
      var paneResults2 = {};
      paneResults2[shell.paneFrom] = "ok";
      shell.put("reply-apply.json", JSON.stringify(Object.assign(shell.snapshotWith(paneChange2), { results: paneResults2 })));
      shell.callsBefore = shell.calls("apply").length;
      big5.editor.contentField.cursorPosition = big5.editor.contentField.text.length;
      for (var p2 of " too") ev.keyClickChar(p2, Qt.NoModifier, -1);
      // The Week view, from the rail: four columns.
      var weekEntry = shell.find(big5, "rail-week");
      ev.mouseClick(weekEntry, weekEntry.width / 2, weekEntry.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      if (!check(big5.weekShown && !big5.editor.visible && !big5.blocked, "the Week view; the pane went, the keys with the list")) return;
      });
      });
      });
      });
      });
      });
      break;
    case 86:
      var big2 = one.popup.bodyItem;
      var weekSent = shell.updatesSince(shell.callsBefore);
      if (!check(JSON.stringify(weekSent) === JSON.stringify([{ op: "update", id: shell.paneFrom, content: shell.paneText }]), "the view change saved the typed text (" + JSON.stringify(weekSent) + ")")) return;
      var ids = big2.weekColumns.map(function(col) { return col.entries.map(function(e) { return e.kind === "day" ? e.key : e.id; }); });
      if (!check(big2.weekShown && big2.week.visible && !big2.list.visible && JSON.stringify(ids) === JSON.stringify([["t1", "t2"], ["t3", "t4", "t5", "t6"], ["t10", "t11"], ["day:2026-11-21", "t12"]]), "the Week view's columns (" + JSON.stringify(ids) + ")")) return;
      if (!check(!big2.editor.visible, "no pane until a card is opened")) return;
      if (!check(!big2.overviewShown && one.cardWidth === 880 && one.popup.contentWidth === 880, "the Week view: 880, no overview (" + JSON.stringify([big2.overviewShown, one.cardWidth, one.popup.contentWidth]) + ")")) return;
      big2.goTo(big2.firstRowStop);
      if (!check(big2.cursorRow().id === "t1" && big2.weekColumn === 0, "the first card")) return;
      ev.keyClick(Qt.Key_Down, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Right, Qt.NoModifier, -1);
      if (!check(big2.weekColumn === 1 && big2.cursorRow().id === "t4", "↓ then →: Today's second card (" + big2.cursorRow().id + ")")) return;
      ev.keyClick(Qt.Key_Left, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Left, Qt.NoModifier, -1);
      if (!check(big2.cursor.index === big2.railStop, "← from the first column: the rail")) return;
      big2.goTo(big2.firstRowStop);
      if (!check(big2.cursorRow().id === "t2", "back on t2")) return;
      ev.keyClick(Qt.Key_Space, Qt.NoModifier, -1);
      if (!check(store.struck.t2 === true, "Space completes")) return;
      // The card's ring as the list's: its priority's look, the completed
      // check reading on its fill; the columns' counts read.
      var weekCard = shell.find(big2.week, "card-t2");
      var weekRing = shell.find(weekCard, "weekRingMark");
      var weekMark = shell.find(weekCard, "weekRingCheck");
      if (!check(weekMark.visible && weekRing.color.a > 0.995 && shell.checkContrast(weekRing, weekMark) >= 4.5, "the completed card's check reads (" + shell.checkContrast(weekRing, weekMark).toFixed(2) + ":1)")) return;
      var p1Ring = shell.find(shell.find(big2.week, "card-t1"), "weekRingMark");
      if (!check(shell.ringIs(p1Ring, 2, 0.4) === "", "a p1 card's ring: " + shell.ringIs(p1Ring, 2, 0.4))) return;
      var weekCount = shell.find(shell.find(big2.week, "weekColumn-today"), "weekCount");
      var weekRatio = Kit.FoamyPalette.contrastRatio(weekCount.color, Kit.FoamyPalette.background);
      if (!check(weekCount.text !== "" && weekRatio >= 4.5, "a column's count reads (" + weekRatio.toFixed(2) + ":1)")) return;
      ev.keyClick(Qt.Key_Space, Qt.NoModifier, -1);
      if (!check(!store.struck.t2, "and undoes")) return;
      // A card is built from the row's parts: the row's ring and title
      // size; the time in the mono face, the project after the row's
      // hash, the repeat mark; overdue, only the date in red, with the
      // warning mark.
      var cardPart = function(id, name) { return shell.find(shell.find(big2.week, "card-" + id), name); };
      var shownPart = function(id, name) { var item = cardPart(id, name); return !!item && item.visible; };
      var standUp = ["cardTime", "cardHash", "cardProject", "cardRepeat"].map(function(name) { return shownPart("t3", name); });
      if (!check(standUp.every(Boolean) && cardPart("t3", "cardTime").text === "09:30" && cardPart("t3", "cardTime").font.family === Kit.FoamyStyle.monoFamily && cardPart("t3", "cardProject").text === "Work" && Qt.colorEqual(cardPart("t3", "cardHash").color, Kit.FoamyPalette.mutedText) && cardPart("t3", "cardText").font.pixelSize === Kit.FoamyStyle.font.body && cardPart("t3", "weekRingMark").width === 16, "a card's parts as a row's: mono time, hash and project, repeat mark, the title's size, the ring (" + JSON.stringify(standUp) + ")")) return;
      var red = Kit.FoamyPalette.onSurface(Kit.FoamyPalette.error);
      if (!check(shownPart("t1", "cardLateMark") && Qt.colorEqual(cardPart("t1", "cardDate").color, red) && !Qt.colorEqual(cardPart("t1", "cardProject").color, red) && !shownPart("t3", "cardLateMark") && !Qt.colorEqual(cardPart("t3", "cardTime").color, red), "overdue: only the date red, with the warning mark (" + JSON.stringify([String(cardPart("t1", "cardDate").color), String(cardPart("t1", "cardProject").color)]) + ")")) return;
      // An unconfirmed completion: as the list's row, not dimmed: the
      // title in the secondary tone, a plain ring, the refresh mark.
      store.unconfirmed = { t5: true };
      var unconfirmedRing = cardPart("t5", "weekRingMark");
      if (!check(shownPart("t5", "cardChecking") && shell.sameColor(cardPart("t5", "cardText").color, Kit.FoamyPalette.secondaryText) && unconfirmedRing.border.width === 1 && unconfirmedRing.color.a === 0 && shell.find(big2.week, "card-t5").children.every(function(child) { return child.opacity === 1; }) && shell.find(shell.find(big2.week, "card-t5"), "cardText").opacity === 1, "an unconfirmed card reads as the row: plain ring, secondary title, refresh mark (" + JSON.stringify([shownPart("t5", "cardChecking"), String(cardPart("t5", "cardText").color), unconfirmedRing.border.width, unconfirmedRing.color.a, shell.find(big2.week, "card-t5").children.map(function(child) { return child.opacity; })]) + ")")) return;
      store.unconfirmed = {};
      // While the board has the keys, the footer names them.
      var weekHints = shell.find(big2, "keyHints");
      var weekHintTexts = shell.visibleTexts(weekHints);
      if (!check(weekHints.visible && JSON.stringify(weekHintTexts) === JSON.stringify(["t", "tomorrow", "Ctrl", "←", "→", "move a day", "Space", "complete", "↵", "details"]), "the Week footer names its keys (" + JSON.stringify(weekHintTexts) + ")")) return;
      big2.goTo(big2.railStop);
      if (!check(!weekHints.visible, "the keys on the rail: no Week hints")) return;
      big2.goTo(big2.firstRowStop);
      // Ctrl+→: a day later with the due op; the cursor follows the task.
      shell.put("reply-apply.json", JSON.stringify(Object.assign(shell.snapshotWith({ t2: { due: Fixtures.due(shell.today) } }), { results: { t2: "ok" } })));
      shell.callsBefore = shell.calls("apply").length;
      big2.focusList();
      ev.keyClick(Qt.Key_Right, Qt.ControlModifier, -1);
      break;
    case 87:
      var big3 = one.popup.bodyItem;
      // The hints fit beside the footer's status, Wide.
      var fitHints = shell.find(big3, "keyHints");
      var footerStatus = shell.find(big3, "foamyFooterStatus");
      var hintsEnd = fitHints.mapToItem(big3, fitHints.width, 0).x;
      var statusStart = footerStatus.mapToItem(big3, 0, 0).x + footerStatus.width - footerStatus.contentWidth;
      if (!check(fitHints.visible && footerStatus.visible && !footerStatus.truncated && hintsEnd + Kit.FoamyStyle.gap <= statusStart, "the Week hints fit beside the status (" + JSON.stringify([hintsEnd, statusStart, footerStatus.text]) + ")")) return;
      var sent5 = JSON.parse(shell.calls("apply").pop().slice("apply ".length));
      if (!check(JSON.stringify(sent5) === JSON.stringify({ commands: [{ op: "due", id: "t2", date: shell.today }] }), "Ctrl+→ moved t2 to today (" + JSON.stringify(sent5) + ")")) return;
      if (!check(big3.weekColumn === 1 && big3.cursorRow().id === "t2", "the cursor followed it to Today")) return;
      // Ctrl+←: never before today.
      ev.keyClick(Qt.Key_Left, Qt.ControlModifier, -1);
      if (!check(store.queue.length === 0 && !store.busy && shell.calls("apply").length === shell.callsBefore + 1, "Ctrl+← on today sends nothing")) return;
      // Enter: the pane over the right part, the caret in it.
      shell.put("reply-task.json", JSON.stringify({ ok: true, task: { id: "t2", description: "", truncated: false } }));
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
      if (!check(big3.weekPaneOpen && big3.editor.visible && big3.editor.taskId === "t2" && Math.abs(big3.week.width - shell.find(big3, "listArea").width) < 1, "Enter opened the pane over the week")) return;
      break;
    case 88:
      var big4 = one.popup.bodyItem;
      // The pane over the Week view: the card is tall enough to show it
      // whole instead of cutting it to the week's height.
      if (!check(big4.bodyHeight >= big4.editor.implicitHeight - 1 && big4.editor.implicitHeight <= big4.maxListHeight, "the card holds the pane, under the cap (" + JSON.stringify([big4.editor.implicitHeight, big4.bodyHeight, big4.maxListHeight]) + ")")) return;
      // The pane stands beside the board: the four columns narrow, none is
      // under the pane.
      var boardEnd = big4.week.mapToItem(big4, big4.week.width, 0).x;
      var paneStart = big4.editor.mapToItem(big4, 0, 0).x;
      var lastColumn = shell.find(big4.week, "weekColumn-later");
      if (!check(big4.week.narrow && boardEnd <= paneStart + 1 && lastColumn.visible && lastColumn.mapToItem(big4, lastColumn.width, 0).x <= paneStart + 1, "the board beside the pane, its four columns whole (" + JSON.stringify([boardEnd, paneStart]) + ")")) return;
      var weekPaneScroll = shell.find(big4.editor, "editorScroll");
      if (!check(weekPaneScroll.contentHeight <= weekPaneScroll.height + 1, "the pane over the week shows whole (" + JSON.stringify([weekPaneScroll.contentHeight, weekPaneScroll.height]) + ")")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(!big4.blocked && big4.weekPaneOpen, "Esc: the keys back, the pane stays")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(!big4.weekPaneOpen && !big4.editor.visible && one.opened, "Esc: the pane closes")) return;
      // The pane again; a click in it keeps it, a click on a column's empty
      // space (below its cards, its heading) closes it and clears the cursor.
      big4.goTo(big4.firstRowStop);
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(big4.weekPaneOpen && big4.editor.visible && !big4.blocked, "Enter opened the pane over the week again")) return;
      // The pane's Close: as Esc, the pane closes and the selection stays.
      var weekClose = shell.find(big4.editor, "paneClose");
      ev.mouseClick(weekClose, weekClose.width / 2, weekClose.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      if (!check(!big4.weekPaneOpen && !big4.editor.visible && big4.cursor.index === big4.firstRowStop && !big4.blocked && one.opened, "the pane's Close closed it, the cursor kept")) return;
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(big4.weekPaneOpen && big4.editor.visible && !big4.blocked, "Enter opened the pane over the week once more")) return;
      ev.mouseClick(big4.editor, big4.editor.width / 2, 4, Qt.LeftButton, Qt.NoModifier, -1);
      if (!check(big4.weekPaneOpen && big4.cursor.index === big4.firstRowStop, "a click in the pane over the week keeps it")) return;
      var todayList = shell.find(big4.week, "weekColumn-today").list;
      var todayBelow = todayList.contentHeight - todayList.contentY;
      if (!check(todayBelow < todayList.height - 12, "Today's column has room below its cards (" + JSON.stringify([todayList.contentHeight, todayList.height]) + ")")) return;
      ev.mouseClick(todayList, todayList.width / 2, todayBelow + 8, Qt.LeftButton, Qt.NoModifier, -1);
      if (!check(!big4.weekPaneOpen && !big4.editor.visible && big4.cursor.index === -1 && big4.paneTask === "", "a click below a column's cards closed the pane, the cursor gone")) return;
      big4.goTo(big4.firstRowStop);
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      var overdueHead = shell.find(big4.week, "weekColumn-overdue");
      ev.mouseClick(overdueHead, overdueHead.width / 2, 6, Qt.LeftButton, Qt.NoModifier, -1);
      if (!check(!big4.weekPaneOpen && big4.cursor.index === -1, "a click on a column's heading closed it too")) return;
      if (!check(!big4.overviewShown && one.cardWidth === 880, "the Week view: 880 with nothing selected, no overview")) return;
      // Wide keeps its height while open: a view that needs less (Inbox)
      // leaves the card as tall as it has been, and never under 12 rows.
      var heldBody = big4.bodyHeight;
      big4.setView("inbox");
      // The Inbox selected in the rail: its count reads on the selected fill.
      var railInbox = shell.railCounts(big4);
      if (!check(railInbox.selected === 1 && railInbox.low.length === 0, "the selected rail row's count reads (" + JSON.stringify(railInbox) + ")")) return;
      if (!check(big4.fittedBodyHeight < heldBody - 1 && big4.bodyHeight === heldBody && heldBody >= Kit.FoamyStyle.rowHeight * 12, "a shorter view keeps the card's height (" + JSON.stringify([big4.fittedBodyHeight, big4.bodyHeight, heldBody]) + ")")) return;
      big4.setView("week");
      // Overdue with thousands of tasks: only the cards in view are built,
      // and the keys scroll to the cursor's card.
      var many = shell.snapshot();
      for (var m = 0; m < 3000; m++)
        many.tasks.push(Fixtures.task("o" + m, "Old " + m, "home", { due: Fixtures.due(Fixtures.shift(shell.today, -3 - (m % 30))), child_order: 100 + m }));
      store.snapshot = many;
      var overdueList = shell.find(big4.week, "weekColumn-overdue").list;
      var countCards = function(item) { return item.children.reduce(function(sum, child) { return sum + (child.objectName.indexOf("card-") === 0 ? 1 : 0) + countCards(child); }, 0); };
      var built = countCards(overdueList.contentItem);
      if (!check(big4.weekColumns[0].cards.length === 3002 && built > 0 && built < 200, "Overdue builds only what shows (" + built + " of " + big4.weekColumns[0].cards.length + ")")) return;
      big4.weekPlace(0, 0);
      big4.goTo(big4.firstRowStop);
      for (var k = 0; k < 60; k++) ev.keyClick(Qt.Key_Down, Qt.NoModifier, -1);
      var at = big4.cursorRow();
      var atCard = shell.find(overdueList.contentItem, "card-" + at.id);
      var atTop = atCard ? atCard.mapToItem(overdueList, 0, 0).y : -1000;
      if (!check(big4.weekColumn === 0 && big4.weekCard === 60 && at.id === big4.weekColumns[0].entries[60].id && atCard && atTop >= -1 && atTop + atCard.height <= overdueList.height + 1, "↓ 60 times: the card in view (" + JSON.stringify([big4.weekCard, at.id, atTop]) + ")")) return;
      // → and ←: the same row where the column has it, else its last card.
      ev.keyClick(Qt.Key_Right, Qt.NoModifier, -1);
      if (!check(big4.weekColumn === 1 && big4.weekCard === big4.weekCards(1) - 1, "→: Today's last card (" + big4.weekCard + ")")) return;
      ev.keyClick(Qt.Key_Left, Qt.NoModifier, -1);
      if (!check(big4.weekColumn === 0 && big4.weekCard === big4.weekCards(1) - 1, "←: that row in Overdue (" + big4.weekCard + ")")) return;
      store.snapshot = shell.snapshot();
      shell.weekPaneKeys(big4, function() {
        // A task moved to Monday the 23rd: its card stands there (the undo
        // window held, so the move isn't sent meanwhile).
        store.holdUndo(true);
        store.move("t11", "2026-11-23");
        shell.put("reply-add.json", JSON.stringify(Object.assign(shell.snapshot(), { added: "t1" })));
        var tomorrow = Model.addDays(shell.today, 1);
        shell.weekAdds(big4, [
          ["overdue", 0, 0, shell.today, "Add a task for today…"],
          ["today", 1, 2, shell.today, "Add a task for today…"],
          ["tomorrow", 2, 0, tomorrow, "Add a task for Thursday 19 November…"],
          ["later", 3, 0, "2026-11-21", "Add a task for Saturday 21 November…"],
          ["moved", 3, 1, "2026-11-23", "Add a task for Monday 23 November…"],
          ["off the board", 0, -1, shell.today, "Add a task for today…"]
        ], function() {
          // The cursor leaves the board for +: the day it was on stays
          // (as Upcoming's); "Add as a task" from a search without a match
          // is for today.
          big4.focusList();
          big4.weekPlace(2, 0);
          big4.goTo(big4.firstRowStop);
          var plus = shell.find(big4, "addAction");
          ev.mouseMove(plus, plus.width / 2, plus.height / 2, -1, Qt.NoButton, Qt.NoModifier);
          ev.mouseClick(plus, plus.width / 2, plus.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
          if (!check(big4.fieldFocused && big4.field.placeholderText === "Add a task for Thursday 19 November…", "+ from a Tomorrow card: the add is for tomorrow (" + big4.field.placeholderText + ")")) return;
          ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
          big4.focusList();
          big4.weekPlace(2, 0);
          big4.goTo(big4.firstRowStop);
          big4.startSearch();
          for (var q of "zzzz") ev.keyClickChar(q, Qt.NoModifier, -1);
          big4.addQuery();
          if (!check(big4.adding && big4.field.text === "zzzz" && big4.addDay === shell.today, "Add as a task from a search without a match: for today (" + JSON.stringify([big4.field.text, big4.addDay]) + ")")) return;
          ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
          ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
          if (!check(!big4.fieldOpen, "Esc twice: the field closed")) return;
          // The cursor's card moved a day (Ctrl+→): the add is for its new
          // column's day.
          big4.focusList();
          big4.weekPlace(1, 1);
          big4.goTo(big4.firstRowStop);
          var moving = big4.cursorRow().id;
          ev.keyClick(Qt.Key_Right, Qt.ControlModifier, -1);
          if (!check(big4.cursorRow() && big4.cursorRow().id === moving && big4.weekColumns[big4.weekColumn].key === "tomorrow" && store.moves[moving] === tomorrow, "Ctrl+→: the card and the cursor in Tomorrow (" + JSON.stringify([big4.weekColumn, store.moves]) + ")")) return;
          big4.cursor.emitTextKey(big4, "a");
          if (!check(big4.fieldFocused && big4.field.placeholderText === "Add a task for Thursday 19 November…", "a after Ctrl+→: the add is for tomorrow (" + big4.field.placeholderText + ")")) return;
          // A draft keeps the day it was started for: a click on a Later
          // card (the field stays open, its text hides the placeholder)
          // doesn't change it.
          for (var w of "Draft") ev.keyClickChar(w, Qt.NoModifier, -1);
          var laterCard = shell.find(big4.week, "card-" + big4.weekColumns[3].entries[big4.weekColumns[3].cards[0]].id);
          ev.mouseClick(laterCard, laterCard.width / 2, laterCard.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
          if (!check(big4.fieldOpen && big4.field.text === "Draft" && big4.weekColumns[big4.weekColumn].key === "later" && big4.addDay === tomorrow, "a click on a Later card with a draft: the draft's day stays (" + JSON.stringify([big4.fieldOpen, big4.weekColumn, big4.addDay]) + ")")) return;
          big4.field.focusInput();
          ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
          ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
          big4.clearSelection();
          big4.focusList();
          store.undo(moving);
          if (!check(!big4.fieldOpen && !big4.weekPaneOpen && !Model.has(store.moves, moving), "the field and the pane closed, the move undone")) return;
          store.undo("t11");
          store.holdUndo(false);
          ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
          check(!one.opened, "Esc: the popup closes");
        });
      });
      break;
    case 89:
      // Closing lets the held height go.
      if (!check(one.popup.bodyItem.heldBodyHeight === 0, "the closed popup holds no height (" + one.popup.bodyItem.heldBodyHeight + ")")) return;
      // The closed popup keeps its view, but builds no list behind it.
      var hidden = one.popup.bodyItem;
      if (!check(hidden && hidden.weekShown && hidden.weekColumns.length === 0 && hidden.rows.length === 0, "a closed popup builds no Week columns or rows (" + (hidden ? JSON.stringify([hidden.weekColumns.length, hidden.rows.length]) : "no view") + ")")) return;
      // Wide again, in Norwegian.
      shell.put("reply-task.json", JSON.stringify({ ok: true, task: { id: "t1", description: "One", truncated: false } }));
      shell.pickLanguage("no");
      ev.mouseClick(button, button.width / 2, button.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      Qt.callLater(function() { var v = one.popup.bodyItem; if (v) v.goTo(v.firstRowStop); });
      break;
    case 90:
      var big6 = one.popup.bodyItem;
      if (!check(big6.view === "today" && big6.rows.length > 0, "open again (on Today): the rows are back (" + big6.rows.length + ")")) return;
      var noOpen = shell.find(big6.editor, "paneOpen");
      var noClose = shell.find(big6.editor, "paneClose");
      var noTexts = ["section-place", "section-due", "section-deadline", "section-priority", "section-labels"].map(function(name) { return shell.find(shell.find(big6.editor, name), "sectionCaption").text; });
      if (!check(big6.editor.ring.Accessible.name === "Fullfør" && noOpen.tooltipText === "Åpne i Todoist" && noClose.tooltipText === "Lukk" && JSON.stringify(noTexts) === JSON.stringify(["Prosjekt", "Dato", "Frist", "Prioritet", "Etiketter"]), "Norwegian: the ring, Open, Close and the captions (" + JSON.stringify(noTexts) + ")")) return;
      // Typed in the pane, then a click outside the popup: it closes, and
      // the text is saved for its task.
      shell.paneFrom = big6.paneTask;
      shell.paneText = store.model.byId[shell.paneFrom].content + " later";
      var closeChange = {};
      closeChange[shell.paneFrom] = { content: shell.paneText };
      var closeResults = {};
      closeResults[shell.paneFrom] = "ok";
      shell.put("reply-apply.json", JSON.stringify(Object.assign(shell.snapshotWith(closeChange), { results: closeResults })));
      shell.callsBefore = shell.calls("apply").length;
      big6.editor.contentField.focusInput();
      big6.editor.contentField.cursorPosition = big6.editor.contentField.text.length;
      for (var p6 of " later") ev.keyClickChar(p6, Qt.NoModifier, -1);
      ev.mouseClick(one.popup, 20, one.popup.height - 20, Qt.LeftButton, Qt.NoModifier, -1);
      if (!check(!one.opened, "a click outside closed the popup")) return;
      shell.pickLanguage("en");
      break;
    case 91:
      var closeSent = shell.updatesSince(shell.callsBefore);
      if (!check(JSON.stringify(closeSent) === JSON.stringify([{ op: "update", id: shell.paneFrom, content: shell.paneText }]), "closing saved the typed text (" + JSON.stringify(closeSent) + ")")) return;
      // Wide in Arabic (right to left).
      shell.pickLanguage("ar");
      ev.mouseClick(button, button.width / 2, button.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      break;
    case 92:
      // Mirrored: the rail on the right, the list beside it, the overview
      // on the left.
      if (!check(view.overviewShown && shell.rtlLayout(view) === "", "Arabic, the overview: " + shell.rtlLayout(view))) return;
      var rtlArea = shell.find(view, "listArea");
      shell.listBox = [rtlArea.width, view.width - rtlArea.mapToItem(view, 0, 0).x];
      // The timeline's blocks mirror too: past the hours, on the right.
      var rtlBlock = shell.find(view, "block-t3");
      var rtlBlockBox = rtlBlock.mapToItem(shell.find(view, "timeline"), 0, 0);
      if (!check(rtlBlock.visible && rtlBlockBox.x + rtlBlock.width < shell.find(view, "timeline").width - Kit.FoamyStyle.controlHeight + 1 && rtlBlockBox.x < Kit.FoamyStyle.controlHeight, "Arabic: the block left of the hours (" + JSON.stringify([rtlBlockBox.x, rtlBlock.width]) + ")")) return;
      view.goTo(view.firstRowStop);
      break;
    case 93:
      // A task in the pane: the list keeps its width and place.
      var rtlTask = shell.find(view, "listArea");
      if (!check(shell.popupPlacement(one, 880) === "" && Math.abs(rtlTask.width - shell.listBox[0]) < 0.5 && Math.abs(view.width - rtlTask.mapToItem(view, 0, 0).x - shell.listBox[1]) < 0.5, "Arabic, a task in the pane: 880, the list where it was (" + JSON.stringify([shell.popupPlacement(one, 880), rtlTask.width, shell.listBox]) + ")")) return;
      if (!check(shell.rtlLayout(view) === "", "Arabic, a task in the pane: " + shell.rtlLayout(view))) return;
      view.setView("week");
      break;
    case 94:
      if (!check(view.weekColumns.length === 4 && one.popup.contentWidth === 880 && shell.rtlLayout(view) === "", "Arabic, the Week view: " + shell.rtlLayout(view))) return;
      view.setView("today");
      one.close();
      shell.pickLanguage("en");
      break;
    case 95:
      // Wide needs room for 880 on the bar's screen; with less, Small.
      shell.savedMargin = one.popup.margin;
      one.popup.margin = 520;
      if (!check(one.popup.availableCardWidth === 880 && one.size === "wide", "room for 880: Wide (" + JSON.stringify([one.popup.availableCardWidth, one.size]) + ")")) return;
      one.popup.margin = 521;
      if (!check(one.popup.availableCardWidth === 878 && one.size === "standard" && one.cardWidth === Kit.FoamyStyle.popupWidth, "no room for 880: Small (" + JSON.stringify([one.popup.availableCardWidth, one.size]) + ")")) return;
      one.popup.margin = shell.savedMargin;
      ev.mouseClick(button, button.width / 2, button.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      break;
    case 96:
      if (!check(view.size === "wide" && shell.popupPlacement(one, 880) === "", "the popup is Wide, 880 (" + view.size + ", " + shell.popupPlacement(one, 880) + ")")) return;
      // Selecting and clearing never change the width.
      view.goTo(view.firstRowStop);
      var withTask = [one.cardWidth, one.popup.contentWidth, view.paneShown];
      view.clearSelection();
      if (!check(JSON.stringify(withTask) === JSON.stringify([880, 880, true]) && one.cardWidth === 880 && one.popup.contentWidth === 880 && view.overviewShown, "880 with a task and without (" + JSON.stringify([withTask, one.cardWidth]) + ")")) return;
      // Settings: 880 too, its sections in a column of the settings width, centred.
      view.settingsRequested();
      var section = shell.find(view.settingsPage, "accountSection");
      var sectionX = section.mapToItem(view, 0, 0).x;
      var column = Kit.FoamyStyle.popupWidthWide - Kit.FoamyStyle.padding * 2;
      if (!check(view.editingSettings && one.cardWidth === 880 && one.popup.contentWidth === 880 && section.width === column && Math.abs(sectionX - (view.width - column) / 2) < 1, "settings in Wide: 880, the column " + column + " centred (" + JSON.stringify([one.cardWidth, section.width, sectionX]) + ")")) return;
      view.settingsClosed();
      if (!check(!view.editingSettings && one.popup.contentWidth === 880, "back from settings: 880")) return;
      one.close();
      // IPC toggle: the leader's popup, Wide.
      var ipc = one.data.concat(two.data).find(function(item) { return item.target === "foamy.todoist" && item.enabled && typeof item.toggle === "function"; });
      shell.ipcPanel = one.data.indexOf(ipc) >= 0 ? one : two;
      if (!check(shell.ipcPanel === shell.leader(), "the leader owns IPC")) return;
      shell.afterClose(function() { ipc.toggle(); });
      break;
    case 97:
      var lead = shell.leader();
      if (!check(shell.popupPlacement(lead, 880) === "", "IPC toggle: the leader's popup, 880 wide under its button (" + shell.popupPlacement(lead, 880) + ")")) return;
      // IPC add while Wide is open: the caret in the band's field.
      var ipcAdd = lead.data.find(function(item) { return item.target === "foamy.todoist" && item.enabled && typeof item.add === "function"; });
      ipcAdd.add();
      break;
    case 98:
      var lead2 = shell.leader();
      var leadView = lead2.popup.bodyItem;
      if (!check(lead2.opened && leadView.fieldOpen && !leadView.searching && leadView.size === "wide", "IPC add: the add field in the Wide popup")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      // The Week view from Today with nothing selected: 880.
      // Then another size: Today, and "Open on: Last view" opens Today.
      leadView.setView("week");
      if (!check(store.lastView === "week" && lead2.cardWidth === 880, "Week is the last view, at 880")) return;
      one.prefs.save("openOn", "last");
      one.prefs.save("panelWidth", "standard");
      break;
    case 99:
      var lead3 = shell.leader();
      if (!check(lead3.popup.bodyItem.view === "today" && lead3.popup.bodyItem.size === "standard", "another size: the Week view became Today (" + lead3.popup.bodyItem.view + ")")) return;
      lead3.close();
      one.open();
      break;
    case 100:
      if (!check(view.view === "today" && view.size === "standard", "the Week view fell back to Today (" + view.view + ")")) return;
      view.settingsRequested();
      shell.refusedPicks(view, function() {
        shell.keysAfterSettings(view, function() { one.prefs.save("openOn", "today"); });
      });
      break;
    case 101:
      // A sync still running when the user signs out: its reply is for the
      // account that went and must show nothing (the sign-out waits behind it,
      // held until the step has looked).
      shell.hold("sync");
      shell.hold("token-clear");
      store.sync();
      break;
    case 102:
      shell.callsBefore = shell.calls("token-clear").length;
      store.signOut();
      shell.release("sync");
      break;
    case 103:
      if (!check(store.snapshot === null && !store.loaded && !one.barContent.countLabel.visible, "a sync reply from before sign-out shows nothing of the old account (" + JSON.stringify([store.loaded, one.barContent.countLabel.visible]) + ")")) return;
      shell.release("token-clear");
      break;
    case 104:
      if (!check(button.tooltipText === "Todoist: not signed in" && shell.calls("token-clear").length === shell.callsBefore + 1, "signed out: the bar says so, one token-clear (" + button.tooltipText + ")")) return;
      shell.put("reply-token-set.json", JSON.stringify({ ok: true, state: "signed_in", user: shell.snapshot().user }));
      store.setToken("again");
      break;
    case 105:
      // The keyring item went elsewhere: a SIGNED_OUT reply from any job
      // clears the tasks and shows the signed-out state.
      shell.put("reply-sync.json", JSON.stringify({ ok: false, code: "SIGNED_OUT", error: "Not signed in to Todoist." }));
      store.sync();
      break;
    case 106:
      if (!check(!store.loaded && !one.barContent.countLabel.visible && button.tooltipText === "Todoist: not signed in", "SIGNED_OUT: no tasks, no count (" + button.tooltipText + ")")) return;
      one.open();
      break;
    case 107:
      if (!check(shell.find(view, "stateText").text === "Add your Todoist API token in Settings" && view.rows.length === 0, "SIGNED_OUT: the popup asks for a token, no rows (" + JSON.stringify([shell.find(view, "stateText").text, view.rows.length]) + ")")) return;
      // The keyring is locked: unlocking it can fix that, so the popup
      // offers Retry. Unlocked, it holds a value that another program
      // stored and that isn't a token: Retry checks again (step 108).
      shell.callsBefore = shell.calls("status").length;
      shell.put("reply-status.json", JSON.stringify({ ok: false, code: "KEYRING_LOCKED", error: "The keyring that holds the Todoist token is locked. Unlock it and try again." }));
      store.check();
      wait.waitFor(function() { return store.account === "error" && !store.busy; }, 15000, function(locked) {
        var retry = shell.find(view, "stateButton");
        if (!check(locked && shell.find(view, "stateText").text === "The keyring that holds the Todoist token is locked. Unlock it and try again." && retry.visible && retry.text === "Retry", "a locked keyring: the popup says so, with Retry (" + JSON.stringify([locked, shell.find(view, "stateText").text, retry.text]) + ")")) return;
        shell.put("reply-status.json", JSON.stringify({ ok: false, code: "INVALID_TOKEN", error: "Todoist didn't accept the API token." }));
        retry.clicked();
      });
      break;
    case 108:
      if (!check(shell.find(view, "stateText").text === "Todoist didn't accept the API token.", "a refused stored value: the popup says so (" + shell.find(view, "stateText").text + ")")) return;
      // Retry would get the same refusal: the popup's button opens
      // Settings, with the token form, the reason, and Sign out to remove
      // the stored value and the cache without a working token.
      var toSettings = shell.find(view, "stateButton");
      if (!check(toSettings.visible && toSettings.text === "Open settings", "a refused stored value: the popup offers Open settings, not Retry (" + toSettings.text + ")")) return;
      toSettings.clicked();
      var refusedPage = view.settingsPage;
      if (!check(view.editingSettings, "Open settings opened Settings")) return;
      if (!check(shell.find(refusedPage, "signedOutForm").visible && !shell.find(refusedPage, "signedInRow").visible && shell.find(refusedPage, "tokenError").text === "Todoist didn't accept the API token.", "a refused stored value: the token form and the reason (" + shell.find(refusedPage, "tokenError").text + ")")) return;
      var errorSignOut = shell.find(refusedPage, "errorSignOutButton");
      if (!check(errorSignOut && errorSignOut.visible && errorSignOut.text === "Sign out", "a refused stored value: Sign out is offered")) return;
      shell.put("reply-token-clear.json", JSON.stringify({ ok: true, state: "signed_out", user: null }));
      shell.callsBefore = shell.calls("token-clear").length;
      errorSignOut.clicked();
      break;
    case 109:
      if (!check(shell.calls("token-clear").length === shell.callsBefore + 1 && !shell.find(view.settingsPage, "errorSignOutButton").visible, "Sign out ran one token-clear and is gone once signed out")) return;
      // A token stored whose new cache couldn't be written: the warning
      // shows until a sync answers (held until the step has seen it).
      shell.put("reply-token-set.json", JSON.stringify({ ok: true, state: "signed_in", user: shell.snapshot().user, warning: "Can't save the Todoist cache (%1).\u001fPermission denied (os error 13)" }));
      shell.put("reply-sync.json", JSON.stringify(shell.snapshot()));
      shell.hold("sync");
      store.setToken("again");
      break;
    case 110:
      if (!check(store.error === "Can't save the Todoist cache (Permission denied (os error 13)).", "token-set's warning shows (" + store.error + ")")) return;
      view.settingsClosed();
      // No tasks yet, so the list says why a sync failed. The held sync
      // finds the keyring locked: Retry. The next one is refused by
      // Todoist: Open settings, where Sign out and a new token are.
      shell.put("reply-sync.json", JSON.stringify({ ok: false, code: "KEYRING_LOCKED", error: "The keyring that holds the Todoist token is locked. Unlock it and try again." }));
      shell.release("sync");
      wait.waitFor(function() { return store.errorCode === "KEYRING_LOCKED" && !store.busy; }, 15000, function(locked) {
        var stateButton = shell.find(view, "stateButton");
        if (!check(locked && !store.loaded && shell.find(view, "stateText").text === "The keyring that holds the Todoist token is locked. Unlock it and try again." && stateButton.visible && stateButton.text === "Retry", "a sync that found the keyring locked: no tasks, why, Retry (" + JSON.stringify([locked, store.loaded, shell.find(view, "stateText").text, stateButton.text]) + ")")) return;
        shell.put("reply-sync.json", JSON.stringify({ ok: false, code: "INVALID_TOKEN", error: "Todoist didn't accept the API token." }));
        var syncs = shell.calls("sync").length;
        stateButton.clicked();
        wait.waitFor(function() { return shell.calls("sync").length === syncs + 1 && !store.busy; }, 15000, function(retried) {
          if (!check(retried && shell.find(view, "stateText").text === "Todoist didn't accept the API token." && stateButton.text === "Open settings", "Retry synced again; a token Todoist refused: why, with Open settings, not Retry (" + JSON.stringify([retried, shell.find(view, "stateText").text, stateButton.text]) + ")")) return;
          stateButton.clicked();
          if (!check(view.editingSettings && shell.find(view.settingsPage, "signedInRow").visible && shell.find(view.settingsPage, "signOutButton").visible, "Open settings opened Settings, signed in, with Sign out")) return;
          view.settingsClosed();
          shell.put("reply-sync.json", JSON.stringify(shell.snapshot()));
          shell.put("reply-status.json", JSON.stringify({ ok: true, state: "signed_in", user: shell.snapshot().user }));
          one.close();
          store.check();
        });
      });
      break;
    case 111:
      // Settings, signed in: Account last. Sign out asks first: one click,
      // Enter or Space only asks; Cancel, Esc and leaving the page put the
      // row back; the question's own Sign out signs out. The keyring
      // refuses it (locked): the token stays, so the user is still signed
      // in, with the reason under the row.
      shell.put("reply-token-clear.json", JSON.stringify({ ok: false, code: "KEYRING_LOCKED", error: "The keyring that holds the Todoist token is locked. Unlock it and try again." }));
      ev.mouseClick(button, button.width / 2, button.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      wait.waitFor(function() { var v = one.popup.bodyItem; return one.opened && v && v.active; }, 10000, function(opened) {
        if (!check(opened, "the popup opened for Settings")) return;
        var settingsView = one.popup.bodyItem;
        settingsView.settingsRequested();
        var page = settingsView.settingsPage;
        wait.waitFor(function() { return page.backTarget.activeFocus; }, 5000, function(shown) {
          if (!check(shown, "the settings page has the keys")) return;
          if (!check(JSON.stringify(shell.settingsSections(page)) === JSON.stringify(["Panel", "Open command", "Bar", "Refresh", "Account"]), "signed in: the sections, Account last (" + JSON.stringify(shell.settingsSections(page)) + ")")) return;
          var others = shell.find(page, "othersTasks");
          if (!check(others.description === "In Today, Upcoming, Week, the Inbox and the bar" && shell.find(page, "openCommand").field.Accessible.name === "Open command", "Tasks assigned to others says where; the command field keeps its name")) return;
          var clears = shell.calls("token-clear").length;
          var signOut = shell.find(page, "signOutButton");
          var shownOn = function(name) { var item = shell.find(page, name); return !!item && item.visible; };
          var asking = function() { return shownOn("signOutQuestion") && !shownOn("signedInRow"); };
          var unchanged = function() { return store.signedIn && shell.calls("token-clear").length === clears && !store.tokenBusy; };
          var click = function(name) { var item = shell.find(page, name); ev.mouseClick(item, item.width / 2, item.height / 2, Qt.LeftButton, Qt.NoModifier, -1); };
          // Each stage after a frame: a row that just showed is laid out then.
          var spot = null;
          var stages = [function() {
            spot = signOut.mapToItem(page, signOut.width / 2, signOut.height / 2);
            click("signOutButton");
          }, function() {
            // A double-click: its second click lands where the first did,
            // on Cancel, never on the Sign out that signs out.
            if (!check(asking() && unchanged(), "a click on Sign out asks")) return false;
            ev.mouseClick(page, spot.x, spot.y, Qt.LeftButton, Qt.NoModifier, -1);
            if (!check(unchanged() && !asking() && shownOn("signedInRow"), "a second click on the same spot cancels, it does not sign out (" + JSON.stringify([store.signedIn, store.tokenBusy, asking()]) + ")")) return false;
          }, function() {
            click("signOutButton");
          }, function() {
            if (!check(asking() && unchanged() && shell.find(page, "signOutAsk").text === "Sign out of Ada Lovelace?" && !shownOn("signOutUnsent"), "a click on Sign out only asks (" + JSON.stringify([asking(), unchanged()]) + ")")) return false;
            // A completion still in its undo window would be dropped: the question says so.
            store.complete("t4");
            if (!check(shownOn("signOutUnsent") && shell.find(page, "signOutUnsent").text === "Changes not sent to Todoist yet will be lost.", "unsent changes: the question says they will be lost")) return false;
            store.undo("t4");
          }, function() {
            click("cancelSignOut");
            if (!check(!asking() && shownOn("signedInRow") && unchanged(), "Cancel put the row back")) return false;
          }, function() {
            click("signOutButton");
          }, function() {
            shell.find(page, "cancelSignOut").forceActiveFocus();
            ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
            if (!check(!asking() && settingsView.editingSettings && unchanged(), "Esc put the row back, the page stays")) return false;
          }, function() {
            click("signOutButton");
          }, function() {
            if (!check(asking(), "asked again")) return false;
            settingsView.settingsClosed();
            settingsView.settingsRequested();
          }, function() {
            if (!check(!asking() && shownOn("signedInRow") && unchanged(), "leaving the page put the row back")) return false;
            // The keys: Enter asks (the keys on Cancel), Shift+Tab to the
            // question's Sign out before it, Enter signs out.
            signOut.forceActiveFocus(Qt.TabFocusReason);
            ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
            if (!check(asking() && unchanged() && shell.find(page, "cancelSignOut").activeFocus, "Enter on Sign out only asks, the keys on Cancel")) return false;
          }, function() {
            ev.keyClick(Qt.Key_Backtab, Qt.ShiftModifier, -1);
            var confirm = shell.find(page, "confirmSignOut");
            if (!check(confirm.activeFocus && confirm.kind === "destructive" && signOut.kind === "secondary", "Shift+Tab: the destructive Sign out")) return false;
            ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
            check(store.tokenBusy && !asking() && signOut.activeFocus, "the second Sign out signs out; the row is back, with the keys");
          }];
          var go = function() {
            if (!stages.length) return;
            var stage = stages.shift();
            shell.afterFrame(page, function() { if (stage() !== false) go(); });
          };
          go();
        });
      });
      break;
    case 112:
      if (!check(store.tokenError === "The keyring that holds the Todoist token is locked. Unlock it and try again.", "a refused sign-out says why (" + store.tokenError + ")")) return;
      var refusedSignOut = shell.find(view.settingsPage, "signedInError");
      if (!check(view.editingSettings && refusedSignOut.visible && refusedSignOut.text === store.tokenError && shell.find(view.settingsPage, "signedInRow").visible, "the page says why, under the signed-in row (" + JSON.stringify([view.editingSettings, refusedSignOut.visible, refusedSignOut.text, shell.find(view.settingsPage, "signedInRow").visible, view.settingsPage.visible, one.opened]) + ")")) return;
      view.settingsClosed();
      one.close();
      // A sync that times out (exit 124, no reply) keeps the cached tasks.
      shell.put("exit-sync", "124");
      store.sync();
      break;
    case 113:
      if (!check(store.loaded && !!store.model.byId.t4 && store.failures >= 1, "a timed-out sync keeps the tasks (" + store.failures + " failures)")) return;
      // A reply that isn't JSON: the helper failed, the tasks stay.
      shell.put("exit-sync", "");
      shell.put("reply-sync.json", "not json");
      store.sync();
      break;
    case 114:
      if (!check(store.loaded && !!store.model.byId.t4, "a sync with a broken reply keeps the tasks")) return;
      shell.put("reply-sync.json", JSON.stringify(shell.snapshot()));
      store.sync();
      break;
    case 115:
      // Icon only: no number in the bar, the tooltip keeps the counts.
      one.prefs.save("barCount", "none");
      wait.waitFor(function() { return one.prefs.value("barCount") === "none"; }, 10000, function(ok) {
        if (!check(ok && !one.barContent.countLabel.visible && button.tooltipText.indexOf("left today") > 0, "Icon only hides the number, the tooltip keeps the counts (" + button.tooltipText + ")")) return;
        one.prefs.save("barCount", "today");
      });
      break;
    case 116:
      // Todoist text is shown as plain text: markup in a title, a project,
      // section or label name, or a description (anyone in a shared project
      // can write one) is never rendered.
      if (!check(one.barContent.countLabel.visible, "the number is back with the setting")) return;
      var marked = shell.snapshotWith({ t3: { content: "<b>Bold</b> <img src=\"file:///nonexistent.png\"> **stand-up**", labels: ["<i>tag</i>"] } });
      marked.projects = marked.projects.map(function(p) { return p.id === "work" ? Object.assign({}, p, { name: "<i>Work</i>" }) : p; });
      marked.sections = marked.sections.map(function(section) { return section.id === "s-ops" ? Object.assign({}, section, { name: "<b>Ops</b>" }) : section; });
      marked.labels = marked.labels.concat([{ id: "l-marked", name: "<i>tag</i>", color: "teal", item_order: 5 }]);
      store.snapshot = marked;
      shell.put("reply-task.json", JSON.stringify({ ok: true, task: { id: "t3", description: "<b>Agenda</b> first", truncated: false } }));
      one.open();
      break;
    case 117:
      var listMarkup = shell.markupTexts(view);
      var listRich = listMarkup.filter(function(item) { return item.textFormat !== Text.PlainText; });
      if (!check(listMarkup.length >= 5 && listRich.length === 0, "Todoist text is plain text in the list (" + listMarkup.length + " found; " + JSON.stringify(listRich.map(function(item) { return [item.objectName, item.textFormat, item.text]; })) + ")")) return;
      view.openTask("t3", false);
      break;
    case 118:
      // The task's page shows the same text again: the rendered title and
      // the fields, the project and section, the label and the description.
      var pageMarkup = shell.markupTexts(view.editor);
      var pageRich = pageMarkup.filter(function(item) { return item.textFormat !== Text.PlainText; });
      if (!check(pageMarkup.length >= 6 && pageRich.length === 0, "Todoist text is plain text on the task's page (" + pageMarkup.length + " found; " + JSON.stringify(pageMarkup.map(function(item) { return [item.objectName, item.textFormat, item.text]; })) + ")")) return;
      view.closeTask();
      store.snapshot = shell.snapshot();
      one.prefs.save("panelWidth", "wide");
      one.open();
      break;
    case 119:
      // The edges of a move. Saves fail here, so nothing changes Todoist's
      // side of the fixture.
      var wv = one.popup.bodyItem;
      var tomorrowDay = Model.addDays(shell.today, 1);
      shell.put("reply-apply.json", JSON.stringify({ ok: false, code: "NETWORK", error: "Can't reach Todoist. Check your connection." }));
      wv.setView("today");
      wv.selectTask("t4");
      // A typed date still on its way: a move of the same task waits for it
      // when the undo window ends (built later from Todoist's new date).
      shell.hold("apply");
      wv.editor.openField("due");
      for (var td of " friday") ev.keyClickChar(td, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
      store.move("t4", tomorrowDay);
      store.flushCompletions();
      if (!check(store.current && store.current.extra.update === "t4" && store.moves.t4 === tomorrowDay && !Model.has(store.movesSent, "t4") && store.undoWindow.running, "a move waits for the typed date on its way")) return;
      store.undo("t4");
      shell.release("apply");
      // A refused typed date, then Tomorrow from the Date menu: the pick
      // wins (the draft gave way), and the undo window waits while a menu
      // is open.
      wv.editor.setError("due", "Todoist answered HTTP 500.");
      wv.editor.openDateMenu(false);
      if (!check(wv.editor.menu.opened && store.holdingUndo, "a menu open: the undo window waits")) return;
      wv.editor.menu.activate(1);
      if (!check(store.moves.t4 === tomorrowDay && wv.editor.errorOf("due") === "" && wv.editor.dueLabel === "Tomorrow 14:00" && !store.holdingUndo && store.undoWindow.running, "the pick replaced the refused draft; the window runs again (" + wv.editor.dueLabel + ")")) return;
      store.undo("t4");
      // A moved Week card: Space completes it (it has no Undo to show).
      wv.setView("week");
      store.move("t2", tomorrowDay);
      wv.completeTask("t2");
      if (!check(store.struck.t2 && !Model.has(store.moves, "t2"), "Space on a moved Week card completes it")) return;
      store.undo("t2");
      wv.setView("today");
      wv.selectTask("t4");
      store.move("t4", tomorrowDay);
      store.move("t6", tomorrowDay);
      // A date typed for t4, and the pane changes task while the field
      // still has the keys: t4's save cancels t4's move only (it used to
      // cancel the newly shown task's).
      wv.editor.openField("due");
      for (var fd of " friday") ev.keyClickChar(fd, Qt.NoModifier, -1);
      wv.paneTask = "t6";
      if (!check(wv.paneTask === "t6" && !Model.has(store.moves, "t4") && store.moves.t6 === tomorrowDay, "a typed date cancels its own task's move, not the next one's (" + JSON.stringify(store.moves) + ")")) return;
      // Space on a moved row undoes the move, as Undo does.
      wv.completeTask("t6");
      if (!check(!Model.has(store.moves, "t6") && !Model.has(store.struck, "t6") && !store.pending, "Space on a moved row: the move undone, not completed")) return;
      // A task that leaves the snapshot in its undo window: nothing is sent
      // for it, and nothing stays waiting for a reply.
      store.move("t6", tomorrowDay);
      store.snapshot = shell.snapshot(["t6"]);
      store.flushCompletions();
      if (!check(!Model.has(store.movesSent, "t6") && !Model.has(store.moves, "t6"), "a move for a task that left: dropped (" + JSON.stringify(store.movesSent) + ")")) return;
      store.snapshot = shell.snapshot();
      // A move whose call fails as a whole: the row is back where it was,
      // the line says why, and a sync follows.
      store.error = "";
      shell.callsBefore = shell.calls("sync").length;
      // The sync after it is held, so the line still says why.
      shell.hold("sync");
      store.move("t1", shell.today);
      store.flushCompletions();
      if (!check(store.movesSent.t1 === shell.today, "a sent move shows until its reply")) return;
      break;
    case 120:
      var t1Row = one.popup.bodyItem.rows.find(function(r) { return r.id === "t1"; });
      if (!check(t1Row && !t1Row.moved && store.model.byId.t1.due.day !== shell.today && store.error === "Can't reach Todoist. Check your connection." && store.moveErrors.t1 === store.error, "a failed move: the row back, the reason on the line and for its editor, a sync (" + store.error + ")")) return;
      // Its editor says why under Date, without Retry (nothing to retry there).
      var failedView = one.popup.bodyItem;
      failedView.selectTask("t1");
      var dueLine = shell.find(shell.find(failedView.editor, "section-due"), "fieldErrorText");
      if (!check(dueLine.visible && dueLine.text === store.error && !shell.find(shell.find(failedView.editor, "section-due"), "fieldRetry").visible, "the editor's Date says why the move failed (" + dueLine.text + ")")) return;
      failedView.clearSelection();
      // No helper for this CPU: says so, no retry loop; an add waiting
      // behind the sync ends as failed. The held sync is the one that
      // finds no helper: its exit status is in place before it is let go
      // (a helper let go first could answer before the status lands).
      shell.put("exit-sync", "127");
      shell.release("sync");
      store.error = "";
      one.close();
      shell.settled = [];
      store.sync();
      shell.lateAdd = store.add("Waiting", "", "");
      break;
    case 121:
      if (!check(store.accountError === "This plugin's helper isn't available for this CPU.", "unavailable: the message (" + store.accountError + ")")) return;
      var before = shell.calls().length;
      store.sync();
      store.check();
      if (!check(!store.busy && shell.calls().length === before && !store.polling, "unavailable: nothing runs again")) return;
      var late = shell.settled.find(function(s) { return s.request === shell.lateAdd; });
      if (!check(late && !late.ok && late.message === store.accountError, "the waiting add ended as failed (" + JSON.stringify(shell.settled) + ")")) return;
      shell.afterAdd = store.add("After", "", "");
      // One drawn frame: a job queued by the add would have started by then.
      shell.afterFrame(frameProbe, function() {
        // Not signed in any more: no request, so no view waits for one.
        if (!check(shell.afterAdd === -1 && shell.calls().length === before, "an add while unavailable is refused at once, without a helper")) return;
        shell.finishRun();
      });
      return;
    }
  }
  function finishRun() {
    {
      one.close();
      shell.finished = true;
      console.log("FOAMY DONE runtime interactions passed"); Qt.quit();
    }
  }
}
"""

# Stands in for xdg-open and a custom open command: logs its name and argv
# (tab-separated), and fails with the status in $FOAMY_OUT/open-fail when
# that file isn't empty.
FAKE_OPENER = r"""#!/bin/sh
{ printf '%s' "${0##*/}"; printf '\t%s' "$@"; printf '\n'; } >>"$FOAMY_OUT/opened.log"
if [ -s "$FOAMY_OUT/open-fail" ]; then exit "$(cat "$FOAMY_OUT/open-fail")"; fi
exit 0
"""


def offscreen_copy(dest):
    """The plugin as the offscreen shell loads it: a copy without the helper
    and its build files."""
    shutil.copytree(
        plugin,
        dest,
        ignore=shutil.ignore_patterns(".git", "native", "rust", "bin", "target", "*.png", "THIRD_PARTY_NOTICES.md"),
    )
    return dest


copy = Path(tempfile.mkdtemp(prefix="foamy-todoist-runtime-plugin-"))
run = harness.Run(
    "4.5",
    SHELL,
    plugin=offscreen_copy(copy / "plugin"),
    prefix="foamy-todoist-runtime-",
    fakebin={"xdg-open": FAKE_OPENER, "todoist-open": FAKE_OPENER},
)
try:
    (run.out / "reply-status.json").write_text(json.dumps({"ok": True, "state": "signed_out", "user": None}))
    run.env["FAKE_HELPER"] = FAKE_HELPER
    # One zone with an offset from UTC on every machine: the UTC due-date
    # check needs one, and local days then fall the same everywhere.
    run.env["TZ"] = "Europe/Oslo"
    # The kit's stand-in wl-paste: a paste reads "folder", never the real clipboard.
    run.env.update(hostenv.clipboard_fakes(run.base / "clipboard", env=run.env))
    run.run(timeout=200)
    expired = run.out / "hold-expired.log"
    if expired.exists():
        print("FAIL: the scene never released a held reply:", *expired.read_text().split(), sep="\n  ")
        print(run.log)
        sys.exit(1)
    refused = run.host_commands()
    if refused:
        print("FAIL: the plugin ran host commands:", *refused, sep="\n  ")
        sys.exit(1)
    # A binding loop is a layout that depends on itself (RTL's mirrored
    # anchors once made the list's width depend on its own x).
    loops = [line for line in run.log.splitlines() if "Binding loop" in line]
    if loops:
        print("FAIL: binding loops:", *loops, sep="\n  ")
        sys.exit(1)
    # FOAMY_TEST_VERBOSE=1 prints the shell's log on success too.
    print(run.log if not run.ok or os.environ.get("FOAMY_TEST_VERBOSE") else "PASS: real plugin runtime interactions")
    sys.exit(0 if run.ok else 1)
finally:
    run.cleanup()
    shutil.rmtree(copy, ignore_errors=True)
