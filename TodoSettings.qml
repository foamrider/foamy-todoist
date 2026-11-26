import QtQuick
import QtQuick.Layouts
import "kit"
import "kit/FoamyPrefs.js" as Prefs
import "Preferences.js" as Schema

// The settings page: the account (API token in the keyring), the panel, the
// bar and how often to refresh. Saved through the Panel's FoamyPrefsQueue;
// the token never is a setting.
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
  onVisibleChanged: if (!visible)
    tokenInput.clear()

  FoamySettingsSection {
    id: accountSection
    objectName: "accountSection"
    width: Math.min(parent.width, page.columnWidth)
    x: (parent.width - width) / 2
    title: FoamyI18n.t("Account")
    info: page.store.signedIn ? "" : FoamyI18n.t("Find your API token in Todoist under Settings → Integrations → Developer.")
    // Signed in: who, and Sign out.
    RowLayout {
      objectName: "signedInRow"
      visible: page.store.signedIn
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
        objectName: "signOutButton"
        focusable: true
        text: FoamyI18n.t("Sign out")
        kind: "destructive"
        busy: page.store.tokenBusy
        onClicked: page.store.signOut()
      }
    }
    // Signed out: the token field and Save token.
    Column {
      objectName: "signedOutForm"
      visible: !page.store.signedIn
      width: parent.width
      spacing: FoamyStyle.gap
      PlainText {
        width: parent.width
        text: FoamyI18n.t("API token")
        color: FoamyPalette.secondaryText
        font.pixelSize: FoamyStyle.font.bodySmall
      }
      SafeTextField {
        id: tokenInput
        objectName: "tokenField"
        width: parent.width
        height: FoamyStyle.controlHeight
        // Dots only; the value is secretText (never drawn, copied or kept in undo).
        masked: true
        maximumLength: 256
        translate: FoamyI18n.t
        Accessible.name: FoamyI18n.t("API token")
        onAccepted: page.saveToken()
        // A refused paste (pasteError, a catalog key) is the newest news:
        // it ends the last token error, so the line says why.
        onPasteErrorChanged: if (pasteError !== "")
          page.store.tokenError = ""
      }
      RowLayout {
        width: parent.width
        spacing: FoamyStyle.gap
        FoamyButton {
          objectName: "saveTokenButton"
          focusable: true
          text: FoamyI18n.t("Save token")
          kind: "primary"
          busy: page.store.tokenBusy
          actionEnabled: tokenInput.secretText.trim() !== "" && page.store.account !== "unavailable"
          onClicked: page.saveToken()
        }
        FoamyButton {
          objectName: "openTodoistSettings"
          focusable: true
          text: FoamyI18n.t("Open Todoist settings")
          iconName: "external-link"
          onClicked: page.store.openUrl(page.settingsUrl)
        }
        Item {
          Layout.fillWidth: true
        }
        // The account check failed (a stored value that isn't a token, a
        // locked or missing keyring, the lock or the cache folder): Sign
        // out removes the cache, then the item. A cache that can't be
        // removed refuses it and keeps both; a locked or missing keyring
        // removes only the cache and refuses it with its own message.
        FoamyButton {
          objectName: "errorSignOutButton"
          visible: page.store.account === "error"
          focusable: true
          text: FoamyI18n.t("Sign out")
          kind: "destructive"
          busy: page.store.tokenBusy
          onClicked: page.store.signOut()
        }
      }
    }
    // Why the token failed, why the token field refused a paste, or why
    // the account can't be used.
    PlainText {
      objectName: "tokenError"
      readonly property string message: page.store.tokenError !== "" ? page.store.tokenError : tokenInput.pasteError !== "" ? FoamyI18n.t(tokenInput.pasteError) : page.store.account === "unavailable" || page.store.account === "error" ? page.store.accountError : ""
      visible: message !== ""
      width: parent.width
      text: message
      color: FoamyPalette.onSurface(FoamyPalette.error)
      font.pixelSize: FoamyStyle.font.bodySmall
      Accessible.role: Accessible.AlertMessage
    }
  }

  FoamySettingsSection {
    width: Math.min(parent.width, page.columnWidth)
    x: (parent.width - width) / 2
    title: FoamyI18n.t("Panel")
    info: FoamyI18n.t("A command to open Todoist links with, for example omarchy-launch-or-focus-webapp Todoist {url}. {url} is replaced with the link; without it, the link is added at the end. No shell: quotes and pipes aren't supported.")
    FoamyDropdown {
      objectName: "panelWidth"
      width: parent.width
      compact: true
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
      objectName: "afterAdd"
      width: parent.width
      compact: true
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
      objectName: "openOn"
      width: parent.width
      compact: true
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
      objectName: "othersTasks"
      width: parent.width
      compact: true
      label: FoamyI18n.t("Tasks assigned to others")
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
    // A command, so full width (DESIGN.md); Preferences.js validates it.
    FoamyTextSettingField {
      objectName: "openCommand"
      width: parent.width
      label: FoamyI18n.t("Open command")
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
    width: Math.min(parent.width, page.columnWidth)
    x: (parent.width - width) / 2
    title: FoamyI18n.t("Bar")
    FoamyDropdown {
      objectName: "barCount"
      width: parent.width
      compact: true
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
    FoamyDropdown {
      objectName: "refreshSeconds"
      width: parent.width
      compact: true
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
}
