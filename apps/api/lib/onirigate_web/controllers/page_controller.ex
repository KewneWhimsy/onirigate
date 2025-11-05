defmodule OnirigateWeb.PageController do
  use OnirigateWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
