defmodule EnableWeb.PageController do
  use EnableWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  def mirror(conn, _params) do
    render(conn, :mirror)
  end
end
