"""Run the real plugin, store and UI in foamy-kit's isolated offscreen shell.

The helper is a stand-in (TodoStore.helperCommand): a shell script that logs
each call with its standard input to $FOAMY_OUT/calls.log and answers with
$FOAMY_OUT/reply-<command>.json (after $FOAMY_OUT/slow-<command> seconds;
with $FOAMY_OUT/exit-<command> as its exit status instead, when that file
is not empty). Nothing reaches Todoist or a keyring.

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
if [ -s "$out/slow-$cmd" ]; then sleep "$(cat "$out/slow-$cmd")"; fi
if [ -s "$out/exit-$cmd" ]; then exit "$(cat "$out/exit-$cmd")"; fi
cat "$out/reply-$cmd.json"
"""

SHELL = r"""
import QtQuick
import QtQuick.Controls as Controls
import QtTest
import Quickshell
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
  property int openedBefore: 0
  property int queuedAdds: 0
  property real rowY: 0
  property var ipcPanel: null
  property string expectedUrl: ""
  property string ringTask: ""
  // The task the pane's typed text belongs to, and the text.
  property string paneFrom: ""
  property string paneText: ""
  property real oneLineX: 0
  // The popup's margin before a step narrows its room.
  property int savedMargin: 0
  property bool othersChecked: false
  // The store's wall clock: moved by setting `clock.at`, which (like a real
  // clock) notifies nothing, so only the store's own checks see it.
  property var clock: ({ at: new Date(2026, 10, 18, 12, 0, 0) })
  readonly property string unknownText: "Todoist didn't answer. The task may have been added: check the list before adding it again."
  // A task row's vertical layout: "" when the text block has the same space
  // above and below (±1px) and the ring and the time are centred on it;
  // else what is off.
  function rowGeometry(row) {
    var surface = shell.find(row, "taskSurface");
    var text = shell.find(row, "taskText");
    var detail = shell.find(row, "taskDetail");
    var y = function(item, at) { return item.mapToItem(surface, 0, at).y; };
    var top = y(text, 0);
    var bottom = detail.visible ? y(detail, detail.height) : y(text, text.height);
    var middle = (top + bottom) / 2;
    var ring = shell.find(row, "ringMark");
    var time = shell.find(row, "taskTime");
    var off = [];
    if (Math.abs(top - (surface.height - bottom)) > 1) off.push("padding " + top + " above, " + (surface.height - bottom) + " below");
    if (Math.abs(y(ring, ring.height / 2) - middle) > 1) off.push("ring at " + y(ring, ring.height / 2) + ", text block at " + middle);
    if (time.visible && Math.abs(y(time, time.height / 2) - middle) > 1) off.push("time at " + y(time, time.height / 2) + ", text block at " + middle);
    return off.join("; ");
  }
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
  TestEvent { id: ev }
  FoamyWait { id: wait }
  FileView { id: writer; blockWrites: true; printErrors: false }
  function put(name, text) { writer.path = shell.out + "/" + name; writer.setText(text); }
  // The Omarchy language picker's file (the kit's translations follow it).
  FileView { id: languageFile; path: Quickshell.env("OMARCHY_LANGUAGE_FILE"); blockWrites: true; printErrors: false }
  function pickLanguage(code) { languageFile.setText(code + "\n"); }
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
  // The snapshot with some tasks' fields changed ({id: {field: value}}).
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
  // A save reply for t4 with these fields (the slow helper reads it as it answers).
  function t4Reply(fields) {
    shell.put("reply-apply.json", JSON.stringify(Object.assign(shell.snapshotWith({ t4: fields }), { results: { t4: "ok" } })));
  }
  // Two saves of one field before the first reply (the helper slow): each
  // reply is matched to its own request, and each edit builds on the one in
  // flight. Then `done`.
  function racingSaves(view, done) {
    var store = Plugin.TodoStore;
    var editor = view.editor;
    var from = shell.calls("apply").length;
    shell.put("slow-apply", "0.6");
    shell.t4Reply({ content: "One", priority: 4, labels: ["code", "calls"] });
    editor.contentField.focusInput();
    editor.contentField.selectAll();
    for (var c1 of "One") ev.keyClickChar(c1, Qt.NoModifier, -1);
    ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
    for (var c2 of " Two") ev.keyClickChar(c2, Qt.NoModifier, -1);
    ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
    if (!check(Object.keys(editor.pending).length === 2, "two saves of the text in flight")) return;
    wait.waitFor(function() { return Object.keys(editor.pending).length === 1; }, 15000, function(ok) {
      // The first reply: Todoist has "One"; the newer text stays, still tracked.
      if (!check(ok && store.model.byId.t4.content === "One" && editor.contentField.text === "One Two" && editor.newest("content") > 0, "the first reply kept the newer text (" + JSON.stringify(editor.contentField.text) + ")")) return;
      shell.t4Reply({ content: "One Two", priority: 4, labels: ["code", "calls"] });
      wait.waitFor(function() { return Object.keys(editor.pending).length === 0 && !store.busy; }, 15000, function(ok2) {
        var sent = shell.updatesSince(from).map(function(command) { return command.content; });
        if (!check(ok2 && JSON.stringify(sent) === JSON.stringify(["One", "One Two"]) && editor.contentField.text === "One Two" && editor.errorOf("content") === "" && !editor.dirty("content"), "both replies: the field shows the newest (" + JSON.stringify([sent, editor.contentField.text]) + ")")) return;
        // Leaving the field sends nothing more.
        editor.openField("deadline");
        if (!check(shell.calls("apply").length === from + 2, "the next blur sent nothing")) return;
        // Two labels removed before the first reply: the second keeps the first off.
        var from2 = shell.calls("apply").length;
        shell.t4Reply({ content: "One Two", priority: 4, labels: ["calls"] });
        // The chip's × by the pointer: it removes the label, the section's menu stays shut.
        var codeX = shell.find(shell.find(editor, "label-code"), "removeLabel");
        ev.mouseClick(codeX, codeX.width / 2, codeX.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
        if (!check(!editor.menu.opened, "the × didn't open the label menu")) return;
        if (!check(shell.find(editor, "label-code") === null && shell.find(editor, "label-calls") !== null, "the chips show the list in flight")) return;
        shell.find(shell.find(editor, "label-calls"), "removeLabel").clicked();
        wait.waitFor(function() { return Object.keys(editor.pending).length === 1; }, 15000, function(ok3) {
          if (!check(ok3 && shell.find(editor, "label-code") === null && shell.find(editor, "label-calls") === null, "the first reply didn't bring a label back")) return;
          shell.t4Reply({ content: "One Two", priority: 4, labels: [] });
          wait.waitFor(function() { return Object.keys(editor.pending).length === 0 && !store.busy; }, 15000, function(ok4) {
            var lists = shell.updatesSince(from2).map(function(command) { return command.labels; });
            if (!check(ok4 && JSON.stringify(lists) === JSON.stringify([["calls"], []]) && store.model.byId.t4.labels.length === 0, "each removal built on the one in flight (" + JSON.stringify(lists) + ")")) return;
            shell.put("slow-apply", "");
            done();
          });
        });
      });
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
  // The editor's menus (Wide, t7 open): each field's context menu, then a
  // project menu taller than its room; back to the list, then done().
  function editorMenus(view, done) {
    view.openTask("t7", true);
    wait.waitFor(function() { var d = Plugin.TodoStore.description; return view.pageShown && view.editor.taskId === "t7" && d.id === "t7" && d.state === "ready" && view.editor.descriptionField.enabled; }, 15000, function(ok) {
      if (!check(ok, "t7 open in the editor, its description read")) return;
      var ed = view.editor;
      shell.contextPaste(ed, [
        { name: "dueField", open: "due" },
        { name: "deadlineField", open: "deadline" },
        { name: "contentField", open: "" },
        { name: "descriptionField", open: "" }
      ], function() {
        shell.menuLeave(ed, function() {
          shell.longPlaceMenu(ed, function() {
            view.editor.back();
            done();
          });
        });
      });
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
  // "" when entry `index` of the menu shows whole in its view; else where.
  function menuRowShown(menu, index) {
    // The panel's Flickable (it has a contentItem).
    var view = null;
    for (var child of menu.panel.children)
      if (child.contentItem !== undefined && child.contentY !== undefined) view = child;
    if (!view) return "no menu view";
    var list = view.contentItem.children[0];
    var row = null;
    for (var item of list.children)
      if (item.objectName === "foamyMenuRow" && item.index === index) row = item;
    if (!row) return "no row " + index;
    var top = row.mapToItem(view, 0, 0).y;
    return top >= -0.5 && top + row.height <= view.height + 0.5 ? "" : "row " + index + " at " + top + ".." + (top + row.height) + " of " + view.height;
  }
  // Many projects: the project menu is taller than its room (it scrolls);
  // End and Down keep the entry the keys are on in view.
  function longPlaceMenu(ed, done) {
    var store = Plugin.TodoStore;
    var many = shell.snapshot();
    for (var n = 1; n <= 40; n++)
      many.projects.push({ id: "extra" + n, name: "Extra " + n, color: "grey", parent_id: null, child_order: 10 + n, inbox: false });
    store.snapshot = many;
    ed.openPlaceMenu(true);
    var menu = ed.menu;
    var last = menu.entries.length - 1;
    var tall = function() { return menu.opened && last > 40 && menu.panel.height > 100 && menu.panel.height + 1 < menu.overlayItem.naturalHeight; };
    wait.waitFor(tall, 3000, function(ok) {
    if (!check(ok, "the project menu is taller than its room (" + JSON.stringify([last + 1, menu.panel.height, menu.overlayItem.naturalHeight]) + ")")) return;
    ev.keyClick(Qt.Key_End, Qt.NoModifier, -1);
    if (!check(menu.currentIndex === last && shell.menuRowShown(menu, last) === "", "End: the last project, in view (" + shell.menuRowShown(menu, last) + ")")) return;
    ev.keyClick(Qt.Key_Home, Qt.NoModifier, -1);
    var hidden = [];
    for (var i = 0; i < last; i++) {
      ev.keyClick(Qt.Key_Down, Qt.NoModifier, -1);
      var at = shell.menuRowShown(menu, menu.currentIndex);
      if (at !== "") hidden.push(at);
    }
    if (!check(menu.currentIndex === last && hidden.length === 0, "Down keeps each project in view (" + JSON.stringify(hidden.slice(0, 3)) + ")")) return;
    ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
    if (!check(!menu.opened && Object.keys(ed.pending).length === 0, "Esc closed the menu, nothing picked")) return;
    store.snapshot = shell.snapshot();
    done();
    });
  }
  function check(ok, message) {
    if (!ok && !shell.finished) { shell.finished = true; console.log("FOAMY FAIL " + message); Qt.quit(); }
    return ok;
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
  // Large: a click on the pane's empty space takes the keys from its title
  // (the typed text saved) and keeps the selection; a click on the list's
  // space that isn't a row (below the rows, a heading, the top margin)
  // clears it: no row, no cursor, the pane's empty state and the band's
  // Search again, the pane's draft saved first. Then `done`.
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
    var from = shell.calls("apply").length;
    var first = typed(" here");
    var stop = view.cursor.index;
    // The pane's top, beside "Saving…": nothing there takes a click.
    ev.mouseClick(editor, editor.width / 2, 4, Qt.LeftButton, Qt.NoModifier, -1);
    if (!check(!editor.contentField.inputActiveFocus && !view.blocked && view.paneTask === id && view.cursor.index === stop && view.taskInBand, "a click in the pane's empty space took the keys, kept the selection")) return;
    wait.waitFor(function() { return shell.calls("apply").length === from + 1 && !store.busy && !editor.saving; }, 15000, function(ok) {
      if (!check(ok && store.model.byId[id].content === first, "and saved the typed text (" + JSON.stringify(shell.updatesSince(from)) + ")")) return;
      var second = typed(" there");
      var list = view.list;
      var below = list.contentHeight - list.contentY;
      if (!check(below < list.height - 12, "the list has room below its rows (" + JSON.stringify([list.contentHeight, list.height]) + ")")) return;
      ev.mouseClick(list, list.width / 2, below + 8, Qt.LeftButton, Qt.NoModifier, -1);
      var empty = shell.find(editor, "editorEmpty");
      var actions = function() { return JSON.stringify(view.band.shownTrailing.map(function(item) { return item.objectName; })); };
      if (!check(view.paneTask === "" && view.cursor.index === -1 && shell.highlighted(view).length === 0 && editor.taskId === "" && empty.visible && empty.text === "No task selected" && !view.blocked && !view.taskInBand, "a click below the rows cleared the selection (" + JSON.stringify([view.paneTask, view.cursor.index]) + ")")) return;
      // The band lays its buttons out again on the next turn of the event loop.
      wait.waitFor(function() { return actions() === JSON.stringify(["addAction", "searchAction"]) && shell.calls("apply").length === from + 2 && !store.busy; }, 15000, function(ok2) {
        if (!check(ok2 && store.model.byId[id].content === second, "no task in the pane: the band has Search again; the pane's draft was saved first (" + actions() + ", " + JSON.stringify(shell.updatesSince(from)) + ")")) return;
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
        // A row still selects.
        view.goTo(view.firstRowStop);
        if (!check(view.paneTask !== "" && view.taskInBand, "the keys select a row again")) return;
        done();
      });
    });
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
  }
  // A row on its own, to give it one entry after another (as a reused
  // delegate gets them).
  Plugin.TaskRow {
    id: probeRow
    width: 400
    height: 42
    entry: shell.probeEntry({})
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
  }
  function gate(n) {
    var store = Plugin.TodoStore;
    var view = one ? one.popup.bodyItem : null;
    switch (n) {
    case 0: return [function() { return store.account === "signed_out" && !store.busy; }, 15000, "the first status"];
    case 1: return [function() { return one.popup.bodyItem !== null; }, 10000, "the popup opened"];
    case 2: return [function() { return store.signedIn && store.syncing; }, 15000, "signed in, syncing"];
    case 3: return [function() { return store.loaded && !store.busy; }, 15000, "the first sync"];
    case 4: return [function() { return view && view.active; }, 10000, "the reopened popup"];
    case 5: return [function() { return view.fieldFocused && view.band.fieldProgress === 1; }, 10000, "the field has the keys, grown"];
    case 6: return [function() { return view.fieldFocused; }, 10000, "a opened the field"];
    case 9: return [function() { return shell.calls("apply").length === 1 && !store.busy && Object.keys(store.sending).length === 0; }, 15000, "the completion was sent when the undo window ended"];
    case 10: return [function() { return shell.calls("apply").length >= 2 && !store.busy; }, 15000, "the move to tomorrow was sent"];
    case 12: return [function() { return view.view === "upcoming" && view.list.count > 0; }, 10000, "Upcoming shown"];
    case 13: return [function() { return view.fieldFocused; }, 10000, "the field opened in Upcoming"];
    case 15: return [function() { return shell.calls("add").length === shell.callsBefore + 1 && !view.addBusy && !store.busy; }, 15000, "the add from the field"];
    case 17: return [function() { var opened = shell.ipcPanel && shell.ipcPanel.popup.bodyItem; return opened && opened.active && opened.fieldFocused; }, 10000, "the popup opened by IPC add"];
    case 18: return [function() { return store.error !== "" && !store.busy; }, 15000, "the failed sync"];
    case 19: return [function() { return one.wide && view.wide; }, 10000, "the wide setting"];
    case 20: return [function() { return store.model.truncated && !store.busy; }, 15000, "a truncated snapshot"];
    case 21: return [function() { return !!store.unconfirmed && store.unconfirmed.t2 === true && store.syncing; }, 15000, "a failed completion is unconfirmed while the sync runs"];
    case 22: return [function() { return !store.busy && !store.unconfirmed.t2; }, 15000, "the sync after the failed completion"];
    case 23: return [function() { return view && !view.addBusy && store.retryUntil > Date.now(); }, 15000, "the rate-limited add"];
    case 24: return [function() { return !store.busy && !view.addBusy && Object.keys(store.sending).length === 0; }, 5000, "the jobs refused while rate limited settled"];
    case 25: return [function() { return store.account === "signed_out" && !store.busy && !view.addBusy; }, 20000, "signed out with a full queue"];
    case 26: return [function() { return !store.tokenBusy && store.tokenError !== ""; }, 15000, "the refused token"];
    case 27: return [function() { return store.signedIn && store.loaded && !store.busy; }, 15000, "signed in again"];
    case 28: return [function() { return shell.calls("add").length >= 1 && !view.addBusy && !store.busy; }, 15000, "an add after signing in again"];
    case 29: return [function() { return one === null && !store.busy; }, 15000, "the sync that ends after the bar is gone"];
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
    case 40: return [function() { return store.openCommand === "" && one.wide === false && view && view.active && !view.wide; }, 10000, "the standard popup again"];
    case 41: return [function() { return view.fieldFocused; }, 10000, "the empty field, to click away from"];
    case 42: return [function() { return view.fieldFocused; }, 10000, "the empty field again"];
    case 43: return [function() { return view.fieldFocused; }, 10000, "the field for search and drafts"];
    case 44: return [function() { var v = one.popup.bodyItem; return one.opened && v && v.active && v.fieldFocused; }, 10000, "the reopened popup with the draft"];
    case 45: return [function() { var v = one.popup.bodyItem; return one.opened && v && v.active; }, 10000, "the reopened popup after Esc"];
    case 46: return [function() { return view.fieldFocused; }, 10000, "the field for a draft before search"];
    case 48: return [function() { return view.view === "today" && shell.builtRows(view).length >= 4; }, 10000, "Today again, on reused rows"];
    case 49: return [function() { return view.fieldFocused; }, 10000, "the field for an add that ends after closing"];
    case 50: return [function() { return !view.addBusy && !one.opened; }, 15000, "the add's reply, the popup closed"];
    case 51: return [function() { return one.opened && view.active; }, 10000, "the reopened popup"];
    case 52: return [function() { return view.fieldFocused; }, 10000, "the field for an add edited after submitting"];
    case 53: return [function() { return !view.addBusy && !one.opened; }, 15000, "the second add's reply"];
    case 54: return [function() { return one.opened && view.active && view.fieldFocused; }, 10000, "the reopened popup with the edit"];
    case 55: return [function() { return !view.addBusy && !store.busy && shell.calls("sync").length > shell.callsBefore; }, 15000, "an add with an unknown outcome, then a sync"];
    case 56: return [function() { return Kit.FoamyI18n.language === "no" && view.fieldFocused; }, 10000, "Norwegian"];
    case 57: return [function() { return !view.addBusy && !store.busy && shell.calls("add").length > shell.callsBefore; }, 15000, "the add with an unknown outcome in Norwegian"];
    case 58: return [function() { return shell.othersChecked && store.othersTasks === "hide" && Kit.FoamyI18n.language === "en"; }, 10000, "the setting shown, then back to hide"];
    case 59: return [function() { return view.fieldFocused; }, 10000, "the field for an add across two monitors"];
    case 60: return [function() { var v = two.popup.bodyItem; return two.opened && v && v.active && v.fieldFocused; }, 10000, "the other monitor's popup with the draft"];
    case 61: return [function() { var v = two.popup.bodyItem; return !store.busy && !v.addBusy && shell.calls("add").length > shell.callsBefore; }, 15000, "the add from the first monitor answered"];
    case 62: return [function() { return !store.busy; }, 15000, "the sync of the poll after midnight"];
    case 63: return [function() { return !store.busy && shell.calls("sync").length > shell.callsBefore; }, 15000, "a sync reply after another midnight"];
    case 65: return [function() { var v = one.popup.bodyItem; return one.opened && v && v.active && v.pref("afterAdd") === "keep"; }, 10000, "the popup with Keep the field open"];
    case 66: return [function() { return view.fieldFocused && view.band.fieldProgress === 1; }, 10000, "the add field (keep)"];
    case 67: return [function() { return shell.calls("add").length === shell.callsBefore + 1 && !view.addBusy && !store.busy; }, 15000, "the add with Enter (keep)"];
    case 68: return [function() { return shell.calls("add").length === shell.callsBefore + 2 && !store.addPending && !store.busy; }, 15000, "the add with Shift+Enter (keep)"];
    case 69: return [function() { return one.opened && view && view.active && view.pref("afterAdd") === "close" && shell.builtRows(view).some(function(r) { return r.entry.id === "t4"; }); }, 10000, "the popup for the editor"];
    case 70: return [function() { return view.pageShown && store.description.state === "ready" && store.description.id === "t4"; }, 15000, "the editor page with the description"];
    case 71: return [function() { return shell.calls("apply").length === shell.callsBefore + 1 && !store.busy && !view.editor.saving; }, 15000, "the text saved"];
    case 72: return [function() { return shell.calls("apply").length === shell.callsBefore + 2 && !store.busy && !view.editor.saving; }, 15000, "the refused date"];
    case 73: return [function() { return shell.calls("apply").length === shell.callsBefore + 3 && !store.busy && !view.editor.saving; }, 15000, "the date sent again"];
    case 74: return [function() { return shell.calls("apply").length === shell.callsBefore + 4 && !store.busy && !view.editor.saving; }, 15000, "the priority saved"];
    case 75: return [function() { return view.pageShown && store.description.state === "error"; }, 15000, "the failed description read"];
    case 76: return [function() { return store.description.state === "ready"; }, 15000, "the description read again"];
    case 77: return [function() { return store.current !== null && store.current.command === "task"; }, 15000, "the slow description read runs"];
    case 78: return [function() { return !store.busy; }, 15000, "the late reply came"];
    case 79: return [function() { return store.description.state === "ready" && store.description.id === "t7"; }, 15000, "t7's description"];
    case 80: return [function() { return view.wide && one.size === "wide"; }, 20000, "Wide"];
    case 81: return [function() { return one.size === "large"; }, 40000, "Large"];
    case 82: return [function() { var v = one.popup.bodyItem; return one.opened && v && v.active && v.size === "large" && Math.abs(one.popup.cardItem.width - 880) < 1; }, 10000, "the Large popup"];
    case 83: return [function() { return store.description.state === "ready" && store.description.id === "t1"; }, 15000, "the pane's description"];
    case 84: return [function() { var v = one.popup.bodyItem; return v.editor.contentField.inputActiveFocus && store.description.state === "ready" && store.description.id === v.paneTask && shell.opened().length > shell.openedBefore && !store.launchRunning; }, 10000, "e put the caret in the pane, the description read, Open launched"];
    case 85: return [function() { return shell.calls("apply").length === shell.callsBefore + 1 && !store.busy; }, 15000, "the pane's text saved as the selection moved"];
    case 86: return [function() { return one.popup.bodyItem.weekShown && shell.calls("apply").length === shell.callsBefore + 1 && !store.busy; }, 20000, "the pane's text saved as the view changed"];
    case 87: return [function() { return shell.calls("apply").length === shell.callsBefore + 1 && !store.busy; }, 15000, "Ctrl+→ sent"];
    case 88: return [function() { return one.popup.bodyItem.editor.contentField.inputActiveFocus; }, 10000, "the caret in the week's pane"];
    case 89: return [function() { return !one.opened && !one.popup.visible; }, 10000, "the Large popup closed"];
    case 90: return [function() { var v = one.popup.bodyItem; return one.opened && v.active && Kit.FoamyI18n.language === "no" && v.paneTask === "t1" && store.description.id === "t1" && store.description.state === "ready"; }, 15000, "Large again, in Norwegian"];
    case 91: return [function() { return shell.calls("apply").length === shell.callsBefore + 1 && !store.busy && Kit.FoamyI18n.language === "en"; }, 15000, "the pane's text saved as the popup closed"];
    case 92: return [function() { var v = one.popup.bodyItem; return one.opened && v.active && v.size === "wide"; }, 10000, "the Wide popup"];
    case 93: return [function() { var l = shell.leader(); var v = l.popup.bodyItem; return l.opened && v && v.active && v.size === "large" && Math.abs(l.popup.cardItem.width - 880) < 1; }, 10000, "the Large popup from IPC"];
    case 94: return [function() { var v = shell.leader().popup.bodyItem; return v.fieldFocused && v.band.fieldProgress === 1; }, 10000, "IPC add in the open Large popup"];
    case 95: return [function() { return one.size === "standard" && one.prefs.value("openOn") === "last" && one.prefs.value("panelWidth") === "standard"; }, 10000, "Small, Open on: Last view"];
    case 96: return [function() { var v = one.popup.bodyItem; return one.opened && v && v.active; }, 10000, "the popup on the last view"];
    case 97: return [function() { return store.account === "unavailable"; }, 15000, "the helper unavailable"];
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
      one.open();
      break;
    case 1:
      if (!check(shell.find(view, "stateText").text === "Add your Todoist API token in Settings", "signed out: the line (" + shell.find(view, "stateText").text + ")")) return;
      var open = shell.find(view, "stateButton");
      if (!check(open.visible && open.text === "Open settings", "signed out: Open settings")) return;
      if (!check(!view.field.visible && !view.footer.visible, "no field or footer while signed out")) return;
      one.close();
      shell.put("reply-status.json", JSON.stringify({ ok: true, state: "signed_in", user: shell.snapshot().user }));
      shell.put("reply-sync.json", JSON.stringify(shell.snapshot()));
      shell.put("slow-sync", "1.5");
      store.check();
      break;
    case 2:
      one.open();
      break;
    case 3:
      // The first sync was still running when the popup opened.
      if (!check(shell.calls("sync").length === 1, "one sync after signing in (" + JSON.stringify(shell.calls()) + ")")) return;
      one.close();
      shell.put("slow-sync", "");
      wait.after(100, function() { one.open(); });
      break;
    case 4:
      // Reopened: no field, no cursor; the band has +, Search and ⋯ (Settings in it).
      if (!check(!view.fieldFocused && !view.fieldOpen && view.cursor.index === -1 && !view.blocked, "nothing has the cursor on open (" + view.cursor.index + ")")) return;
      if (!check(shell.builtRows(view).length >= 6, "the today rows are built (" + shell.builtRows(view).length + ")")) return;
      if (!check(shell.highlighted(view).length === 0, "no row highlight on open")) return;
      var actions = view.band.shownTrailing.map(function(item) { return item.objectName; });
      if (!check(JSON.stringify(actions) === JSON.stringify(["addAction", "searchAction"]) && view.band.settingsInMenu && view.band.menuButton.visible, "the band: +, Search, ⋯ (" + JSON.stringify(actions) + ", Settings in the menu " + view.band.settingsInMenu + ")")) return;
      var plus = shell.find(view.band, "addAction");
      if (!check(plus.tooltipText === "Add a task" && plus.iconName === "plus", "+ says Add a task")) return;
      if (!check(shell.find(view, "addRow") === null && !view.band.fieldShown, "no add row; the band field is closed")) return;
      shell.rowY = view.band.height;
      if (!check(view.band.meta === "Today · 6 left · 2 overdue", "the band's meta (" + view.band.meta + ")")) return;
      if (!check(view.band.iconName === "todoist", "the band shows the Todoist mark")) return;
      // One number, as in foamy-zendesk: left today, in the bar's urgent colour.
      var count = one.barContent.countLabel;
      if (!check(count.visible && count.text === "6" && Qt.colorEqual(count.color, bar.urgent) && count.font.family === button.fontFamily, "the bar: 6 in the urgent colour (" + count.text + ", " + count.color + ", " + count.font.family + ")")) return;
      var texts = one.barContent.children.filter(function(item) { return item.visible && item.hasOwnProperty("text"); });
      if (!check(texts.length === 1 && one.barContent.overdueLabel === undefined, "no separate overdue number in the bar (" + texts.length + ")")) return;
      if (!check(button.tooltipText === "Todoist: 6 left today, 2 overdue", "the tooltip (" + button.tooltipText + ")")) return;
      // Section counts sit at the end of the heading line, where times end.
      var overdueHead = view.list.contentItem.children.find(function(item) { return item.hasOwnProperty("entry") && item.visible && item.entry && item.entry.key === "header:overdue"; });
      var overdueCount = shell.find(overdueHead, "headerCount");
      var at = function(item) { return item.mapToItem(view, 0, 0).x; };
      var timed = shell.builtRows(view).find(function(r) { return r.entry.id === "t3"; });
      var timeLabel = shell.find(timed, "taskTime");
      if (!check(overdueCount && timed && timeLabel, "found the count and a timed row (" + !!overdueCount + " " + !!timed + " " + !!timeLabel + " " + (overdueHead && overdueHead.entry.key) + ")")) return;
      if (!check(overdueCount.text === "2" && Math.abs(at(overdueCount) + overdueCount.width - at(timeLabel) - timeLabel.width) < 1, "the Overdue count ends where the times do (" + (at(overdueCount) + overdueCount.width) + " vs " + (at(timeLabel) + timeLabel.width) + ")")) return;
      // Nothing left today: the bar shows the mark alone, no "0".
      var full = store.snapshot;
      store.snapshot = Object.assign({}, full, { tasks: [] });
      if (!check(store.counts.today === 0 && one.barContent.countLabel.visible === false, "no count in the bar when nothing is left")) return;
      var emptyTabs = shell.find(view, "viewSwitch").model;
      if (!check(emptyTabs[0].count === -1 && emptyTabs[1].count === -1, "no 0 in the tabs either (" + emptyTabs[0].count + ", " + emptyTabs[1].count + ")")) return;
      store.snapshot = full;
      if (!check(one.barContent.countLabel.visible && one.barContent.countLabel.text === "6", "the count is back")) return;
      // The tab row: in the body, right under the band, full width.
      var tabs = shell.find(view, "viewSwitch");
      if (!check(tabs && tabs.visible && shell.find(view.band, "viewSwitch") === null, "the tabs are not in the band")) return;
      var top = function(item) { return item.mapToItem(view, 0, 0).y; };
      var at = function(item) { return item.mapToItem(view, 0, 0).x; };
      if (!check(Math.abs(top(tabs) - view.band.height) < 1 && Math.abs(at(tabs)) < 1 && Math.abs(tabs.width - view.width) < 1, "the tabs sit under the band, full width (" + top(tabs) + " vs " + view.band.height + ", " + at(tabs) + "+" + tabs.width + ")")) return;
      if (!check(tabs.model[0].count === 4 && tabs.model[1].count === 6 && tabs.model[1].countUrgent === true, "the tabs' counts")) return;
      // Section headers start where the rows' rings do; the add row's
      // edges are the rows' edges, its icon where the rings are.
      var header = view.list.contentItem.children.find(function(item) { return item.hasOwnProperty("entry") && item.visible && item.kind === "header"; });
      var firstRow = shell.builtRows(view)[0];
      var ringX = at(shell.find(firstRow, "ringMark"));
      if (!check(Math.abs(at(shell.find(header, "header")) - ringX) < 1, "a header lines up with the rings (" + at(shell.find(header, "header")) + " vs " + ringX + ")")) return;
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
      var box = shell.find(view, "fieldBox");
      var at = function(item) { return item.mapToItem(view, 0, 0); };
      if (!check(view.fieldOpen && view.band.fieldOpen && view.blocked && !view.band.buttonsActive, "Enter opened the band field, with the keys; the buttons are inert")) return;
      // Over the title row, the band's width between its paddings; the band keeps its height.
      if (!check(Math.abs(view.band.height - shell.rowY) < 1 && Math.abs(at(box).x - Kit.FoamyStyle.padding) < 1 && Math.abs(box.width - (view.band.width - Kit.FoamyStyle.padding * 2)) < 1 && at(box).y + box.height <= view.band.height, "the field covers the band, which keeps its height (" + JSON.stringify([view.band.height, shell.rowY, at(box).x, box.width, at(box).y]) + ")")) return;
      if (!check(view.field.placeholderText === "Add a task for today…", "the placeholder says where it goes (" + view.field.placeholderText + ")")) return;
      if (!check(view.field.font.pixelSize === Kit.FoamyStyle.font.title, "the field's text is the band title's size (" + view.field.font.pixelSize + ")")) return;
      // No chips or hints under it; the footer shows the keys.
      if (!check(shell.find(view, "dateChip") === null && shell.find(view, "fieldHint") === null, "nothing under the field")) return;
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
      // t: a recurring task stays; another one moves to tomorrow.
      view.cursor.index = view.firstRowStop + 1;
      if (!check(shell.highlighted(view)[0].entry.recurring, "the second row is recurring")) return;
      view.cursor.emitTextKey(view, "t");
      view.cursor.index = view.firstRowStop;
      view.cursor.emitTextKey(view, "t");
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
      if (!check(view.band.meta === "Upcoming · 3 tasks in the next 7 days", "the band's meta (" + view.band.meta + ")")) return;
      var heads = view.rows.filter(function(row) { return row.kind === "header"; });
      if (!check(JSON.stringify(heads.map(function(h) { return h.group; })) === JSON.stringify(["day", "day", "week", "later", "month", "month"]), "the groups (" + JSON.stringify(heads.map(function(h) { return h.group; })) + ")")) return;
      var built = function(key) { return view.list.contentItem.children.find(function(item) { return item.hasOwnProperty("entry") && item.visible && item.entry && item.entry.key === key; }); };
      var text = function(item, name) { var found = shell.find(item, name); return found && found.visible ? found.text : ""; };
      var shown = function(head) { var item = built(head.key); return item ? [text(item, "headerTitle"), text(item, "headerSub"), text(item, "headerCount"), shell.find(item, "headerDivider").visible] : null; };
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
      view.cursor.index = stopOf("t12");
      view.cursor.index = -1;
      if (!check(view.addDay === "2026-11-19", "no cursor: tomorrow (" + view.addDay + ")")) return;
      view.list.positionViewAtBeginning();
      view.openAdd();
      break;
    case 13:
      if (!check(view.fieldFocused && view.field.placeholderText === "Add a task for Thursday 19 November…", "Upcoming adds for tomorrow (" + view.field.placeholderText + ")")) return;
      ev.keyClick(Qt.Key_2, Qt.AltModifier, -1);
      break;
    case 14:
      if (!check(view.view === "today" && view.fieldFocused, "Alt+2 while typing shows Today and keeps the caret (" + view.view + ")")) return;
      // Shift+Enter (with "Close the panel") adds and keeps the field open for the next task.
      shell.put("reply-add.json", JSON.stringify(Object.assign(shell.snapshot(), { added: "t1" })));
      shell.callsBefore = shell.calls("add").length;
      for (var m of "Milk") ev.keyClickChar(m, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Return, Qt.ShiftModifier, -1);
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
      view.cursor.emitTextKey(view, "/");
      for (var c of "parcel") ev.keyClickChar(c, Qt.NoModifier, -1);
      if (!check(view.searching && view.fieldOpen && view.query === "parcel", "typing searches in the slot (" + view.query + ")")) return;
      var found = view.rows.map(function(row) { return row.kind === "task" ? row.id : row.title; });
      if (!check(JSON.stringify(found) === JSON.stringify(["Inbox", "t9"]), "search finds the parcel, grouped by project (" + JSON.stringify(found) + ")")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(view.searching && view.field.text === "", "Esc with text clears it")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(!view.searching && !view.fieldOpen && view.cursor.index === view.searchStop && one.opened, "Esc when empty leaves search, the cursor on Search")) return;
      // IPC add: the popup opens with the field open and focused.
      one.close();
      wait.after(100, function() {
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
      if (!check(!view.band.fieldShown && shell.find(view, "addRow") === null && !shell.find(view, "viewSwitch").visible, "wide: the title row in the band, no tabs, no add row")) return;
      if (!check(shell.find(view, "rail-week") === null, "wide: no Week in the rail")) return;
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
      shell.put("slow-sync", "2");
      shell.put("reply-apply.json", JSON.stringify({ ok: false, code: "NETWORK", error: "Can't reach Todoist. Check your connection." }));
      shell.callsBefore = shell.calls("sync").length;
      view.setView("today");
      store.complete("t2");
      store.flushCompletions();
      break;
    case 21:
      var row = view.rows.find(function(r) { return r.id === "t2"; });
      if (!check(row && row.unconfirmed, "t2 is shown, marked unconfirmed")) return;
      store.complete("t2");
      store.moveToTomorrow("t2");
      if (!check(!store.struck.t2 && store.queue.length === 0, "an unconfirmed task can't be completed or moved again")) return;
      break;
    case 22:
      if (!check(shell.calls("sync").length === shell.callsBefore + 1, "a sync followed the failed completion")) return;
      shell.put("slow-sync", "");
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
      store.next();
      if (!check(store.queue.length === 0 && store.error.indexOf("Todoist is limiting requests.") === 0, "a refused move to tomorrow says why (" + store.error + ")")) return;
      store.error = "";
      store.retryUntil = 0;
      // A full queue, a repeated t, then sign-out: every add settles.
      shell.put("slow-sync", "3");
      shell.put("reply-add.json", JSON.stringify(Object.assign(shell.snapshot(), { added: "t1" })));
      shell.put("reply-token-clear.json", JSON.stringify({ ok: true, state: "signed_out", user: null }));
      shell.settled = [];
      shell.callsBefore = shell.calls("add").length;
      store.sync();
      store.moveToTomorrow("t6");
      store.moveToTomorrow("t6");
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
      shell.put("slow-sync", "");
      shell.put("reply-token-set.json", JSON.stringify({ ok: true, state: "signed_in", user: shell.snapshot().user }));
      view.settingsPage.tokenField.clear();
      view.settingsPage.tokenField.focusInput();
      for (var r of "right-token") ev.keyClickChar(r, Qt.NoModifier, -1);
      view.settingsPage.saveToken();
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
      // A reply after the last bar went: nothing restarts the poll.
      one.close();
      shell.put("slow-sync", "2");
      store.sync();
      shell.panelsAlive = false;
      break;
    case 29:
      if (!check(!store.polling && !store.poll.running, "no poll without a bar (" + store.poll.running + ")")) return;
      shell.callsBefore = shell.calls().length;
      store.refreshIfStale(0);
      shell.put("slow-sync", "");
      shell.panelsAlive = true;
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
      var box = shell.find(view, "fieldBox");
      if (!check(Math.abs(list.mapToItem(view, 0, 0).x - box.mapToItem(view, 0, 0).x) < 1 && Math.abs(list.width - box.width) < 1 && list.mapToItem(view, 0, 0).y >= box.mapToItem(view, 0, 0).y + box.height, "the list drops from the field, as wide as it")) return;
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
      // With the list closed, Enter adds (Shift: and the field stays).
      ev.keyClickChar("x", Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Return, Qt.ShiftModifier, -1);
      break;
    case 33:
      if (!check(JSON.parse(shell.calls("add").pop().slice("add ".length)).text === "#Launch x", "Enter with the list closed added the text")) return;
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
      // The IPC target keeps only the panel's own functions (Foamy Menu's
      // openTask and openInbox are gone).
      var target = one.data.concat(two.data).find(function(item) { return item.target === "foamy.todoist" && item.enabled; });
      if (!check(target && typeof target.toggle === "function" && typeof target.openTask === "undefined" && typeof target.openInbox === "undefined", "the IPC target has toggle, no openTask or openInbox")) return;
      // Wide: ← on a row goes to the rail, → from the rail back to the rows.
      view.goTo(view.firstRowStop);
      view.moveRequested(-1, 0);
      if (!check(view.cursor.index === view.railStop, "← on a row goes to the rail (wide)")) return;
      view.moveRequested(1, 0);
      if (!check(view.cursor.index === view.firstRowStop, "→ from the rail goes to the rows (wide)")) return;
      one.prefs.save("openCommand", "");
      one.prefs.save("panelWidth", "standard");
      one.close();
      wait.after(100, function() { one.open(); });
      break;
    case 40:
      // Small: ← and → on a row do nothing.
      view.goTo(view.firstRowStop);
      view.moveRequested(1, 0);
      view.moveRequested(-1, 0);
      if (!check(view.cursor.index === view.firstRowStop, "← → on a row stay (small)")) return;
      view.openAdd();
      break;
    case 41:
      // A click on a tab while the empty field has the keys: it closes, the view switches.
      view.setView("today");
      var tab = shell.find(shell.find(view, "viewSwitch"), "foamyTab0");
      ev.mouseClick(tab, tab.width / 2, tab.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      if (!check(view.view === "inbox" && !view.fieldOpen && !view.fieldFocused, "a tab click closed the empty field (" + view.view + ", " + view.fieldOpen + ")")) return;
      view.openAdd();
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
      wait.after(100, function() { one.open(); });
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
      wait.after(100, function() { one.open(); });
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
      if (!check(shell.rowGeometry(oneLine) === "", "one-line row: " + shell.rowGeometry(oneLine))) return;
      shell.oneLineX = shell.find(oneLine, "taskSurface").mapToItem(view, 0, 0).x;
      view.setView("today");
      break;
    case 48:
      // A row that had no detail line shows one when its next task has only a project.
      probeRow.entry = shell.probeEntry({ showProject: true, projectName: "Gjøremål", projectRole: "success", detail: true });
      if (!check(shell.find(probeRow, "taskDetail").visible && shell.find(probeRow, "taskProject").visible && shell.find(probeRow, "taskProject").text === "Gjøremål", "a row reused for a project-only task shows the project")) return;
      probeRow.entry = shell.probeEntry({ recurring: true, detail: true });
      if (!check(shell.find(probeRow, "taskDetail").visible && shell.find(probeRow, "taskRepeat").visible, "and the repeat icon alone")) return;
      // Today shows the project of a task in another project, also on a reused row.
      for (var r of shell.builtRows(view)) {
        var project = shell.find(r, "taskProject");
        if (!check(r.entry.showProject && shell.find(r, "taskDetail").visible && project.visible && project.text === r.entry.projectName && project.text !== "", "Today: " + r.entry.id + " shows its project (" + project.text + ", detail " + shell.find(r, "taskDetail").visible + ")")) return;
        if (!check(shell.rowGeometry(r) === "", "two-line row " + r.entry.id + ": " + shell.rowGeometry(r))) return;
        if (!check(Math.abs(shell.find(r, "taskSurface").mapToItem(view, 0, 0).x - shell.oneLineX) < 1, "the same fill insets on every row")) return;
      }
      // An add whose reply comes after the popup closed leaves no draft.
      shell.put("reply-add.json", JSON.stringify(Object.assign(shell.snapshot(), { added: "t1" })));
      shell.put("slow-add", "1.5");
      view.openAdd();
      break;
    case 49:
      // Enter ("Close the panel", the default): sent, the field and the panel close.
      for (var m of "Milk soon") ev.keyClickChar(m, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
      if (!check(view.addBusy && !one.opened && !view.fieldOpen && store.addDraft === "Milk soon", "Enter sent it and closed the panel, the text the draft meanwhile (" + one.opened + ", " + JSON.stringify(store.addDraft) + ")")) return;
      break;
    case 50:
      if (!check(store.addDraft === "", "the added text isn't a draft (" + JSON.stringify(store.addDraft) + ")")) return;
      one.open();
      break;
    case 51:
      if (!check(!view.fieldOpen && view.field.text === "", "reopened without a draft (" + JSON.stringify(view.field.text) + ")")) return;
      view.openAdd();
      break;
    case 52:
      // Edited after submitting: the edit is the draft and stays.
      for (var e of "Eggs") ev.keyClickChar(e, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Return, Qt.ShiftModifier, -1);
      for (var h of " and ham") ev.keyClickChar(h, Qt.NoModifier, -1);
      one.close();
      break;
    case 53:
      if (!check(store.addDraft === "Eggs and ham", "the edit stays the draft (" + JSON.stringify(store.addDraft) + ")")) return;
      one.open();
      break;
    case 54:
      if (!check(view.field.text === "Eggs and ham", "the edit is back (" + JSON.stringify(view.field.text) + ")")) return;
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
      // and drops it once added.
      shell.put("reply-add.json", JSON.stringify(Object.assign(shell.snapshot(), { added: "t1" })));
      shell.put("slow-add", "1.5");
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
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
      break;
    case 61:
      var second = two.popup.bodyItem;
      if (!check(shell.calls("add").length === shell.callsBefore + 1, "Enter on the other monitor added nothing more (" + JSON.stringify(shell.calls("add")) + ")")) return;
      if (!check(second.field.text === "" && store.addDraft === "", "added: the text is gone (" + JSON.stringify(second.field.text) + ", draft " + JSON.stringify(store.addDraft) + ")")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      two.close();
      shell.put("slow-add", "");
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
      break;
    case 67:
      if (!check(one.opened && view.fieldOpen && view.fieldFocused && view.field.text === "", "the field is empty for the next task, the caret in it (" + JSON.stringify(view.field.text) + ")")) return;
      for (var k2 of "Close two") ev.keyClickChar(k2, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Return, Qt.ShiftModifier, -1);
      if (!check(!one.opened && store.addDraft === "Close two", "Shift+Enter (keep): sent, the panel closes")) return;
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
      // It reads like the task: the title, the captions and their values,
      // no help text and no form buttons (the description is a field).
      var shown = shell.visibleTexts(editor);
      var expected = ["Work › Review", "Review pull request #482", "Project", "Work › Review", "Date", "Today 14:00", "Deadline", "Priority", "P3", "Labels", "@code"];
      if (!check(JSON.stringify(shown) === JSON.stringify(expected), "the page shows the task, no help text (" + JSON.stringify(shown) + ")")) return;
      if (!check(shell.find(editor, "editComplete") === null && shell.find(editor, "editButtons") === null, "no Complete or Open buttons in the form")) return;
      // The title and description are quiet: no fill or border at rest.
      if (!check(editor.contentField.quiet && editor.descriptionField.quiet && editor.contentField.font.pixelSize === Kit.FoamyStyle.font.heading && editor.contentField.font.weight === Font.DemiBold, "the title and the description are edited in place")) return;
      // Open in Todoist: an icon in the page's band.
      var bandOpen = editor.openButton;
      if (!check(bandOpen.objectName === "editOpen" && bandOpen.visible && bandOpen.iconName === "external-link" && bandOpen.tooltipText === "Open in Todoist" && bandOpen.Accessible.name === "Open in Todoist" && shell.find(shell.find(editor, "editorBand"), "editOpen") === bandOpen, "Open in Todoist is an icon in the band")) return;
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
      // No deadline: the caption alone, with +; + opens a one-line field.
      // A deadline that isn't a day: said at once, nothing sent, the field
      // stays open; Esc drops it and closes the field.
      var deadlineSection = shell.find(editor1, "section-deadline");
      var deadlinePlus = shell.find(deadlineSection, "sectionAdd");
      var deadlineBox = shell.find(deadlineSection, "sectionBox");
      if (!check(deadlinePlus.visible && deadlineBox.Accessible.name === "Add deadline" && shell.valueText(editor1, "deadlineRow") === "" && !editor1.deadlineField.visible, "no deadline: the caption and +")) return;
      // The section is one click target, as in Todoist: the pointer over
      // its caption lights all of it, a click there does what + does.
      var deadlineCaption = shell.find(deadlineSection, "sectionCaption");
      ev.mouseMove(deadlineCaption, 4, deadlineCaption.height / 2, -1, Qt.NoButton, Qt.NoModifier);
      if (!check(deadlineBox.lit && Qt.colorEqual(deadlineBox.color, Kit.FoamyPalette.hoverFill) && deadlineBox.radius === Kit.FoamyStyle.radius && !shell.sectionBox(editor1, "section-due").lit, "hover lights the whole section, alone (" + deadlineBox.color + ")")) return;
      ev.mouseClick(deadlineCaption, 4, deadlineCaption.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      if (!check(editor1.deadlineField.visible && editor1.deadlineField.inputActiveFocus && !deadlinePlus.visible && !deadlineBox.lit, "a click on the caption opened the deadline field with the caret")) return;
      for (var d1 of "2026-02-30") ev.keyClickChar(d1, Qt.NoModifier, -1);
      ev.keyClick(Qt.Key_Return, Qt.NoModifier, -1);
      var deadlineError = shell.find(deadlineSection, "fieldErrorText");
      if (!check(deadlineError.visible && deadlineError.text === "Enter a deadline as YYYY-MM-DD." && shell.calls("apply").length === shell.callsBefore + 1 && editor1.deadlineField.inputActiveFocus, "a bad deadline is caught before sending, the field open")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(editor1.deadlineField.text === "" && !deadlineError.visible && !editor1.deadlineField.visible && deadlineBox.activeFocus && view.pageShown, "Esc dropped the change, closed the field, the keys on its section")) return;
      // A save Todoist refuses: the error under the date, with Retry, the text kept.
      shell.put("reply-apply.json", JSON.stringify(Object.assign(shell.snapshotWith({ t4: { content: "Review the **PR**" } }), { results: { t4: { code: "HTTP", error: "Todoist answered HTTP %1.\u001f500" } } })));
      var dueRow1 = shell.find(editor1, "dueRow");
      ev.mouseClick(dueRow1, dueRow1.width / 2, dueRow1.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      if (!check(editor1.dueField.visible && editor1.dueField.inputActiveFocus && editor1.dueField.text === "today 14:00" && !dueRow1.visible, "the date row opened its field with Todoist's words")) return;
      if (!check(shell.visibleTexts(shell.find(editor1, "section-due")).join("|") === "Date", "no help text under the open date field (" + shell.visibleTexts(shell.find(editor1, "section-due")) + ")")) return;
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
      // A reply that comes after its editor closed is dropped.
      shell.put("slow-task", "1.5");
      view.editor.back();
      view.openTask("t5", true);
      break;
    case 77:
      view.closeTask();
      if (!check(store.description.id === "" && store.description.state === "", "closed: no description")) return;
      break;
    case 78:
      if (!check(store.description.id === "" && store.description.state === "", "the late reply was dropped (" + JSON.stringify(store.description) + ")")) return;
      shell.put("slow-task", "");
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
          one.prefs.save("panelWidth", "wide");
        });
      });
      break;
    case 80:
      // Wide: Todoist's split. The title and description on the left, the
      // properties in a column on a tinted surface at the trailing edge.
      view.openTask("t4", true);
      var wideEditor = view.editor;
      // "" when the split is laid out; else where things are.
      var splitOff = function() {
        var side = shell.find(wideEditor, "editorSide");
        var head = shell.find(wideEditor, "editorHead");
        var props = shell.find(wideEditor, "editorProperties");
        var sideX = side.mapToItem(wideEditor, 0, 0).x;
        var propsX = props.mapToItem(wideEditor, 0, 0).x;
        var headEnd = head.mapToItem(wideEditor, head.width, 0).x;
        var propsY = props.mapToItem(wideEditor, 0, 0).y;
        var headY = head.mapToItem(wideEditor, 0, 0).y;
        var ok = wideEditor.split && side.visible && Math.abs(sideX + side.width - wideEditor.width) < 1 && side.width === wideEditor.sideWidth && propsX >= sideX && headEnd <= sideX + 1 && Math.abs(propsY - headY) < Kit.FoamyStyle.gapLarge + 1 && !Qt.colorEqual(side.color, "transparent");
        return ok ? "" : JSON.stringify([sideX, side.width, propsX, headEnd, propsY, headY]);
      };
      // The layout settles on the next frame after the size change.
      wait.waitFor(function() { return splitOff() === ""; }, 3000, function(laidOut) {
      if (!check(laidOut && !shell.find(view, "rail").visible, "wide: the properties beside the title, on their own tint (" + splitOff() + ")")) return;
      // The project: its row opens a menu of the projects and their
      // sections, the task's place checked; a pick saves the move alone.
      if (!check(shell.valueText(wideEditor, "editPlace") === "Work › Review", "the project row: Work › Review (" + shell.valueText(wideEditor, "editPlace") + ")")) return;
      var placeRow = shell.find(wideEditor, "editPlace");
      ev.mouseClick(placeRow, placeRow.width / 2, placeRow.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      var places = wideEditor.menu.entries.map(function(entry) { return entry.text + (entry.checked ? "*" : ""); });
      if (!check(wideEditor.menu.opened && JSON.stringify(places.slice(0, 4)) === JSON.stringify(["Inbox", "Work", "Work › Review*", "Work › Ops"]), "the project menu: projects and sections, the place checked (" + JSON.stringify(places) + ")")) return;
      shell.put("reply-apply.json", JSON.stringify(Object.assign(shell.snapshotWith({ t4: { section_id: "s-ops" } }), { results: { t4: "ok" } })));
      shell.callsBefore = shell.calls("apply").length;
      wideEditor.menu.activate(3);
      wait.waitFor(function() { return shell.calls("apply").length === shell.callsBefore + 1 && !store.busy && !wideEditor.saving; }, 15000, function(ok) {
        var moved = shell.updatesSince(shell.callsBefore);
        if (!check(ok && JSON.stringify(moved) === JSON.stringify([{ op: "update", id: "t4", section_id: "s-ops" }]) && shell.valueText(wideEditor, "editPlace") === "Work › Ops", "the pick moved it to Ops alone (" + JSON.stringify(moved) + ")")) return;
        // Open in Todoist: the band's icon opens the task.
        shell.openedBefore = shell.opened().length;
        var bandOpen = wideEditor.openButton;
        ev.mouseClick(bandOpen, bandOpen.width / 2, bandOpen.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
        wait.waitFor(function() { return shell.opened().length === shell.openedBefore + 1 && !store.launchRunning; }, 15000, function(ok2) {
          var launched = ok2 ? shell.opened()[shell.openedBefore] : [];
          if (!check(ok2 && launched.indexOf(Model.webUrl("task", "t4")) >= 0, "the band's icon opened the task (" + JSON.stringify(launched) + ")")) return;
          // The ring beside the title completes the task and leaves the page.
          var ring = wideEditor.ring;
          if (!check(ring.Accessible.name === "Complete" && ring.activeFocusOnTab, "the ring is named and on the Tab path")) return;
          ev.mouseClick(ring, ring.width / 2, ring.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
          if (!check(store.struck.t4 === true && !view.pageShown, "the ring completed it, back to the list")) return;
          // Undone within its window: nothing is sent.
          store.toggleComplete("t4");
          if (!check(!store.struck.t4 && shell.calls("apply").length === shell.callsBefore + 1, "and undone, nothing sent")) return;
          shell.editorMenus(view, function() { one.prefs.save("panelWidth", "large"); });
        });
      });
      });
      break;
    case 81:
      // Large: a click on the bar opens the popup under the button, wider.
      shell.put("reply-task.json", JSON.stringify({ ok: true, task: { id: "t1", description: "One", truncated: false } }));
      // The popup's pointer over its band, as a user's on the bar: no row is
      // under it when Large opens (only the keys move the cursor below).
      ev.mouseMove(view.band, 10, 10, -1, Qt.NoButton, Qt.NoModifier);
      one.close();
      ev.mouseClick(button, button.width / 2, button.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      break;
    case 82:
      var big = one.popup.bodyItem;
      if (!check(shell.popupPlacement(one, 880) === "", "the popup, 880 wide under the button (" + shell.popupPlacement(one, 880) + ")")) return;
      if (!check(one.popup.maxHeight === Math.round(one.popup.screenH * 0.7) && one.popup.cardItem.height <= one.popup.maxHeight + 1, "at most 70% of the screen high (" + JSON.stringify([one.popup.cardItem.height, one.popup.maxHeight]) + ")")) return;
      if (!check(big.size === "large" && shell.find(big, "rail-week") !== null && big.band.visible && big.editor.visible && shell.find(big.editor, "editorEmpty").text === "No task selected", "the band, the rail with Week, the pane's empty state")) return;
      ev.keyClick(Qt.Key_Down, Qt.NoModifier, -1);
      if (!check(big.cursorRow() && big.paneTask === big.cursorRow().id && big.editor.taskId === "t1" && !big.editor.descriptionField.enabled && big.editor.descriptionField.placeholderText === "Loading…", "↓: the pane shows the row, the description loading (" + big.paneTask + ")")) return;
      break;
    case 83:
      var big1 = one.popup.bodyItem;
      // The pane: no Open icon and no "Task" caption; Open in Todoist is in
      // the band, in Search's place, and Search leads the ⋯ menu.
      var paneTexts = shell.visibleTexts(big1.editor);
      if (!check(big1.editor.openButton === null && shell.find(big1.editor, "paneOpen") === null && paneTexts.indexOf("Task") < 0 && paneTexts[0] === store.model.byId.t1.text && paneTexts[1] === "Project", "no Open icon in the pane; no Task caption (" + JSON.stringify(paneTexts) + ")")) return;
      var taskActions = big1.band.shownTrailing.map(function(item) { return item.objectName; });
      var openTask = shell.find(big1.band, "openTaskAction");
      if (!check(big1.taskInBand && JSON.stringify(taskActions) === JSON.stringify(["addAction", "openTaskAction"]) && openTask.iconName === "external-link" && openTask.tooltipText === "Open in Todoist" && openTask.Accessible.name === "Open in Todoist" && big1.band.menuButton.visible, "the band: +, Open, ⋯ (" + JSON.stringify(taskActions) + ")")) return;
      big1.band.openMenu(false);
      var menuTexts = big1.band.menu.entries.filter(function(entry) { return !entry.separator; }).map(function(entry) { return entry.text; });
      if (!check(JSON.stringify(menuTexts) === JSON.stringify(["Search", "Open in Todoist", "Settings"]), "Search leads the ⋯ menu (" + JSON.stringify(menuTexts) + ")")) return;
      big1.band.menu.activate(0);
      if (!check(big1.searching && big1.fieldFocused && !big1.band.menuOpen, "the menu's Search searches")) return;
      big1.leaveSearch();
      big1.cursor.emitTextKey(big1, "/");
      if (!check(big1.searching && big1.fieldFocused, "/ still searches with a task in the pane")) return;
      big1.leaveSearch();
      // The cursor stop and Enter: Open opens the pane's task.
      shell.openedBefore = shell.opened().length;
      big1.goTo(big1.searchStop);
      if (!check(openTask.hasCursor, "Open is the band's second stop")) return;
      big1.activate(false);
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
      if (!check(launchedTask.length === 1 && launchedTask[0].indexOf(Model.webUrl("task", "t1")) >= 0, "the band's Open opened the pane's task once (" + JSON.stringify(launchedTask) + ")")) return;
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
      break;
    case 86:
      var big2 = one.popup.bodyItem;
      var weekSent = shell.updatesSince(shell.callsBefore);
      if (!check(JSON.stringify(weekSent) === JSON.stringify([{ op: "update", id: shell.paneFrom, content: shell.paneText }]), "the view change saved the typed text (" + JSON.stringify(weekSent) + ")")) return;
      var ids = big2.weekColumns.map(function(col) { return col.entries.map(function(e) { return e.kind === "day" ? e.key : e.id; }); });
      if (!check(big2.weekShown && big2.week.visible && !big2.list.visible && JSON.stringify(ids) === JSON.stringify([["t1", "t2"], ["t3", "t4", "t5", "t6"], ["t10", "t11"], ["day:2026-11-21", "t12"]]), "the Week view's columns (" + JSON.stringify(ids) + ")")) return;
      if (!check(!big2.editor.visible, "no pane until a card is opened")) return;
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
      ev.keyClick(Qt.Key_Space, Qt.NoModifier, -1);
      if (!check(!store.struck.t2, "and undoes")) return;
      // Ctrl+→: a day later with the due op; the cursor follows the task.
      shell.put("reply-apply.json", JSON.stringify(Object.assign(shell.snapshotWith({ t2: { due: Fixtures.due(shell.today) } }), { results: { t2: "ok" } })));
      shell.callsBefore = shell.calls("apply").length;
      big2.focusList();
      ev.keyClick(Qt.Key_Right, Qt.ControlModifier, -1);
      break;
    case 87:
      var big3 = one.popup.bodyItem;
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
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      if (!check(!one.opened, "Esc: the popup closes")) return;
      break;
    case 89:
      // The closed popup keeps its view, but builds no list behind it.
      var hidden = one.popup.bodyItem;
      if (!check(hidden && hidden.weekShown && hidden.weekColumns.length === 0 && hidden.rows.length === 0, "a closed popup builds no Week columns or rows (" + (hidden ? JSON.stringify([hidden.weekColumns.length, hidden.rows.length]) : "no view") + ")")) return;
      // Large again, in Norwegian: the pane's buttons still on one line.
      shell.put("reply-task.json", JSON.stringify({ ok: true, task: { id: "t1", description: "One", truncated: false } }));
      shell.pickLanguage("no");
      ev.mouseClick(button, button.width / 2, button.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      Qt.callLater(function() { var v = one.popup.bodyItem; if (v) v.goTo(v.firstRowStop); });
      break;
    case 90:
      var big6 = one.popup.bodyItem;
      if (!check(big6.view === "today" && big6.rows.length > 0, "open again (on Today): the rows are back (" + big6.rows.length + ")")) return;
      var noOpen = shell.find(big6.band, "openTaskAction");
      var noTexts = shell.visibleTexts(big6.editor);
      if (!check(big6.editor.ring.Accessible.name === "Fullfør" && noOpen.tooltipText === "Åpne i Todoist" && JSON.stringify(noTexts.filter(function(text) { return ["Prosjekt", "Dato", "Frist", "Prioritet", "Etiketter"].indexOf(text) >= 0; })) === JSON.stringify(["Prosjekt", "Dato", "Frist", "Prioritet", "Etiketter"]), "Norwegian: the ring, Open and the captions (" + JSON.stringify(noTexts) + ")")) return;
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
      // Large where the popup has no room on the bar's screen: Wide; with
      // no room for Wide either, Small.
      shell.savedMargin = one.popup.margin;
      one.popup.margin = 600;
      if (!check(one.popup.availableCardWidth === one.popup.screenW - 1200 && one.size === "wide", "no room for Large: Wide (" + one.size + ")")) return;
      one.popup.margin = 700;
      if (!check(one.size === "standard", "no room for Wide: Small (" + one.size + ")")) return;
      one.popup.margin = 600;
      ev.mouseClick(button, button.width / 2, button.height / 2, Qt.LeftButton, Qt.NoModifier, -1);
      break;
    case 92:
      // (The test's huge margin pushes the card down; only its width counts here.)
      if (!check(view.size === "wide" && one.popup.contentWidth === 560 && Math.abs(one.popup.cardItem.width - 560) < 1, "the popup is Wide (" + view.size + ", " + one.popup.contentWidth + ")")) return;
      one.close();
      one.popup.margin = shell.savedMargin;
      if (!check(one.size === "large", "room again: Large")) return;
      // IPC toggle: the leader's popup, Large.
      var ipc = one.data.concat(two.data).find(function(item) { return item.target === "foamy.todoist" && item.enabled && typeof item.toggle === "function"; });
      shell.ipcPanel = one.data.indexOf(ipc) >= 0 ? one : two;
      if (!check(shell.ipcPanel === shell.leader(), "the leader owns IPC")) return;
      ipc.toggle();
      break;
    case 93:
      var lead = shell.leader();
      if (!check(shell.popupPlacement(lead, 880) === "", "IPC toggle: the leader's popup, 880 wide under its button (" + shell.popupPlacement(lead, 880) + ")")) return;
      // IPC add while Large is open: the caret in the band's field.
      var ipcAdd = lead.data.find(function(item) { return item.target === "foamy.todoist" && item.enabled && typeof item.add === "function"; });
      ipcAdd.add();
      break;
    case 94:
      var lead2 = shell.leader();
      var leadView = lead2.popup.bodyItem;
      if (!check(lead2.opened && leadView.fieldOpen && !leadView.searching && leadView.size === "large", "IPC add: the add field in the Large popup")) return;
      ev.keyClick(Qt.Key_Escape, Qt.NoModifier, -1);
      // The Week view, then another size: Today, and "Open on: Last view"
      // opens Today.
      leadView.setView("week");
      if (!check(store.lastView === "week", "Week is the last view")) return;
      one.prefs.save("openOn", "last");
      one.prefs.save("panelWidth", "standard");
      break;
    case 95:
      var lead3 = shell.leader();
      if (!check(lead3.popup.bodyItem.view === "today" && lead3.popup.bodyItem.size === "standard", "another size: the Week view became Today (" + lead3.popup.bodyItem.view + ")")) return;
      lead3.close();
      one.open();
      break;
    case 96:
      if (!check(view.view === "today" && view.size === "standard", "the Week view fell back to Today (" + view.view + ")")) return;
      one.close();
      one.prefs.save("openOn", "today");
      // No helper for this CPU: says so, no retry loop; an add waiting
      // behind the sync ends as failed.
      shell.put("exit-sync", "127");
      shell.settled = [];
      store.sync();
      shell.lateAdd = store.add("Waiting", "", "");
      break;
    case 97:
      if (!check(store.accountError === "This plugin's helper isn't available for this CPU.", "unavailable: the message (" + store.accountError + ")")) return;
      var before = shell.calls().length;
      store.sync();
      store.check();
      if (!check(!store.busy && shell.calls().length === before && !store.polling, "unavailable: nothing runs again")) return;
      var late = shell.settled.find(function(s) { return s.request === shell.lateAdd; });
      if (!check(late && !late.ok && late.message === store.accountError, "the waiting add ended as failed (" + JSON.stringify(shell.settled) + ")")) return;
      shell.afterAdd = store.add("After", "", "");
      wait.after(50, function() {
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
    # The kit's stand-in wl-paste: a paste reads "folder", never the real clipboard.
    run.env.update(hostenv.clipboard_fakes(run.base / "clipboard", env=run.env))
    run.run(timeout=200)
    refused = run.host_commands()
    if refused:
        print("FAIL: the plugin ran host commands:", *refused, sep="\n  ")
        sys.exit(1)
    # FOAMY_TEST_VERBOSE=1 prints the shell's log on success too.
    print(run.log if not run.ok or os.environ.get("FOAMY_TEST_VERBOSE") else "PASS: real plugin runtime interactions")
    sys.exit(0 if run.ok else 1)
finally:
    run.cleanup()
    shutil.rmtree(copy, ignore_errors=True)
