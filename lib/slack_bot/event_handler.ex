defmodule SlackBot.EventHandler do
  @moduledoc """
  Decides whether to mark a Slack channel as read in response to a message
  event from one of the configured target users, and performs the mark
  when appropriate.

  Lives behind `Task.Supervisor` so the controller can return 200 within
  Slack's 3-second window while the API round-trips happen async.

  Pre-filtering (channel_type, subtype, thread_ts, target-user-match) happens
  in the controller — this module assumes the event is already a top-level
  message from a configured target user in a channel/group worth processing.

  Race-condition note: when multiple messages from target users arrive in
  quick succession, an in-flight `conversations.mark` may not have landed
  before we check `last_read` for the next event. So we don't reject just
  because there is *something* unread between `last_read` and `event.ts` —
  we look at the unread messages and only abstain if any are from a user
  outside the configured target list.
  """

  require Logger

  alias SlackBot.SlackClient

  # Hard cap on how many "between" messages we'll inspect for the race-aware
  # check. If there's a burst of >@history_limit unread messages from the
  # target between marks, we'd rather skip-mark and be safe than mark over
  # potentially missed content.
  @history_limit 20

  @spec handle_message(map()) :: :ok
  def handle_message(%{"channel" => channel, "ts" => event_ts} = _event) do
    with {:ok, info} <- SlackClient.conversations_info(channel),
         {:ok, last_read} <- fetch_last_read(info),
         :continue <- compare_ts(last_read, event_ts),
         {:ok, between} <-
           SlackClient.conversations_history(channel, last_read, event_ts, @history_limit),
         :ok <- check_only_target_users(between, target_user_ids()) do
      case SlackClient.conversations_mark(channel, event_ts) do
        :ok ->
          Logger.info("marked channel #{channel} read up to #{event_ts}")
          :ok

        {:error, reason} ->
          Logger.warning("conversations.mark failed for #{channel}: #{inspect(reason)}")
          :ok
      end
    else
      :skip_already_read ->
        :ok

      :skip_other_user_unread ->
        Logger.debug("skipping #{channel}@#{event_ts}: non-target unread content present")
        :ok

      {:error, reason} ->
        Logger.warning("event handling failed for #{channel}@#{event_ts}: #{inspect(reason)}")
        :ok
    end
  end

  defp fetch_last_read(%{"last_read" => last_read}) when is_binary(last_read),
    do: {:ok, last_read}

  defp fetch_last_read(_), do: {:error, :no_last_read}

  # Slack ts strings sort lexicographically when zero-padded — they always
  # are (e.g. "1700000000.000123"), so plain string compare is correct.
  defp compare_ts(last_read, event_ts) do
    cond do
      last_read >= event_ts -> :skip_already_read
      true -> :continue
    end
  end

  defp check_only_target_users(messages, target_user_ids) do
    if only_target_users?(messages, target_user_ids) do
      :ok
    else
      :skip_other_user_unread
    end
  end

  @doc """
  True iff every message in `messages` was authored by a user in
  `target_user_ids`. Public for direct testing of the race-aware mark
  rule — keeps the decision logic unit-testable without HTTP mocking.
  """
  @spec only_target_users?([map()], [String.t()]) :: boolean()
  def only_target_users?(messages, target_user_ids) do
    Enum.all?(messages, fn msg -> Map.get(msg, "user") in target_user_ids end)
  end

  defp target_user_ids do
    Application.get_env(:slack_bot, :slack, [])
    |> Keyword.get(:target_user_ids, [])
  end
end
