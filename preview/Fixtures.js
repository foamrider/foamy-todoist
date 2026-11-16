// Sample Todoist data for the previews and the tests: a snapshot as the
// helper sends it, with dates relative to `today` ("YYYY-MM-DD").

function shift(today, days) {
  var date = new Date(Number(today.slice(0, 4)), Number(today.slice(5, 7)) - 1, Number(today.slice(8, 10)) + days, 12)
  var pad = function (n) {
    return (n < 10 ? "0" : "") + n
  }
  return date.getFullYear() + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate())
}

function task(id, content, project, extra) {
  var out = { id: id, content: content, project_id: project, section_id: null, parent_id: null, priority: 1, due: null, labels: [], child_order: 1, day_order: 0 }
  for (var key in extra || {})
    out[key] = extra[key]
  return out
}

function due(date, recurring, string) {
  return { date: date, is_recurring: recurring === true, string: string || "" }
}

function snapshot(today) {
  var d = function (days, time) {
    return shift(today, days) + (time ? "T" + time + ":00" : "")
  }
  return {
    user: { id: "1", full_name: "Ada Lovelace", email: "ada@example.com", inbox_project_id: "inbox", timezone: "Europe/Oslo" },
    projects: [
      { id: "inbox", name: "Inbox", color: "charcoal", parent_id: null, child_order: 0, inbox: true },
      { id: "work", name: "Work", color: "blue", parent_id: null, child_order: 1, inbox: false },
      { id: "launch", name: "Launch", color: "orange", parent_id: "work", child_order: 1, inbox: false, shared: true },
      { id: "home", name: "Home", color: "green", parent_id: null, child_order: 2, inbox: false },
      { id: "reading", name: "Reading list", color: "grape", parent_id: null, child_order: 3, inbox: false }
    ],
    sections: [
      { id: "s-review", project_id: "work", name: "Review", section_order: 1 },
      { id: "s-ops", project_id: "work", name: "Ops", section_order: 2 }
    ],
    tasks: [
      task("t1", "Send the quarterly report to [Finance](https://example.com/finance)", "work", { priority: 4, due: due(d(-2)), labels: ["office"], child_order: 1 }),
      task("t2", "Renew the passport", "home", { priority: 3, due: due(d(-1)), child_order: 1 }),
      task("t3", "Stand-up with the platform team", "work", { due: due(d(0, "09:30"), true, "every weekday at 9:30"), section_id: "s-ops", child_order: 1 }),
      task("t4", "Review **pull request** #482", "work", { priority: 2, due: due(d(0, "14:00")), section_id: "s-review", labels: ["code"], child_order: 1 }),
      task("t5", "Water the plants", "home", { due: due(d(0), true, "every 3 days"), day_order: 1, child_order: 2 }),
      task("t6", "Book a table for Friday", "inbox", { priority: 2, due: due(d(0)), day_order: 2, child_order: 1 }),
      task("t7", "Call the dentist", "inbox", { child_order: 2 }),
      task("t8", "Ask about the opening hours", "inbox", { parent_id: "t7", child_order: 1 }),
      task("t9", "Pick up the parcel", "inbox", { child_order: 3, labels: ["errand"] }),
      task("t10", "Draft the launch post", "launch", { priority: 3, due: due(d(1, "10:00")), child_order: 1, responsible_uid: "7" }),
      task("t11", "Pay the electricity bill", "home", { priority: 4, due: due(d(1)), child_order: 3 }),
      task("t12", "Team retro", "work", { due: due(d(3, "15:00"), true, "every other thursday"), section_id: "s-ops", child_order: 2 }),
      task("t13", "Finish *Middlemarch*", "reading", { due: due(d(9)), child_order: 1 }),
      task("t14", "Update the on-call runbook", "work", { section_id: "s-ops", child_order: 3 }),
      task("t15", "Fix the flaky upload test", "work", { priority: 3, child_order: 2 })
    ],
    labels: [
      { id: "l-office", name: "office", color: "blue", item_order: 1 },
      { id: "l-waiting", name: "Waiting on", color: "red", item_order: 2 },
      { id: "l-errand", name: "errand", color: "green", item_order: 3 },
      { id: "l-calls", name: "calls", color: "orange", item_order: 4 }
    ],
    // The people in the shared Launch project (the user among them).
    collaborators: [
      { id: "1", full_name: "Ada Lovelace", email: "ada@example.com" },
      { id: "7", full_name: "Bo Ek", email: "bo@example.com" },
      { id: "8", full_name: "Cy Moreno", email: "cy@example.com" }
    ],
    project_collaborators: { launch: ["1", "7", "8"] },
    truncated: false,
    synced_at: "2026-11-16T08:00:00Z"
  }
}

// Tasks further out, for Upcoming's later groups (the rest of the month,
// next month, the next year).
function upcomingExtras(today) {
  var d = function (days, time) {
    return shift(today, days) + (time ? "T" + time + ":00" : "")
  }
  return [
    task("u1", "Book flights for Christmas", "home", { due: due(d(12)), child_order: 10 }),
    task("u2", "Dentist check-up", "home", { priority: 2, due: due(d(19, "10:30")), child_order: 11 }),
    task("u3", "Car insurance renewal", "home", { due: due(d(48)), child_order: 12 })
  ]
}

if (typeof module !== "undefined")
  module.exports = { snapshot, upcomingExtras, shift, task, due }
