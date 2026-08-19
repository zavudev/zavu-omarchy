import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "lib/Format.js" as Fmt

// One glyph in the bar, and a panel with the recent threads and a reply box.
// All state comes from the dev.zavu.inbox service, so this never polls.
Panel {
  id: root
  moduleName: "dev.zavu.inbox"
  // Sin ipcTarget a propósito. La base Panel monta un IpcHandler en cuanto se
  // le da uno, y registrarlo mientras el bar widget se crea dinámicamente
  // (createObject, una instancia por monitor) revienta quickshell con SIGSEGV
  // dentro de IpcHandler::updateRegistration. El widget no necesita ruta IPC
  // propia: se abre con un clic, y el overlay se invoca por el id del plugin.

  readonly property var svc: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("dev.zavu.inbox") : null

  readonly property int unread: svc ? svc.unreadTotal : 0
  readonly property string status: svc ? svc.status : "loading"
  readonly property var threads: svc ? svc.conversations : []

  // Signal Violet, resolved for the active theme rather than pinned.
  readonly property color accent: Fmt.accentFor(Color.bar.background)

  property int selected: 0
  property bool composing: false

  // "threads" | "senders" | "settings" — qué muestra el cuerpo del popover.
  property string mode: "threads"

  readonly property string senderFilterName: {
    if (!svc || !svc.senderFilter) return "All senders"
    for (var i = 0; i < svc.senders.length; i++)
      if (svc.senders[i].id === svc.senderFilter)
        return svc.senders[i].name || svc.senders[i].phoneNumber || "sender"
    return "sender"
  }

  // `omarchy bar set` sin --json guarda cadenas, y "false" es verdadero en JS:
  // sin esto, apagar las notificaciones las dejaría encendidas.
  function boolSetting(name, fallback) {
    var v = setting(name, fallback)
    if (typeof v === "string") return v === "true"
    return v === true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Se aplican en cada cambio, no sólo al arrancar: shell.json recarga en
  // caliente, así que apagar las notificaciones en los ajustes debe surtir
  // efecto ya, sin reiniciar el shell.
  function applySettings() {
    if (!svc) return
    svc.pollSeconds = Number(setting("pollSeconds", 10))
    svc.notify = boolSetting("notify", true)
    svc.locale = String(setting("locale", "en"))
    svc.threadLimit = Number(setting("threadLimit", 25))
    svc.messageLimit = Number(setting("messageLimit", 25))
  }

  Component.onCompleted: applySettings()
  onSettingsChanged: applySettings()

  onOpenedChanged: {
    if (!svc) return
    if (opened) {
      selected = 0
      composing = false
      mode = "threads"
      svc.viewOpened()
      if (threads.length > 0) svc.loadMessages(threads[0].id)
    } else {
      svc.viewClosed()
    }
  }

  function currentThread() {
    return (selected >= 0 && selected < threads.length) ? threads[selected] : null
  }

  function move(delta) {
    if (threads.length === 0) return
    var next = selected + delta
    if (next < 0) next = 0
    if (next > threads.length - 1) next = threads.length - 1
    if (next === selected) return
    selected = next
    if (svc) svc.loadMessages(threads[selected].id)
  }

  function openInbox() {
    root.close()
    if (bar && bar.shell && typeof bar.shell.summon === "function")
      bar.shell.summon("dev.zavu.inbox", "{}")
  }

  function sendCurrent(text) {
    var t = currentThread()
    if (!t || !svc || !text || text.length === 0) return
    svc.sendReply(t, text, null)
    svc.markRead(t.id)
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰭹"
    active: root.opened
    tooltipText: {
      if (root.status === "needs_login") return "Zavu — not signed in"
      if (root.status === "unauthorized") return "Zavu — key rejected"
      if (root.status === "offline") return "Zavu — can't reach the API"
      return root.unread > 0 ? "Zavu — " + root.unread + " unread" : "Zavu Inbox"
    }
    // A signed-out or broken client recedes rather than shouting: nothing has
    // gone wrong for the user yet, they just have not connected it.
    opacity: (root.status === "ready" || root.unread > 0) ? 1.0 : 0.55

    onPressed: function (b) { root.toggle() }

    // Unread marker. Violet, never red — red is the failure colour and this is
    // not a failure. The count only appears past one, so a normal day is quiet.
    Rectangle {
      visible: root.unread > 0
      width: root.unread > 1 ? countLabel.implicitWidth + Style.space(6) : Style.space(6)
      height: Style.space(6)
      radius: height / 2
      color: root.accent
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: Style.space(3)
      anchors.topMargin: Style.space(4)

      Text {
        id: countLabel
        anchors.centerIn: parent
        visible: root.unread > 1
        text: root.unread > 99 ? "99+" : String(root.unread)
        color: Color.bar.background
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    // Error pip, in the theme's own urgent colour.
    Rectangle {
      visible: root.status === "unauthorized" || root.status === "offline"
      width: Style.space(5); height: Style.space(5); radius: width / 2
      color: Color.urgent
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.rightMargin: Style.space(3)
      anchors.bottomMargin: Style.space(4)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent

      onMoveRequested: function (dx, dy) { if (dy !== 0) root.move(dy) }
      onActivateRequested: root.openInbox()
      onCloseRequested: root.close()
      onTabRequested: function (d) { root.switchPanel(d) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        // ---------- header: sender · refresh · settings ----------
        Row {
          width: parent.width
          spacing: Style.space(8)

          Text {
            text: "ZAVU"
            color: root.bar ? root.bar.foreground : Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.letterSpacing: 2
            anchors.verticalCenter: parent.verticalCenter
          }

          // Selector de sender. Filtra por la API, no la página descargada.
          Text {
            id: senderChip
            text: Fmt.elide(root.senderFilterName, 16) + "  ▾"
            color: root.mode === "senders" ? root.accent
                                           : Qt.darker(root.bar ? root.bar.foreground : Color.popups.text, 1.3)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter

            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              cursorShape: Qt.PointingHandCursor
              onClicked: root.mode = root.mode === "senders" ? "threads" : "senders"
            }
          }

          Item {
            width: Math.max(0, parent.width - senderChip.width - Style.space(120))
            height: 1
          }

          Text {
            visible: root.svc && root.svc.testMode
            text: "TEST"
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: refreshGlyph
            text: root.svc && root.svc.refreshing ? "󰑐" : "󰑓"
            color: root.svc && root.svc.refreshing ? root.accent
                                                   : Qt.darker(root.bar ? root.bar.foreground : Color.popups.text, 1.3)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter

            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (root.svc) root.svc.refreshNow(root.currentThread() ? root.currentThread().id : "")
              }
            }
          }

          Text {
            id: gearGlyph
            text: "󰒓"
            color: root.mode === "settings" ? root.accent
                                            : Qt.darker(root.bar ? root.bar.foreground : Color.popups.text, 1.3)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter

            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              cursorShape: Qt.PointingHandCursor
              onClicked: root.mode = root.mode === "settings" ? "threads" : "settings"
            }
          }
        }

        PanelSeparator { width: parent.width }

        // ---------- signed out ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.status === "needs_login"

          Text {
            text: "Not signed in"
            color: root.bar ? root.bar.foreground : Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Sign in through your browser. Zavu creates a key for this machine — nothing to copy or paste."
            color: Qt.darker(root.bar ? root.bar.foreground : Color.popups.text, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
          Button {
            bordered: true
            text: "Sign in"
            onClicked: { if (root.svc) root.svc.signIn(); root.close() }
          }
          Text {
            text: "runs npx zavudev login"
            color: Qt.darker(root.bar ? root.bar.foreground : Color.popups.text, 1.8)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- error ----------
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.status === "unauthorized" || root.status === "offline"

          Text {
            text: root.status === "unauthorized" ? "Key rejected" : "Can't reach the API"
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.svc ? root.svc.errorMessage : ""
            color: Qt.darker(root.bar ? root.bar.foreground : Color.popups.text, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
          Button {
            bordered: true
            visible: root.status === "unauthorized"
            text: "Sign in again"
            onClicked: { if (root.svc) root.svc.signIn(); root.close() }
          }
        }

        // ---------- no accounts ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.status === "ready" && root.svc && root.svc.senders.length === 0

          Text {
            text: "No accounts connected"
            color: root.bar ? root.bar.foreground : Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Connect WhatsApp, Telegram, Instagram, Messenger or a phone number to start receiving messages."
            color: Qt.darker(root.bar ? root.bar.foreground : Color.popups.text, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
          Button {
            bordered: true
            text: "Connect an account"
            onClicked: {
              if (root.svc) root.svc.openUrl(Fmt.accountsUrl(root.svc.locale))
              root.close()
            }
          }
        }

        // ---------- no conversations ----------
        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          visible: root.status === "ready" && root.svc && root.svc.senders.length > 0 && root.threads.length === 0
          text: "No conversations yet. Threads appear here the moment someone writes to one of your numbers."
          color: Qt.darker(root.bar ? root.bar.foreground : Color.popups.text, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        // ---------- senders (filtro) ----------
        Column {
          width: parent.width
          spacing: Style.space(1)
          visible: root.mode === "senders"

          Rectangle {
            width: parent.width
            height: Style.space(24)
            color: (root.svc && !root.svc.senderFilter)
                   ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.10) : "transparent"
            Text {
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.leftMargin: Style.space(8)
              text: "All senders"
              color: root.bar ? root.bar.foreground : Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: { if (root.svc) root.svc.setSenderFilter(""); root.mode = "threads" }
            }
          }

          Repeater {
            model: root.svc ? root.svc.senders.length : 0
            Rectangle {
              required property int index
              readonly property var sender: root.svc.senders[index]
              readonly property bool sendable: sender.channels && sender.channels.length > 0
              readonly property bool active: root.svc.senderFilter === sender.id

              width: parent.width
              height: Style.space(24)
              color: active ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.10) : "transparent"

              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(70)
                elide: Text.ElideRight
                text: sender.name || sender.phoneNumber || sender.emailAddress || "sender"
                color: sendable ? (root.bar ? root.bar.foreground : Color.popups.text)
                                : Qt.darker(root.bar ? root.bar.foreground : Color.popups.text, 1.9)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                visible: !sendable
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                text: "no channels"
                color: Qt.darker(root.bar ? root.bar.foreground : Color.popups.text, 1.9)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { if (root.svc) root.svc.setSenderFilter(sender.id); root.mode = "threads" }
              }
            }
          }
        }

        // ---------- ajustes rápidos ----------
        // Cada fila escribe de verdad en shell.json vía `omarchy bar set`, y
        // vuelve por onSettingsChanged. Nada de interruptores decorativos.
        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: root.mode === "settings"

          Repeater {
            model: [
              { key: "notify",       label: "Notifications",     kind: "bool" },
              { key: "pollSeconds",  label: "Refresh every",     kind: "cycle", values: [5, 10, 30, 60], suffix: "s" },
              { key: "threadLimit",  label: "Threads / refresh", kind: "cycle", values: [10, 25, 50] },
              { key: "messageLimit", label: "Messages / thread", kind: "cycle", values: [10, 25, 50] }
            ]

            Rectangle {
              required property int index
              readonly property var row: [
                { key: "notify",       label: "Notifications",     kind: "bool", values: [], suffix: "" },
                { key: "pollSeconds",  label: "Refresh every",     kind: "cycle", values: [5, 10, 30, 60], suffix: "s" },
                { key: "threadLimit",  label: "Threads / refresh", kind: "cycle", values: [10, 25, 50], suffix: "" },
                { key: "messageLimit", label: "Messages / thread", kind: "cycle", values: [10, 25, 50], suffix: "" }
              ][index]

              readonly property var currentValue: row.kind === "bool"
                ? root.boolSetting(row.key, true)
                : Number(root.setting(row.key, row.values[1]))

              width: parent.width
              height: Style.space(26)
              color: "transparent"

              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                text: row.label
                color: root.bar ? root.bar.foreground : Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                text: row.kind === "bool"
                      ? (currentValue ? "on" : "off")
                      : String(currentValue) + row.suffix
                color: row.kind === "bool" && !currentValue
                       ? Qt.darker(root.bar ? root.bar.foreground : Color.popups.text, 1.9)
                       : root.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (!root.svc) return
                  if (row.kind === "bool") {
                    root.svc.setSetting(row.key, !currentValue)
                    return
                  }
                  var vals = row.values
                  var i = vals.indexOf(currentValue)
                  root.svc.setSetting(row.key, vals[(i + 1) % vals.length])
                }
              }
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Saved to shell.json. Turning notifications off keeps the unread dot in the bar."
            color: Qt.darker(root.bar ? root.bar.foreground : Color.popups.text, 1.9)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            topPadding: Style.space(6)
          }
        }

        // ---------- threads ----------
        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: root.mode === "threads" && root.threads.length > 0

          Repeater {
            model: Math.min(6, root.threads.length)

            Rectangle {
              required property int index
              readonly property var thread: root.threads[index]
              readonly property bool current: index === root.selected

              width: parent.width
              height: threadCol.implicitHeight + Style.space(10)
              color: current ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.10) : "transparent"

              Rectangle {
                visible: parent.current
                width: Style.space(2); height: parent.height
                color: root.accent
                anchors.left: parent.left
              }

              Column {
                id: threadCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(1)

                Row {
                  width: parent.width
                  spacing: Style.space(6)

                  Text {
                    text: Fmt.elide(Fmt.threadTitle(thread), 24)
                    color: root.bar ? root.bar.foreground : Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    font.bold: (thread.unreadCount || 0) > 0
                  }
                  Rectangle {
                    visible: (thread.unreadCount || 0) > 0
                    width: Style.space(5); height: Style.space(5); radius: width / 2
                    color: root.accent
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Item { width: Math.max(0, parent.width - Style.space(190)); height: 1 }
                  Text {
                    text: Fmt.ago(thread.lastMessage ? thread.lastMessage.at : null)
                    color: Qt.darker(root.bar ? root.bar.foreground : Color.popups.text, 1.7)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }

                Text {
                  width: parent.width
                  text: Fmt.channelGlyph(thread.lastMessage ? thread.lastMessage.channel : "") + "  " +
                        Fmt.elide(Fmt.preview(thread), 42)
                  color: Qt.darker(root.bar ? root.bar.foreground : Color.popups.text, 1.5)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.selected = index
                  if (root.svc) root.svc.loadMessages(thread.id)
                  root.composing = true
                  replyField.forceActiveFocus()
                }
              }
            }
          }
        }

        // ---------- reply ----------
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.mode === "threads" && root.threads.length > 0

          PanelSeparator { width: parent.width }

          TextField {
            id: replyField
            width: parent.width
            placeholderText: {
              var t = root.currentThread()
              return t ? "Reply to " + Fmt.elide(Fmt.threadTitle(t), 18) + "…" : "Reply…"
            }
            onAccepted: {
              root.sendCurrent(text)
              text = ""
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(10)

            Text {
              text: "enter to send"
              color: Qt.darker(root.bar ? root.bar.foreground : Color.popups.text, 1.8)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Item { width: Math.max(0, parent.width - Style.space(180)); height: 1 }
            Text {
              text: root.svc && root.svc.lastSyncAt > 0
                    ? "synced " + Fmt.ago(root.svc.lastSyncAt)
                    : ""
              color: Qt.darker(root.bar ? root.bar.foreground : Color.popups.text, 1.8)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        PanelSeparator { width: parent.width; visible: root.threads.length > 0 }

        Button {
          bordered: true
          visible: root.mode === "threads" && root.threads.length > 0
          text: "Open inbox"
          onClicked: root.openInbox()
        }
      }
    }
  }
}
