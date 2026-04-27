defmodule SlackBotWeb.Plugs.VerifySlackSignature do
  @moduledoc """
  Plug that rejects any request to the Slack events endpoint whose
  HMAC-SHA256 signature does not match the configured signing secret. Reads
  the raw body that `SlackBotWeb.Plugs.RawBodyReader` stashed in
  `conn.assigns[:raw_body]`.

  Returns 403 on failure. Halts the conn — the controller never sees an
  unverified request.
  """

  import Plug.Conn

  require Logger

  alias SlackBot.SlackVerifier

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    raw_body = conn.assigns[:raw_body] || ""
    timestamp = get_header(conn, "x-slack-request-timestamp")
    signature = get_header(conn, "x-slack-signature")
    secret = signing_secret()

    case SlackVerifier.verify(raw_body, timestamp, signature, secret) do
      :ok ->
        conn

      {:error, reason} ->
        Logger.warning("rejecting Slack request: #{inspect(reason)}")

        conn
        |> send_resp(403, "invalid signature")
        |> halt()
    end
  end

  defp get_header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp signing_secret do
    Application.get_env(:slack_bot, :slack, [])
    |> Keyword.get(:signing_secret)
  end
end
