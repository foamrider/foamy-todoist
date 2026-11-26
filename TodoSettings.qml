import QtQuick
import QtQuick.Layouts
import "kit"
import "kit/FoamyPrefs.js" as Prefs
import "Preferences.js" as Schema

// The settings page: the panel, the open command, the bar, how often to
// refresh, and the account (API token in the keyring) last; signed out, the
// account's steps come first. Saved through the Panel's FoamyPrefsQueue;
// the token never is a setting. The sections stand further apart than the
// rows in one, and the short choices' dropdowns share one width.
FoamySettingsPage {
  id: page
  property var preferences: ({})
  // The Panel's FoamyPrefsQueue. Each choice is linked to it and its key,
  // so a pick the queue refuses (no bar entry) shows the saved value again
  // at once instead of staying on show beside the error.
  property FoamyPrefsQueue prefs: null
  // The sections' width, centred on the page: Wide's page is the popup's
  // 880 but keeps the settings width (TodoView sets it).
  property real columnWidth: width
  signal saveRequested(string key, var value)
  function pref(key) {
    return Prefs.value(Schema.fields, preferences, key)
  }
  readonly property var store: TodoStore
  readonly property alias tokenField: tokenInput
  readonly property string settingsUrl: "https://app.todoist.com/app/settings/integrations"
  // Why the token failed, why the token field refused a paste, or why the
  // account can't be used (under the token form, or under the signed-in
  // row: a sign-out the keyring refused).
  readonly property string accountMessage: store.tokenError !== "" ? store.tokenError : tokenInput.pasteError !== "" ? FoamyI18n.t(tokenInput.pasteError) : store.account === "unavailable" || store.account === "error" ? store.accountError : ""
  // The widest short choice: every dropdown is drawn this wide.
  readonly property real dropdownWidth: Math.max(panelWidth.compactNaturalWidth, afterAdd.compactNaturalWidth, openOn.compactNaturalWidth, othersTasks.compactNaturalWidth, barCount.compactNaturalWidth, refreshSeconds.compactNaturalWidth)

  // Sign out asks first: the signed-in row turns into the question, with
  // Cancel and the destructive Sign out. Cancel, Esc, leaving the page or
  // closing the panel put the row back.
  property bool askingSignOut: false
  // Sign out drops what isn't sent yet (TodoStore.signOut): completions
  // and moves in their undo window, and the adds and changes that wait
  // for their turn. A call already running still reaches Todoist.
  readonly property bool unsentChanges: store.pending || store.queue.some(function (job) {
    return job.command === "add" || job.command === "apply"
  })
  function askSignOut() {
    var byKeys = signOutButton.activeFocus
    askingSignOut = true
    if (byKeys)
      cancelSignOut.forceActiveFocus(Qt.TabFocusReason)
  }
  // The row back (Cancel, Esc), with the keys if the question had them.
  function keepSignedIn() {
    var byKeys = cancelSignOut.activeFocus || confirmSignOut.activeFocus
    askingSignOut = false
    if (byKeys)
      signOutButton.forceActiveFocus(Qt.TabFocusReason)
  }
  // The question's Sign out. The row comes back while it runs: a sign-out
  // the keyring refuses leaves the user signed in, the reason under it.
  function signOutConfirmed() {
    keepSignedIn()
    store.signOut()
  }
  Connections {
    target: page.store
    function onSignedInChanged() {
      page.askingSignOut = false
    }
  }

  // A typed token goes to the helper on stdin. The field keeps it only
  // until Todoist took it (a refused one stays, to fix a typo) or the page
  // goes away.
  function saveToken() {
    var token = tokenInput.secretText.trim()
    if (token === "" || store.tokenBusy)
      return
    store.setToken(token)
  }
  Connections {
    target: page.store
    function onTokenSetFinished(ok) {
      if (ok)
        tokenInput.clear()
    }
  }
  // Leaving the page (Back, or the panel closing) forgets the token typed
  // and the sign-out question.
  onVisibleChanged: if (!visible) {
    tokenInput.clear()
    askingSignOut = false
  }
  // A save of the Open command that the queue refuses leaves its value as
  // it was: saveFailed() makes the field show the saved command again and
  // lets the same text be sent again.
  Connections {
    target: page.prefs
    function onFailed(key) {
      if (key === "openCommand")
        openCommandField.saveFailed()
    }
  }

  // Signed out: the account's steps first.
  FoamySettingsSection {
    id: accountSection
    objectName: "accountSection"
    visible: !page.store.signedIn
    width: Math.min(parent.width, page.columnWidth)
    x: (parent.width - width) / 2
    title: FoamyI18n.t("Account")
    description: FoamyI18n.t("Find your API token in Todoist under Settings → Integrations → Developer.")
    // Signed out, in the order of the steps: where the token is (Open
    // Todoist settings beside its label), then the field and Save token.
    Column {
      objectName: "signedOutForm"
      visible: !page.store.signedIn
      width: parent.width
      spacing: FoamyStyle.gap
      RowLayout {
        width: parent.width
        spacing: FoamyStyle.gap
        PlainText {
          Layout.fillWidth: true
          text: FoamyI18n.t("API token")
          wrapMode: Text.NoWrap
          elide: Text.ElideRight
          color: FoamyPalette.secondaryText
          font.pixelSize: FoamyStyle.font.bodySmall
        }
        FoamyButton {
          objectName: "openTodoistSettings"
          focusable: true
          text: FoamyI18n.t("Open Todoist settings")
          iconName: "external-link"
          onClicked: page.store.openUrl(page.settingsUrl)
        }
      }
      RowLayout {
        width: parent.width
        spacing: FoamyStyle.gap
        SafeTextField {
          id: tokenInput
          objectName: "tokenField"
          Layout.fillWidth: true
          Layout.preferredHeight: FoamyStyle.controlHeight
          // Dots only; the value is secretText (never drawn, copied or kept in undo).
          masked: true
          maximumLength: 256
          placeholderText: FoamyI18n.t("Paste your API token")
          translate: FoamyI18n.t
          Accessible.name: FoamyI18n.t("API token")
          onAccepted: page.saveToken()
          // A refused paste (pasteError, a catalog key) is the newest news:
          // it ends the last token error, so the line says why.
          onPasteErrorChanged: if (pasteError !== "")
            page.store.tokenError = ""
        }
        FoamyButton {
          objectName: "saveTokenButton"
          focusable: true
          text: FoamyI18n.t("Save token")
          kind: "primary"
          busy: page.store.tokenBusy
          actionEnabled: tokenInput.secretText.trim() !== "" && page.store.account !== "unavailable"
          onClicked: page.saveToken()
        }
      }
      // The account check failed (a stored value that isn't a token, a
      // locked or missing keyring, the lock or the cache folder): Sign
      // out removes the cache, then the item. A cache that can't be
      // removed refuses it and keeps both; a locked or missing keyring
      // removes only the cache and refuses it with its own message.
      FoamyButton {
        objectName: "errorSignOutButton"
        visible: page.store.account === "error"
        anchors.right: parent.right
        focusable: true
        text: FoamyI18n.t("Sign out")
        kind: "destructive"
        busy: page.store.tokenBusy
        onClicked: page.store.signOut()
      }
    }
    PlainText {
      objectName: "tokenError"
      visible: text !== ""
      width: parent.width
      text: page.accountMessage
      color: FoamyPalette.onSurface(FoamyPalette.error)
      font.pixelSize: FoamyStyle.font.bodySmall
      Accessible.role: Accessible.AlertMessage
    }
  }

  FoamySettingsSection {
    objectName: "panelSection"
    width: Math.min(parent.width, page.columnWidth)
    x: (parent.width - width) / 2
    // The first section signed in.
    topPadding: page.store.signedIn ? 0 : FoamyStyle.sectionGap
    title: FoamyI18n.t("Panel")
    FoamyDropdown {
      id: panelWidth
      objectName: "panelWidth"
      width: parent.width
      compact: true
      compactWidth: page.dropdownWidth
      label: FoamyI18n.t("Size")
      value: page.pref("panelWidth")
      enabled: !page.saving
      queue: page.prefs
      queueKey: "panelWidth"
      options: [
        {
          value: "standard",
          label: FoamyI18n.t("Small")
        },
        {
          value: "wide",
          label: FoamyI18n.t("Wide")
        }
      ]
      onChanged: function (value) {
        page.saveRequested("panelWidth", value)
      }
    }
    FoamyDropdown {
      id: afterAdd
      objectName: "afterAdd"
      width: parent.width
      compact: true
      compactWidth: page.dropdownWidth
      label: FoamyI18n.t("After adding a task")
      value: page.pref("afterAdd")
      enabled: !page.saving
      queue: page.prefs
      queueKey: "afterAdd"
      options: [
        {
          value: "close",
          label: FoamyI18n.t("Close the panel")
        },
        {
          value: "keep",
          label: FoamyI18n.t("Keep the field open")
        }
      ]
      onChanged: function (value) {
        page.saveRequested("afterAdd", value)
      }
    }
    FoamyDropdown {
      id: openOn
      objectName: "openOn"
      width: parent.width
      compact: true
      compactWidth: page.dropdownWidth
      label: FoamyI18n.t("Open on")
      value: page.pref("openOn")
      enabled: !page.saving
      queue: page.prefs
      queueKey: "openOn"
      options: [
        {
          value: "today",
          label: FoamyI18n.t("Today")
        },
        {
          value: "inbox",
          label: FoamyI18n.t("Inbox")
        },
        {
          value: "upcoming",
          label: FoamyI18n.t("Upcoming")
        },
        {
          value: "last",
          label: FoamyI18n.t("Last view")
        }
      ]
      onChanged: function (value) {
        page.saveRequested("openOn", value)
      }
    }
    FoamyDropdown {
      id: othersTasks
      objectName: "othersTasks"
      width: parent.width
      compact: true
      compactWidth: page.dropdownWidth
      label: FoamyI18n.t("Tasks assigned to others")
      // Where Hide leaves them out (Model.personal); a project and search
      // always show them.
      description: FoamyI18n.t("In Today, Upcoming, Week, the Inbox and the bar")
      value: page.pref("othersTasks")
      enabled: !page.saving
      queue: page.prefs
      queueKey: "othersTasks"
      options: [
        {
          value: "hide",
          label: FoamyI18n.t("Hide")
        },
        {
          value: "show",
          label: FoamyI18n.t("Show")
        }
      ]
      onChanged: function (value) {
        page.saveRequested("othersTasks", value)
      }
    }
  }

  // A command, so full width (DESIGN.md); Preferences.js validates it. The
  // section's title is its label, with the (i) beside it.
  FoamySettingsSection {
    objectName: "openCommandSection"
    width: Math.min(parent.width, page.columnWidth)
    x: (parent.width - width) / 2
    topPadding: FoamyStyle.sectionGap
    title: FoamyI18n.t("Open command")
    info: FoamyI18n.t("A command to open Todoist links with, for example omarchy-launch-or-focus-webapp Todoist {url}. {url} is replaced with the link; without it, the link is added at the end. No shell: quotes and pipes aren't supported.")
    FoamyTextSettingField {
      id: openCommandField
      objectName: "openCommand"
      width: parent.width
      field.Accessible.name: FoamyI18n.t("Open command")
      placeholderText: FoamyI18n.t("Browser (default)")
      value: page.pref("openCommand")
      enabled: !page.saving
      validate: function (text) {
        return Schema.validOpenCommand(text) || FoamyI18n.t("Start with a command name or an absolute path; at most 300 characters, no control characters.")
      }
      onCommitted: function (value) {
        page.saveRequested("openCommand", value)
      }
    }
  }

  FoamySettingsSection {
    objectName: "barSection"
    width: Math.min(parent.width, page.columnWidth)
    x: (parent.width - width) / 2
    topPadding: FoamyStyle.sectionGap
    title: FoamyI18n.t("Bar")
    FoamyDropdown {
      id: barCount
      objectName: "barCount"
      width: parent.width
      compact: true
      compactWidth: page.dropdownWidth
      label: FoamyI18n.t("Show in the bar")
      value: page.pref("barCount")
      enabled: !page.saving
      queue: page.prefs
      queueKey: "barCount"
      options: [
        {
          value: "today",
          label: FoamyI18n.t("Tasks left today")
        },
        {
          value: "none",
          label: FoamyI18n.t("Icon only")
        }
      ]
      onChanged: function (value) {
        page.saveRequested("barCount", value)
      }
    }
  }

  FoamySettingsSection {
    objectName: "refreshSection"
    width: Math.min(parent.width, page.columnWidth)
    x: (parent.width - width) / 2
    topPadding: FoamyStyle.sectionGap
    title: FoamyI18n.t("Refresh")
    FoamyDropdown {
      id: refreshSeconds
      objectName: "refreshSeconds"
      width: parent.width
      compact: true
      compactWidth: page.dropdownWidth
      label: FoamyI18n.t("Refresh every")
      value: String(page.pref("refreshSeconds"))
      enabled: !page.saving
      queue: page.prefs
      queueKey: "refreshSeconds"
      options: Schema.refreshChoices.map(function (seconds) {
        return {
          value: String(seconds),
          label: FoamyI18n.tn("%1 minutes", seconds / 60)
        }
      })
      onChanged: function (value) {
        page.saveRequested("refreshSeconds", Number(value))
      }
    }
  }

  // Signed in: who, and Sign out, last.
  FoamySettingsSection {
    id: signedInSection
    objectName: "signedInSection"
    visible: page.store.signedIn
    width: Math.min(parent.width, page.columnWidth)
    x: (parent.width - width) / 2
    topPadding: FoamyStyle.sectionGap
    title: FoamyI18n.t("Account")
    // Esc while the question has the keys: the row back, the page stays.
    Keys.onEscapePressed: function (event) {
      if (!page.askingSignOut) {
        event.accepted = false
        return
      }
      page.keepSignedIn()
      event.accepted = true
    }
    RowLayout {
      objectName: "signedInRow"
      visible: !page.askingSignOut
      width: parent.width
      spacing: FoamyStyle.gapLarge
      Column {
        Layout.fillWidth: true
        spacing: 2
        PlainText {
          objectName: "accountTitle"
          width: parent.width
          text: page.store.user && page.store.user.full_name ? FoamyI18n.t("Signed in as %1", [page.store.user.full_name]) : FoamyI18n.t("Signed in")
          font.pixelSize: FoamyStyle.font.subtitle
        }
        PlainText {
          objectName: "accountEmail"
          visible: text !== ""
          width: parent.width
          text: page.store.user && page.store.user.email ? page.store.user.email : ""
          color: FoamyPalette.secondaryText
          font.pixelSize: FoamyStyle.font.bodySmall
        }
      }
      FoamyButton {
        id: signOutButton
        objectName: "signOutButton"
        focusable: true
        text: FoamyI18n.t("Sign out")
        busy: page.store.tokenBusy
        onClicked: page.askSignOut()
      }
    }
    // The question, in the row's place.
    RowLayout {
      objectName: "signOutQuestion"
      visible: page.askingSignOut
      width: parent.width
      spacing: FoamyStyle.gap
      Column {
        Layout.fillWidth: true
        spacing: 2
        PlainText {
          objectName: "signOutAsk"
          width: parent.width
          text: page.store.user && page.store.user.full_name ? FoamyI18n.t("Sign out of %1?", [page.store.user.full_name]) : FoamyI18n.t("Sign out?")
          font.pixelSize: FoamyStyle.font.subtitle
        }
        PlainText {
          objectName: "signOutUnsent"
          visible: page.unsentChanges
          width: parent.width
          text: FoamyI18n.t("Changes not sent to Todoist yet will be lost.")
          color: FoamyPalette.secondaryText
          font.pixelSize: FoamyStyle.font.bodySmall
        }
      }
      FoamyButton {
        id: confirmSignOut
        objectName: "confirmSignOut"
        focusable: true
        text: FoamyI18n.t("Sign out")
        kind: "destructive"
        busy: page.store.tokenBusy
        onClicked: page.signOutConfirmed()
      }
      // Last, and at least as wide as the row's Sign out: it stands where
      // that button stood, so the second click of a double-click cancels
      // (it must never be the one that signs out).
      FoamyButton {
        id: cancelSignOut
        objectName: "cancelSignOut"
        focusable: true
        Layout.preferredWidth: Math.max(implicitWidth, signOutButton.implicitWidth)
        text: FoamyI18n.t("Cancel")
        onClicked: page.keepSignedIn()
      }
    }
    // A sign-out the keyring refused, while still signed in.
    PlainText {
      objectName: "signedInError"
      visible: text !== ""
      width: parent.width
      text: page.accountMessage
      color: FoamyPalette.onSurface(FoamyPalette.error)
      font.pixelSize: FoamyStyle.font.bodySmall
      Accessible.role: Accessible.AlertMessage
    }
  }
}
