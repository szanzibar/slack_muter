defmodule SlackBot.SlackVerifierTest do
  use ExUnit.Case, async: true

  alias SlackBot.SlackVerifier

  @secret "8f742231b10e8888abcd99yyyzzz85a5"
  @body ~s({"token":"abc","type":"event_callback"})

  defp sign(timestamp, body, secret \\ @secret) do
    base = "v0:" <> timestamp <> ":" <> body
    digest = :crypto.mac(:hmac, :sha256, secret, base) |> Base.encode16(case: :lower)
    "v0=" <> digest
  end

  test "verifies a fresh, correctly-signed request" do
    now = 1_700_000_000
    ts = "1700000000"
    sig = sign(ts, @body)

    assert :ok = SlackVerifier.verify(@body, ts, sig, @secret, now: now)
  end

  test "rejects a wrong signature" do
    now = 1_700_000_000
    ts = "1700000000"
    bad_sig = "v0=" <> String.duplicate("0", 64)

    assert {:error, :bad_signature} = SlackVerifier.verify(@body, ts, bad_sig, @secret, now: now)
  end

  test "rejects when body has been tampered with" do
    now = 1_700_000_000
    ts = "1700000000"
    sig = sign(ts, @body)

    assert {:error, :bad_signature} =
             SlackVerifier.verify(@body <> "x", ts, sig, @secret, now: now)
  end

  test "rejects timestamps older than 5 minutes" do
    now = 1_700_000_000
    ts = "1699999000"
    sig = sign(ts, @body)

    assert {:error, :stale_timestamp} = SlackVerifier.verify(@body, ts, sig, @secret, now: now)
  end

  test "rejects timestamps more than 5 minutes in the future" do
    now = 1_700_000_000
    ts = "1700000400"
    sig = sign(ts, @body)

    assert {:error, :stale_timestamp} = SlackVerifier.verify(@body, ts, sig, @secret, now: now)
  end

  test "rejects non-numeric timestamps" do
    sig = "v0=" <> String.duplicate("0", 64)
    assert {:error, :bad_timestamp} = SlackVerifier.verify(@body, "not-a-number", sig, @secret)
  end

  test "rejects when timestamp header missing" do
    assert {:error, :missing_timestamp} = SlackVerifier.verify(@body, nil, "v0=x", @secret)
  end

  test "rejects when signature header missing" do
    assert {:error, :missing_signature} = SlackVerifier.verify(@body, "1700000000", nil, @secret)
  end

  test "rejects when signing secret unset" do
    assert {:error, :missing_signing_secret} =
             SlackVerifier.verify(@body, "1700000000", "v0=x", nil)

    assert {:error, :missing_signing_secret} =
             SlackVerifier.verify(@body, "1700000000", "v0=x", "")
  end
end
