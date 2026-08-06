defmodule SlackBot.ChannelKickerTest do
  use ExUnit.Case

  alias SlackBot.ChannelKicker

  setup do
    original = Application.get_env(:slack_bot, :slack, [])

    Application.put_env(
      :slack_bot,
      :slack,
      Keyword.merge(original, kick_channel_ids: ["C_GUARDED"], kick_user_ids: ["U_KICK"])
    )

    on_exit(fn -> Application.put_env(:slack_bot, :slack, original) end)
  end

  test "kicks a listed user joining a listed channel" do
    assert ChannelKicker.should_kick?(%{
             "type" => "member_joined_channel",
             "channel" => "C_GUARDED",
             "user" => "U_KICK"
           })
  end

  test "ignores unlisted channels, unlisted users, and other event types" do
    refute ChannelKicker.should_kick?(%{
             "type" => "member_joined_channel",
             "channel" => "C_OTHER",
             "user" => "U_KICK"
           })

    refute ChannelKicker.should_kick?(%{
             "type" => "member_joined_channel",
             "channel" => "C_GUARDED",
             "user" => "U_OTHER"
           })

    refute ChannelKicker.should_kick?(%{
             "type" => "message",
             "channel" => "C_GUARDED",
             "user" => "U_KICK"
           })
  end
end
