defmodule SlackBot.SlackVerifier do
  @moduledoc """
  Verifies inbound Slack webhooks per
  https://api.slack.com/authentication/verifying-requests-from-slack:

    1. Check the `X-Slack-Request-Timestamp` is within 5 minutes of now (replay
       protection).
    2. Compute HMAC-SHA256 of `"v0:" <> timestamp <> ":" <> raw_body` keyed on
       the signing secret. The hex digest, prefixed with `"v0="`, must match
       `X-Slack-Signature` (constant-time compare).

  Both bytes must match exactly — even a re-encoded JSON body will fail.
  """

  @max_skew_seconds 60 * 5

  @type result :: :ok | {:error, atom()}

  @spec verify(String.t(), String.t() | nil, String.t() | nil, String.t(), keyword()) :: result()
  def verify(raw_body, timestamp, signature, signing_secret, opts \\ [])

  def verify(_raw_body, nil, _signature, _secret, _opts), do: {:error, :missing_timestamp}
  def verify(_raw_body, _timestamp, nil, _secret, _opts), do: {:error, :missing_signature}

  def verify(_raw_body, _timestamp, _signature, secret, _opts)
      when secret in [nil, ""],
      do: {:error, :missing_signing_secret}

  def verify(raw_body, timestamp, signature, secret, opts) do
    now = Keyword.get(opts, :now, System.system_time(:second))

    with {ts_int, ""} <- Integer.parse(timestamp),
         :ok <- check_recent(ts_int, now),
         expected = compute_signature(secret, timestamp, raw_body),
         true <- Plug.Crypto.secure_compare(expected, signature) do
      :ok
    else
      :error -> {:error, :bad_timestamp}
      {:error, _} = err -> err
      {_int, _rest} -> {:error, :bad_timestamp}
      false -> {:error, :bad_signature}
    end
  end

  defp check_recent(ts, now) do
    if abs(now - ts) <= @max_skew_seconds do
      :ok
    else
      {:error, :stale_timestamp}
    end
  end

  defp compute_signature(secret, timestamp, raw_body) do
    base = "v0:" <> timestamp <> ":" <> raw_body
    digest = :crypto.mac(:hmac, :sha256, secret, base) |> Base.encode16(case: :lower)
    "v0=" <> digest
  end
end
