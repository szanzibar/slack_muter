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
    if should_handle?(event, target_user_id()) do
      Task.Supervisor.start_child(SlackBot.TaskSupervisor, fn ->
        EventHandler.handle_message(event)
      end)
    end

    send_resp(conn, 200, "")
  end

  def events(conn, _params), do: send_resp(conn, 200, "")

  @doc false
  # Public for direct testing — keeps the dispatch rules isolated from
  # signature/HTTP concerns.
  def should_handle?(event, target_user_id \\ target_user_id())

  def should_handle?(%{"type" => "message"} = event, target_user_id) do
    is_nil(Map.get(event, "subtype")) and
      is_nil(Map.get(event, "thread_ts")) and
      Map.get(event, "channel_type") not in @ignored_channel_types and
      Map.get(event, "user") == target_user_id
  end

  def should_handle?(_, _target_user_id), do: false

  defp target_user_id do
    Application.get_env(:slack_bot, :slack, [])
    |> Keyword.get(:target_user_id)
  end
end
