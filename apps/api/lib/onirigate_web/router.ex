defmodule OnirigateWeb.Router do
  use OnirigateWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {OnirigateWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", OnirigateWeb do
    pipe_through :browser

    get "/", PageController, :home
    
    # Routes Coral Wars
    live "/coral-wars", CoralWarsLive.Lobby
    live "/coral-wars/:room_id", CoralWarsLive.Game
  end
end