defmodule SlackBot.LoggerHandler do
  @moduledoc """
  Custom Erlang `:logger` handler that pipes every log event into
  `SlackBot.EventLogger` so `Logger.info/warning/debug/...` calls land in
  the same daily-rotating `logs/events-YYYY-MM-DD.log` file as the Slack
  event audit trail.

  Additive — this is installed alongside the default stdout handler, so
  `docker compose logs -f` keeps working unchanged.

  Registered from `SlackBot.Application.start/2` after the supervision tree
  is up. If any formatting work fails we swallow the error rather than
  blowing up the caller's process, since logging must never crash code.
  """

  @doc false
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    text = msg |> format_msg() |> to_binary()

    unless request_log?(text) do
      line =
        IO.iodata_to_binary([
          format_timestamp(meta),
          " [",
          Atom.to_string(level),
          "] ",
          text,
          ?\n
        ])

      SlackBot.EventLogger.write_line(line)
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc """
  True for the per-request log lines emitted by `Plug.Logger`
  (`"POST /…"`, `"Sent 200 in 443µs"`, etc.). The file log is meant to be
  a focused audit trail; the request firehose is left to stdout/docker
  compose logs. Public for direct testing.
  """
  @spec request_log?(binary()) :: boolean()
  def request_log?(text) when is_binary(text) do
    String.starts_with?(text, [
      "GET ",
      "POST ",
      "PUT ",
      "PATCH ",
      "DELETE ",
      "HEAD ",
      "OPTIONS ",
      "Sent "
    ])
  end

  def request_log?(_), do: false

  defp to_binary(b) when is_binary(b), do: b
  defp to_binary(io), do: IO.iodata_to_binary(io)

  defp format_msg({:string, str}), do: str
  defp format_msg({:report, report}), do: inspect(report)

  defp format_msg({fmt, args}) when is_list(fmt) or is_binary(fmt) do
    try do
      fmt |> :io_lib.format(args) |> IO.iodata_to_binary()
    rescue
      _ -> inspect({fmt, args})
    end
  end

  defp format_msg(other), do: inspect(other)

  defp format_timestamp(%{time: micros}) when is_integer(micros) do
    micros |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()
  end

  defp format_timestamp(_) do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end
end
