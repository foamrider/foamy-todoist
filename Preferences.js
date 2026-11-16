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
  { key: "panelWidth", type: "enum", options: ["standard", "wide"], defaultValue: "standard" },
  // "last": the view of the last open, kept for the shell session only.
  { key: "openOn", type: "enum", options: ["today", "inbox", "upcoming", "last"], defaultValue: "today" },
  // Tasks assigned to someone else in Today, Upcoming, the Inbox and the
  // bar count: left out ("hide") or shown.
  { key: "othersTasks", type: "enum", options: ["hide", "show"], defaultValue: "hide" },
  { key: "refreshSeconds", type: "integer", defaultValue: 300, min: 60, max: 1800, step: 60 },
  // Empty: the browser (xdg-open).
  { key: "openCommand", type: "string", defaultValue: "", maxLength: 300, pattern: openCommandPattern }
]

if (typeof module !== "undefined") module.exports = { fields: fields, refreshChoices: refreshChoices, views: views, openCommandPattern: openCommandPattern, validOpenCommand: validOpenCommand }
