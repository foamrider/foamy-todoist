// The panel's view logic, pure: the helper's snapshot in, the rows of each
// view out (grouped, sorted, counted). Days are the user's local dates
// ("YYYY-MM-DD", the shell's clock); nothing here reads the clock itself.
// TodoStore computes an index once per snapshot and the rows once per
// snapshot, day or view change, never per frame.

// Todoist's web app. The todoist:// links in the API docs need the desktop
// app; these work in any browser.
var WEB = "https://app.todoist.com/app/"

function webUrl(kind, id) {
  if (kind === "inbox" || kind === "today" || kind === "upcoming")
    return WEB + kind
  if ((kind === "project" || kind === "task") && validId(id))
    return WEB + kind + "/" + encodeURIComponent(id)
  return ""
}

// A map with no prototype: keys such as "constructor" or "__proto__"
// (names and ids come from the user's data) are ordinary keys.
function dict() {
  return Object.create(null)
}

// Whether `map` (a plain object from JSON or QML) holds `key` itself.
function has(map, key) {
  return !!map && typeof map === "object" && Object.prototype.hasOwnProperty.call(map, key)
}

function validId(id) {
  return typeof id === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(id)
}

// Todoist colour names → the theme colour nearest to each (FoamyPalette
// roles). Unknown names are muted, like Todoist's own default (charcoal).
var COLOR_ROLES = {
  berry_red: "error",
  red: "error",
  magenta: "error",
  orange: "warning",
  yellow: "warning",
  salmon: "warning",
  olive_green: "success",
  lime_green: "success",
  green: "success",
  mint_green: "success",
  teal: "info",
  sky_blue: "info",
  light_blue: "info",
  blue: "accent",
  grape: "accent",
  violet: "accent",
  lavender: "accent",
  charcoal: "muted",
  grey: "muted",
  taupe: "muted"
}

function colorRole(name) {
  return Object.prototype.hasOwnProperty.call(COLOR_ROLES, name) ? COLOR_ROLES[name] : "muted"
}

// API priority 4 is the user's p1.
function priorityRole(priority) {
  return priority === 4 ? "error" : priority === 3 ? "warning" : priority === 2 ? "accent" : "muted"
}

// ---- days -------------------------------------------------------------------

function pad(n) {
  return (n < 10 ? "0" : "") + n
}

function dayKey(date) {
  return date.getFullYear() + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate())
}

// Noon of that local day: adding days to it never lands on the wrong date
// across a daylight-saving change.
function dayDate(key) {
  return new Date(Number(key.slice(0, 4)), Number(key.slice(5, 7)) - 1, Number(key.slice(8, 10)), 12)
}

function addDays(key, days) {
  var date = dayDate(key)
  date.setDate(date.getDate() + days)
  return dayKey(date)
}

// A real calendar day as "YYYY-MM-DD" (no 30 February).
function validDate(text) {
  if (typeof text !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(text))
    return false
  return dayKey(dayDate(text)) === text
}

// Whole days from `from` to `to` (both keys).
function daysBetween(from, to) {
  return Math.round((dayDate(to) - dayDate(from)) / 86400000)
}

// A due date as {day, time ("HH:MM" or ""), minutes (-1 without a time),
// recurring}. Floating dates are local already; fixed-zone ones ("…Z") are
// UTC and shown in local time. null for no or a broken date.
function dueOf(due) {
  if (!due || typeof due.date !== "string")
    return null
  var text = due.date
  if (!/^\d{4}-\d{2}-\d{2}/.test(text))
    return null
  var recurring = due.is_recurring === true
  if (text.length === 10)
    return { day: text, time: "", minutes: -1, recurring: recurring }
  if (text.endsWith("Z")) {
    var moment = new Date(text)
    if (isNaN(moment.getTime()))
      return null
    return { day: dayKey(moment), time: pad(moment.getHours()) + ":" + pad(moment.getMinutes()), minutes: moment.getHours() * 60 + moment.getMinutes(), recurring: recurring }
  }
  var match = /^T(\d{2}):(\d{2})/.exec(text.slice(10))
  if (!match)
    return null
  return { day: text.slice(0, 10), time: match[1] + ":" + match[2], minutes: Number(match[1]) * 60 + Number(match[2]), recurring: recurring }
}

// How a day reads next to today: "today", "yesterday", "tomorrow",
// "weekday" (within a week either way) or "date". QML words it.
function dayKind(key, today) {
  var days = daysBetween(today, key)
  if (days === 0)
    return "today"
  if (days === -1)
    return "yesterday"
  if (days === 1)
    return "tomorrow"
  return Math.abs(days) < 7 ? "weekday" : "date"
}

// ---- text -------------------------------------------------------------------

