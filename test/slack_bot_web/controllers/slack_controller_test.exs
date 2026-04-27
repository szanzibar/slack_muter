defmodule SlackBotWeb.SlackControllerTest do
  use SlackBotWeb.ConnCase, async: false

  alias SlackBotWeb.SlackController

  @signing_secret "test_signing_secret"
  @target_user "U_TARGET"
  @other_target "U_TARGET_2"
  @targets [@target_user, @other_target]

  setup do
    prev = Application.get_env(:slack_bot, :slack, [])

    Application.put_env(:slack_bot, :slack,
      signing_secret: @signing_secret,
      user_token: "xoxp-test",
      target_user_ids: @targets
    )

    on_exit(fn -> Application.put_env(:slack_bot, :slack, prev) end)
    :ok
  end

  defp post_signed(conn, body, opts \\ []) do
    timestamp = Keyword.get(opts, :timestamp, Integer.to_string(System.system_time(:second)))
    secret = Keyword.get(opts, :secret, @signing_secret)
    base = "v0:" <> timestamp <> ":" <> body
    digest = :crypto.mac(:hmac, :sha256, secret, base) |> Base.encode16(case: :lower)
    sig = "v0=" <> digest

    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("x-slack-request-timestamp", timestamp)
    |> Plug.Conn.put_req_header("x-slack-signature", sig)
    |> Phoenix.ConnTest.dispatch(SlackBotWeb.Endpoint, :post, "/slack/events", body)
  end

  describe "POST /slack/events — signature verification" do
    test "echoes the challenge for url_verification", %{conn: conn} do
      body = ~s({"type":"url_verification","challenge":"abc123"})
      conn = post_signed(conn, body)

      assert json_response(conn, 200) == %{"challenge" => "abc123"}
    end

    test "rejects requests with a bad signature", %{conn: conn} do
      body = ~s({"type":"url_verification","challenge":"abc123"})

      conn =
        post_signed(conn, body, secret: "wrong_secret")

      assert response(conn, 403)
    end

    test "rejects stale timestamps", %{conn: conn} do
      body = ~s({"type":"url_verification","challenge":"abc123"})
      old = Integer.to_string(System.system_time(:second) - 600)

      conn = post_signed(conn, body, timestamp: old)
      assert response(conn, 403)
    end

    test "rejects when timestamp header is missing", %{conn: conn} do
      body = ~s({"type":"url_verification","challenge":"abc123"})

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-slack-signature", "v0=" <> String.duplicate("0", 64))
        |> Phoenix.ConnTest.dispatch(SlackBotWeb.Endpoint, :post, "/slack/events", body)

      assert response(conn, 403)
    end
  end

  describe "POST /slack/events — event_callback" do
    test "returns 200 for any well-formed event_callback", %{conn: conn} do
      body =
        Jason.encode!(%{
          type: "event_callback",
          event: %{
            type: "message",
            channel: "C123",
            channel_type: "channel",
            user: @target_user,
            ts: "1700000000.000100"
          }
        })

      conn = post_signed(conn, body)
      assert response(conn, 200) == ""
    end

    test "still 200s on events we ignore (non-target user)", %{conn: conn} do
      body =
        Jason.encode!(%{
          type: "event_callback",
          event: %{
            type: "message",
            channel: "C123",
            channel_type: "channel",
            user: "U_OTHER",
            ts: "1700000000.000100"
          }
        })

      conn = post_signed(conn, body)
      assert response(conn, 200) == ""
    end
  end

  describe "should_handle?/2" do
    test "true for top-level message in channel from target user" do
      assert SlackController.should_handle?(
               %{
                 "type" => "message",
                 "channel" => "C1",
                 "channel_type" => "channel",
                 "user" => @target_user,
                 "ts" => "1700000000.000100"
               },
               @targets
             )
    end

    test "false when channel_type is im (DM)" do
      refute SlackController.should_handle?(
               %{
                 "type" => "message",
                 "channel_type" => "im",
                 "user" => @target_user,
                 "ts" => "1700000000.000100"
               },
               @targets
             )
    end

    test "false when channel_type is mpim (group DM)" do
      refute SlackController.should_handle?(
               %{
                 "type" => "message",
                 "channel_type" => "mpim",
                 "user" => @target_user,
                 "ts" => "1700000000.000100"
               },
               @targets
             )
    end

    test "false when subtype is present (edits, joins, bot messages)" do
      refute SlackController.should_handle?(
               %{
                 "type" => "message",
                 "subtype" => "message_changed",
                 "channel_type" => "channel",
                 "user" => @target_user
               },
               @targets
             )
    end

    test "false when thread_ts is present (thread reply)" do
      refute SlackController.should_handle?(
               %{
                 "type" => "message",
                 "channel_type" => "channel",
                 "user" => @target_user,
                 "ts" => "1700000001.000200",
                 "thread_ts" => "1700000000.000100"
               },
               @targets
             )
    end

    test "false when user is not the target" do
      refute SlackController.should_handle?(
               %{
                 "type" => "message",
                 "channel_type" => "channel",
                 "user" => "U_OTHER"
               },
               @targets
             )
    end

    test "false for non-message event types" do
      refute SlackController.should_handle?(
               %{"type" => "reaction_added", "user" => @target_user},
               @targets
             )
    end

    test "true when user matches any of multiple configured targets" do
      assert SlackController.should_handle?(
               %{
                 "type" => "message",
                 "channel" => "C1",
                 "channel_type" => "channel",
                 "user" => @other_target,
                 "ts" => "1700000000.000100"
               },
               @targets
             )
    end

    test "false with empty target list" do
      refute SlackController.should_handle?(
               %{
                 "type" => "message",
                 "channel" => "C1",
                 "channel_type" => "channel",
                 "user" => @target_user,
                 "ts" => "1700000000.000100"
               },
               []
             )
    end
  end
end
