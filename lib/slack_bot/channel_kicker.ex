defmodule SlackBot.ChannelKicker do
  @moduledoc """
  Removes configured users from configured channels the moment they join.

  Driven by `member_joined_channel` events from the Events API. The
  controller calls `should_kick?/1` to decide dispatch and runs `kick/1`
  in a supervised Task, same as the auto-read feature.
  """

  require Logger

  alias SlackBot.SlackClient

  @spec should_kick?(map()) :: boolean()
  def should_kick?(%{"type" => "member_joined_channel", "channel" => channel, "user" => user}) do
    channel in config(:kick_channel_ids) and user in config(:kick_user_ids)
  end

  def should_kick?(_event), do: false

  @spec kick(map()) :: :ok | {:error, term()}
  def kick(%{"channel" => channel, "user" => user}), do: kick(channel, user)

  @spec kick(String.t(), String.t()) :: :ok | {:error, term()}
  def kick(channel, user) do
    case SlackClient.conversations_kick(channel, user) do
      :ok ->
        Logger.info("kicked #{user} from #{channel}")
        :ok

      # The boot sweep kicks blindly; the user not being there is success.
      {:error, {:slack_error, "not_in_channel"}} ->
        :ok

      {:error, reason} = err ->
        Logger.warning("kick failed for #{user} in #{channel}: #{inspect(reason)}")
        err
    end
  end

  @doc """
  Boot sweep: kick every configured user from every configured channel,
  so anyone already present before the app started doesn't linger.
  Runs as a one-shot Task from the supervision tree.
  """
  @spec kick_all() :: :ok
  def kick_all do
    for channel <- config(:kick_channel_ids), user <- config(:kick_user_ids) do
      kick(channel, user)
    end

    :ok
  end

  defp config(key) do
    Application.get_env(:slack_bot, :slack, [])
    |> Keyword.get(key, [])
  end
end
