// The task editor's logic, pure: a task (Model.index) and what was typed
// in one field in, the helper's `update` fields out (only what changed),
// or why they can't be sent. TaskEditor.qml shows the fields and keeps the
// drafts; TodoStore sends the change. The limits are the helper's, checked
// here first so a typo is caught before a request.

var MAX_CONTENT = 500
var MAX_DESCRIPTION = 16383
var MAX_DUE_STRING = 200
var MAX_LABELS = 50
var MAX_LABEL = 60

// Catalog keys: the helper's own messages for the same rules.
var ERRORS = {
  emptyContent: "Enter a task.",
  longContent: "A task can have at most 500 characters.",
  controlContent: "A task can't have line breaks or other control characters.",
  dueString: "Enter the date in words, at most 200 characters.",
  deadline: "Enter a deadline as YYYY-MM-DD.",
  longDescription: "A description can have at most 16383 characters.",
  controlDescription: "A description can't have control characters other than line breaks and tabs.",
  labels: "Give at most 50 labels of 1 to 60 characters each, without control characters.",
  twiceLabel: "A label is given twice."
}

// Characters as the helper counts them (code points, not UTF-16 units).
function chars(text) {
  return Array.from(String(text)).length
}

// A real calendar day as "YYYY-MM-DD".
function validDate(text) {
  var match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(text))
  if (!match)
    return false
  var date = new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]), 12)
  return date.getFullYear() === Number(match[1]) && date.getMonth() === Number(match[2]) - 1 && date.getDate() === Number(match[3])
}

// A place in the project menu: "<project id>/<section id>" ("" section:
// the project's root).
function placeValue(projectId, sectionId) {
  return projectId + "/" + (sectionId || "")
}
function parsePlace(value) {
  var parts = String(value).split("/")
  return { projectId: parts[0] || "", sectionId: parts[1] || "" }
}

// What a field starts with for `task`. `description` is the fetched one.
function initial(task, key, description) {
  if (!task)
    return key === "labels" ? [] : key === "priority" ? 1 : ""
  switch (key) {
  case "content":
    return task.content
  case "due":
    return task.dueString
  case "deadline":
    return task.deadline
  case "priority":
    return task.priority
  case "labels":
    return task.labels.slice()
  case "place":
    return placeValue(task.projectId, task.sectionId)
  case "description":
    return typeof description === "string" ? description : ""
  }
  return ""
}

// The task as it will be once the saves in flight land: `saves` are their
// `update` fields (Edit.change), oldest first. Each new edit is measured
// against this, so a second edit made before the first reply builds on the
// first (two labels removed in a row stay removed) and an older reply can't
// stand in for a newer request.
function pending(task, saves) {
  if (!task)
    return null
  var out = Object.assign({}, task)
  saves.forEach(function (fields) {
    if (typeof fields.content === "string")
      out.content = fields.content
    if (typeof fields.due_string === "string") {
      out.dueString = fields.due_string
      if (fields.due_string === "")
        out.due = null
    }
    if (typeof fields.deadline === "string")
      out.deadline = fields.deadline
    if (typeof fields.priority === "number")
      out.priority = fields.priority
    if (Array.isArray(fields.labels))
      out.labels = fields.labels.slice()
    // A move to another project lands in its root unless a section is named.
    if (typeof fields.project_id === "string") {
      out.projectId = fields.project_id
      out.sectionId = fields.section_id || ""
    } else if (typeof fields.section_id === "string")
      out.sectionId = fields.section_id
  })
  return out
}

// Two descriptions read the same: line ends don't count (the text area
// turns CRLF into LF, so an untouched CRLF description is no change).
function sameDescription(a, b) {
  return String(a).replace(/\r\n?/g, "\n") === String(b).replace(/\r\n?/g, "\n")
}

// The same names, in any order (a change of case is a change).
function sameLabels(a, b) {
  return a.length === b.length && JSON.stringify(a.slice().sort()) === JSON.stringify(b.slice().sort())
}

