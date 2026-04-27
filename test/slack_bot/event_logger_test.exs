defmodule SlackBot.EventLoggerTest do
  use ExUnit.Case, async: true

  alias SlackBot.EventLogger

  describe "format_line/1" do
    test "includes channel, type, user, ts, and a quoted text snippet" do
      line =
        EventLogger.format_line(%{
          "channel" => "C123",
          "channel_type" => "channel",
          "user" => "U_TARGET",
          "ts" => "1700000000.000100",
          "text" => "hello world"
        })

      assert line =~ "channel=C123"
      assert line =~ "type=channel"
      assert line =~ "user=U_TARGET"
      assert line =~ "ts=1700000000.000100"
      assert line =~ ~s(text="hello world")
      assert String.ends_with?(line, "\n")
    end

    test "collapses newlines and truncates long text" do
      long = String.duplicate("a", 500)

      line =
        EventLogger.format_line(%{
          "channel" => "C1",
          "user" => "U1",
          "text" => "first line\nsecond\rthird " <> long
        })

      # newlines replaced with spaces, body capped at @max_text_chars (200)
      refute line =~ "\nsecond"
      assert line =~ "first line second third"
      # the inspected text content (between the first " and last ") is <= 200 chars
      [_, inspected] = Regex.run(~r/text=("(?:[^"\\]|\\.)*")/, line)
      decoded = inspected |> String.trim_trailing("\"") |> String.trim_leading("\"")
      assert byte_size(decoded) <= 200
    end

    test "falls back to '?' when fields are missing" do
      line = EventLogger.format_line(%{})

      assert line =~ "channel=?"
      assert line =~ "type=?"
      assert line =~ "user=?"
      assert line =~ "ts=?"
    end

    test "uses username if user is missing (bot/integration messages)" do
      line = EventLogger.format_line(%{"username" => "github-bot"})
      assert line =~ "user=github-bot"
    end
  end

  describe "Logger integration via SlackBot.LoggerHandler" do
    test "Logger.warning lines land in today's event-log file" do
      require Logger

      dir = Application.fetch_env!(:slack_bot, :event_log_dir)
      today = Date.utc_today() |> Date.to_iso8601()
      path = Path.join(dir, "events-#{today}.log")

      marker = "logger_handler_marker_#{System.unique_integer([:positive])}"
      Logger.warning(marker)

      # Drain the EventLogger mailbox so the cast has been processed before
      # we read the file.
      :sys.get_state(SlackBot.EventLogger)

      contents = File.read!(path)
      assert contents =~ marker
      assert contents =~ "[warning]"
    end
  end

  describe "cleanup_old/1" do
    test "deletes files older than 7 days, keeps newer ones" do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "slack_bot_logger_cleanup_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)

      on_exit(fn -> File.rm_rf!(tmp) end)

      today = Date.utc_today()
      old_date = Date.add(today, -8)
      new_date = Date.add(today, -3)
      unrelated = Path.join(tmp, "events-not-a-date.log")

      old_path = Path.join(tmp, "events-#{Date.to_iso8601(old_date)}.log")
      new_path = Path.join(tmp, "events-#{Date.to_iso8601(new_date)}.log")

      File.write!(old_path, "stale\n")
      File.write!(new_path, "fresh\n")
      File.write!(unrelated, "ignore\n")

      EventLogger.cleanup_old(tmp)

      refute File.exists?(old_path), "expected old file to be removed"
      assert File.exists?(new_path), "expected recent file to be kept"
      assert File.exists?(unrelated), "non-matching files must not be touched"
    end
  end
end
