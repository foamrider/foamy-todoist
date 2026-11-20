// Inline settings schema for foamy.todoist (mirrors manifest.json barWidget.schema).
// Validation and saving live in kit/FoamyPrefs.js. The API token is never a
// setting: it lives in the keyring, handled by the helper.
var refreshChoices = [60, 120, 300, 600, 900, 1800]
var views = ["today", "inbox", "upcoming"]

// The open command: a bare command name or an absolute path, then
// arguments separated by spaces; no control characters, no leading space.
// Model.openArgv runs it without a shell.
var openCommandPattern = "^$|^(?:[A-Za-z0-9_][A-Za-z0-9._+-]*|/[^\\s\\x00-\\x1f\\x7f]*)(?: +[^\\s\\x00-\\x1f\\x7f]+)* *$"
function validOpenCommand(text) {
  return typeof text === "string" && text.length <= 300 && new RegExp(openCommandPattern).test(text)
}

var fields = [
  // The number in the bar: tasks left today, or nothing (icon only).
  { key: "barCount", type: "enum", options: ["today", "none"], defaultValue: "today" },
  // The size: Small (the 420 px popup with tabs) or Wide (the rail, the
  // list, and the details pane while a task is selected). The key keeps its
  // old name, so a saved "standard" or "wide" needs no migration; a saved
  // "large" (the size Wide took over) reads as "wide" (current()).
  { key: "panelWidth", type: "enum", options: ["standard", "wide"], defaultValue: "standard" },
  // Enter in the add field: add and close the panel, or add and keep the
  // field open for the next task (Shift+Enter does the other).
  { key: "afterAdd", type: "enum", options: ["close", "keep"], defaultValue: "close" },
  // "last": the view of the last open, kept for the shell session only.
  { key: "openOn", type: "enum", options: ["today", "inbox", "upcoming", "last"], defaultValue: "today" },
  // Tasks assigned to someone else in Today, Upcoming, the Inbox and the
  // bar count: left out ("hide") or shown.
  { key: "othersTasks", type: "enum", options: ["hide", "show"], defaultValue: "hide" },
  { key: "refreshSeconds", type: "integer", defaultValue: 300, min: 60, max: 1800, step: 60 },
  // Empty: the browser (xdg-open).
  { key: "openCommand", type: "string", defaultValue: "", maxLength: 300, pattern: openCommandPattern }
]

// The bar entry as the panel reads it (Panel.qml's FoamyPrefsQueue):
// "large", the size Wide took over, reads as "wide", quietly; the next save
// of any setting writes the entry with "wide".
function current(settings) {
  if (settings && settings.panelWidth === "large")
    return Object.assign({}, settings, { panelWidth: "wide" })
  return settings
}

if (typeof module !== "undefined") module.exports = { fields: fields, refreshChoices: refreshChoices, views: views, openCommandPattern: openCommandPattern, validOpenCommand: validOpenCommand, current: current }
