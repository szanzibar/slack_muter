defmodule SlackBotWeb.Router do
  use SlackBotWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SlackBotWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :slack_events do
    plug :accepts, ["json"]
    plug SlackBotWeb.Plugs.VerifySlackSignature
  end

  scope "/", SlackBotWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/slack", SlackBotWeb do
    pipe_through :slack_events

    post "/events", SlackController, :events
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:slack_bot, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SlackBotWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end

    # Diagnostic endpoint to simulate Slack events without signature
    # verification — see SlackBotWeb.DevController for the request shape.
    scope "/dev/slack", SlackBotWeb do
      pipe_through :api
      post "/events", DevController, :events
    end
  end
end
