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

  alias SlackBot.{EventLogger, SlackClient}

  # Hard cap on how many "between" messages we'll inspect for the race-aware
  # check. If there's a burst of >@history_limit unread messages from the
  # target between marks, we'd rather skip-mark and be safe than mark over
  # potentially missed content.
  @history_limit 20

  @type outcome ::
          {:ok, :marked}
          | {:skip, :not_member | :other_user_unread}
          | {:error, term()}

  @spec handle_message(map()) :: outcome
  def handle_message(%{"channel" => channel, "ts" => event_ts} = event) do
    Logger.info(
      "processing target-user event: user=#{Map.get(event, "user")} " <>
        "channel=#{channel} ts=#{event_ts}"
    )

    with {:ok, info} <- SlackClient.conversations_info(channel),
         :ok <- check_is_member(info),
         :ok <- log_member_event(event),
         {:ok, last_read} <- fetch_last_read(info),
         {:ok, between} <-
           SlackClient.conversations_history(channel, last_read, event_ts, @history_limit),
         :ok <- check_only_target_users(between, target_user_ids()) do
      do_mark(channel, event_ts)
    else
      :skip_not_member ->
        Logger.info("skipping #{channel}: not a member")
        {:skip, :not_member}

      :skip_other_user_unread ->
        Logger.info("skipping #{channel}@#{event_ts}: non-target unread content present")
        {:skip, :other_user_unread}

      {:error, reason} = err ->
        Logger.warning("event handling failed for #{channel}@#{event_ts}: #{inspect(reason)}")
        err
    end
  end

  @doc """
  Diagnostic / dev variant. Skips the smart-skip checks (`compare_ts`
  early-return for already-read channels, race-aware target-user-only
  filter) and goes straight to `conversations.mark` after confirming
  membership. Used by the dev test endpoint to verify the API path
  works end-to-end against channels that are already at `last_read`.
  Still respects the membership check — marking a channel you're not in
  would always 403 from Slack.
  """
  @spec force_mark(map()) :: outcome
  def force_mark(%{"channel" => channel, "ts" => event_ts} = event) do
    with {:ok, info} <- SlackClient.conversations_info(channel),
         :ok <- check_is_member(info),
         :ok <- log_member_event(event) do
      Logger.info("[force] proceeding to mark #{channel} up to #{event_ts}")
      do_mark(channel, event_ts)
    else
      :skip_not_member ->
        Logger.debug("[force] skipping #{channel}: not a member")
        {:skip, :not_member}

      {:error, reason} = err ->
        Logger.warning("[force] failed for #{channel}@#{event_ts}: #{inspect(reason)}")
        err
    end
  end

  defp do_mark(channel, event_ts) do
    case SlackClient.conversations_mark(channel, event_ts) do
      :ok ->
        Logger.info("marked channel #{channel} read up to #{event_ts}")
        {:ok, :marked}

      {:error, reason} = err ->
        Logger.warning("conversations.mark failed for #{channel}: #{inspect(reason)}")
        err
    end
  end

  defp fetch_last_read(%{"last_read" => last_read}) when is_binary(last_read),
    do: {:ok, last_read}

  defp fetch_last_read(_), do: {:error, :no_last_read}

  # `is_member` is reliable for public channels (false → user has read
  # access but isn't actually in the channel; we should ignore those).
  # Private channels and groups don't always populate `is_member`, but
  # `conversations.info` only succeeds for those when the calling user
  # is in fact a member, so a missing key is treated as "in".
  defp check_is_member(%{"is_member" => false}), do: :skip_not_member
  defp check_is_member(_info), do: :ok

  # Audit-log the event only after we've confirmed the calling user is a
  # member of the channel. Side-effecting; always returns :ok so the with
  # chain treats this as a non-branching step.
  defp log_member_event(event) do
    EventLogger.log_event(event)
    :ok
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
