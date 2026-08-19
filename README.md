# Zavu Inbox for Omarchy

Read and reply to every conversation your Zavu numbers are having — WhatsApp,
SMS, email, Telegram — without leaving the shell.

One glyph in the bar. `Super+M` for the full inbox.

## Install

```bash
omarchy plugin add https://github.com/zavudev/zavu-omarchy.git --enable
```

## Sign in

There is no second login. If you have ever run `zavudev login` on this machine,
the plugin is already signed in — it reads the CLI's own
`~/.zavu/credentials.json` and never writes to it.

```bash
npx zavudev@latest login
```

The bar picks it up the moment the file appears; no restart. `ZAVUDEV_API_KEY`
in the environment wins over the file, matching the CLI's own precedence.

## Hotkey

Add to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER, M", "Zavu inbox", function()
  hl.dispatch(hl.dsp.exec("omarchy-shell shell toggle dev.zavu.inbox '{}'"))
end)
```

## Keys

| Key | Action |
|-----|--------|
| `j` / `k` · arrows | Move through threads |
| `Enter` | Focus the composer, then send |
| `/` | Search threads |
| `Esc` | Clear the search, then close |

## Settings

Editable from Omarchy's settings panel: refresh interval, desktop
notifications, enter-to-send, dashboard language.

## What it does not do

Being straight about this is the point:

- **It polls, it does not stream.** Webhooks are server-to-server; there is no
  socket for a desktop client. The header says `synced Ns ago` and never claims
  to be live. Cadence adapts: 3s with a surface open, your setting when idle,
  and it backs off on the rate-limit headers the API already sends.
- **Search matches who the thread is with**, never message bodies: phone number
  in any format, email, group subject, WhatsApp username, BSUID. Results come
  back ranked by relevance, so the recency order does not hold while a query is
  active — the scope line says so.
- **The WhatsApp 24-hour window is real.** On the official `whatsapp` channel,
  when the last inbound message is older than 24h the composer closes instead of
  offering a send that the API will refuse. `whatsapp_alt` has no window, so its
  composer stays open.
- **A send is accepted, not completed.** `POST /v1/messages` answers 202 and
  queues; delivery and failure land later. Bubbles stay `sending…` until a poll
  confirms them, and a failure prints the API's own error message verbatim.

## Security

Plugins share the long-running Omarchy shell process with your user's
permissions. This one:

- never writes your API key — it only reads the CLI's file
- talks to exactly one host, whatever `apiBaseUrl` your credentials name
- never passes message content to a shell command
- ships no telemetry

## Why no SDK

`@zavudev/sdk` can be made to run here (bundle it to es2016 and shim `fetch`,
`Headers`, `AbortController`, `setTimeout`, `Object.fromEntries`), but Quickshell
loads plugins by cloning a git repo with no build step, and a correct
`setTimeout` needs a QML `Timer` bridged into the bundle — without it retries and
timeouts hang. For roughly ten endpoints, `lib/Api.js` over `XMLHttpRequest` is
less code than the shims.

## License

MIT
