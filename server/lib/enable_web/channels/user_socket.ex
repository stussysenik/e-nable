defmodule EnableWeb.UserSocket do
  @moduledoc """
  The main WebSocket entry point for browser viewers.

  ## How Phoenix Sockets Work

  A Phoenix Socket is a persistent WebSocket connection between a browser
  and the server. Once connected, the browser can join multiple "channels"
  (topics) over the same socket — multiplexing many logical conversations
  over one TCP connection.

  Flow:
  1. Browser opens WebSocket to `/socket/websocket`
  2. This module's `connect/3` authenticates (we allow all for now)
  3. Browser sends `{topic: "mirror:lobby", event: "phx_join"}`
  4. Phoenix routes to `MirrorChannel.join/3` based on the channel mapping below

  ## Why timeout: :infinity?

  The mirror viewer should stay connected indefinitely — it's a persistent
  display, not a request/response cycle. We override the default 60s
  timeout in the endpoint socket configuration.
  """

  use Phoenix.Socket

  # Route all "mirror:*" topics to MirrorChannel.
  # The wildcard lets us add sub-topics later (e.g., "mirror:room:abc")
  channel "mirror:*", EnableWeb.MirrorChannel

  @doc """
  Accept all connections. In a production system you'd verify auth tokens
  here, but for a local screen-mirroring tool, we trust the local network.
  """
  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @doc """
  Socket identifier — returning nil means each connection is anonymous.
  If we needed to track specific users (e.g., for input attribution),
  we'd return a unique ID like `"user:<user_id>"`.
  """
  @impl true
  def id(_socket), do: nil
end
