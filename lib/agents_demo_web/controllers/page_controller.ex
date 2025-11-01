defmodule AgentsDemoWeb.PageController do
  use AgentsDemoWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