// One field's save: {fields, error}. `fields` holds only what changed, in
// the helper's names (null: nothing to send); `error` is a catalog key
// ("" when it can be sent). An emptied date or deadline removes it.
function change(task, key, value, description) {
  var none = { fields: null, error: "" }
  var fail = function (error) {
    return { fields: null, error: error }
  }
  var send = function (fields) {
    return { fields: fields, error: "" }
  }
  if (!task)
    return none
  switch (key) {
  case "content":
    var content = String(value).trim()
    if (content === task.content.trim())
      return none
    if (content === "")
      return fail(ERRORS.emptyContent)
    if (chars(content) > MAX_CONTENT)
      return fail(ERRORS.longContent)
    if (/[\u0000-\u001f\u007f]/.test(content))
      return fail(ERRORS.controlContent)
    return send({ content: content })
  case "due":
    var due = String(value).trim()
    if (due === task.dueString.trim())
      return none
    if (chars(due) > MAX_DUE_STRING || /[\u0000-\u001f\u007f]/.test(due))
      return fail(ERRORS.dueString)
    return send({ due_string: due })
  case "deadline":
    var deadline = String(value).trim()
    if (deadline === task.deadline)
      return none
    if (deadline !== "" && !validDate(deadline))
      return fail(ERRORS.deadline)
    return send({ deadline: deadline })
  case "priority":
    var priority = Number(value)
    if (priority === task.priority || [1, 2, 3, 4].indexOf(priority) < 0)
      return none
    return send({ priority: priority })
  case "labels":
    var labels = Array.isArray(value) ? value : []
    if (task.labelsTruncated || sameLabels(labels, task.labels))
      return none
    var seen = Object.create(null)
    for (var i = 0; i < labels.length; i++) {
      var name = labels[i]
      if (typeof name !== "string" || name === "" || chars(name) > MAX_LABEL || /[\u0000-\u001f\u007f]/.test(name))
        return fail(ERRORS.labels)
      if (seen[name.toLowerCase()])
        return fail(ERRORS.twiceLabel)
      seen[name.toLowerCase()] = true
    }
    if (labels.length > MAX_LABELS)
      return fail(ERRORS.labels)
    return send({ labels: labels.slice() })
  case "place":
    // Only what the user changed; the helper always sends a requested move.
    var place = parsePlace(value)
    if (place.projectId === "" || (place.projectId === task.projectId && place.sectionId === task.sectionId))
      return none
    if (place.projectId !== task.projectId)
      return send(place.sectionId ? { project_id: place.projectId, section_id: place.sectionId } : { project_id: place.projectId })
    // The same project: into a section, or out to its root (which needs the project).
    return send(place.sectionId ? { section_id: place.sectionId } : { project_id: place.projectId, section_id: "" })
  case "description":
    var text = String(value)
    if (typeof description !== "string" || sameDescription(text, description))
      return none
    if (chars(text) > MAX_DESCRIPTION)
      return fail(ERRORS.longDescription)
    if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(text))
      return fail(ERRORS.controlDescription)
    return send({ description: text })
  }
  return none
}

// The helper's apply request for one save: one `update` command.
function request(id, fields) {
  var command = { op: "update", id: id }
  for (var key in fields)
    command[key] = fields[key]
  return { commands: [command] }
}

// The project menu's entries: each project (the Inbox first, then the
// rail's order), each followed by its sections as "Project › Section".
// `projects` is Model.railProjects-like [{id, name}], `sections` the
// model's sections map. Each entry: {value (placeValue), label, projectId,
// section (true for a section)}.
function placeOptions(model, projects) {
  var sectionsIn = function (projectId) {
    return Object.keys(model.sections).map(function (id) {
      return model.sections[id]
    }).filter(function (section) {
      return section.projectId === projectId
    }).sort(function (a, b) {
      return a.order - b.order || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)
    })
  }
  var out = []
  projects.forEach(function (project) {
    out.push({ value: placeValue(project.id, ""), label: project.name, projectId: project.id, section: false })
    sectionsIn(project.id).forEach(function (section) {
      out.push({ value: placeValue(project.id, section.id), label: project.name + " › " + section.name, projectId: project.id, section: true })
    })
  })
  return out
}

if (typeof module !== "undefined")
  module.exports = { MAX_CONTENT, MAX_DESCRIPTION, ERRORS, chars, validDate, placeValue, parsePlace, initial, pending, sameDescription, change, request, placeOptions }
