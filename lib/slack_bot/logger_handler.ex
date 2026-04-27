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
    iodata = [
      format_timestamp(meta),
      ?\s,
      ?[,
      Atom.to_string(level),
      ?],
      ?\s,
      format_msg(msg),
      ?\n
    ]

    SlackBot.EventLogger.write_line(IO.iodata_to_binary(iodata))
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

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
