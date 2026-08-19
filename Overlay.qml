import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "lib/Format.js" as Fmt

// The full-screen inbox. Summoned with `omarchy-shell shell toggle dev.zavu.inbox`.
// Reads everything from the dev.zavu.inbox service; owns presentation only.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null
  property string omarchyPath: ""

  property bool opened: false
  property int selectedThread: 0
  property string searchText: ""
  property string failureCode: ""
  property string failureMessage: ""

  readonly property var svc: root.service
  readonly property color accent: Fmt.accentFor(Color.menu.background)
  readonly property color fg: Color.menu.text
  readonly property color dim: Qt.darker(Color.menu.text, 1.45)
  readonly property color faint: Qt.darker(Color.menu.text, 1.9)

  // Search results replace the thread list while a query is active. They come
  // back ranked by relevance, not recency, which the scope line says out loud.
  readonly property var threads: root.searchText.length > 0 && svc
    ? svc.searchResults
    : (svc ? svc.conversations : [])

  readonly property var current: (selectedThread >= 0 && selectedThread < threads.length)
    ? threads[selectedThread] : null

  readonly property var messages: (svc && current) ? svc.messagesFor(current.id) : []

  // Only the official WhatsApp channel has a 24-hour window. whatsapp_alt has
  // none, so its composer stays open — deriving this from the thread's channel
  // instead of guessing is what keeps people from being locked out of threads
  // they can actually answer.
  readonly property string currentChannel: current && current.lastMessage ? current.lastMessage.channel : ""
  readonly property var windowMs: {
    if (!current || !Fmt.enforcesWindow(currentChannel)) return null
    var last = null
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].direction === "inbound") { last = messages[i].createdAt; break }
    }
    if (!last && current.lastMessage && current.lastMessage.direction === "inbound")
      last = current.lastMessage.at
    return Fmt.windowRemainingMs(last)
  }
  readonly property bool windowClosed: windowMs !== null && windowMs <= 0

  function open(payloadJson) {
    root.opened = true
    root.failureCode = ""
    if (!svc) return
    svc.viewOpened()
    root.selectedThread = 0
    if (threads.length > 0) svc.loadMessages(threads[0].id)
  }

  function close() {
    root.opened = false
    if (svc) svc.viewClosed()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "dev.zavu.inbox")
  }

  function selectThread(index) {
    if (index < 0 || index >= threads.length) return
    root.selectedThread = index
    root.failureCode = ""
    if (!svc) return
    var t = threads[index]
    svc.loadMessages(t.id)
    if ((t.unreadCount || 0) > 0) svc.markRead(t.id)
  }

  function moveThread(delta) {
    if (threads.length === 0) return
    var next = root.selectedThread + delta
    if (next < 0) next = 0
    if (next > threads.length - 1) next = threads.length - 1
    if (next !== root.selectedThread) selectThread(next)
  }

  function submitReply() {
    if (!svc || !current) return
    var text = composer.text
    if (!text || text.length === 0) return
    if (root.windowClosed) return
    root.failureCode = ""
    svc.sendReply(current, text, null)
    composer.text = ""
  }

  Connections {
    target: root.svc
    ignoreUnknownSignals: true
    function onSendFailed(conversationId, code, message) {
      if (!root.current || conversationId !== root.current.id) return
      root.failureCode = code
      root.failureMessage = message
    }
    function onThreadsUpdated() {
      if (root.threads.length > 0 && root.selectedThread >= root.threads.length)
        root.selectedThread = root.threads.length - 1
    }
  }

  onSearchTextChanged: {
    if (svc) svc.search(root.searchText)
    root.selectedThread = 0
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "zavu-inbox"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: Color.menu.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.close() }

    BorderSurface {
      id: card
      width: Math.min(Style.space(1100), panel.width - Style.gapsOut * 4)
      height: Math.min(Style.space(680), panel.height - Style.gapsOut * 4)
      radius: Style.cornerRadius
      anchors.centerIn: parent
      color: Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        anchors.margins: Style.space(1)
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
          if (event.key === Qt.Key_Escape) {
            if (root.searchText.length > 0) { root.searchText = ""; searchField.text = "" }
            else root.close()
            event.accepted = true
          } else if (event.key === Qt.Key_Slash && !composer.activeFocus && !searchField.activeFocus) {
            searchField.forceActiveFocus()
            event.accepted = true
          } else if ((event.key === Qt.Key_J || event.key === Qt.Key_Down) && !composer.activeFocus && !searchField.activeFocus) {
            root.moveThread(1); event.accepted = true
          } else if ((event.key === Qt.Key_K || event.key === Qt.Key_Up) && !composer.activeFocus && !searchField.activeFocus) {
            root.moveThread(-1); event.accepted = true
          } else if (event.key === Qt.Key_Return && !composer.activeFocus && !searchField.activeFocus) {
            composer.forceActiveFocus(); event.accepted = true
          }
        }

        // ================================================== header
        Item {
          id: header
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: Style.space(38)

          Row {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            spacing: Style.space(12)

            Text {
              text: "ZAVU"
              color: root.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.letterSpacing: 3
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: "inbox"
              color: root.faint
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Row {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            anchors.rightMargin: Style.space(16)
            spacing: Style.space(12)

            Text {
              text: root.svc && root.svc.projectName ? root.svc.projectName : ""
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
            Rectangle {
              visible: root.svc && root.svc.testMode
              width: testLabel.implicitWidth + Style.space(10)
              height: Style.space(16)
              color: "transparent"
              border.width: 1
              border.color: Color.urgent
              anchors.verticalCenter: parent.verticalCenter
              Text {
                id: testLabel
                anchors.centerIn: parent
                text: "TEST"
                color: Color.urgent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
            Text {
              text: root.svc && root.svc.lastSyncAt > 0 ? "synced " + Fmt.ago(root.svc.lastSyncAt) : "—"
              color: root.faint
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }

        Rectangle {
          id: headerRule
          anchors.top: header.bottom
          anchors.left: parent.left; anchors.right: parent.right
          height: 1; color: Color.menu.border; opacity: 0.6
        }

        // ================================================== states
        Item {
          anchors.top: headerRule.bottom
          anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
          visible: !root.svc || root.svc.status !== "ready"

          Column {
            anchors.centerIn: parent
            width: Math.min(Style.space(380), parent.width - Style.space(40))
            spacing: Style.space(12)

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: {
                if (!root.svc) return "◍"
                if (root.svc.status === "needs_login") return "◍"
                if (root.svc.status === "unauthorized") return "⊘"
                if (root.svc.status === "offline") return "⚠"
                return "…"
              }
              color: root.svc && (root.svc.status === "unauthorized" || root.svc.status === "offline")
                     ? Color.urgent : root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.displayLarge
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
              wrapMode: Text.WordWrap
              text: {
                if (!root.svc) return "Starting…"
                if (root.svc.status === "needs_login") return "Not signed in"
                if (root.svc.status === "unauthorized") return "Key rejected"
                if (root.svc.status === "offline") return "Can't reach the API"
                return "Loading…"
              }
              color: root.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
              wrapMode: Text.WordWrap
              text: {
                if (!root.svc) return ""
                if (root.svc.status === "needs_login")
                  return "Sign in through your browser. Zavu creates a key for this machine — nothing to copy or paste."
                return root.svc.errorMessage
              }
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            Button {
            bordered: true
              anchors.horizontalCenter: parent.horizontalCenter
              visible: root.svc && (root.svc.status === "needs_login" || root.svc.status === "unauthorized")
              text: root.svc && root.svc.status === "unauthorized" ? "Sign in again" : "Sign in"
              onClicked: { if (root.svc) root.svc.signIn(); root.close() }
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              visible: root.svc && root.svc.status === "needs_login"
              text: "runs npx zavudev login"
              color: root.faint
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        // ================================================== no accounts
        Item {
          anchors.top: headerRule.bottom
          anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
          visible: root.svc && root.svc.status === "ready" && root.svc.senders.length === 0

          Column {
            anchors.centerIn: parent
            width: Math.min(Style.space(420), parent.width - Style.space(40))
            spacing: Style.space(12)

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "⌁"
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.displayLarge
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "No accounts connected"
              color: root.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
              wrapMode: Text.WordWrap
              text: "This project has no sender that can send or receive yet. Connect WhatsApp, Telegram, Instagram, Messenger, or a phone number to start."
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
            Button {
            bordered: true
              anchors.horizontalCenter: parent.horizontalCenter
              text: "Connect an account"
              onClicked: {
                if (root.svc) root.svc.openUrl(Fmt.accountsUrl(root.svc.locale))
                root.close()
              }
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.svc ? Fmt.accountsUrl(root.svc.locale) : ""
              color: root.faint
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        // ================================================== main
        Item {
          id: body
          anchors.top: headerRule.bottom
          anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
          visible: root.svc && root.svc.status === "ready" && root.svc.senders.length > 0

          // ---------- senders rail ----------
          Item {
            id: rail
            anchors.top: parent.top; anchors.bottom: parent.bottom; anchors.left: parent.left
            width: Style.space(190)

            Column {
              anchors.fill: parent
              anchors.topMargin: Style.space(12)
              spacing: Style.space(2)

              Text {
                text: "SENDERS"
                color: root.faint
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.letterSpacing: 2
                x: Style.space(16)
                bottomPadding: Style.space(6)
              }

              Repeater {
                model: root.svc ? root.svc.senders.length : 0
                Item {
                  required property int index
                  readonly property var sender: root.svc.senders[index]
                  readonly property bool sendable: sender.channels && sender.channels.length > 0

                  width: rail.width
                  height: Style.space(26)

                  Row {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(16)
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(10)
                    spacing: Style.space(6)

                    Text {
                      text: Fmt.elide(sender.name || sender.phoneNumber || sender.emailAddress || "sender", 18)
                      color: sendable ? root.fg : root.faint
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  // A sender with no channels cannot send: say so instead of
                  // letting it look ready. `channels` is computed capability —
                  // a phone number alone enables nothing.
                  Text {
                    visible: !sendable
                    text: "no channels"
                    color: root.faint
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(12)
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }

              Item { width: 1; height: Style.space(10) }

              Button {
            bordered: true
                x: Style.space(12)
                text: "Connect account"
                onClicked: {
                  if (root.svc) root.svc.openUrl(Fmt.accountsUrl(root.svc.locale))
                }
              }
            }
          }

          Rectangle {
            id: railRule
            anchors.left: rail.right; anchors.top: parent.top; anchors.bottom: parent.bottom
            width: 1; color: Color.menu.border; opacity: 0.6
          }

          // ---------- thread list ----------
          Item {
            id: list
            anchors.left: railRule.right; anchors.top: parent.top; anchors.bottom: parent.bottom
            width: Style.space(300)

            // Search sits at the top and is always visible: it asks the API,
            // it is not a filter over what happened to be loaded.
            Item {
              id: searchRow
              anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
              height: Style.space(34)

              TextField {
                id: searchField
                anchors.fill: parent
                anchors.margins: Style.space(8)
                placeholderText: "search threads   /"
                onTextChanged: root.searchText = text
              }
            }

            Rectangle {
              id: searchRule
              anchors.top: searchRow.bottom; anchors.left: parent.left; anchors.right: parent.right
              height: 1; color: Color.menu.border; opacity: 0.6
            }

            Text {
              id: scope
              anchors.top: searchRule.bottom
              anchors.left: parent.left
              anchors.leftMargin: Style.space(14)
              anchors.topMargin: Style.space(6)
              text: {
                if (root.searchText.length === 0) return root.threads.length + " threads"
                if (root.svc && root.svc.searching) return "searching…"
                return root.threads.length + " found · by relevance"
              }
              color: root.faint
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }

            ListView {
              id: threadList
              anchors.top: scope.bottom
              anchors.topMargin: Style.space(6)
              anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
              clip: true
              model: root.threads.length
              currentIndex: root.selectedThread

              delegate: Rectangle {
                required property int index
                readonly property var thread: root.threads[index]
                readonly property bool currentRow: index === root.selectedThread

                width: threadList.width
                height: rowCol.implicitHeight + Style.space(14)
                color: currentRow ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.10) : "transparent"

                Rectangle {
                  visible: parent.currentRow
                  width: Style.space(2); height: parent.height
                  color: root.accent
                  anchors.left: parent.left
                }

                Column {
                  id: rowCol
                  anchors.left: parent.left; anchors.right: parent.right
                  anchors.leftMargin: Style.space(14); anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Row {
                    width: parent.width
                    spacing: Style.space(6)
                    Text {
                      text: Fmt.elide(Fmt.threadTitle(thread), 22)
                      color: root.fg
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
                    Item { width: Math.max(0, parent.width - Style.space(200)); height: 1 }
                    Text {
                      text: Fmt.ago(thread.lastMessage ? thread.lastMessage.at : null)
                      color: root.faint
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Text {
                    width: parent.width
                    text: Fmt.channelGlyph(thread.lastMessage ? thread.lastMessage.channel : "") + "  " +
                          (thread.contactIdentifier || thread.email || "")
                    color: root.faint
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    text: Fmt.preview(thread)
                    color: root.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectThread(index)
                }
              }
            }

            // Nothing found: say it plainly rather than implying the thread
            // does not exist. Search matches identity, never message bodies.
            Column {
              anchors.centerIn: threadList
              width: parent.width - Style.space(40)
              visible: root.threads.length === 0
              spacing: Style.space(6)

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                horizontalAlignment: Text.AlignHCenter
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.searchText.length > 0
                      ? "Nothing matches “" + root.searchText + "”"
                      : "No conversations yet"
                color: root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                horizontalAlignment: Text.AlignHCenter
                width: parent.width
                wrapMode: Text.WordWrap
                visible: root.searchText.length > 0
                text: "Search matches a phone number, email, group name or username — not message text."
                color: root.faint
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          Rectangle {
            id: listRule
            anchors.left: list.right; anchors.top: parent.top; anchors.bottom: parent.bottom
            width: 1; color: Color.menu.border; opacity: 0.6
          }

          // ---------- conversation ----------
          Item {
            id: convPane
            anchors.left: listRule.right; anchors.right: parent.right
            anchors.top: parent.top; anchors.bottom: parent.bottom

            Item {
              id: convHeader
              anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
              height: Style.space(34)
              visible: root.current !== null

              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(16)
                text: root.current ? Fmt.threadTitle(root.current) : ""
                color: root.fg
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }

              Row {
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                anchors.rightMargin: Style.space(16)
                spacing: Style.space(10)

                Text {
                  text: root.currentChannel
                  color: root.faint
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  visible: root.windowMs !== null
                  text: Fmt.windowLabel(root.windowMs)
                  color: root.windowClosed ? Color.urgent : root.faint
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }

            Rectangle {
              id: convRule
              anchors.top: convHeader.bottom
              anchors.left: parent.left; anchors.right: parent.right
              height: 1; color: Color.menu.border; opacity: 0.6
              visible: root.current !== null
            }

            ListView {
              id: messageList
              anchors.top: convRule.bottom
              anchors.left: parent.left; anchors.right: parent.right
              anchors.bottom: composerBox.top
              anchors.margins: Style.space(12)
              clip: true
              spacing: Style.space(8)
              model: root.messages.length
              onCountChanged: positionViewAtEnd()

              delegate: Item {
                required property int index
                readonly property var msg: root.messages[index]
                readonly property bool outbound: msg.direction === "outbound"
                readonly property bool failed: msg.status === "failed"

                width: messageList.width
                height: bubble.height

                BorderSurface {
                  id: bubble
                  width: Math.min(messageList.width * 0.74, bubbleCol.implicitWidth + Style.space(22))
                  height: bubbleCol.implicitHeight + Style.space(14)
                  radius: Style.cornerRadius
                  anchors.right: outbound ? parent.right : undefined
                  anchors.left: outbound ? undefined : parent.left
                  color: outbound ? "transparent" : Color.menu.selectedBackground
                  borderSpec: outbound
                    ? Border.controlSpec(failed ? "selected" : "normal", failed ? Color.urgent : root.fg, root.accent)
                    : Border.controlSpec("normal", "transparent", root.accent)

                  Column {
                    id: bubbleCol
                    anchors.left: parent.left; anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(11); anchors.rightMargin: Style.space(11)
                    spacing: Style.space(4)

                    Text {
                      width: parent.width
                      wrapMode: Text.WordWrap
                      text: msg.text || ("[" + (msg.messageType || "media") + "]")
                      color: root.fg
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                    }

                    // The API's own errorMessage, verbatim. It already tells the
                    // reader what to do; anything we substituted would be worse.
                    Text {
                      visible: failed
                      width: parent.width
                      wrapMode: Text.WordWrap
                      text: (msg.errorCode ? msg.errorCode + " · " : "") + (msg.errorMessage || "Send failed")
                      color: Color.urgent
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      text: {
                        if (msg.__pending) return "sending…"
                        if (failed) return "failed"
                        return (msg.status || "") + " · " + Fmt.ago(msg.createdAt)
                      }
                      color: root.faint
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }
            }

            // ---------- composer ----------
            Item {
              id: composerBox
              anchors.bottom: parent.bottom
              anchors.left: parent.left; anchors.right: parent.right
              height: Style.space(56)
              visible: root.current !== null

              Rectangle {
                anchors.top: parent.top
                anchors.left: parent.left; anchors.right: parent.right
                height: 1; color: Color.menu.border; opacity: 0.6
              }

              // Window closed: do not offer a send that is already known to
              // fail. The template path is the honest next step.
              Row {
                anchors.fill: parent
                anchors.margins: Style.space(12)
                spacing: Style.space(12)
                visible: root.windowClosed

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "window closed · free-form replies are refused on this channel"
                  color: Color.urgent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Item { width: Math.max(0, parent.width - Style.space(430)); height: 1 }
                Button {
            bordered: true
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Open in dashboard"
                  onClicked: {
                    if (root.svc && root.current)
                      root.svc.openUrl(Fmt.conversationUrl(root.svc.locale, root.current.id))
                  }
                }
              }

              TextField {
                id: composer
                visible: !root.windowClosed
                anchors.fill: parent
                anchors.margins: Style.space(12)
                placeholderText: "Reply…   enter to send"
                onAccepted: root.submitReply()
                onActiveFocusChanged: {
                  if (activeFocus && root.svc && root.current) root.svc.showTyping(root.current)
                }
              }
            }

            // Nothing selected yet.
            Text {
              anchors.centerIn: parent
              visible: root.current === null
              text: "Select a thread"
              color: root.faint
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }
        }
      }
    }
  }
}
