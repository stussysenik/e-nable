defmodule EnableWeb.Router do
  use EnableWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {EnableWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", EnableWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/mirror", PageController, :mirror
  end

  # Other scopes may use custom stacks.
  # scope "/api", EnableWeb do
  #   pipe_through :api
  # end
end
