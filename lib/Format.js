.pragma library

// Presentation helpers. Kept out of the QML so they can be reasoned about (and
// changed) without touching layout.

var CHANNEL_GLYPH = {
  whatsapp: "󰖣",
  whatsapp_alt: "󰖣",
  sms: "󰍡",
  sms_oneway: "󰍡",
  email: "󰇮",
  telegram: "󰔁",
  instagram: "󰋾",
  messenger: "󰭹",
  voice: "󰏲"
}

function channelGlyph(channel) {
  return CHANNEL_GLYPH[channel] || "󰭹"
}

/**
 * Relative time, short. Deliberately coarse past an hour: a thread list is
 * scanned, not read, and "2d" carries the same decision as "2 days ago".
 */
function ago(ts) {
  if (!ts) return ""
  var t = typeof ts === "number" ? ts : Date.parse(ts)
  if (!isFinite(t)) return ""
  var s = Math.floor((Date.now() - t) / 1000)
  if (s < 45) return "now"
  if (s < 3600) return Math.floor(s / 60) + "m"
  if (s < 86400) return Math.floor(s / 3600) + "h"
  if (s < 604800) return Math.floor(s / 86400) + "d"
  var d = new Date(t)
  return (d.getMonth() + 1) + "/" + d.getDate()
}

/** Milliseconds left in the WhatsApp 24h window, or null when it does not apply. */
function windowRemainingMs(lastInboundAt) {
  if (!lastInboundAt) return null
  var t = typeof lastInboundAt === "number" ? lastInboundAt : Date.parse(lastInboundAt)
  if (!isFinite(t)) return null
  return Math.max(0, t + 24 * 3600 * 1000 - Date.now())
}

function windowLabel(ms) {
  if (ms === null) return ""
  if (ms <= 0) return "window closed"
  var h = Math.floor(ms / 3600000)
  if (h >= 1) return "window open · " + h + "h left"
  return "window open · " + Math.max(1, Math.floor(ms / 60000)) + "m left"
}

/**
 * Only the official WhatsApp channel enforces the 24-hour window. whatsapp_alt
 * is the QR-linked channel and has neither window nor templates, so its
 * composer must never be closed — guessing from "it's WhatsApp-ish" would lock
 * people out of threads they can actually answer.
 */
function enforcesWindow(channel) {
  return channel === "whatsapp"
}

/** A thread's display name: the profile name when known, else its raw key. */
function threadTitle(conv) {
  if (!conv) return ""
  if (conv.group && conv.group.subject) return conv.group.subject
  if (conv.profileName) return conv.profileName
  if (conv.whatsapp && conv.whatsapp.username) return conv.whatsapp.username
  return conv.email || conv.contactIdentifier || "unknown"
}

function preview(conv) {
  if (!conv || !conv.lastMessage) return ""
  var t = String(conv.lastMessage.text || "")
  if (t.length === 0) return "[" + (conv.lastMessage.channel || "media") + "]"
  return t.replace(/\s+/g, " ")
}

function elide(text, max) {
  var t = String(text || "")
  return t.length > max ? t.slice(0, max - 1) + "…" : t
}

/**
 * Signal Violet, picked for the active theme rather than hardcoded: #615FFF on
 * a dark background, the deeper #4340C7 on a light one, which is the brand's
 * own dark→light mapping. A plugin that pins one of them looks wrong under half
 * the Omarchy themes.
 */
function accentFor(backgroundColor) {
  var lum = 0.2126 * backgroundColor.r + 0.7152 * backgroundColor.g + 0.0722 * backgroundColor.b
  return lum > 0.5 ? "#4340C7" : "#615FFF"
}

/**
 * Dashboard deep links. The inbox one is documented in openapi.json.
 *
 * El id va percent-encoded: es un valor que devuelve la API, entra en una query
 * string, y así ningún carácter raro sobrevive hasta el proceso que abra la URL.
 */
function conversationUrl(locale, conversationId) {
  return "https://dashboard.zavu.dev/" + (locale || "en")
    + "/inbox?conv=" + encodeURIComponent(String(conversationId || ""))
}

function accountsUrl(locale) {
  return "https://dashboard.zavu.dev/" + (locale || "en") + "/accounts"
}

/**
 * ¿Es un mensaje saliente?
 *
 * `GET /v1/conversations/{id}/messages` NO devuelve `direction` (el campo existe
 * en la base pero no se expone), y el estado tampoco sirve: un entrante también
 * se guarda como `delivered`. Lo único fiable que sí publica es el destinatario.
 *
 *   saliente → `to` es el contacto  (o el JID del grupo)
 *   entrante → `to` es tu propio número
 *
 * Comparar contra `contactIdentifier` funciona igual en 1:1, en grupos y en
 * email, que es más de lo que consigue mirar `from` (en un grupo, `from` es el
 * participante y nunca coincide con la clave del hilo).
 *
 * Prefiere `direction` en cuanto la API lo exponga.
 */
function isOutbound(msg, conversation) {
  if (!msg) return false
  if (msg.__pending) return true
  if (msg.direction) return msg.direction === "outbound"
  if (!conversation) return false
  var key = String(conversation.contactIdentifier || conversation.email || "")
  if (key.length === 0) return false
  return String(msg.to || "") === key
}
