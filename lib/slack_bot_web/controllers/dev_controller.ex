defmodule SlackBotWeb.DevController do
  @moduledoc """
  Dev-only diagnostic endpoint for poking the event-handling pipeline
  without going through Slack. Mounted only when `dev_routes` is enabled
  (compile-time gate, dev env). NO signature verification — never enable
  in prod.

  POST /dev/slack/events
  Content-Type: application/json

      { "channel": "C0AQ0ALTE3S",
        "user": "U01ABC12345",
        "ts": "1745786361.000300",
        "channel_type": "channel",   // optional, default "channel"
        "text": "test message",       // optional
        "mode": "normal" | "force"    // optional, default "normal"
      }

  Modes:
    * "normal" — runs `EventHandler.handle_message/1`, the same path
      production uses. Useful for debugging "why was this filtered?";
      the JSON response tells you which branch fired (already_read,
      not_member, other_user_unread, marked, error, ...).
    * "force"  — runs `EventHandler.force_mark/1`, which skips the
      compare_ts and race-aware checks and goes straight to
      `conversations.mark` after confirming membership. Useful for
      validating the API path against channels you've already read.

  Runs synchronously (not under TaskSupervisor) so the response body
  reflects the actual outcome.
  """

  use SlackBotWeb, :controller

  require Logger

  alias SlackBot.EventHandler

  def events(conn, params) do
    Logger.info("DevController: simulating event mode=#{inspect(params["mode"])}")

    with {:ok, event} <- build_event(params),
         {:ok, mode} <- parse_mode(params["mode"]) do
      outcome = run(event, mode)

      conn
      |> put_status(200)
      |> json(%{
        mode: Atom.to_string(mode),
        event: event,
        outcome: format_outcome(outcome)
      })
    else
      {:error, message} ->
        conn
        |> put_status(400)
        |> json(%{error: message})
    end
  end

  defp build_event(params) do
    required = ["channel", "user", "ts"]
    missing = Enum.filter(required, fn k -> blank?(params[k]) end)

    if missing == [] do
      {:ok,
       %{
         "type" => "message",
         "channel" => params["channel"],
         "channel_type" => params["channel_type"] || "channel",
         "user" => params["user"],
         "ts" => params["ts"],
         "text" => params["text"] || "(dev test event)"
       }}
    else
      {:error, "missing required fields: #{Enum.join(missing, ", ")}"}
    end
  end

  defp parse_mode(nil), do: {:ok, :normal}
  defp parse_mode("normal"), do: {:ok, :normal}
  defp parse_mode("force"), do: {:ok, :force}

  defp parse_mode(other),
    do: {:error, "unknown mode: #{inspect(other)} (use \"normal\" or \"force\")"}

  defp run(event, :normal), do: EventHandler.handle_message(event)
  defp run(event, :force), do: EventHandler.force_mark(event)

  # Outcomes are tagged tuples; render them in a JSON-friendly shape.
  defp format_outcome({:ok, :marked}), do: %{status: "marked"}
  defp format_outcome({:skip, reason}), do: %{status: "skipped", reason: Atom.to_string(reason)}
  defp format_outcome({:error, reason}), do: %{status: "error", reason: inspect(reason)}

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