// Task content as plain text: [text](url) links show their text; bold,
// italic, strikethrough and code markers are dropped. Markers inside words
// (snake_case, 2*3*4) stay.
function plainText(text) {
  if (typeof text !== "string")
    return ""
  return text
    .replace(/!?\[([^\]\n]*)\]\((?:[^()\s]|\([^()\s]*\))*\)/g, "$1")
    .replace(/(^|[^\w*])(\*\*|__)(?=\S)([^\n]*?\S)\2(?![\w*])/g, "$1$3")
    .replace(/(^|[^\w*])([*_])(?=\S)([^\n*_]*?\S)\2(?![\w*])/g, "$1$3")
    .replace(/~~(?=\S)([^\n]*?\S)~~/g, "$1")
    .replace(/`([^`\n]+)`/g, "$1")
}

// ---- the snapshot -----------------------------------------------------------

function compare(a, b) {
  return a < b ? -1 : a > b ? 1 : 0
}

// The snapshot, checked and indexed. Records that don't fit are skipped:
// the helper already validated them, this only guards the shapes QML reads.
function index(snapshot) {
  var source = snapshot && typeof snapshot === "object" ? snapshot : {}
  var list = function (value) {
    return Array.isArray(value) ? value : []
  }
  var user = source.user && typeof source.user === "object" ? source.user : null
  var projects = dict()
  var inboxId = user && validId(user.inbox_project_id) ? user.inbox_project_id : ""
  list(source.projects).forEach(function (raw) {
    if (!raw || !validId(raw.id) || typeof raw.name !== "string" || raw.is_archived === true)
      return
    projects[raw.id] = {
      id: raw.id,
      name: raw.name,
      color: typeof raw.color === "string" ? raw.color : "charcoal",
      parentId: validId(raw.parent_id) ? raw.parent_id : "",
      order: Number(raw.child_order) || 0,
      inbox: raw.inbox === true,
      shared: raw.shared === true
    }
    if (!inboxId && raw.inbox === true)
      inboxId = raw.id
  })
  var sections = dict()
  list(source.sections).forEach(function (raw) {
    if (!raw || !validId(raw.id) || !validId(raw.project_id) || typeof raw.name !== "string")
      return
    sections[raw.id] = { id: raw.id, projectId: raw.project_id, name: raw.name, order: Number(raw.section_order) || 0 }
  })
  var tasks = []
  var byId = dict()
  list(source.tasks).forEach(function (raw) {
    if (!raw || !validId(raw.id) || typeof raw.content !== "string" || !projects[raw.project_id])
      return
    var priority = [1, 2, 3, 4].indexOf(raw.priority) >= 0 ? raw.priority : 1
    var task = {
      id: raw.id,
      text: plainText(raw.content),
      projectId: raw.project_id,
      sectionId: validId(raw.section_id) && sections[raw.section_id] ? raw.section_id : "",
      parentId: validId(raw.parent_id) ? raw.parent_id : "",
      priority: priority,
      due: dueOf(raw.due),
      labels: list(raw.labels).filter(function (label) {
        return typeof label === "string" && label !== ""
      }),
      order: Number(raw.child_order) || 0,
      dayOrder: Number(raw.day_order) || 0,
      responsible: validId(raw.responsible_uid) ? raw.responsible_uid : "",
      // For the editor: the content as Todoist has it (Markdown and all),
      // the date in Todoist's words, the deadline, and whether the helper
      // cut the labels (then they can't be edited here).
      content: raw.content,
      dueString: raw.due && typeof raw.due.string === "string" ? raw.due.string : "",
      deadline: validDate(raw.deadline) ? raw.deadline : "",
      labelsTruncated: raw.labels_truncated === true
    }
    tasks.push(task)
    byId[task.id] = task
  })
  // A subtask whose parent isn't listed (closed, elsewhere) is a root one.
  tasks.forEach(function (task) {
    var parent = byId[task.parentId]
    if (!parent || parent.projectId !== task.projectId || parent.sectionId !== task.sectionId)
      task.parentId = ""
  })
  return {
    user: user,
    inboxId: inboxId,
    projects: projects,
    sections: sections,
    tasks: tasks,
    byId: byId,
    labels: labelList(list(source.labels), tasks),
    members: memberLists(source, user, projects),
    people: peopleOf(source),
    truncated: source.truncated === true
  }
}

// Everyone the snapshot names, {id: {id, name, email}}.
function peopleOf(source) {
  var people = dict()
  ;(Array.isArray(source.collaborators) ? source.collaborators : []).forEach(function (raw) {
    if (raw && validId(raw.id) && typeof raw.full_name === "string" && raw.full_name !== "")
      people[raw.id] = { id: raw.id, name: raw.full_name, email: typeof raw.email === "string" ? raw.email : "" }
  })
  return people
}

// The people of each shared project, {project id: [{id, name, email}]}
// by name, the user always among them.
function memberLists(source, user, projects) {
  var people = dict()
  ;(Array.isArray(source.collaborators) ? source.collaborators : []).forEach(function (raw) {
    if (raw && validId(raw.id) && typeof raw.full_name === "string" && raw.full_name !== "")
      people[raw.id] = { id: raw.id, name: raw.full_name, email: typeof raw.email === "string" ? raw.email : "" }
  })
  if (user && validId(user.id) && typeof user.full_name === "string" && user.full_name !== "" && !people[user.id])
    people[user.id] = { id: user.id, name: user.full_name, email: typeof user.email === "string" ? user.email : "" }
  var memberships = source.project_collaborators && typeof source.project_collaborators === "object" ? source.project_collaborators : {}
  var out = dict()
  Object.keys(projects).forEach(function (id) {
    var ids = has(memberships, id) && Array.isArray(memberships[id]) ? memberships[id].slice() : []
    // Assignable: shared, or two or more people active in it (team and
    // workspace projects come with shared false).
    projects[id].assignable = projects[id].shared || ids.length >= 2
    if (!projects[id].assignable)
      return
    if (user && validId(user.id) && ids.indexOf(user.id) < 0)
      ids.push(user.id)
    out[id] = ids.filter(function (who) {
      return has(people, who)
    }).map(function (who) {
      return people[who]
    }).sort(function (a, b) {
      return compare(a.name.toLowerCase(), b.name.toLowerCase())
    })
  })
  return out
}

// Labels to suggest: the personal ones from Sync, then the names on open
// tasks (shared labels exist only there), one entry per name (ignoring
// case; a personal one wins), sorted by name.
function labelList(personal, tasks) {
  var byName = dict()
  personal.forEach(function (raw) {
    if (raw && validId(raw.id) && typeof raw.name === "string" && raw.name !== "")
      byName[raw.name.toLowerCase()] = { name: raw.name, personal: true }
  })
  tasks.forEach(function (task) {
    task.labels.forEach(function (name) {
      if (!byName[name.toLowerCase()])
        byName[name.toLowerCase()] = { name: name, personal: false }
    })
  })
  return Object.keys(byName).sort(compare).map(function (key) {
    return byName[key]
  })
}

// ---- autocomplete in the add field ---------------------------------------------

var MAX_SUGGESTIONS = 6

// Whether text[at] is whitespace that ends a Quick Add word: a space
// escaped as `\ ` belongs to the word (`#My\ Project` is one name).
function breaksWord(text, at) {
  return /\s/.test(text.charAt(at)) && text.charAt(at - 1) !== "\\"
}

