defmodule EnableWeb.MirrorWebSocket do
  @moduledoc """
  Plug that upgrades HTTP requests to /ws/mirror into raw WebSocket connections.

  Phoenix's `socket` macro only works with `Phoenix.Socket` modules (Channel protocol).
  For raw binary WebSocket (no JSON overhead), we use `WebSockAdapter.upgrade/3` directly.
  The `EnableWeb.MirrorWs` module implements the `WebSock` behaviour to handle frames.
  """
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{request_path: "/ws/mirror"} = conn, _opts) do
    conn
    |> WebSockAdapter.upgrade(EnableWeb.MirrorWs, %{}, timeout: :infinity)
    |> Plug.Conn.halt()
  end

  def call(conn, _opts), do: conn
end
