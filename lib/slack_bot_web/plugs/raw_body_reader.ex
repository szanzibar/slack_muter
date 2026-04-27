defmodule SlackBotWeb.Plugs.RawBodyReader do
  @moduledoc """
  Custom `Plug.Parsers` body reader that stashes the raw request body in
  `conn.assigns[:raw_body]` for routes that need it (Slack signature
  verification reads HMAC over the raw bytes).
  """

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, update_raw_body(conn, body)}

      {:more, body, conn} ->
        {:more, body, update_raw_body(conn, body)}

      {:error, _} = err ->
        err
    end
  end

  defp update_raw_body(conn, chunk) do
    Plug.Conn.assign(conn, :raw_body, (conn.assigns[:raw_body] || "") <> chunk)
  end
end
