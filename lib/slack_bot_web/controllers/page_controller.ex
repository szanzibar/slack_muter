defmodule SlackBotWeb.PageController do
  use SlackBotWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
