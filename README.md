# SlackBot — Auto-Read Coworker Messages

A tiny Phoenix app that listens to Slack's Events API and auto-marks a
specific coworker's messages as read in channels (not DMs/group DMs), but
*only when nothing else in the channel is unread*. The moment another
person posts above their message, we leave the channel alone until you
read it yourself.

## How it works

1. Slack POSTs `message` events to `/slack/events`.
2. We HMAC-verify the request (5-min timestamp window + signature).
3. We pre-filter:
   - skip non-`message` events and any event with a `subtype` (edits,
     joins, bot messages…)
   - skip thread replies (events with `thread_ts`)
   - skip DMs (`channel_type == "im"`) and group DMs (`"mpim"`)
   - require `event.user == TARGET_SLACK_USER_ID`
4. We respond `200` immediately and run the rest in a supervised Task
   (Slack requires a fast `200`).
5. In the Task: `conversations.info` → `last_read`. Then
   `conversations.history(oldest=last_read, latest=event.ts, inclusive=false, limit=50)`.
   If the messages between are all from the target user (race-aware
   check), we call `conversations.mark` up to `event.ts`. Otherwise we
   leave the channel alone.

## Slack app setup

1. Create a new Slack app at <https://api.slack.com/apps> (From scratch),
   pick your workspace.
2. **OAuth & Permissions → User Token Scopes**:
   - `channels:history`, `channels:read`, `channels:write`
   - `groups:history`, `groups:read`, `groups:write`
   - `im:read` (so we can identify and skip 1:1 DMs in event payloads)

   The `*:write` scopes are required by `conversations.mark` even though
   we never post messages — Slack treats "mark as read" as a write
   operation per channel type. If you skip them you'll see
   `{"ok":false,"error":"missing_scope"}` from `conversations.mark` and
   the channel will silently never get marked. After adding scopes you
   must reinstall the app to your workspace and replace
   `SLACK_USER_TOKEN` with the new `xoxp-…`.
3. **Event Subscriptions**:
   - Enable, set the **Request URL** to
     `https://YOUR_HOST/slack/events`. Slack pings it with a
     `url_verification` challenge — the app handles that automatically.
   - Subscribe to events on behalf of users:
     `message.channels`, `message.groups`.
     (Do NOT subscribe to `message.im` or `message.mpim` — we ignore
     DMs and group DMs.)
4. **Install App** → copy the **User OAuth Token** (`xoxp-…`) into
   `SLACK_USER_TOKEN`.
5. **Basic Information → App Credentials → Signing Secret** → copy into
   `SLACK_SIGNING_SECRET`.
6. Find the target coworker's member ID (their Slack profile → `…` →
   *Copy member ID*) and put it in `TARGET_SLACK_USER_ID`.

> The bot token (`xoxb-`) is **not used**. `conversations.mark` only
> works as the real user, so all API calls go out with the user token.

## Local development

```sh
mix setup            # deps + assets
cp .env.default .env # then fill in real values
mix phx.server
```

`.env` is gitignored. `dotenv_parser` loads it automatically in `dev`
and `test` (see [`config/runtime.exs`](config/runtime.exs)). In prod the
variables come straight from the environment — `.env` is not shipped.

To expose your local server to Slack during development, use a tunnel
(ngrok, cloudflared, etc.) and set the resulting URL as your app's
Request URL.

## Tests

```sh
mix test
```

Covers signature verification (HMAC + timestamp window), the dispatch
filter rules (DM/mpim/thread/subtype/user filters), and the race-aware
mark decision.

## Deployment

Set these in the prod environment (Docker/Fly/wherever):

| Variable               | Purpose                                                      |
|------------------------|--------------------------------------------------------------|
| `SLACK_SIGNING_SECRET` | Verify inbound Slack webhooks                                |
| `SLACK_USER_TOKEN`     | `xoxp-…` — calls `conversations.{info,history,mark}`         |
| `TARGET_SLACK_USER_ID` | The coworker whose channel posts get auto-read               |
| `PHX_HOST`             | Hostname Phoenix advertises (also Slack's Request URL host)  |
| `SECRET_KEY_BASE`      | Phoenix cookie/session secret. `mix phx.gen.secret`          |
| `PORT`                 | HTTP port (default 4000)                                     |
| `PHX_SERVER`           | Set to `true` when running via `mix release`                 |
