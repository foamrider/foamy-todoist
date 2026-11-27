pragma Singleton
import QtQuick
import Quickshell.Io
import "kit"
import "kit/FoamyNative.js" as FoamyNative
import "Model.js" as Model
import "Edit.js" as Edit

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
  // The helper's code for accountError ("" without one): the view offers
  // Settings instead of Retry for a stored value that isn't a token.
  property string accountErrorCode: ""
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
  // Moved to another day in the panel and still undoable: {id: day} (""
  // for no date). They go with the completions when the undo window ends;
  // `movesSent` keeps showing them until the reply has the new snapshot.
  property var moves: ({})
  property var movesSent: ({})
  // Why a task's last move failed ({id: message}), for its editor (in Small
  // the list's error line is out of sight); a new move of it clears it.
  property var moveErrors: ({})
  // What the rows show: the sent moves, and the waiting ones over them.
  readonly property var shownMoves: Object.assign({}, movesSent, moves)
  readonly property bool pending: struckCount > 0 || Object.keys(moves).length > 0
  property Timer undoWindow: Timer {
    interval: store.undoMs
    onTriggered: store.flushCompletions()
  }
  function complete(id) {
    if (!signedIn || !Model.validId(id) || Model.has(struck, id) || Model.has(sending, id) || Model.has(unconfirmed, id) || Model.has(movesSent, id))
      return
    // Completed instead of moved.
    if (Model.has(moves, id))
      undoMove(id)
    var next = Object.assign({}, struck)
    next[id] = true
    struck = next
    undoWindow.restart()
  }
  // A row's Undo: its completion or its move.
  function undo(id) {
    if (Model.has(moves, id))
      return undoMove(id)
    if (!Model.has(struck, id))
      return
    var next = Object.assign({}, struck)
    delete next[id]
    struck = next
    if (!pending)
      undoWindow.stop()
  }
  function undoMove(id) {
    var next = Object.assign({}, moves)
    delete next[id]
    moves = next
    if (!pending)
      undoWindow.stop()
  }
  // Space: completes; again (or on a moved row) undoes, as the row's Undo.
  function toggleComplete(id) {
    if (Model.has(struck, id) || Model.has(moves, id))
      undo(id)
    else
      complete(id)
  }
  // The completions and moves whose undo window ended (or the popup
  // closed), in one apply call per 100.
  function flushCompletions() {
    undoWindow.stop()
    var closing = Object.keys(struck)
    var waiting = [current].concat(queue)
    // A task that left the snapshot meanwhile has nothing to move. One
    // whose typed date is still on its way waits for it (its move is built
    // from the date Todoist then has, so the typed time isn't lost).
    var held = ({})
    var moved = ({})
    Object.keys(moves).forEach(function (id) {
      var saving = waiting.some(function (job) {
        return !!job && job.extra.update === id
      })
      if (saving)
        held[id] = moves[id]
      else
        moved[id] = moves[id]
    })
    var movedIds = Object.keys(moved).filter(function (id) {
      return !!model.byId[id]
    })
    if (!closing.length && !Object.keys(moved).length) {
      if (Object.keys(held).length)
        undoWindow.restart()
      return
    }
    var hiding = Object.assign({}, sending)
    closing.forEach(function (id) {
      hiding[id] = true
    })
    struck = ({})
    sending = hiding
    moves = held
    if (Object.keys(held).length)
      undoWindow.restart()
    var sent = Object.assign({}, movesSent)
    movedIds.forEach(function (id) {
      sent[id] = moved[id]
    })
    movesSent = sent
    var commands = closing.map(function (id) {
      return {
        op: "close",
        id: id
      }
    }).concat(movedIds.map(function (id) {
      return {
        op: "due",
        id: id,
        date: Model.movedDate(model.byId[id], moved[id])
      }
    }))
    // At most 100 changes per helper call.
    for (let i = 0; i < commands.length; i += 100) {
      const batch = commands.slice(i, i + 100)
      enqueue("apply", {
        commands: batch
      }, {
        closing: batch.filter(function (command) {
          return command.op === "close"
        }).map(function (command) {
          return command.id
        }),
        moving: batch.filter(function (command) {
          return command.op === "due"
        }).map(function (command) {
          return command.id
        })
      })
    }
  }
  // Why a move was refused, for the list's error line ("" when it wasn't).
  function moveRefusal(id) {
    var task = model.byId[id]
    return task && task.due && task.due.recurring ? FoamyI18n.t("A repeating task can't be moved here: open it to change its date.") : ""
  }
  // A move to `day` ("" for no date), undoable like a completion: the row
  // shows its new day at once, the change goes when the undo window ends.
  // The time stays (Model.movedDate). A repeating task isn't moved: one
  // occurrence's date isn't something the API describes; the error line
  // says so. Returns whether the move was taken.
  // Whether a task can take a move now (not completed, sending, unknown,
  // or moving already; a repeating one is refused with a reason, in move).
  function canMove(id) {
    return signedIn && !!model.byId[id] && !Model.has(struck, id) && !Model.has(sending, id) && !Model.has(unconfirmed, id) && !Model.has(movesSent, id)
  }
  function move(id, day) {
    var task = model.byId[id]
    if (!canMove(id))
      return false
    var refusal = moveRefusal(id)
    if (refusal !== "") {
      error = refusal
      return false
    }
    var next = Object.assign({}, moves)
    placeMove(next, task, day)
    moves = next
    settleWindow()
    return true
  }
  // Several tasks to one day (Overdue's Move to today), published once: a
  // repeating task stays, and the error line says why.
  function moveAll(ids, day) {
    var next = Object.assign({}, moves)
    var refused = ""
    ids.forEach(function (id) {
      var task = model.byId[id]
      if (!task || Model.has(struck, id) || Model.has(sending, id) || Model.has(unconfirmed, id) || Model.has(movesSent, id))
        return
      var refusal = moveRefusal(id)
      if (refusal !== "")
        refused = refusal
      else
        placeMove(next, task, day)
    })
    moves = next
    if (refused !== "")
      error = refused
    settleWindow()
  }
  function placeMove(next, task, day) {
    var id = task.id
    clearMoveError(id)
    // Back to where it was: nothing to send, unless a typed date is still on
    // its way (then Todoist's date will change, and this pick must follow).
    var savingDate = [current].concat(queue).some(function (job) {
      return !!job && job.extra.update === id
    })
    if (day === (task.due ? task.due.day : "") && !savingDate)
      delete next[id]
    else
      next[id] = day
  }
  function settleWindow() {
    if (pending && !holdingUndo)
      undoWindow.restart()
    else if (!pending)
      undoWindow.stop()
  }
  // While a menu of days is open the undo window waits, so a pick there
  // still changes a waiting move (it can't once the move is sent).
  property bool holdingUndo: false
  function holdUndo(on) {
    holdingUndo = on
    if (on)
      undoWindow.stop()
    else
      settleWindow()
  }
  function clearMoveError(id) {
    if (!Model.has(moveErrors, id))
      return
    var next = Object.assign({}, moveErrors)
    delete next[id]
    moveErrors = next
  }
  function noteMoveErrors(ids, message) {
    if (message === "" || !ids.length)
      return
    var next = Object.assign({}, moveErrors)
    ids.forEach(function (id) {
      next[id] = message
    })
    moveErrors = next
  }
  // `t`: due tomorrow.
  function moveToTomorrow(id) {
    return move(id, Model.addDays(today, 1))
  }
  // Ctrl+←/→ in the Week view: a day earlier or later than where the card
  // stands, never before today.
  function shiftDue(id, delta) {
    var task = model.byId[id]
    if (task && task.due && task.due.recurring)
      return move(id, task.due.day)
    var day = Model.shiftedDay(task, delta, today, Model.has(moves, id) ? moves[id] : "")
    return day !== "" && move(id, day)
  }

  // ---- editing (the task editor) ---------------------------------------------------
  // One field's save is one apply job with one `update` command (Edit.js
  // builds its fields), so two saves of a task never share a batch. The
  // editor that sent a save owns it (`editorSaves`) until it closes: then
  // a failure has nowhere to show and goes to the error line instead.
  property int saveRequests: 0
  property var editorSaves: ({})
  signal taskSaved(int request, string id, bool ok, string message)
  function saveTask(id, fields) {
    if (!signedIn || !Model.validId(id) || !model.byId[id] || !fields)
      return -1
    var request = ++saveRequests
    var owned = Object.assign({}, editorSaves)
    owned[request] = true
    editorSaves = owned
    enqueue("apply", Edit.request(id, fields), {
      update: id,
      request: request,
      description: typeof fields.description === "string" ? fields.description : null
    })
    return request
  }
  // The editor closed: its saves still in flight report to the error line.
  function releaseSaves(requests) {
    var owned = Object.assign({}, editorSaves)
    requests.forEach(function (request) {
      delete owned[request]
    })
    editorSaves = owned
  }
  // An edit the editor couldn't send as it let its task go: the error
  // line says why, as for a save that fails after the editor closed.
  function editRefused(message) {
    if (message !== "")
      error = message
  }
  function saveDone(job, ok, message) {
    var request = job.extra.request
    var owned = Model.has(editorSaves, request)
    if (owned) {
      let rest = Object.assign({}, editorSaves)
      delete rest[request]
      editorSaves = rest
    } else if (!ok && message !== "")
      error = message
    // A saved description is the one the editor compares with from now on.
    if (ok && job.extra.description !== null && description.id === job.extra.update)
      description = Object.assign({}, description, {
        text: job.extra.description
      })
    taskSaved(request, job.extra.update, ok, message)
  }

  // The open editor's description (not in the snapshot): one at a time,
  // {id, state: "" | "loading" | "ready" | "error", text, truncated,
  // error}. A reply for another request (another task, a closed editor) is
  // ignored.
  property var description: ({
      id: "",
      state: "",
      text: "",
      truncated: false,
      error: ""
    })
  property int descriptionRequest: 0
  function loadDescription(id) {
    if (!signedIn || !Model.validId(id))
      return
    var request = ++descriptionRequest
    // Previews: the sample descriptions, no helper.
    if (fixtures) {
      description = {
        id: id,
        state: "ready",
        text: Model.has(fixtureDescriptions, id) ? fixtureDescriptions[id] : "",
        truncated: false,
        error: ""
      }
      return
    }
    // Only the newest read waits: one queued for an earlier selection goes.
    queue = queue.filter(function (job) {
      return job.command !== "task"
    })
    description = {
      id: id,
      state: "loading",
      text: "",
      truncated: false,
      error: ""
    }
    enqueue("task", {
      id: id
    }, {
      describe: id,
      request: request
    })
  }
  function dropDescription() {
    descriptionRequest++
    queue = queue.filter(function (job) {
      return job.command !== "task"
    })
    description = {
      id: "",
      state: "",
      text: "",
      truncated: false,
      error: ""
    }
  }
  function describeDone(job, reply, ok, code) {
    if (job.extra.request !== descriptionRequest || description.id !== job.extra.describe)
      return
    var task = ok && reply.task && typeof reply.task === "object" ? reply.task : null
    if (task && task.id === job.extra.describe && typeof task.description === "string") {
      description = {
        id: task.id,
        state: "ready",
        text: task.description,
        truncated: task.truncated === true,
        error: ""
      }
      return
    }
    description = Object.assign({}, description, {
      state: "error",
      error: ok ? FoamyI18n.t("Todoist sent an unexpected reply.") : failureText(reply, code)
    })
    if (!ok && reply && reply.code === "SIGNED_OUT")
      failed(reply, code)
  }

  // ---- adding -------------------------------------------------------------------
  property int addRequests: 0
  // A request's end: ok (the task exists, maybe with a warning) or not.
  // `kind` says what the message means for the task (addErrorKind).
  signal addFinished(int request, bool ok, string message, string kind)
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
  // Every view's field (and the draft) still starts with the text on its
  // way: only then is the rest "typed after it" once added. An edit that
  // breaks the prefix in any view clears it (TodoView writes it), so a
  // draft typed afresh that starts the same ("Buy milk" sent, then "Buy
  // milkshakes") stays whole on every monitor. Read once per reply.
  property bool sentKept: false
  readonly property bool addPending: pendingAdd >= 0
  // Why the field's last add failed, or its warning ("" when it worked):
  // it stays with the draft, also when the reply came after closing.
  property string addError: ""
  // What addError means for the task: "unknown" (Quick Add went out, no
  // answer came: it may exist, adding again may make two), "added" (it
  // exists, with a warning), "refused" (it was never added: sending it
  // again is safe), or "" (a reason of the field's own, not a send's).
  property string addErrorKind: ""
  // A failed add's draft and reason have not been seen: the bar buttons
  // say so until a view shows the add field with its error line (each
  // view reports that: TodoView.addErrorShown), or the reason goes with
  // the draft (TodoView.closed).
  property bool addUnseen: false
  // No mark without its reason: whatever ends the reason ends the mark.
  onAddErrorChanged: if (addError === "") {
    addUnseen = false
    addErrorKind = ""
  }
  // `kept`: sentKept as the reply came (what stays: afterAdd).
  signal fieldAdded(string text, bool kept)
  function addFromField(text, dueDate, projectId) {
    if (addPending)
      return false
    addError = ""
    addUnseen = false
    var request = add(text, dueDate, projectId)
    if (request < 0)
      return false
    pendingAdd = request
    pendingAddText = text
    sentKept = true
    return true
  }
  // A field's or the draft's text once `sent` was added: what was typed
  // after it (Model.typedAfter) while every edit kept it in front, else
  // the text, cleared only where it still is the sent one.
  function afterAdd(text, sent, kept) {
    return kept ? Model.typedAfter(text, sent) : text === sent ? "" : text
  }
  onAddFinished: function (request, ok, message, kind) {
    if (request !== pendingAdd)
      return
    var sent = pendingAddText
    var kept = sentKept
    pendingAdd = -1
    pendingAddText = ""
    sentKept = false
    // Set before the reason: a view that shows the error line as it
    // comes clears it at once. With every popup closed, the draft is the
    // store's; an open one's is in its field.
    addUnseen = !ok && message !== "" && (addDraft !== "" || FoamyShared.demandCount("todoist") > 0)
    addErrorKind = message !== "" ? kind : ""
    addError = message
    if (!ok)
      return
    // What was added leaves the draft; text typed after it stays (as in
    // the field).
    addDraft = afterAdd(addDraft, sent, kept)
    fieldAdded(sent, kept)
  }

  // ---- the helper queue ---------------------------------------------------------
  // {command, input, extra}; `current` is the running one.
  property var queue: []
  property var current: null
  readonly property bool busy: current !== null || queue.length > 0
  // A job that brings a new snapshot is running: the footer's Refresh spins.
  readonly property bool syncing: current !== null && current.command !== "status" && current.command !== "token-clear" && current.command !== "token-set" && current.command !== "task"
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
      if (Date.now() < retryUntil && (job.command === "sync" || job.command === "add" || job.command === "apply" || job.command === "task")) {
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
        store.addFinished(request, false, message, "refused")
      })
    }
    if (job.extra.closing) {
      release(job.extra.closing)
      if (message !== "")
        error = message
    }
    // Moves that never ran: the tasks stay where they were, the line says why.
    if (job.extra.moving) {
      movingDone(job.extra.moving)
      noteMoveErrors(job.extra.moving, message)
      if (message !== "")
        error = message
    }
    // A save that never ran: the editor keeps the text and says why.
    if (job.extra.update) {
      Qt.callLater(function () {
        store.saveDone(job, false, message)
      })
    }
    if (job.extra.describe && job.extra.request === descriptionRequest && message !== "")
      description = Object.assign({}, description, {
        state: "error",
        error: message
      })
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
  // What an add's end means for the task (addErrorKind). The helper says
  // UNKNOWN_OUTCOME when Quick Add went out without an answer; a run with
  // no reply at all (timed out, killed) may have sent it too. A helper
  // that never started (-1) sent nothing.
  function addOutcome(ok, reply, code) {
    if (ok)
      return "added"
    if (reply)
      return reply.code === "UNKNOWN_OUTCOME" ? "unknown" : "refused"
    return code === -1 ? "refused" : "unknown"
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
      accountErrorCode = ""
      const waiting = queue
      queue = []
      waiting.forEach(function (queued) {
        store.drop(queued, store.accountError)
      })
      struck = ({})
      sending = ({})
      moves = ({})
      movesSent = ({})
      moveErrors = ({})
      undoWindow.stop()
      if (job.command === "add")
        addFinished(job.extra.request, false, accountError, "refused")
      if (job.extra.update)
        saveDone(job, false, accountError)
      if (job.command === "task")
        drop(job, accountError)
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
    if (job.command === "task")
      return stale ? undefined : describeDone(job, reply, ok, code)
    if (job.extra.closing)
      closingDone(job.extra.closing, ok, stale)
    if (job.extra.moving)
      movingDone(job.extra.moving)
    if (stale) {
      if (job.command === "add")
        addFinished(job.extra.request, false, "", "")
      if (job.extra.update)
        saveDone(job, false, "")
      return
    }
    // A failed add is reported under the add field, a failed save under
    // its field, not as a sync error.
    if (ok)
      receive(reply)
    else if ((job.command !== "add" && !job.extra.update) || (reply && reply.code === "SIGNED_OUT"))
      failed(reply, code)
    // Quick Add went out but no answer came: the task may exist. A sync
    // now shows whether it does (the queue still honours a rate limit).
    if (job.command === "add" && !ok && reply && reply.code === "UNKNOWN_OUTCOME")
      syncSoon()
    // What the failed completions and moves did is learned from a
    // snapshot, now.
    if (!ok && (job.extra.closing || job.extra.moving))
      syncSoon()
    if (job.extra.moving) {
      if (!ok)
        noteMoveErrors(job.extra.moving, failureText(reply, code))
      else if (reply.results)
        job.extra.moving.forEach(function (id) {
          var result = reply.results[id]
          if (result !== undefined && result !== "ok")
            store.noteMoveErrors([id], result && typeof result.error === "string" ? store.helperText(result.error) : FoamyI18n.t("Todoist didn't accept the change."))
        })
    }
    if (job.command === "add")
      addFinished(job.extra.request, ok, ok ? (reply.warning ? helperText(reply.warning) : "") : failureText(reply, code), addOutcome(ok, reply, code))
    else if (ok && reply.warning)
      error = helperText(reply.warning)
    if (job.extra.update) {
      // The task's own result: "ok", or why Todoist refused it.
      const result = ok && reply.results && Model.has(reply.results, job.extra.update) ? reply.results[job.extra.update] : null
      const saved = result === "ok"
      saveDone(job, saved, saved ? "" : !ok ? failureText(reply, code) : result && typeof result.error === "string" ? helperText(result.error) : FoamyI18n.t("Todoist didn't accept the change."))
    } else if (ok && reply.results)
      reportResults(reply.results)
  }

  function statusDone(reply, ok, code) {
    if (!ok) {
      account = "error"
      accountError = failureText(reply, code)
      accountErrorCode = reply && typeof reply.code === "string" ? reply.code : ""
      return
    }
    accountError = ""
    accountErrorCode = ""
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
    // The token is stored but its new cache wasn't written: shown until a
    // sync answers.
    if (reply.warning)
      error = helperText(reply.warning)
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
  // Sent moves stop showing: the reply's snapshot has their new dates, or
  // the error line says why they didn't happen.
  function movingDone(ids) {
    var next = Object.assign({}, movesSent)
    ids.forEach(function (id) {
      delete next[id]
    })
    movesSent = next
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
    // A fresh read says where every task is: an old move's reason goes.
    if (fresh)
      moveErrors = ({})
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
    addUnseen = false
    snapshot = null
    syncedAt = 0
    error = ""
    errorCode = ""
    failures = 0
    retryUntil = 0
    struck = ({})
    sending = ({})
    moves = ({})
    movesSent = ({})
    moveErrors = ({})
    unconfirmed = ({})
    undoWindow.stop()
    dropDescription()
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
  property var fixtureDescriptions: ({})
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