// The word at the caret when it is a Quick Add `#project` or `@label`: the
// trigger at the start or after whitespace, then up to the caret (an
// escaped space, `\ `, belongs to the word). {kind, start, end, query,
// items}: `end` is where the word ends (it may go on past the caret),
// `query` the text between the trigger and the caret (escapes undone),
// `items` the matches (none: the list hides). null without a trigger.
function suggestions(model, text, caret) {
  if (typeof text !== "string" || !(caret > 0) || caret > text.length)
    return null
  var start = caret
  while (start > 0 && !breaksWord(text, start - 1))
    start--
  var trigger = text.charAt(start)
  var kind = { "#": "project", "@": "label", "/": "section", "+": "assignee" }[trigger]
  if (!kind)
    return null
  var end = caret
  while (end < text.length && !breaksWord(text, end))
    end++
  var query = text.slice(start + 1, caret).replace(/\\ /g, " ")
  var pool
  if (kind === "project")
    pool = Object.keys(model.projects).map(function (id) {
      var project = model.projects[id]
      return { kind: "project", id: project.id, name: project.name, role: colorRole(project.color) }
    })
  else if (kind === "label")
    pool = (model.labels || []).map(function (label) {
      return { kind: "label", name: label.name }
    })
  else {
    // Sections and assignees belong to the last #project before the trigger.
    var project = projectBefore(model, text, start)
    if (!project)
      return null
    if (kind === "section")
      pool = Object.keys(model.sections).map(function (id) {
        return model.sections[id]
      }).filter(function (section) {
        return section.projectId === project.id
      }).map(function (section) {
        return { kind: "section", name: section.name }
      })
    else if (!project.assignable)
      return null
    else
      pool = (has(model.members, project.id) ? model.members[project.id] : []).map(function (person) {
        return { kind: "assignee", name: person.name, email: person.email }
      })
  }
  return { kind: kind, start: start, end: end, query: query, items: matchNames(pool, query) }
}

// The project the last `#name` token before `at` names (escapes undone,
// the name matched ignoring case), or null.
function projectBefore(model, text, at) {
  var token = /(^|\s)#((?:\\ |\S)+)/g
  var name = ""
  var found
  var before = text.slice(0, at)
  while ((found = token.exec(before)) !== null)
    name = found[2].replace(/\\ /g, " ").toLowerCase()
  if (!name)
    return null
  for (var id in model.projects)
    if (model.projects[id].name.toLowerCase() === name)
      return model.projects[id]
  return null
}

// Prefix matches first, then the rest that contain the query, each by name
// (case-insensitive), at most MAX_SUGGESTIONS. Each item gets where the
// match is (matchStart, matchLength) for the bold part.
function matchNames(pool, query) {
  var needle = query.toLowerCase()
  var prefix = []
  var inside = []
  pool.forEach(function (item) {
    var at = item.name.toLowerCase().indexOf(needle)
    if (at < 0)
      return
    item.matchStart = at
    item.matchLength = needle.length
    if (at === 0)
      prefix.push(item)
    else
      inside.push(item)
  })
  var byName = function (a, b) {
    return compare(a.name.toLowerCase(), b.name.toLowerCase()) || compare(a.name, b.name)
  }
  return prefix.sort(byName).concat(inside.sort(byName)).slice(0, MAX_SUGGESTIONS)
}

// The word replaced by `#Name` or `@name` (spaces escaped as `\ `, as Quick
// Add reads them), then one space (unless one follows already); the caret
// after that space.
function applySuggestion(text, start, end, item) {
  var token = ({ project: "#", label: "@", section: "/", assignee: "+" })[item.kind] + item.name.replace(/ /g, "\\ ")
  var rest = text.slice(end)
  var spaced = /^\s/.test(rest) ? rest : " " + rest
  return { text: text.slice(0, start) + token + spaced, caret: start + token.length + 1 }
}

// ---- Quick Add tokens (the add field's colours) ---------------------------------
// The rules are Foamy Menu's (core/TodoistInput.js, tokens and runs), with
// this file's word rule. Dates are Todoist's to read, in the account's
// language, so they are never coloured here.

// Todoist's limit; over it nothing is coloured, so a long paste can't
// build thousands of runs on the UI thread.
var MAX_TEXT = 500

// Where " // description" starts: `//` at the start or after whitespace,
// followed by whitespace or the end; -1 without one.
function descriptionStart(text) {
  var found = /(^|\s)\/\/(?=\s|$)/.exec(text)
  return found ? found.index + found[1].length : -1
}

