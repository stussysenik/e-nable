defmodule EnableWeb.MirrorWs do
  @moduledoc """
  Raw WebSocket handler for binary frame streaming to browser viewers.

  ## Why raw WebSocket instead of Phoenix Channels?

  Phoenix Channels wrap WebSocket in a JSON-based protocol with topics,
  events, and refs. For screen mirroring, we need to push raw binary
  frame data (greyscale pixels) at high frequency. Encoding binary as
  base64 JSON would add ~33% overhead and parsing latency.

  Raw WebSocket lets us send binary ArrayBuffer messages directly,
  which the browser receives as an ArrayBuffer and renders to canvas
  without any encoding/decoding step.

  ## Protocol

  Server → Client (binary):
    [0xDA 0x7E] [flags:1] [seq:4 LE] [width:2 LE] [height:2 LE] [payload...]

  Client → Server (text/JSON):
    {"type": "input", "x": 0.5, "y": 0.3, ...}
  """

  @behaviour WebSock

  require Logger

  @impl WebSock
  def init(_opts) do
    # Subscribe to frame broadcasts from FrameIngress
    Phoenix.PubSub.subscribe(Enable.PubSub, "mirror:frames")

    Logger.info("[MirrorWs] Browser viewer connected")

    # Send the latest cached frame immediately so the viewer sees something
    case Enable.FrameStore.get_latest() do
      {frame_data, meta} ->
        # Build a binary message with the frame
        header = build_header(meta)
        {:push, {:binary, header <> frame_data}, %{viewers: 1}}

      :none ->
        {:ok, %{viewers: 1}}
    end
  end

  @impl WebSock
  def handle_in({text, opcode: :text}, state) do
    # Text messages from browser are JSON (input events, settings)
    case Jason.decode(text) do
      {:ok, %{"type" => "input"} = event} ->
        # Forward input event to Swift capture via FrameIngress
        Enable.FrameIngress.send_to_swift(Jason.encode!(event))
        {:ok, state}

      {:ok, %{"type" => "settings"} = event} ->
        Logger.info("[MirrorWs] Settings: #{inspect(event)}")
        {:ok, state}

      {:ok, %{"type" => "viewport"} = event} ->
        Logger.debug("[MirrorWs] Viewport: #{inspect(event)}")
        {:ok, state}

      {:ok, other} ->
        Logger.warning("[MirrorWs] Unknown message: #{inspect(other)}")
        {:ok, state}

      {:error, _} ->
        Logger.warning("[MirrorWs] Invalid JSON from browser")
        {:ok, state}
    end
  end

  def handle_in({_binary, opcode: :binary}, state) do
    # We don't expect binary from the browser, ignore
    {:ok, state}
  end

  @impl WebSock
  def handle_info({:new_frame, frame_data, meta}, state) do
    # New frame from FrameIngress via PubSub — push to browser
    header = build_header(meta)
    {:push, {:binary, header <> frame_data}, state}
  end

  def handle_info(_msg, state) do
    {:ok, state}
  end

  @impl WebSock
  def terminate(_reason, _state) do
    Logger.info("[MirrorWs] Browser viewer disconnected")
    :ok
  end

  # Build the 11-byte binary header matching the wire protocol.
  #
  # Format: [magic:2] [flags:1] [seq:4 LE] [width:2 LE] [height:2 LE]
  #
  # The browser client (mirror.js) parses this exact format.
  defp build_header(meta) do
    flags = if meta[:keyframe], do: 0x01, else: 0x00
    flags = if meta[:color], do: Bitwise.bor(flags, 0x02), else: flags
    seq = meta[:sequence] || 0
    width = meta[:width] || 1240
    height = meta[:height] || 930

    <<0xDA, 0x7E, flags::8, seq::little-32, width::little-16, height::little-16>>
  end
end
