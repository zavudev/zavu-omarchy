.pragma library

// Zavu REST client for the Quickshell JS engine.
//
// Not the npm SDK: that one is built on fetch / Headers / AbortController and a
// module loader, none of which exist here (Qt 6 gives us XMLHttpRequest, no
// fetch, no setTimeout, no crypto). This is ~10 endpoints over XHR, which is
// less code than the shims the SDK would need.
//
// Callbacks rather than Promises on purpose: a rejected Promise in the shell
// process is swallowed with no stack, and every caller here wants the error
// anyway. Signature is always `done(err, data, meta)`.

var DEFAULT_BASE = "https://api.zavu.dev"

function _qs(params) {
  var parts = []
  for (var k in params) {
    var v = params[k]
    if (v === undefined || v === null || v === "") continue
    parts.push(encodeURIComponent(k) + "=" + encodeURIComponent(String(v)))
  }
  return parts.length ? "?" + parts.join("&") : ""
}

/**
 * One request. Returns the XHR so the caller can abort it — we have no
 * AbortController and no setTimeout, so timeouts are a QML Timer calling
 * `.abort()` on this object.
 *
 * `meta` carries the rate-limit headers the API already sends, so the poll
 * loop can back off instead of finding out by getting a 429.
 */
function request(cfg, method, path, params, body, done) {
  var base = (cfg && cfg.baseUrl ? cfg.baseUrl : DEFAULT_BASE).replace(/\/+$/, "")
  var url = base + path + _qs(params || {})
  var xhr = new XMLHttpRequest()

  xhr.open(method, url)
  xhr.setRequestHeader("Authorization", "Bearer " + (cfg ? cfg.apiKey : ""))
  xhr.setRequestHeader("Accept", "application/json")
  if (body) xhr.setRequestHeader("Content-Type", "application/json")
  if (cfg && cfg.senderId) xhr.setRequestHeader("Zavu-Sender", cfg.senderId)

  xhr.onreadystatechange = function () {
    if (xhr.readyState !== XMLHttpRequest.DONE) return
    if (xhr.__aborted) return

    var meta = {
      status: xhr.status,
      rateRemaining: Number(xhr.getResponseHeader("X-RateLimit-Remaining")),
      rateReset: Number(xhr.getResponseHeader("X-RateLimit-Reset"))
    }

    // status 0 is the shape every transport failure takes here: DNS, TLS,
    // no route, aborted. It is not an API error and must not be shown as one.
    if (xhr.status === 0) {
      done({ kind: "offline", message: "Can't reach " + base }, null, meta)
      return
    }

    var payload = null
    try { payload = xhr.responseText ? JSON.parse(xhr.responseText) : null }
    catch (e) { payload = null }

    if (xhr.status >= 200 && xhr.status < 300) {
      done(null, payload, meta)
      return
    }

    // The API answers errors as {code, message}. Pass both through verbatim —
    // its message is written for the person reading it and is more useful than
    // anything we could invent here.
    done({
      kind: xhr.status === 401 ? "unauthorized" : xhr.status === 429 ? "rate_limited" : "api",
      status: xhr.status,
      code: payload && payload.code ? payload.code : String(xhr.status),
      message: payload && payload.message ? payload.message : "Request failed (" + xhr.status + ")"
    }, null, meta)
  }

  xhr.send(body ? JSON.stringify(body) : null)
  return xhr
}

function abort(xhr) {
  if (!xhr) return
  xhr.__aborted = true
  try { xhr.abort() } catch (e) { /* already finished */ }
}

// ------------------------------------------------------------------ endpoints

function me(cfg, done) {
  return request(cfg, "GET", "/v1/me", null, null, done)
}

function senders(cfg, done) {
  return request(cfg, "GET", "/v1/senders", { limit: 100 }, null, done)
}

/**
 * `search` matches thread identity (phone in any format, email, group subject,
 * WhatsApp username, BSUID) — never message bodies. Results come back ranked by
 * relevance, so the recency order does not hold while it is set.
 */
function conversations(cfg, opts, done) {
  opts = opts || {}
  return request(cfg, "GET", "/v1/conversations", {
    limit: opts.limit || 50,
    cursor: opts.cursor,
    channel: opts.channel,
    senderId: opts.senderId,
    search: opts.search
  }, null, done)
}

function conversationMessages(cfg, conversationId, opts, done) {
  opts = opts || {}
  return request(cfg, "GET", "/v1/conversations/" + conversationId + "/messages",
    { limit: opts.limit || 50, cursor: opts.cursor }, null, done)
}

function markRead(cfg, conversationId, done) {
  return request(cfg, "POST", "/v1/conversations/" + conversationId + "/read", null, null, done)
}

/**
 * Reply in a thread. `senderId` goes on the header so the answer leaves from
 * the number the contact already knows.
 *
 * No crypto and no Qt.createUuid here, so the idempotency key is time plus
 * randomness. It only has to be unique per send, not unguessable.
 */
function send(cfg, senderId, to, text, channel) {
  var payload = { to: to, text: text }
  if (channel) payload.channel = channel
  payload.idempotencyKey = "omarchy_" + Date.now() + "_" + Math.floor(Math.random() * 1e9)
  return payload
}

function sendMessage(cfg, senderId, payload, done) {
  var c = { apiKey: cfg.apiKey, baseUrl: cfg.baseUrl, senderId: senderId }
  return request(c, "POST", "/v1/messages", null, payload, done)
}

function message(cfg, messageId, done) {
  return request(cfg, "GET", "/v1/messages/" + messageId, null, null, done)
}

/** Marks the inbound message read and shows "typing…" on the contact's phone. */
function typing(cfg, senderId, messageId, done) {
  var c = { apiKey: cfg.apiKey, baseUrl: cfg.baseUrl, senderId: senderId }
  return request(c, "POST", "/v1/messages/" + messageId + "/typing", null, null, done)
}

function templates(cfg, done) {
  return request(cfg, "GET", "/v1/templates", { limit: 100 }, null, done)
}