// The Quick Add tokens in `text`, in order: {kind, start, end}. Kinds:
// project (#name), section (/name), label (@name), assignee (+name, only
// after a #project), priority (p1–p3; p4 is the default and stays plain),
// reminder (!text), deadline ({text}, braces closed) and description
// (" // text" to the end). A token starts at the start or after whitespace.
function quickAddTokens(text) {
  var s = String(text || "")
  var out = []
  if (s.length > MAX_TEXT)
    return out
  var description = descriptionStart(s)
  var limit = description >= 0 ? description : s.length
  var projectSeen = false
  var i = 0
  while (i < limit) {
    if (/\s/.test(s.charAt(i))) {
      i++
      continue
    }
    var end = i
    while (end < limit && !breaksWord(s, end))
      end++
    var word = s.slice(i, end)
    var first = word.charAt(0)
    if (first === "{") {
      var close = s.indexOf("}", i + 1)
      if (close > i + 1 && close < limit) {
        out.push({ kind: "deadline", start: i, end: close + 1 })
        i = close + 1
        continue
      }
    } else if (word.length > 1 && (first === "#" || first === "/" || first === "@" || (first === "+" && projectSeen))) {
      var kind = { "#": "project", "/": "section", "@": "label", "+": "assignee" }[first]
      out.push({ kind: kind, start: i, end: end })
      if (kind === "project")
        projectSeen = true
    } else if (/^p[1-3]$/.test(word)) {
      out.push({ kind: "priority", start: i, end: end })
    } else if (word.length > 1 && first === "!") {
      out.push({ kind: "reminder", start: i, end: end })
    }
    i = end
  }
  if (description >= 0)
    out.push({ kind: "description", start: description, end: s.length })
  return out
}

// The text as SafeTextField runs, [{text, color}]: each token in
// `colors[kind]`, the text between them plain (no colour: the field's
// own). [] without tokens, so the field draws plain text.
function quickAddRuns(text, colors) {
  var s = String(text || "")
  var list = quickAddTokens(s)
  if (!list.length)
    return []
  var out = []
  var at = 0
  list.forEach(function (token) {
    if (token.start > at)
      out.push({ text: s.slice(at, token.start) })
    out.push({ text: s.slice(token.start, token.end), color: colors ? colors[token.kind] : undefined })
    at = token.end
  })
  if (at < s.length)
    out.push({ text: s.slice(at) })
  return out
}

// The add field's placeholder: where the task goes (the view's project or
// date applies when the text names none). `format` is the locale's date
// formatting, `t` the catalog.
var PLACEHOLDER_KEYS = ["Add a task to the Inbox…", "Add a task for today…", "Add a task for %1…", "Add a task to %1…"]
function addPlaceholder(view, day, today, projectName, format, t) {
  if (view === "project" && projectName)
    return t("Add a task to %1…", [projectName])
  if (day && day === today)
    return t("Add a task for today…")
  if (day) {
    var date = dayDate(day)
    return t("Add a task for %1…", [format(date, "dddd") + " " + format(date, t("d MMMM"))])
  }
  return t("Add a task to the Inbox…")
}

// ---- ordering -----------------------------------------------------------------

// Todoist order within one list: roots by child_order, each followed by its
// subtasks (depth 1; deeper levels indent the same).
// A task whose parent isn't in `tasks` (filtered out) counts as a root.
function treeOrder(tasks) {
  var children = dict()
  var roots = []
  var listed = dict()
  tasks.forEach(function (task) {
    listed[task.id] = true
  })
  tasks.forEach(function (task) {
    if (task.parentId && listed[task.parentId]) {
      if (!children[task.parentId])
        children[task.parentId] = []
      children[task.parentId].push(task)
    } else
      roots.push(task)
  })
  var byOrder = function (a, b) {
    return a.order - b.order || compare(a.id, b.id)
  }
  var out = []
  var visit = function (task, depth) {
    out.push({ task: task, depth: Math.min(depth, 1) })
    ;(children[task.id] || []).sort(byOrder).forEach(function (child) {
      visit(child, depth + 1)
    })
  }
  roots.sort(byOrder).forEach(function (task) {
    visit(task, 0)
  })
  return out
}

// Within a day: timed tasks by time, then the others by day_order, then
// priority (p1 first).
function byDay(a, b) {
  var am = a.due ? a.due.minutes : -1
  var bm = b.due ? b.due.minutes : -1
  if ((am >= 0) !== (bm >= 0))
    return am >= 0 ? -1 : 1
  if (am >= 0 && am !== bm)
    return am - bm
  return a.dayOrder - b.dayOrder || b.priority - a.priority || compare(a.id, b.id)
}

// Overdue: oldest first, then as within a day.
function byOverdue(a, b) {
  return compare(a.due.day, b.due.day) || byDay(a, b)
}

// Projects for the rail: every one but the Inbox, as a tree (children under
// their parent, one indent step for any depth).
function projectTree(model) {
  var all = Object.keys(model.projects).map(function (id) {
    return model.projects[id]
  }).filter(function (project) {
    return project.id !== model.inboxId && !project.inbox
  })
  var children = dict()
  var roots = []
  all.forEach(function (project) {
    if (project.parentId && model.projects[project.parentId] && project.parentId !== model.inboxId) {
      if (!children[project.parentId])
        children[project.parentId] = []
      children[project.parentId].push(project)
    } else
      roots.push(project)
  })
  var byOrder = function (a, b) {
    return a.order - b.order || compare(a.name, b.name) || compare(a.id, b.id)
  }
  var out = []
  var seen = dict()
  var visit = function (project, depth) {
    if (seen[project.id])
      return
    seen[project.id] = true
    out.push({ project: project, depth: Math.min(depth, 1) })
    ;(children[project.id] || []).sort(byOrder).forEach(function (child) {
      visit(child, depth + 1)
    })
  }
  roots.sort(byOrder).forEach(function (project) {
    visit(project, 0)
  })
  return out
}

// ---- counts -----------------------------------------------------------------

// Someone else's task: assigned (responsible_uid) to a person other than
// the signed-in user. Unassigned tasks are always yours.
function othersTask(model, task) {
  var me = model.user && model.user.id
  return !!task.responsible && task.responsible !== me
}

