# Slack Muter — Auto-Read Coworker Messages

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
6. Find each target coworker's member ID (their Slack profile → `…` →
   *Copy member ID*) and put a comma-separated list in
   `TARGET_SLACK_USER_IDS` — e.g. `U01ABC12345,U02DEF67890`. A single ID
   works fine; whitespace around commas is trimmed.

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

### Local debug endpoint

`POST /dev/slack/events` is mounted only when `dev_routes` is enabled
(local dev — never prod) and **bypasses Slack signature verification**.
It runs the same pipeline production uses, synchronously, and returns a
JSON outcome — useful for figuring out why a real event was filtered.

```sh
# Run the same path as prod (mode: "normal", default).
# Tells you exactly which branch fired: marked / already_read /
# not_member / other_user_unread / error.
curl -s -X POST http://localhost:4000/dev/slack/events \
  -H 'Content-Type: application/json' \
  -d '{
    "channel": "C0AQ0ALTE3S",
    "user": "U01ABC12345",
    "ts": "1745786361.000300"
  }' | jq

# Force a mark even on an already-read channel (skips the
# already_read / race-aware checks). Useful for verifying the
# conversations.mark API path / scopes / token end-to-end.
curl -s -X POST http://localhost:4000/dev/slack/events \
  -H 'Content-Type: application/json' \
  -d '{
    "channel": "C0AQ0ALTE3S",
    "user": "U01ABC12345",
    "ts": "1745786361.000300",
    "mode": "force"
  }' | jq
```

Tail `log/events-$(date -u +%F).log` while you run these — every dev
event still goes through the same logging path as a real one.

## Tests

```sh
mix test
```

Covers signature verification (HMAC + timestamp window), the dispatch
filter rules (DM/mpim/thread/subtype/user filters), and the race-aware
mark decision.

## Deployment

### Required environment variables

Set these in the prod environment (Docker/Fly/wherever):

| Variable                | Purpose                                                                |
|-------------------------|------------------------------------------------------------------------|
| `SLACK_SIGNING_SECRET`  | Verify inbound Slack webhooks                                          |
| `SLACK_USER_TOKEN`      | `xoxp-…` — calls `conversations.{info,history,mark}`                   |
| `TARGET_SLACK_USER_IDS` | Comma-separated coworker member IDs whose posts get auto-read          |
| `PHX_HOST`              | Hostname Phoenix advertises (also Slack's Request URL host)            |
| `SECRET_KEY_BASE`       | Phoenix cookie/session secret. `mix phx.gen.secret`                    |
| `PORT`                  | Host-side port docker-compose binds to (container always uses 4000)    |

### Deploy from the prebuilt image (recommended)

Every push to `main` runs [`.github/workflows/build.yml`](.github/workflows/build.yml),
which builds the Docker image and pushes it to GitHub Container Registry
as `ghcr.io/szanzibar/slack_muter:latest` (also tagged with the commit
SHA). Layer caching is via GitHub Actions cache.

The package is **private by default** — to let your server pull it
without auth, go to <https://github.com/users/szanzibar/packages/container/slack_muter/settings>
and set Package Visibility → Public. (Alternatively, keep it private and
`docker login ghcr.io -u szanzibar -p <PAT-with-read:packages>` on the
server once.)

On the server, you only need two files: `docker-compose.prod.yml` and
`.env`. No source checkout required.

```sh
# First time only — bootstrap the directory:
mkdir -p slack_muter && cd slack_muter
mkdir -p logs && chmod 777 logs

# Grab the standalone compose file:
curl -O https://raw.githubusercontent.com/szanzibar/slack_muter/main/docker-compose.prod.yml

# Create your .env (see "Required environment variables" above):
cat > .env <<'EOF'
SLACK_SIGNING_SECRET=
SLACK_USER_TOKEN=
TARGET_SLACK_USER_IDS=
PHX_HOST=
SECRET_KEY_BASE=
PORT=4000
EOF
$EDITOR .env

# Bring it up:
docker compose -f docker-compose.prod.yml up -d
```

To update later:

```sh
docker compose -f docker-compose.prod.yml pull
docker compose -f docker-compose.prod.yml up -d
```

`pull_policy: always` is set in the compose file, so a plain
`docker compose -f docker-compose.prod.yml up -d --force-recreate` also
fetches the latest tag.

### Deploy from source (build on the server)

If you'd rather build locally on the server (e.g. for an
unmerged branch) the original [`docker-compose.yml`](docker-compose.yml)
+ [`deploy.sh`](deploy.sh) flow still works: `git pull && docker compose
build && docker compose up -d`, all wrapped in `./deploy.sh`.
