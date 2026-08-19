import QtQuick
import Quickshell
import Quickshell.Io
import "lib/Api.js" as Api

// The one thing that talks to api.zavu.dev.
//
// Both surfaces (bar widget and overlay) read from here through
// `shell.serviceFor("dev.zavu.inbox")`, so there is a single poll loop, a
// single cache and a single place where auth can go wrong — rather than two
// widgets racing each other for the same rate limit.
QtObject {
  id: root

  property var shell: null
  property var manifest: null

  // ---------------------------------------------------------------- settings
  property int pollSeconds: 30
  property bool notify: true
  property string locale: "en"

  // Cuánto se pide en cada llamada. Bajo a propósito: la lista de hilos se
  // sondea sin parar y el historial de un chat se lee de una sentada. Pedir 50
  // de cada cosa era mover mucho JSON por algo que casi nunca se mira entero.
  property int threadLimit: 25
  property int messageLimit: 25

  // Filtro por sender. Va como `senderId` a la API en vez de filtrar la página
  // ya descargada: filtrar en local enseñaría "no hay nada" para un número cuyos
  // hilos simplemente no entraron en los primeros 25.
  property string senderFilter: ""

  /**
   * Escribe un ajuste del widget en shell.json a través del CLI de Omarchy.
   * `--json` para que un booleano se guarde como booleano y no como la cadena
   * "false", que es verdadera en JS y haría que apagar algo lo dejara encendido.
   * shell.json recarga en caliente, así que el cambio vuelve por onSettingsChanged.
   */
  function setSetting(key, value) {
    root.run("omarchy bar set dev.zavu.inbox " + key + " " + JSON.stringify(value) + " --json")
  }

  // ------------------------------------------------------------------- state
  //
  // `status` is the whole story for the UI, so every surface renders the same
  // thing for the same condition instead of inventing its own empty state.
  //   loading | needs_login | unauthorized | offline | rate_limited | ready
  property string status: "loading"
  property string errorMessage: ""

  property string apiKey: ""
  property string baseUrl: "https://api.zavu.dev"
  property bool testMode: false
  property string projectName: ""
  property string teamName: ""

  property var senders: []
  property var conversations: []
  property int unreadTotal: 0
  property double lastSyncAt: 0
  property int rateRemaining: -1

  // Per-conversation message cache: { convId: [messages...] }
  property var messagesByConversation: ({})
  property string loadingConversationId: ""

  // Raised while a surface is open so polling speeds up; dropped when it closes.
  property int activeViewers: 0

  readonly property bool hasCredentials: apiKey.length > 0
  readonly property bool sendable: status === "ready" || status === "rate_limited"

  // Nombres deliberadamente distintos de las propiedades: QML ya genera
  // `conversationsChanged` para `property var conversations`, y declarar una
  // señal con ese nombre impide que el componente cargue.
  signal threadsUpdated()
  signal threadMessagesUpdated(string conversationId)
  signal inboundArrived(string conversationId, string title, string text)
  signal sendFailed(string conversationId, string code, string message)

  function cfg() { return { apiKey: root.apiKey, baseUrl: root.baseUrl } }

  // ------------------------------------------------------------ credentials
  //
  // Read, never written: `npx zavudev login` owns this file. Watching it means
  // the bar wakes up the moment the user finishes signing in, with no restart
  // and no "reload plugins" step.
  property FileView credentialsFile: FileView {
    path: Quickshell.env("HOME") + "/.zavu/credentials.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyCredentials(text())
    onFileChanged: reload()
    onLoadFailed: root.applyCredentials("")
  }

  function applyCredentials(raw) {
    // Environment wins over the file, matching the CLI's own resolveCredentials
    // so a container or a coding agent behaves the same way here.
    var envKey = Quickshell.env("ZAVUDEV_API_KEY")
    if (envKey && String(envKey).length > 0) {
      root.apiKey = String(envKey)
      var envBase = Quickshell.env("ZAVUDEV_API_BASE_URL")
      root.baseUrl = envBase && String(envBase).length > 0 ? String(envBase) : "https://api.zavu.dev"
      root.bootstrap()
      return
    }

    var parsed = null
    try { parsed = raw ? JSON.parse(raw) : null } catch (e) { parsed = null }

    if (!parsed || !parsed.apiKey) {
      root.apiKey = ""
      root.status = "needs_login"
      root.errorMessage = ""
      return
    }

    root.apiKey = String(parsed.apiKey)
    // Never hardcode the host: the dashboard reports its own API origin through
    // the CLI callback, so a local dev stack works exactly like production.
    root.baseUrl = parsed.apiBaseUrl ? String(parsed.apiBaseUrl) : "https://api.zavu.dev"
    root.testMode = root.apiKey.indexOf("zv_test_") === 0
    root.bootstrap()
  }

  /** Launch the real CLI. One auth path for the whole product, not a second one. */
  function signIn() {
    root.run("$TERMINAL -e bash -lc 'npx zavudev@latest login; echo; read -n 1 -s -r -p \"Press any key…\"'")
  }

  function run(command) {
    if (root.shell && typeof root.shell.run === "function") { root.shell.run(command); return }
    launcher.exec(["bash", "-lc", command])
  }

  function openUrl(url) { root.run("xdg-open " + JSON.stringify(url)) }

  property Process launcher: Process { }
  property Process notifier: Process { }

  // ------------------------------------------------------------------ boot
  function bootstrap() {
    if (!root.hasCredentials) { root.status = "needs_login"; return }
    root.status = "loading"
    Api.me(root.cfg(), function (err, data) {
      if (err) { root.applyError(err); return }
      root.projectName = data && data.project ? (data.project.name || "") : ""
      root.teamName = data && data.team ? (data.team.name || "") : ""
      root.testMode = !!(data && data.isTestMode)
      root.loadSenders()
    })
  }

  function loadSenders() {
    Api.senders(root.cfg(), function (err, data) {
      if (err) { root.applyError(err); return }
      root.senders = (data && data.items) ? data.items : []
      root.refresh()
    })
  }

  function applyError(err) {
    root.errorMessage = err.message || "Unknown error"
    if (err.kind === "unauthorized") root.status = "unauthorized"
    else if (err.kind === "offline") root.status = "offline"
    else if (err.kind === "rate_limited") root.status = "rate_limited"
    else root.status = "offline"
  }

  // --------------------------------------------------------------- polling
  property var _inflight: null
  property var _seenLastMessage: ({})
  property bool _primed: false

  function refresh() {
    if (!root.hasCredentials) return
    Api.abort(root._inflight)
    root._inflight = Api.conversations(root.cfg(), { limit: root.threadLimit, senderId: root.senderFilter || undefined }, function (err, data, meta) {
      root._inflight = null
      if (meta && isFinite(meta.rateRemaining)) root.rateRemaining = meta.rateRemaining
      if (err) { root.applyError(err); return }

      var items = (data && data.items) ? data.items : []
      root.detectInbound(items)
      root.conversations = items

      var unread = 0
      for (var i = 0; i < items.length; i++) unread += (items[i].unreadCount || 0)
      root.unreadTotal = unread

      root.status = "ready"
      root.errorMessage = ""
      root.lastSyncAt = Date.now()
      root.threadsUpdated()
    })
  }

  /**
   * A thread is "new activity" when its last message id changed and that
   * message came inbound. Comparing ids rather than timestamps means our own
   * replies do not notify us, and a redelivered poll does not double-notify.
   *
   * The first successful poll only primes the map: otherwise every thread in
   * the account would fire a notification the moment the shell starts.
   */
  function detectInbound(items) {
    var next = ({})
    for (var i = 0; i < items.length; i++) {
      var c = items[i]
      var last = c.lastMessage || {}
      next[c.id] = last.id || ""

      if (!root._primed) continue
      if (root._seenLastMessage[c.id] === next[c.id]) continue
      if (last.direction !== "inbound") continue

      root.inboundArrived(c.id, root.titleOf(c), String(last.text || ""))
      if (root.notify && root.activeViewers === 0) root.notifyDesktop(c, last)
    }
    root._seenLastMessage = next
    root._primed = true
  }

  function titleOf(c) {
    if (!c) return ""
    if (c.group && c.group.subject) return c.group.subject
    return c.profileName || c.email || c.contactIdentifier || "unknown"
  }

  function notifyDesktop(c, last) {
    var title = root.titleOf(c)
    var body = String(last.text || "").slice(0, 160)
    notifier.exec(["notify-send", "-a", "Zavu", "-i", "mail-message-new", title, body])
  }

  /**
   * Poll cadence, in order of precedence:
   *   rate limited     — back off hard, the API told us to
   *   a surface is open — 3s, someone is watching a conversation
   *   signed out/error  — 30s, just enough to notice it got fixed
   *   otherwise         — the user's setting
   */
  readonly property int currentInterval: {
    if (root.status === "rate_limited") return 60000
    if (root.rateRemaining >= 0 && root.rateRemaining < 60) return 30000
    if (root.activeViewers > 0) return 3000
    if (!root.hasCredentials) return 3000
    if (root.status === "unauthorized") return 30000
    if (root.status === "offline") return 15000
    return Math.max(3, root.pollSeconds) * 1000
  }

  property Timer poller: Timer {
    interval: root.currentInterval
    repeat: true
    running: true
    onTriggered: {
      // Sin credenciales el trabajo es re-leer el fichero, no rendirse.
      //
      // `watchChanges` vigila un inodo, y cuando el usuario aún no ha hecho
      // login ese fichero no existe: `zavudev login` lo CREA, y esa creación no
      // llega como cambio. Sin este reintento el plugin se queda en "Not signed
      // in" para siempre aunque el login haya ido bien — que es exactamente lo
      // que pasó la primera vez que se probó.
      if (!root.hasCredentials) { root.credentialsFile.reload(); return }
      if (root.status === "unauthorized") return
      root.refresh()
    }
  }

  // ------------------------------------------------------------- messages
  function loadMessages(conversationId) {
    if (!conversationId || !root.hasCredentials) return
    root.loadingConversationId = conversationId
    Api.conversationMessages(root.cfg(), conversationId, { limit: root.messageLimit }, function (err, data) {
      root.loadingConversationId = ""
      if (err) { root.applyError(err); return }
      var items = (data && data.items) ? data.items.slice().reverse() : []
      var next = ({})
      for (var k in root.messagesByConversation) next[k] = root.messagesByConversation[k]
      next[conversationId] = items
      root.messagesByConversation = next
      root.threadMessagesUpdated(conversationId)
    })
  }

  function messagesFor(conversationId) {
    return root.messagesByConversation[conversationId] || []
  }

  function markRead(conversationId) {
    if (!conversationId || !root.hasCredentials) return
    Api.markRead(root.cfg(), conversationId, function (err) { if (!err) root.refresh() })
  }

  /**
   * Send, optimistically.
   *
   * POST /v1/messages answers 202 and queues: delivery, failure and the reason
   * all land on the message record later. So the bubble goes in as `pending`
   * and only a later poll can promote it — showing a checkmark here would be
   * inventing an outcome the API has not given us.
   */
  function sendReply(conversation, text, channelOverride) {
    if (!conversation || !text || text.length === 0) return
    var senderId = conversation.senderId || ""
    var to = conversation.group && conversation.group.id
      ? conversation.group.id
      : (conversation.contactIdentifier || conversation.email || "")

    var payload = Api.send(root.cfg(), senderId, to, text, channelOverride)
    var pending = {
      id: "pending_" + payload.idempotencyKey,
      text: text,
      direction: "outbound",
      status: "pending",
      channel: channelOverride || (conversation.lastMessage ? conversation.lastMessage.channel : ""),
      createdAt: new Date().toISOString(),
      __pending: true
    }
    root.appendLocal(conversation.id, pending)

    Api.sendMessage(root.cfg(), senderId, payload, function (err, data) {
      if (err) {
        root.replacePending(conversation.id, pending.id, {
          id: pending.id, text: text, direction: "outbound", status: "failed",
          errorCode: err.code, errorMessage: err.message,
          createdAt: pending.createdAt, __pending: false
        })
        root.sendFailed(conversation.id, err.code || "error", err.message || "Send failed")
        return
      }
      var msg = data && data.message ? data.message : null
      if (msg) root.replacePending(conversation.id, pending.id, msg)
      root.watchMessage(conversation.id, msg ? msg.id : "")
      root.refresh()
    })
  }

  /**
   * A 202 only means accepted. The 24-hour window, a bad recipient and a
   * suppressed address all fail afterwards, so poll the message a few times to
   * catch the real outcome and print the API's own errorMessage on the bubble.
   */
  function watchMessage(conversationId, messageId) {
    if (!messageId) return
    watcher.conversationId = conversationId
    watcher.messageId = messageId
    watcher.attempts = 0
    watcher.restart()
  }

  property Timer watcher: Timer {
    property string conversationId: ""
    property string messageId: ""
    property int attempts: 0
    interval: 2000
    repeat: true
    onTriggered: {
      attempts += 1
      if (attempts > 6 || messageId === "") { stop(); return }
      Api.message(root.cfg(), messageId, function (err, data) {
        if (err) return
        var m = data && data.message ? data.message : null
        if (!m) return
        root.replacePending(watcher.conversationId, m.id, m)
        if (m.status === "failed") {
          root.sendFailed(watcher.conversationId, m.errorCode || "SEND_ERROR",
                          m.errorMessage || "The message could not be sent.")
          watcher.stop()
        } else if (m.status === "delivered" || m.status === "read" || m.status === "sent") {
          watcher.stop()
        }
      })
    }
  }

  function appendLocal(conversationId, message) {
    var list = (root.messagesByConversation[conversationId] || []).slice()
    list.push(message)
    var next = ({})
    for (var k in root.messagesByConversation) next[k] = root.messagesByConversation[k]
    next[conversationId] = list
    root.messagesByConversation = next
    root.threadMessagesUpdated(conversationId)
  }

  function replacePending(conversationId, pendingId, message) {
    var list = (root.messagesByConversation[conversationId] || []).slice()
    var replaced = false
    for (var i = 0; i < list.length; i++) {
      if (list[i].id === pendingId) { list[i] = message; replaced = true; break }
    }
    if (!replaced) list.push(message)
    var next = ({})
    for (var k in root.messagesByConversation) next[k] = root.messagesByConversation[k]
    next[conversationId] = list
    root.messagesByConversation = next
    root.threadMessagesUpdated(conversationId)
  }

  /** Typing indicator on the contact's phone, for inbound WhatsApp only. */
  function showTyping(conversation) {
    if (!conversation || !conversation.senderId) return
    var msgs = root.messagesFor(conversation.id)
    for (var i = msgs.length - 1; i >= 0; i--) {
      var m = msgs[i]
      if (m.direction === "inbound" && (m.channel === "whatsapp")) {
        Api.typing(root.cfg(), conversation.senderId, m.id, function () {})
        return
      }
    }
  }

  // ---------------------------------------------------------------- search
  property var searchResults: []
  property string searchQuery: ""
  property bool searching: false
  property var _searchInflight: null

  function search(query) {
    root.searchQuery = query
    Api.abort(root._searchInflight)
    if (!query || query.length === 0) {
      root.searchResults = []
      root.searching = false
      return
    }
    root.searching = true
    root._searchInflight = Api.conversations(root.cfg(), { search: query, limit: root.threadLimit }, function (err, data) {
      root._searchInflight = null
      root.searching = false
      if (err) { root.searchResults = []; return }
      root.searchResults = (data && data.items) ? data.items : []
    })
  }

  /**
   * Refresco a petición del usuario. Además de la lista, recarga los mensajes
   * del hilo abierto — que es lo que el sondeo NO hace: el tick sólo trae los
   * hilos, así que un chat abierto no ve llegar nada hasta que se re-selecciona.
   */
  property bool refreshing: false
  function refreshNow(conversationId) {
    if (!root.hasCredentials) { root.credentialsFile.reload(); return }
    root.refreshing = true
    root.refresh()
    if (conversationId) root.loadMessages(conversationId)
    refreshDone.restart()
  }

  // Sólo apaga el indicador; el trabajo real lo hacen los callbacks. Sin
  // setTimeout en este motor, un Timer es la forma de dar el respiro visual.
  property Timer refreshDone: Timer {
    interval: 600
    onTriggered: root.refreshing = false
  }

  function setSenderFilter(senderId) {
    if (root.senderFilter === senderId) return
    root.senderFilter = senderId
    root.refresh()
  }

  function viewOpened() { root.activeViewers += 1; root.refresh() }
  function viewClosed() { root.activeViewers = Math.max(0, root.activeViewers - 1) }
}
