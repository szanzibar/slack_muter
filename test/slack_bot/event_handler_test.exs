defmodule SlackBot.EventHandlerTest do
  use ExUnit.Case, async: true

  alias SlackBot.EventHandler

  @target "U_TARGET"
  @other_target "U_TARGET_2"
  @targets [@target, @other_target]

  describe "only_target_users?/2 (race-aware mark rule)" do
    test "true when there are no unread messages between" do
      assert EventHandler.only_target_users?([], @targets)
    end

    test "true when every unread message is from a target user" do
      msgs = [
        %{"user" => @target, "ts" => "1700000000.000050"},
        %{"user" => @other_target, "ts" => "1700000000.000040"}
      ]

      assert EventHandler.only_target_users?(msgs, @targets)
    end

    test "false when any unread message is from a non-target user" do
      msgs = [
        %{"user" => @target, "ts" => "1700000000.000050"},
        %{"user" => "U_OTHER", "ts" => "1700000000.000040"}
      ]

      refute EventHandler.only_target_users?(msgs, @targets)
    end

    test "false for unauthored messages (e.g. bot_id with no user)" do
      msgs = [%{"bot_id" => "B123", "ts" => "1700000000.000050"}]

      refute EventHandler.only_target_users?(msgs, @targets)
    end

    test "false when target list is empty" do
      msgs = [%{"user" => @target, "ts" => "1700000000.000050"}]

      refute EventHandler.only_target_users?(msgs, [])
    end
  end
end