// The one filter for "Tasks assigned to others: Hide" (options.hideOthers):
// false for a task the personal views and their counts leave out.
function personal(model, options, task) {
  return !(options && options.hideOthers && othersTask(model, task))
}

function isHidden(options, id) {
  return !!(options && has(options.hidden, id) && options.hidden[id])
}

// {inbox, today (left today: overdue + due today), overdue, week (due
// tomorrow up to seven days from today), projects: {id: open tasks}}.
function counts(model, today, options) {
  var out = { inbox: 0, today: 0, overdue: 0, week: 0, projects: dict() }
  var weekEnd = addDays(today, 7)
  model.tasks.forEach(function (task) {
    if (isHidden(options, task.id))
      return
    // Project counts are about the whole project: everyone's tasks.
    out.projects[task.projectId] = (out.projects[task.projectId] || 0) + 1
    if (!personal(model, options, task))
      return
    if (task.projectId === model.inboxId)
      out.inbox++
    if (!task.due)
      return
    if (task.due.day < today)
      out.overdue++
    if (task.due.day <= today)
      out.today++
    else if (task.due.day <= weekEnd)
      out.week++
  })
  return out
}

// ---- rows -------------------------------------------------------------------

// One list row. `kind`: "header" (a section or day title, not a cursor
// stop), "fold" (Upcoming's folded Overdue row, a stop) or "task".
function taskRow(model, entry, today, view, struck, unconfirmed) {
  var task = entry.task
  var project = model.projects[task.projectId]
  var due = task.due
  var showDate = !!due && (view === "inbox" || view === "project" || view === "search" || due.day < today)
  // The project everywhere but its own view; in the Inbox only for a task
  // from elsewhere (which the Inbox view doesn't list).
  var showProject = !!project && view !== "project" && (view !== "inbox" || task.projectId !== model.inboxId)
  // Assigned to someone else: their first name (an unknown id: nothing).
  var userId = model.user && model.user.id
  var person = task.responsible && task.responsible !== userId && has(model.people, task.responsible) ? model.people[task.responsible] : null
  return {
    kind: "task",
    key: "task:" + task.id,
    id: task.id,
    text: task.text,
    priority: task.priority,
    priorityRole: priorityRole(task.priority),
    depth: entry.depth,
    dueDay: due ? due.day : "",
    dueTime: due ? due.time : "",
    dateKind: showDate ? dayKind(due.day, today) : "",
    overdue: !!due && due.day < today,
    recurring: !!due && due.recurring,
    showProject: showProject,
    assignee: person ? person.name.split(/\s+/)[0] : "",
    // A second line (date, project, labels, recurring) under the text.
    detail: showDate || showProject || task.labels.length > 0 || !!person || (!!due && due.recurring),
    projectName: project ? project.name : "",
    projectRole: project ? colorRole(project.color) : "muted",
    labels: task.labels,
    struck: has(struck, task.id) && !!struck[task.id],
    // Its completion's outcome is unknown until the next snapshot.
    unconfirmed: has(unconfirmed, task.id) && !!unconfirmed[task.id]
  }
}

function header(key, title, count, extra) {
  var row = { kind: "header", key: "header:" + key, title: title, count: count, dayKey: "", tomorrow: false, urgent: false }
  for (var name in extra || {})
    row[name] = extra[name]
  return row
}

function visibleTasks(model, options, filter) {
  var mineOnly = !!(options && options.personalView)
  return model.tasks.filter(function (task) {
    return !isHidden(options, task.id) && (!mineOnly || personal(model, options, task)) && filter(task)
  })
}

// One project's tasks in Todoist's order: those without a section first,
// then each section in order. [{section (null first), entries}], empty
// sections left out.
function projectGroups(model, projectId, tasks) {
  var bySection = dict()
  tasks.forEach(function (task) {
    var key = task.sectionId || ""
    if (!bySection[key])
      bySection[key] = []
    bySection[key].push(task)
  })
  var groups = bySection[""] ? [{ section: null, entries: treeOrder(bySection[""]) }] : []
  Object.keys(model.sections).map(function (id) {
    return model.sections[id]
  }).filter(function (section) {
    return section.projectId === projectId && bySection[section.id]
  }).sort(function (a, b) {
    return a.order - b.order || compare(a.id, b.id)
  }).forEach(function (section) {
    groups.push({ section: section, entries: treeOrder(bySection[section.id]) })
  })
  return groups
}

// A project view: its groups, each section with a header (its name).
function projectRows(model, projectId, today, view, options) {
  var tasks = visibleTasks(model, options, function (task) {
    return task.projectId === projectId
  })
  var struck = options && options.struck
  var rows = []
  projectGroups(model, projectId, tasks).forEach(function (group) {
    if (group.section)
      rows.push(header("section:" + group.section.id, group.section.name, group.entries.length))
    group.entries.forEach(function (entry) {
      rows.push(taskRow(model, entry, today, view, struck, options && options.unconfirmed))
    })
  })
  return rows
}

// The rows of a view. `options`: {hidden: {id: true}} (sent completions,
// left the list), struck ({id: true}, completed but undoable), overdueOpen
// (Upcoming), projectId (project view), query (search). Header titles are
// left to QML ("" for Overdue/Today; the day key for Upcoming days).
function rows(model, view, today, options) {
  // The personal views (Today, Upcoming, the Inbox) leave out tasks assigned
  // to others when asked; a project view and search show every task.
  if (view === "today" || view === "upcoming" || view === "inbox")
    options = Object.assign({}, options, { personalView: true })
  var struck = options && options.struck
  var flat = function (list) {
    return list.map(function (task) {
      return taskRow(model, { task: task, depth: 0 }, today, view, struck, options && options.unconfirmed)
    })
  }
  if (view === "inbox")
    return model.inboxId ? projectRows(model, model.inboxId, today, view, options) : []
  if (view === "project")
    return model.projects[options && options.projectId] ? projectRows(model, options.projectId, today, view, options) : []
  if (view === "today") {
    var overdue = visibleTasks(model, options, function (task) {
      return task.due && task.due.day < today
    }).sort(byOverdue)
    var due = visibleTasks(model, options, function (task) {
      return task.due && task.due.day === today
    }).sort(byDay)
    var out = []
    if (overdue.length)
      out = out.concat([header("overdue", "overdue", overdue.length, { urgent: true })], flat(overdue))
    if (due.length && overdue.length)
      out.push(header("today", "today", due.length))
    return out.concat(flat(due))
  }
  if (view === "upcoming")
    return upcomingRows(model, today, options, flat)
  if (view === "search")
    return searchRows(model, options && options.query, today, options)
  return []
}

