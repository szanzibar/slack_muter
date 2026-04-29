defmodule SlackBotWeb.SlackController do
  @moduledoc """
  Receives Slack Events API webhooks at POST /slack/events.

  Three shapes of payload:

    1. URL verification — first-time setup; echo `challenge` back as JSON.
    2. `event_callback` wrapping a `message` event — pre-filter and dispatch
       to `SlackBot.EventHandler` in a supervised Task so we can return 200
       within Slack's 3-second window.
    3. Anything else — ignore, return 200.

  Slack retries on non-2xx responses and on timeouts, so we always 200 unless
  the signature plug already rejected the request as 403.
  """

  use SlackBotWeb, :controller

  require Logger

  alias SlackBot.EventHandler

  @ignored_channel_types ~w(im mpim)

  def events(conn, %{"type" => "url_verification", "challenge" => challenge}) do
    json(conn, %{challenge: challenge})
  end

  def events(conn, %{"type" => "event_callback", "event" => event}) do
    target_ids = target_user_ids()

    if should_handle?(event, target_ids) do
      Task.Supervisor.start_child(SlackBot.TaskSupervisor, fn ->
        EventHandler.handle_message(event)
      end)
    else
      log_filter_miss(event, target_ids)
    end

    send_resp(conn, 200, "")
  end

  def events(conn, _params), do: send_resp(conn, 200, "")

  @doc false
  # Public for direct testing — keeps the dispatch rules isolated from
  # signature/HTTP concerns.
  def should_handle?(event, target_user_ids \\ target_user_ids())

  def should_handle?(%{"type" => "message"} = event, target_user_ids)
      when is_list(target_user_ids) do
    Map.get(event, "user") in target_user_ids and
      Map.get(event, "channel_type") not in @ignored_channel_types and
      processable_message?(event)
  end

  def should_handle?(_, _target_user_ids), do: false

  # Slack delivers a lot of subtype variants — some are real user content
  # (file upload, /me, broadcasted thread reply) that we want to process,
  # others are system noise (edits, joins, bot proxies) that we don't.
  # Allowlist subtypes we want to act on, plus the nil case (a plain
  # top-level message). Plain thread replies (subtype=nil, thread_ts set)
  # are filtered out because Slack's public API has no way to mark them
  # as read — only conversations.mark which is channel-level only.
  defp processable_message?(event) do
    subtype = Map.get(event, "subtype")
    in_thread? = not is_nil(Map.get(event, "thread_ts"))

    case subtype do
      nil -> not in_thread?
      "file_share" -> not in_thread?
      "me_message" -> not in_thread?
      # Thread reply that was *also* posted to the channel feed — appears
      # to readers as a regular channel message, so worth marking.
      "thread_broadcast" -> true
      "reply_broadcast" -> true
      _ -> false
    end
  end

  # Diagnostic: emits an info line for every type=message event that we
  # rejected, with the four fields should_handle? checks. Helps explain
  # "why didn't the bot react to my coworker's message?" by showing what
  # Slack actually delivered (subtype, thread_ts, channel_type, user).
  # Limited to message events to avoid logging unrelated event types.
  defp log_filter_miss(%{"type" => "message"} = event, target_ids) do
    Logger.info(
      "filtered message: " <>
        "channel=#{inspect(Map.get(event, "channel"))} " <>
        "user=#{inspect(Map.get(event, "user"))} " <>
        "in_targets=#{inspect(Map.get(event, "user") in target_ids)} " <>
        "channel_type=#{inspect(Map.get(event, "channel_type"))} " <>
        "subtype=#{inspect(Map.get(event, "subtype"))} " <>
        "thread_ts=#{inspect(Map.get(event, "thread_ts"))}"
    )
  end

  defp log_filter_miss(_event, _target_ids), do: :ok

  defp target_user_ids do
    Application.get_env(:slack_bot, :slack, [])
    |> Keyword.get(:target_user_ids, [])
  end
end
