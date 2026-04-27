defmodule SlackBot.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SlackBotWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:slack_bot, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: SlackBot.PubSub},
      {Task.Supervisor, name: SlackBot.TaskSupervisor},
      SlackBot.EventLogger,
      # Start to serve requests, typically the last entry
      SlackBotWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SlackBot.Supervisor]
    result = Supervisor.start_link(children, opts)
    install_file_logger_handler()
    result
  end

  # Routes every Logger call through SlackBot.EventLogger so they end up
  # in the same daily-rotating logs/events-YYYY-MM-DD.log file. Idempotent —
  # if the handler is already installed (e.g. from a previous app start in
  # tests), we leave it alone.
  defp install_file_logger_handler do
    handler_id = :slack_bot_file

    case :logger.add_handler(handler_id, SlackBot.LoggerHandler, %{level: :all}) do
      :ok -> :ok
      {:error, {:already_exist, ^handler_id}} -> :ok
      other -> other
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SlackBotWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