// ---- Upcoming ----------------------------------------------------------------

// The group a future day falls in, for `today` and the locale's first day
// of the week (`weekStart`, 0 = Sunday … 6, as QML's Locale gives it):
// "day" up to the end of this week (key: the day), "week" for the next
// calendar week, "later" for the rest of this month after that (key:
// "YYYY-MM"), then one "month" per month (key: "YYYY-MM").
function upcomingGroup(day, today, weekStart) {
  var start = ((Number(weekStart) % 7) + 7) % 7
  var sinceStart = (dayDate(today).getDay() - start + 7) % 7
  var weekEnd = addDays(today, 6 - sinceStart)
  // Tomorrow is always a day of its own, also on the week's last day.
  if (day <= weekEnd || day === addDays(today, 1))
    return { group: "day", key: day }
  if (day <= addDays(weekEnd, 7))
    return { group: "week", key: "week" }
  if (day.slice(0, 7) === today.slice(0, 7))
    return { group: "later", key: day.slice(0, 7) }
  return { group: "month", key: day.slice(0, 7) }
}

// Upcoming: the folded Overdue row, then the groups in order, each with a
// header (empty groups have none). Day groups have no count and no
// divider; the later ones have both, except a first one on top. Tasks by
// date, then time, then day order.
function upcomingRows(model, today, options, flat) {
  var weekStart = options && options.weekStart !== undefined ? options.weekStart : 1
  var late = visibleTasks(model, options, function (task) {
    return task.due && task.due.day < today
  }).sort(byOverdue)
  var result = []
  if (late.length) {
    var open = !!(options && options.overdueOpen)
    result.push({ kind: "fold", key: "fold:overdue", title: "overdue", count: late.length, open: open, urgent: true })
    if (open)
      result = result.concat(flat(late))
  }
  var groups = dict()
  var order = []
  visibleTasks(model, options, function (task) {
    return task.due && task.due.day > today
  }).forEach(function (task) {
    var where = upcomingGroup(task.due.day, today, weekStart)
    var key = where.group + ":" + where.key
    if (!groups[key]) {
      groups[key] = { group: where.group, key: where.key, tasks: [] }
      order.push(key)
    }
    groups[key].tasks.push(task)
  })
  var rank = { day: 0, week: 1, later: 2, month: 3 }
  order.sort(function (a, b) {
    return rank[groups[a].group] - rank[groups[b].group] || compare(groups[a].key, groups[b].key)
  })
  var weekEnd = addDays(today, 6 - (dayDate(today).getDay() - (((Number(weekStart) % 7) + 7) % 7) + 7) % 7)
  var trail = { day: "", week: "weekday", later: "weekdayDate", month: "weekdayDate" }
  order.forEach(function (key) {
    var entry = groups[key]
    var list = entry.tasks.sort(function (a, b) {
      return compare(a.due.day, b.due.day) || byDay(a, b)
    })
    var isDay = entry.group === "day"
    result.push(header("group:" + key, entry.group, isDay ? -1 : list.length, {
      group: entry.group,
      divider: !isDay && result.length > 0,
      dayKey: isDay ? entry.key : "",
      tomorrow: isDay && entry.key === addDays(today, 1),
      // Next week starts after tomorrow when tomorrow is its first day.
      rangeStart: entry.group === "week" ? (weekEnd === today ? addDays(today, 2) : addDays(weekEnd, 1)) : "",
      rangeEnd: entry.group === "week" ? addDays(weekEnd, 7) : "",
      monthKey: isDay || entry.group === "week" ? "" : entry.key,
      showYear: entry.group === "month" && entry.key.slice(0, 4) !== today.slice(0, 4)
    }))
    flat(list).forEach(function (row) {
      row.group = entry.group
      row.trail = trail[entry.group]
      result.push(row)
    })
  })
  return result
}

// ---- the Week view (Wide) --------------------------------------------------------

// Four columns, [{key, entries, cards}]: "overdue" (oldest first), "today",
// "tomorrow" and "later", the seven days after tomorrow, each day under a
// heading ({kind: "day", key, dayKey}). The tasks are rows as in the list
// (taskRow, view "week": the project, an overdue task's date, the time),
// with the personal filter of Today and Upcoming.
function weekColumns(model, today, options) {
  options = Object.assign({}, options, { personalView: true })
  var card = function (task) {
    return taskRow(model, { task: task, depth: 0 }, today, "week", options.struck, options.unconfirmed)
  }
  var dueOn = function (test) {
    return visibleTasks(model, options, function (task) {
      return !!task.due && test(task.due.day)
    })
  }
  var tomorrow = addDays(today, 1)
  var last = addDays(today, 8)
  var later = []
  var heading = ""
  dueOn(function (day) {
    return day > tomorrow && day <= last
  }).sort(function (a, b) {
    return compare(a.due.day, b.due.day) || byDay(a, b)
  }).forEach(function (task) {
    if (task.due.day !== heading) {
      heading = task.due.day
      later.push({ kind: "day", key: "day:" + heading, dayKey: heading })
    }
    later.push(card(task))
  })
  return [
    weekColumn("overdue", dueOn(function (day) {
      return day < today
    }).sort(byOverdue).map(card)),
    weekColumn("today", dueOn(function (day) {
      return day === today
    }).sort(byDay).map(card)),
    weekColumn("tomorrow", dueOn(function (day) {
      return day === tomorrow
    }).sort(byDay).map(card)),
    weekColumn("later", later)
  ]
}
// A column's indices, computed once: each card's `card` (its place among
// the column's tasks, headings left out; -1 on a heading), and `cards`,
// each card's entry, so the view finds an entry without searching.
function weekColumn(key, entries) {
  var cards = []
  entries.forEach(function (entry, index) {
    if (entry.kind === "task") {
      entry.card = cards.length
      cards.push(index)
    } else
      entry.card = -1
  })
  return { key: key, entries: entries, cards: cards }
}

