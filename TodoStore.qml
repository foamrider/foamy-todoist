pragma Singleton
import QtQuick
import Quickshell.Io
import "kit"
import "kit/FoamyNative.js" as FoamyNative
import "Model.js" as Model

// Todoist for every bar instance: one helper process at a time, the last
// snapshot, the sign-in, completions waiting for their undo window, and the
// poll. A qmldir singleton is created once per shell (QML engine), so this
// runs once however many monitors draw the bar; it polls only while some
// bar instance is alive (FoamyShared scope "todoist").
//
// Helper jobs run in order. A sync asked for while another job is running
// or waiting is dropped: every reply but status and sign-out carries the
// snapshot. Sign-out and a new token bump `generation`, so a reply from a
// job that started before them is ignored.
QtObject {
  id: store

  readonly property string pluginDir: FoamyNative.localPath(Qt.resolvedUrl("."))
  // The helper's argv (after the timeout); tests replace it.
  property var helperCommand: function (args) {
    return FoamyNative.command(store.pluginDir, "foamy-todoist-helper", args)
  }

  // ---- the sign-in --------------------------------------------------------------
  // checking (the first status), signed_out, signed_in, error (the keyring
  // can't be read: accountError says why), unavailable (no helper for this CPU).
  property string account: "checking"
  readonly property bool signedIn: account === "signed_in"
  property var user: null
  property string accountError: ""
  // Why the last token-set or token-clear failed (shown in Settings).
  property string tokenError: ""
  property int generation: 0

  // ---- the data ------------------------------------------------------------------
  property var snapshot: null
  readonly property bool loaded: snapshot !== null
  // Indexed once per snapshot (Model.index); views and counts read this.
  property var model: Model.index(null)
  onSnapshotChanged: model = Model.index(snapshot)
  property double syncedAt: 0
  // Why the last sync, change or add failed ("" when it worked); the data
  // shown stays the last good one.
  property string error: ""
  property string errorCode: ""
  property int failures: 0
  // Not before this (ms), when Todoist said how long to wait (RATE_LIMITED).
  property double retryUntil: 0

  // The clock "today" comes from; tests replace it (Upcoming's groups
  // depend on the weekday).
  property var now: function () {
    return new Date()
  }
  // The user's local date. A timer that ran through a suspend fires late,
  // so the clock is also read on every snapshot reply, every poll tick and
  // every open (Quickshell has no resume signal).
  property string today: Model.dayKey(now())
  property Timer midnight: Timer {
    running: true
    interval: Model.msToMidnight(store.now())
    onTriggered: store.updateToday()
  }
  function updateToday() {
    var day = Model.dayKey(now())
    if (day !== today)
      today = day
    midnight.interval = Model.msToMidnight(now())
    midnight.restart()
  }

  // The bar's numbers and the switch's counts, without completions that left the list.
  readonly property var counts: Model.counts(model, today, {
    hidden: sending,
    hideOthers: hideOthers
  })
  // "Tasks assigned to others" (pushed by the panels): "hide" leaves them out
  // of Today, Upcoming, the Inbox and these counts.
  property string othersTasks: "hide"
  readonly property bool hideOthers: othersTasks !== "show"

  // ---- settings (pushed by the panels) -------------------------------------------
  property int refreshSeconds: 300
  // The view of the last open, for "Open on: Last view" (this shell session only).
  property string lastView: "today"
  property string lastProject: ""
  // What was being typed in the add field when the popup closed, for the
  // next open (this shell session only, never on disk).
  property string addDraft: ""

  // ---- completions -----------------------------------------------------------------
  // Completed in the panel and still undoable: {id: true}. They are sent
  // together once no completion was added for `undoMs`, or when the popup
  // closes. Then they are `sending` (hidden) until the reply says.
  readonly property int undoMs: 4000
  property var struck: ({})
  property var sending: ({})
  // Sent completions whose apply call failed as a whole (no reply, a
  // timeout, the network): Todoist may have done them (a recurring task
  // may have moved on). They show, but can't be completed or moved again
  // until the next snapshot says what happened.
  property var unconfirmed: ({})
  readonly property int struckCount: Object.keys(struck).length
  property Timer undoWindow: Timer {
    interval: store.undoMs
    onTriggered: store.flushCompletions()
  }
  function complete(id) {
    if (!signedIn || !Model.validId(id) || Model.has(struck, id) || Model.has(sending, id) || Model.has(unconfirmed, id))
      return
    var next = Object.assign({}, struck)
    next[id] = true
    struck = next
    undoWindow.restart()
  }
  function undo(id) {
    if (!Model.has(struck, id))
      return
    var next = Object.assign({}, struck)
    delete next[id]
    struck = next
    if (!struckCount)
      undoWindow.stop()
  }
  function toggleComplete(id) {
    if (Model.has(struck, id))
      undo(id)
    else
      complete(id)
  }
  function flushCompletions() {
    undoWindow.stop()
    var ids = Object.keys(struck)
    if (!ids.length)
      return
    var moving = Object.assign({}, sending)
    ids.forEach(function (id) {
      moving[id] = true
    })
    struck = ({})
    sending = moving
    // At most 100 changes per helper call.
    for (let i = 0; i < ids.length; i += 100)
      enqueue("apply", {
        commands: ids.slice(i, i + 100).map(function (id) {
          return {
            op: "close",
            id: id
          }
        })
      }, {
        closing: ids.slice(i, i + 100)
      })
  }
  // `t`: due tomorrow (all-day). Recurring tasks are left alone: moving one
  // occurrence isn't something the API describes.
  function moveToTomorrow(id) {
    var task = model.byId[id]
    if (!signedIn || !task || (task.due && task.due.recurring) || Model.has(struck, id) || Model.has(sending, id) || Model.has(unconfirmed, id))
      return
    // A key repeat: this task's move is already waiting or running.
    var moving = [current].concat(queue).some(function (job) {
      return !!job && job.extra.due === id
    })
    if (moving)
      return
    enqueue("apply", {
      commands: [
        {
          op: "due",
          id: id,
          date: Model.addDays(today, 1)
        }
      ]
    }, {
      due: id
    })
  }

  // ---- adding -------------------------------------------------------------------
  property int addRequests: 0
  // A request's end: ok (the task exists, maybe with a warning) or not.
  signal addFinished(int request, bool ok, string message)
  // A token-set's end (the settings page clears the field on success).
  signal tokenSetFinished(bool ok)
  function add(text, dueDate, projectId) {
    if (!signedIn)
      return -1
    var request = ++addRequests
    enqueue("add", {
      text: text,
      due_date: dueDate || null,
      project_id: projectId || null
    }, {
      request: request
    })
    return request
  }
  // The add field's add in flight, once per shell: the popup that sent it
  // may close and another monitor's open before the reply. Every view
  // shows it busy (no second add of the same text on Enter); once added,
  // every view drops the text where it is unchanged (fieldAdded).
  property int pendingAdd: -1
  property string pendingAddText: ""
  readonly property bool addPending: pendingAdd >= 0
  // Why the field's last add failed, or its warning ("" when it worked):
  // it stays with the draft, also when the reply came after closing.
  property string addError: ""
  signal fieldAdded(string text)
  function addFromField(text, dueDate, projectId) {
    if (addPending)
      return false
    addError = ""
    var request = add(text, dueDate, projectId)
    if (request < 0)
      return false
    pendingAdd = request
    pendingAddText = text
    return true
  }
  onAddFinished: function (request, ok, message) {
    if (request !== pendingAdd)
      return
    var sent = pendingAddText
    pendingAdd = -1
    pendingAddText = ""
    addError = message
    if (!ok)
      return
    // Cleared only where it still holds what was added (typing went on).
    if (addDraft === sent)
      addDraft = ""
    fieldAdded(sent)
  }

  // ---- the helper queue ---------------------------------------------------------
  // {command, input, extra}; `current` is the running one.
  property var queue: []
  property var current: null
  readonly property bool busy: current !== null || queue.length > 0
  // A job that brings a new snapshot is running: the footer's Refresh spins.
  readonly property bool syncing: current !== null && current.command !== "status" && current.command !== "token-clear" && current.command !== "token-set"
  readonly property bool tokenBusy: [current].concat(queue).some(function (job) {
    return !!job && (job.command === "token-set" || job.command === "token-clear")
  })
  readonly property bool adding: [current].concat(queue).some(function (job) {
    return !!job && job.command === "add"
  })
  // At most this many jobs wait; more are refused (sign-out always goes).
  readonly property int maxQueue: 20
  readonly property string queueFullText: FoamyI18n.t("Too many changes are waiting. Try again in a moment.")
  function enqueue(command, input, extra) {
    var job = {
      command: command,
      input: input === null ? "" : JSON.stringify(input) + "\n",
      extra: extra || {}
    }
    if (account === "unavailable") {
      drop(job, accountError)
      return false
    }
    if (fixtures) {
      drop(job, "")
      return false
    }
    if (command === "sync" && busy && !job.extra.soon)
      return false
    if (queue.length >= maxQueue && command !== "token-clear") {
      drop(job, command === "sync" ? "" : queueFullText)
      return false
    }
    queue = queue.concat([job])
    Qt.callLater(next)
    return true
  }
  function next() {
    if (current)
      return
    while (queue.length) {
      const job = queue[0]
      queue = queue.slice(1)
      // While Todoist asks to wait, nothing that calls it starts: a sync
      // is dropped, an add or a change ends at once as failed.
      if (Date.now() < retryUntil && (job.command === "sync" || job.command === "add" || job.command === "apply")) {
        drop(job, job.command === "sync" ? "" : rateLimitText())
        continue
      }
      start(job)
      return
    }
  }
  function rateLimitText() {
    return FoamyI18n.t("Todoist is limiting requests. Try again in %1 seconds.", [FoamyI18n.number(Math.max(1, Math.ceil((retryUntil - Date.now()) / 1000)))])
  }
  // A job that will never run settles here: an add ends as failed, the
  // tasks of a change come back to the list (with `message` on the error
  // line), a token check says why.
  function drop(job, message) {
    if (job.command === "add") {
      const request = job.extra.request
      // Later: add() returns its request before the view can match the end.
      Qt.callLater(function () {
        store.addFinished(request, false, message)
      })
    }
    if (job.extra.closing) {
      release(job.extra.closing)
      if (message !== "")
        error = message
    }
    // A move to tomorrow that never ran: the task stays, the line says why.
    if (job.extra.due && message !== "")
      error = message
    if (job.command === "token-set") {
      if (message !== "")
        tokenError = message
      tokenSetFinished(false)
    }
  }
  function start(job) {
    job.generation = generation
    current = job
    helperInput = job.input
    // Always a pipe, closed once the input (maybe none) is written: the
    // helper reads its request to the end of standard input.
    helper.stdinEnabled = true
    helper.command = ["timeout", "--kill-after=2s", "30s"].concat(helperCommand([job.command]))
    helper.running = true
  }
  // The one way a job ends: its exit, or a start that failed (code -1).
  function finish(code, text) {
    var job = current
    if (!job)
      return
    current = null
    Qt.callLater(next)
    handle(job, code, text)
  }
  // What the running job writes to the helper's standard input.
  property string helperInput: ""
  property Process helper: Process {
    onStarted: {
      if (store.helperInput !== "")
        store.helper.write(store.helperInput)
      store.helper.stdinEnabled = false
      // Written: the request (a token, for token-set) isn't kept in QML.
      store.helperInput = ""
      if (store.current)
        store.current.input = ""
    }
    stdout: StdioCollector {
      id: helperOutput
      waitForEnd: true
    }
    onExited: function (code) {
      store.finish(code, helperOutput.text)
    }
    // After exited() this finds nothing in flight; before it, the helper never started.
    onRunningChanged: if (!running)
      store.finish(-1, "")
  }

  // A helper message, translated: a catalog key, then the values for its %1, %2…
  function helperText(message) {
    var parts = Model.messageParts(message)
    return FoamyI18n.t(parts.key, parts.values)
  }
  function failureText(reply, code) {
    if (reply && typeof reply.error === "string" && reply.error !== "")
      return helperText(reply.error)
    return code === 124 ? FoamyI18n.t("Todoist didn't answer in time.") : FoamyI18n.t("The Todoist helper failed.")
  }

  function handle(job, code, text) {
    if (FoamyNative.unavailable(code)) {
      account = "unavailable"
      accountError = FoamyI18n.t(FoamyNative.UNAVAILABLE_TEXT)
      const waiting = queue
      queue = []
      waiting.forEach(function (queued) {
        store.drop(queued, store.accountError)
      })
      struck = ({})
      sending = ({})
      undoWindow.stop()
      if (job.command === "add")
        addFinished(job.extra.request, false, accountError)
      return
    }
    var reply = Model.parseReply(text)
    var ok = !!reply && reply.ok === true
    var stale = job.generation !== generation
    // Todoist's retry time, from whichever call learned it (an add's
    // follow-up too), with a default wait when it gave none.
    var wait = stale ? 0 : Model.retryDelayMs(reply)
    if (wait > 0)
      retryUntil = Math.max(retryUntil, Date.now() + wait)
    if (job.command === "status")
      return stale ? undefined : statusDone(reply, ok, code)
    if (job.command === "token-set" || job.command === "token-clear")
      return tokenDone(job, reply, ok, code)
    if (job.extra.closing)
      closingDone(job.extra.closing, ok, stale)
    if (stale) {
      if (job.command === "add")
        addFinished(job.extra.request, false, "")
      return
    }
    // A failed add is reported under the add field, not as a sync error.
    if (ok)
      receive(reply)
    else if (job.command !== "add" || (reply && reply.code === "SIGNED_OUT"))
      failed(reply, code)
    // Quick Add went out but no answer came: the task may exist. A sync
    // now shows whether it does (the queue still honours a rate limit).
    if (job.command === "add" && !ok && reply && reply.code === "UNKNOWN_OUTCOME")
      syncSoon()
    // What the failed completions did is learned from a snapshot, now.
    if (!ok && job.extra.closing)
      syncSoon()
    if (job.command === "add")
      addFinished(job.extra.request, ok, ok ? (reply.warning ? helperText(reply.warning) : "") : failureText(reply, code))
    else if (ok && reply.warning)
      error = helperText(reply.warning)
    if (ok && reply.results)
      reportResults(reply.results)
  }

  function statusDone(reply, ok, code) {
    if (!ok) {
      account = "error"
      accountError = failureText(reply, code)
      return
    }
    accountError = ""
    user = reply.user || null
    account = reply.state === "signed_in" ? "signed_in" : "signed_out"
    if (signedIn)
      sync()
  }

  function tokenDone(job, reply, ok, code) {
    if (job.command === "token-set")
      tokenSetFinished(ok)
    if (!ok) {
      tokenError = failureText(reply, code)
      // A sign-out that didn't finish (a locked keyring): still signed in.
      if (job.command === "token-clear")
        check()
      return
    }
    tokenError = ""
    generation++
    resetData()
    user = reply.user || null
    account = reply.state === "signed_in" ? "signed_in" : "signed_out"
    if (signedIn)
      sync()
  }

  // Sent completions leave `sending`. With a reply, the snapshot says
  // whether each is gone, and a rejected one is back with the error line
  // (reportResults). Without one, they are unconfirmed until a snapshot.
  function closingDone(ids, ok, stale) {
    release(ids)
    if (ok || stale)
      return
    var next = Object.assign({}, unconfirmed)
    ids.forEach(function (id) {
      next[id] = true
    })
    unconfirmed = next
  }
  function release(ids) {
    var next = Object.assign({}, sending)
    ids.forEach(function (id) {
      delete next[id]
    })
    sending = next
  }
  function reportResults(results) {
    for (const id in results) {
      const result = results[id]
      if (result !== "ok") {
        error = result && typeof result.error === "string" ? helperText(result.error) : FoamyI18n.t("Todoist didn't accept the change.")
        errorCode = result && typeof result.code === "string" ? result.code : "HTTP"
        return
      }
    }
  }

  function receive(reply) {
    // A reply after a suspend can come before the midnight timer has
    // caught up: the counts it brings are for the date on the clock now.
    updateToday()
    snapshot = reply
    // Only a fresh read confirms what unanswered completions did, and only
    // it ends a wait Todoist asked for (a stale add reply may carry one).
    var fresh = Model.freshSnapshot(reply)
    if (fresh)
      unconfirmed = ({})
    var at = Date.parse(reply.synced_at)
    syncedAt = isNaN(at) ? Date.now() : at
    if (reply.user)
      user = reply.user
    error = ""
    errorCode = ""
    failures = 0
    if (fresh)
      retryUntil = 0
    // A late reply must not start the poll again once no bar is left.
    if (polling)
      poll.restart()
  }

  function failed(reply, code) {
    errorCode = reply && typeof reply.code === "string" ? reply.code : ""
    error = failureText(reply, code)
    failures++
    // Signed out elsewhere (the keyring item went): say so.
    if (errorCode === "SIGNED_OUT") {
      resetData()
      account = "signed_out"
      user = null
      return
    }
    // Count the backed-off wait from this failure (only while polling).
    if (polling)
      poll.restart()
  }

  function resetData() {
    addDraft = ""
    addError = ""
    snapshot = null
    syncedAt = 0
    error = ""
    errorCode = ""
    failures = 0
    retryUntil = 0
    struck = ({})
    sending = ({})
    unconfirmed = ({})
    undoWindow.stop()
  }

  // ---- what the panels ask for --------------------------------------------------
  function check() {
    enqueue("status", null)
  }
  function sync() {
    if (signedIn && Date.now() >= retryUntil)
      enqueue("sync", null)
  }
  // A sync even while other jobs wait (unless one is already on its way).
  function syncSoon() {
    var queued = [current].concat(queue).some(function (job) {
      return !!job && job.command === "sync"
    })
    if (signedIn && !queued)
      enqueue("sync", null, {
        soon: true
      })
  }
  // Opening the popup refreshes data older than `maxAgeMs`.
  function refreshIfStale(maxAgeMs) {
    updateToday()
    if (polling && !busy && Date.now() - syncedAt > maxAgeMs)
      sync()
  }
  function retry() {
    if (account === "error" || account === "checking")
      check()
    else
      sync()
  }
  function setToken(token) {
    tokenError = ""
    // The token goes to the helper on stdin only.
    enqueue("token-set", {
      token: token
    })
  }
  function signOut() {
    tokenError = ""
    // Anything queued is for the account that goes; a reply already on its
    // way is ignored (generation).
    generation++
    var keep = function (job) {
      return job.command === "token-set" || job.command === "token-clear"
    }
    var dropped = queue.filter(function (job) {
      return !keep(job)
    })
    queue = queue.filter(keep)
    resetData()
    // Every dropped add ends (failed, no message), so no view waits on it.
    dropped.forEach(function (job) {
      store.drop(job, "")
    })
    enqueue("token-clear", null)
  }

  // Every `refreshSeconds` while signed in and some bar is alive; failures
  // back off (twice as long each time, at most 30 minutes, never sooner
  // than Todoist's retry_after).
  // Automatic syncs (the poll, refreshIfStale) only while a bar is alive.
  readonly property bool polling: signedIn && FoamyShared.memberCount("todoist") > 0
  property Timer poll: Timer {
    running: store.polling
    repeat: true
    interval: Model.backoffSeconds(store.refreshSeconds, store.failures, Math.max(0, (store.retryUntil - Date.now()) / 1000)) * 1000
    // A tick after a suspend may be the first thing to run on a new day.
    onTriggered: {
      store.updateToday()
      if (store.polling)
        store.sync()
    }
  }

  // ---- links ----------------------------------------------------------------------
  // Todoist links open with the open command (Preferences "openCommand",
  // pushed by the panels; empty: xdg-open), split into argv without a
  // shell (Model.openArgv). It runs in its own session (setsid), so it and
  // what it starts outlive the shell (a user-launched application). The
  // wrapper waits up to 2 s for it: its exit status when it ends by then,
  // otherwise 0, as a browser can hold its launcher open while it runs.
  // One launch at a time, at most 8 waiting; only app.todoist.com links.
  property string openCommand: ""
  readonly property string launchScript: ['setsid -w -- "$@" </dev/null >/dev/null 2>&1 &', 'opener=$!', 'for _ in {1..20}; do', '  kill -0 "$opener" 2>/dev/null || { wait "$opener"; exit; }', '  sleep 0.1', 'done', 'exit 0'].join("\n")
  property var launches: []
  property bool launchRunning: false
  // Why the last launch failed ("" once one worked); the footer shows it.
  property string launchError: ""
  function openUrl(url) {
    if (!/^https:\/\/app\.todoist\.com\//.test(url) || launches.length >= 8)
      return
    launches = launches.concat([Model.openArgv(openCommand, url)])
    launchNext()
  }
  function openView(kind, id) {
    openUrl(Model.webUrl(kind, id))
  }
  function launchNext() {
    if (launchRunning || !launches.length)
      return
    var argv = launches[0]
    launches = launches.slice(1)
    launchRunning = true
    launcher.command = ["timeout", "--kill-after=1s", "10s", "bash", "-c", launchScript, "bash"].concat(argv)
    launcher.running = true
  }
  // Every launch ends here once: its exit code, or -1 when the wrapper never started.
  function launched(code) {
    if (!launchRunning)
      return
    launchRunning = false
    Qt.callLater(launchNext)
    launchError = code === 0 ? "" : FoamyI18n.t("Can't open Todoist")
  }
  property Process launcher: Process {
    onExited: function (code) {
      store.launched(code)
    }
    onRunningChanged: if (!running)
      store.launched(-1)
  }

  // Preview: sample data, and no helper is ever started.
  property bool fixtures: false
  function loadFixture(reply, signedInState) {
    fixtures = true
    queue = []
    generation++
    resetData()
    account = signedInState === false ? "signed_out" : "signed_in"
    user = reply ? reply.user : null
    if (reply)
      receive(reply)
  }

  // Later, so a preview can turn on `fixtures` first.
  Component.onCompleted: Qt.callLater(check)
}
