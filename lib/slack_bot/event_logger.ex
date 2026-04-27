defmodule SlackBot.EventLogger do
  @moduledoc """
  Writes one line per inbound Slack message event to a date-stamped file
  under `log/`. Files are named `events-YYYY-MM-DD.log` (UTC). On the first
  write of a new UTC day we close the previous handle and open the new
  file, then sweep anything older than 7 days. A daily timer also fires the
  cleanup so quiet weekends don't strand stale files.

  This is a lightweight audit trail of what the bot saw — not a replacement
  for `Logger`, which still goes to stdout/docker logs for warnings and
  operational info.

  Slack message events typically only carry user/channel IDs, not display
  names or emails. Resolving those would require extra `users.info` calls
  per event, which the user explicitly said wasn't worth it — IDs are fine.
  """

  use GenServer

  require Logger

  @retention_days 7
  @cleanup_interval :timer.hours(24)
  @max_text_chars 200

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Append a single message event to the current day's log file. Asynchronous —
  callers don't block on disk I/O, and the controller can return its 200
  to Slack without waiting.
  """
  @spec log_event(map()) :: :ok
  def log_event(event) when is_map(event) do
    write_line(format_line(event))
  end

  @doc """
  Append an already-formatted line (must end in `\\n`) to today's log file.
  Used by `SlackBot.LoggerHandler` to route Elixir/Erlang `:logger` output
  to the same rotated file. Silently no-ops if the GenServer isn't up
  (e.g. during boot before children start, or after shutdown) so logging
  can never crash a caller.
  """
  @spec write_line(iodata()) :: :ok
  def write_line(line) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:write, line})
    end
  end

  ## Server

  @impl true
  def init(_opts) do
    dir = log_dir()
    File.mkdir_p!(dir)
    cleanup_old(dir)
    schedule_cleanup()
    {:ok, open_today(dir)}
  end

  @impl true
  def handle_cast({:write, line}, state) do
    state = ensure_today_file(state)
    IO.write(state.io, line)
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_old(state.dir)
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state[:io], do: File.close(state.io)
    :ok
  end

  ## Internals

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval)

  defp ensure_today_file(%{date: date} = state) do
    today = Date.utc_today()

    if today == date do
      state
    else
      File.close(state.io)
      cleanup_old(state.dir)
      open_today(state.dir)
    end
  end

  defp open_today(dir) do
    today = Date.utc_today()
    path = Path.join(dir, "events-#{Date.to_iso8601(today)}.log")
    {:ok, io} = File.open(path, [:append, :utf8])
    %{io: io, date: today, path: path, dir: dir}
  end

  @doc false
  def cleanup_old(dir) do
    cutoff = Date.add(Date.utc_today(), -@retention_days)

    dir
    |> Path.join("events-*.log")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      with [_, datestr] <- Regex.run(~r/events-(\d{4}-\d{2}-\d{2})\.log$/, path),
           {:ok, date} <- Date.from_iso8601(datestr),
           :lt <- Date.compare(date, cutoff) do
        File.rm(path)
      else
        _ -> :ok
      end
    end)
  end

  @doc false
  def format_line(event) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    channel = Map.get(event, "channel", "?")
    channel_type = Map.get(event, "channel_type", "?")
    user = Map.get(event, "user") || Map.get(event, "username") || "?"
    ts = Map.get(event, "ts", "?")
    text = event |> Map.get("text", "") |> truncate_text()

    "#{timestamp} channel=#{channel} type=#{channel_type} user=#{user} ts=#{ts} text=#{inspect(text)}\n"
  end

  defp truncate_text(text) when is_binary(text) do
    text
    |> String.replace(["\r", "\n"], " ")
    |> String.slice(0, @max_text_chars)
  end

  defp truncate_text(_), do: ""

  defp log_dir do
    Application.get_env(:slack_bot, :event_log_dir, "log")
  end
end