// Ctrl+←/→ in the Week view: the task's day moved by `delta` days, never
// before today (an overdue task lands on today); "" when it can't move: no
// date, recurring (as `t`), or nothing would change.
function shiftedDay(task, delta, today) {
  if (!task || !task.due || task.due.recurring)
    return ""
  var day = addDays(task.due.day, delta)
  if (day < today)
    day = today
  return day === task.due.day ? "" : day
}

// Catalog keys the Upcoming texts use (translated by `t`, the formats
// passed to the locale's date formatting).
var UPCOMING_KEYS = ["Tomorrow", "Next week", "Later in %1", "d MMMM", "d MMM", "d", "ddd d"]

function capitalized(text) {
  return text ? text.charAt(0).toLocaleUpperCase() + text.slice(1) : text
}

// An Upcoming group header's {title, sub}. `format(date, pattern)` is the
// locale's date formatting (Qt.locale in QML), `t` the catalog.
function upcomingHeading(row, format, t) {
  if (row.group === "day") {
    var day = dayDate(row.dayKey)
    var date = format(day, t("d MMMM"))
    return row.tomorrow ? { title: t("Tomorrow"), sub: format(day, "dddd") + " " + date } : { title: capitalized(format(day, "dddd")), sub: date }
  }
  if (row.group === "week") {
    var from = dayDate(row.rangeStart)
    var to = dayDate(row.rangeEnd)
    var sameMonth = row.rangeStart.slice(0, 7) === row.rangeEnd.slice(0, 7)
    return { title: t("Next week"), sub: format(from, t(sameMonth ? "d" : "d MMM")) + "–" + format(to, t("d MMM")) }
  }
  var first = dayDate(row.monthKey + "-01")
  if (row.group === "later")
    return { title: t("Later in %1", [format(first, "MMMM")]), sub: "" }
  return { title: capitalized(format(first, row.showYear ? "MMMM yyyy" : "MMMM")), sub: "" }
}

// A task row's date on its detail line: the words for yesterday, today
// and tomorrow, the weekday within a week, else the short weekday, day and
// month ("man. 23. nov."), with the year when it isn't this one.
var DETAIL_KEYS = ["Today", "Yesterday", "Tomorrow", "ddd d MMM", "ddd d MMM yyyy"]
function detailDate(row, format, t, today) {
  if (!row || !row.dateKind || !row.dueDay)
    return ""
  var day = dayDate(row.dueDay)
  switch (row.dateKind) {
  case "today":
    return t("Today")
  case "yesterday":
    return t("Yesterday")
  case "tomorrow":
    return t("Tomorrow")
  case "weekday":
    return format(day, "dddd")
  default:
    return format(day, t(row.dueDay.slice(0, 4) === today.slice(0, 4) ? "ddd d MMM" : "ddd d MMM yyyy"))
  }
}

// The editor's date in the panel's words: the day as on a row's detail
// line ("Tomorrow", a weekday, "Mon 23 Nov") and the time after it
// ("Tomorrow 09:00"); "" without a date.
function dueWords(task, format, t, today) {
  if (!task || !task.due)
    return ""
  var day = dayWords(task.due.day, format, t, today)
  return task.due.time ? day + " " + task.due.time : day
}

// A day ("YYYY-MM-DD", a deadline) in the same words; "" without one.
function dayWords(day, format, t, today) {
  return validDate(day) ? detailDate({ dueDay: day, dateKind: dayKind(day, today) }, format, t, today) : ""
}

// A day's colour role, as Todoist colours dates: past days "error", today
// "success", tomorrow "warning", the rest of the coming week "accent",
// later (or no day) "muted".
function dayRole(day, today) {
  if (!validDate(day))
    return "muted"
  var days = daysBetween(today, day)
  return days < 0 ? "error" : days === 0 ? "success" : days === 1 ? "warning" : days < 7 ? "accent" : "muted"
}

// A task row's day before its time in Upcoming's later groups: the short
// weekday next week, the short weekday and the date after that; "" elsewhere.
function trailingDay(row, format, t) {
  if (!row || !row.trail || !row.dueDay)
    return ""
  var day = dayDate(row.dueDay)
  return format(day, row.trail === "weekday" ? "ddd" : t("ddd d"))
}

// ---- the open command ------------------------------------------------------------

// The argv that opens `url`: xdg-open without a command; else the command
// split on spaces (no shell, no quotes), each token that is exactly {url}
// replaced by the link, or the link appended when none is. Preferences.js
// validates the command before it can be saved.
function openArgv(command, url) {
  var tokens = String(command || "").trim().split(/ +/).filter(function (token) {
    return token !== ""
  })
  if (!tokens.length)
    return ["xdg-open", url]
  var replaced = false
  var argv = tokens.map(function (token) {
    if (token !== "{url}")
      return token
    replaced = true
    return url
  })
  return replaced ? argv : argv.concat([url])
}

