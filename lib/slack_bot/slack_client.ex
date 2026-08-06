defmodule SlackBot.SlackClient do
  @moduledoc """
  Thin wrapper around the three Slack Web API methods we need:

    * `conversations.info` — to read `last_read` for a channel
    * `conversations.history` — to check for unread content between two ts'es
    * `conversations.mark` — to mark the channel read up to a ts

  All calls authenticate with the user token (xoxp-) — `conversations.mark`
  only works as the real user. The base URL is injectable via app config
  (`config :slack_bot, :slack, base_url: "...")` so tests can point at a
  Bypass server.
  """

  require Logger

  @default_base_url "https://slack.com/api"

  @type ts :: String.t()
  @type channel :: String.t()
  @type message :: %{optional(String.t()) => any()}

  @spec conversations_info(channel) :: {:ok, map()} | {:error, term()}
  def conversations_info(channel) do
    post("conversations.info", %{channel: channel})
    |> case do
      {:ok, %{"channel" => ch}} -> {:ok, ch}
      other -> other
    end
  end

  @doc """
  Returns messages strictly between `oldest` and `latest` (exclusive on both
  ends). `limit` caps the number returned — we only ever need 1 to know if
  *anything* is unread there.
  """
  @spec conversations_history(channel, ts, ts, pos_integer()) ::
          {:ok, [message]} | {:error, term()}
  def conversations_history(channel, oldest, latest, limit \\ 1) do
    post("conversations.history", %{
      channel: channel,
      oldest: oldest,
      latest: latest,
      inclusive: false,
      limit: limit
    })
    |> case do
      {:ok, %{"messages" => msgs}} -> {:ok, msgs}
      other -> other
    end
  end

  @spec conversations_mark(channel, ts) :: :ok | {:error, term()}
  def conversations_mark(channel, ts) do
    case post("conversations.mark", %{channel: channel, ts: ts}) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec conversations_kick(channel, String.t()) :: :ok | {:error, term()}
  def conversations_kick(channel, user) do
    case post("conversations.kick", %{channel: channel, user: user}) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp post(method, params) do
    url = base_url() <> "/" <> method
    token = user_token()

    if token in [nil, ""] do
      {:error, :missing_user_token}
    else
      do_post(url, token, params)
    end
  end

  defp do_post(url, token, params) do
    Req.post(url,
      form: params,
      headers: [
        {"authorization", "Bearer " <> token},
        {"content-type", "application/x-www-form-urlencoded; charset=utf-8"}
      ],
      retry: false
    )
    |> handle_response()
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: %{"ok" => true} = body}}) do
    {:ok, body}
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: %{"ok" => false, "error" => err}}}) do
    {:error, {:slack_error, err}}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    Logger.warning("slack api non-200: status=#{status} body=#{inspect(body)}")
    {:error, {:http_error, status}}
  end

  defp handle_response({:error, reason}) do
    Logger.warning("slack api transport error: #{inspect(reason)}")
    {:error, {:transport, reason}}
  end

  defp base_url do
    Application.get_env(:slack_bot, :slack, [])
    |> Keyword.get(:base_url, @default_base_url)
  end

  defp user_token do
    Application.get_env(:slack_bot, :slack, [])
    |> Keyword.get(:user_token)
  end
end