// Search: open tasks whose text, project name or a label contains every
// word of the query (case-insensitive), flat, grouped by project (Inbox
// first, then the rail's order).
function searchRows(model, query, today, options) {
  var words = String(query || "").toLowerCase().split(/\s+/).filter(function (word) {
    return word !== ""
  }).map(function (word) {
    return word.charAt(0) === "@" && word.length > 1 ? word.slice(1) : word
  })
  if (!words.length)
    return []
  var matches = visibleTasks(model, options, function (task) {
    var project = model.projects[task.projectId]
    var haystack = [task.text, project ? project.name : ""].concat(task.labels).join("\n").toLowerCase()
    return words.every(function (word) {
      return haystack.indexOf(word) >= 0
    })
  })
  var byProject = dict()
  matches.forEach(function (task) {
    if (!byProject[task.projectId])
      byProject[task.projectId] = []
    byProject[task.projectId].push(task)
  })
  var order = (model.inboxId ? [model.inboxId] : []).concat(projectTree(model).map(function (entry) {
    return entry.project.id
  }))
  var struck = options && options.struck
  var out = []
  order.forEach(function (id) {
    var list = byProject[id]
    if (!list)
      return
    out.push(header("project:" + id, model.projects[id].name, list.length, { projectRole: colorRole(model.projects[id].color) }))
    projectGroups(model, id, list).forEach(function (group) {
      group.entries.forEach(function (entry) {
        out.push(taskRow(model, { task: entry.task, depth: 0 }, today, "search", struck, options && options.unconfirmed))
      })
    })
  })
  return out
}

// What an empty list says (a catalog key). A truncated snapshot may have
// left tasks out, so then it says that instead of "nothing".
var TRUNCATED_TEXT = "Showing part of your tasks: the account has more than this panel keeps"
var EMPTY_TEXTS = {
  search: "No matching tasks",
  inbox: "Inbox is empty",
  today: "Nothing left for today",
  upcoming: "Nothing planned",
  project: "No tasks"
}
function emptyText(view, truncated) {
  return truncated ? TRUNCATED_TEXT : EMPTY_TEXTS[view] || EMPTY_TEXTS.project
}

// The rail's project rows: {id, name, role, depth, count}.
function railProjects(model, projectCounts) {
  return projectTree(model).map(function (entry) {
    return {
      id: entry.project.id,
      name: entry.project.name,
      role: colorRole(entry.project.color),
      depth: entry.depth,
      count: (projectCounts && projectCounts[entry.project.id]) || 0
    }
  })
}

// ---- the helper's replies -----------------------------------------------------

// One reply line: the last line of the output, parsed, or null.
function parseReply(text) {
  var lines = String(text || "").trim().split("\n")
  try {
    var reply = JSON.parse(lines[lines.length - 1])
    return reply && typeof reply === "object" && !Array.isArray(reply) ? reply : null
  } catch (e) {
    return null
  }
}

// A helper message: the catalog key and the values for its %1, %2…
function messageParts(message) {
  var parts = String(message || "").split("\u001f")
  return { key: parts[0], values: parts.slice(1) }
}

// The next poll after `failures` failures in a row: the interval doubled
// each time, at most 30 minutes, and never before Todoist's retry_after.
function backoffSeconds(intervalSeconds, failures, retryAfter) {
  var wait = intervalSeconds * Math.pow(2, Math.min(Math.max(failures, 0), 10))
  wait = Math.min(wait, 1800)
  if (retryAfter > 0)
    wait = Math.max(wait, Math.min(retryAfter, 86400))
  return wait
}

// How long Todoist asked to wait, in ms, for a reply that says RATE_LIMITED
// (an error, or an add's warning after the task was made): its retry_after,
// at most a day, else DEFAULT_RETRY_SECONDS. 0 for any other reply.
var DEFAULT_RETRY_SECONDS = 60
function retryDelayMs(reply) {
  if (!reply || (reply.code !== "RATE_LIMITED" && reply.warning_code !== "RATE_LIMITED"))
    return 0
  var seconds = typeof reply.retry_after === "number" && reply.retry_after > 0 ? reply.retry_after : DEFAULT_RETRY_SECONDS
  return Math.min(seconds, 86400) * 1000
}

// Whether a successful reply is a fresh read of Todoist. An add whose
// follow-up sync failed is the cache plus the new task (`stale`): it can't
// confirm what earlier, unanswered changes did.
function freshSnapshot(reply) {
  return !!reply && reply.ok === true && reply.stale !== true
}

// Milliseconds from `now` to the next local midnight (the Today count
// changes then), at least one second.
function msToMidnight(now) {
  var next = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1)
  return Math.max(1000, next.getTime() - now.getTime())
}

if (typeof module !== "undefined")
  module.exports = {
    WEB, webUrl, validId, validDate, colorRole, priorityRole, dayKey, addDays, daysBetween, dueOf, dayKind, plainText,
    has, othersTask, index, treeOrder, counts, rows, railProjects, parseReply, messageParts, backoffSeconds, msToMidnight,
    TRUNCATED_TEXT, EMPTY_TEXTS, emptyText, suggestions, applySuggestion,
    upcomingGroup, upcomingHeading, trailingDay, UPCOMING_KEYS, detailDate, DETAIL_KEYS, openArgv, DEFAULT_RETRY_SECONDS, retryDelayMs, freshSnapshot,
    MAX_TEXT, quickAddTokens, quickAddRuns, PLACEHOLDER_KEYS, addPlaceholder, dueWords, dayWords, dayRole, weekColumns, shiftedDay, capitalized, dayDate
  }
