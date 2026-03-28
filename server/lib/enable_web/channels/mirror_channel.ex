defmodule EnableWeb.MirrorChannel do
  @moduledoc """
  Phoenix Channel for real-time frame streaming to browser viewers.

  ## Channel Lifecycle

  1. **join** — Browser connects. We send the latest keyframe immediately
     so the viewer sees something right away (no waiting for next frame).
     We also subscribe to PubSub so we receive frame broadcasts.

  2. **handle_info({:new_frame, ...})** — FrameIngress parsed a new TCP frame
     and broadcast it via PubSub. We push it to the browser as a "frame" event.

  3. **handle_in("input", ...)** — Browser sends touch/stylus input. We forward
     it back to the Swift app via FrameIngress's TCP connection.

  ## PubSub Integration

  Phoenix PubSub is the glue between the TCP ingress and WebSocket channels.
  When FrameIngress receives a frame, it broadcasts to the "mirror:frames"
  PubSub topic. Every MirrorChannel process (one per connected browser) is
  subscribed to that topic and receives the message.

  This decouples producers (TCP) from consumers (WebSockets) elegantly —
  the ingress doesn't need to know about channels, and channels don't
  need to know about TCP.

  ## Binary Efficiency

  Frames are base64-encoded before sending over the WebSocket JSON channel.
  This adds ~33% overhead but keeps compatibility with Phoenix's JSON transport.
  For even better performance, a raw WebSocket binary channel could be used,
  but the JSON channel gives us Phoenix's built-in features (presence, etc).
  """

  use EnableWeb, :channel

  require Logger

  @stats_push_interval_ms 5_000

  # -------------------------------------------------------------------
  # Join — the browser wants to start viewing the mirror
  # -------------------------------------------------------------------

  @impl true
  def join("mirror:lobby", _payload, socket) do
    # Subscribe this channel process to frame broadcasts from FrameIngress.
    # Phoenix.PubSub.subscribe makes the current process receive messages
    # sent to the "mirror:frames" topic — they arrive in handle_info/2.
    Phoenix.PubSub.subscribe(Enable.PubSub, "mirror:frames")

    # Send the latest frame immediately so the viewer doesn't see a blank screen.
    # This is a common pattern: "catch up" on join, then stream live updates.
    send(self(), :send_latest_frame)

    # Start periodic stats push
    schedule_stats_push()

    Logger.info("[MirrorChannel] Viewer joined mirror:lobby")

    {:ok, socket}
  end

  # Reject joins to unknown subtopics
  def join("mirror:" <> _subtopic, _payload, _socket) do
    {:error, %{reason: "unknown subtopic"}}
  end

  # -------------------------------------------------------------------
  # Incoming events from the browser
  # -------------------------------------------------------------------

  @doc """
  Handle touch/stylus input from the browser viewer.

  The browser sends input events (tap, drag, stylus) which we forward
  back to the Swift capture app over TCP. This enables remote control
  of the Mac from the e-ink display.
  """
  @impl true
  def handle_in("input", %{"type" => type, "x" => x, "y" => y} = payload, socket) do
    # Encode as a simple JSON message to send back to Swift.
    # The Swift app will parse this and inject input events.
    input_msg = Jason.encode!(%{event: "input", type: type, x: x, y: y, data: payload})

    case Enable.FrameIngress.send_to_swift(input_msg) do
      :ok -> {:noreply, socket}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  # Handle settings changes from the browser (e.g., quality, FPS cap).
  def handle_in("settings", payload, socket) do
    settings_msg = Jason.encode!(%{event: "settings", data: payload})

    case Enable.FrameIngress.send_to_swift(settings_msg) do
      :ok ->
        {:reply, {:ok, %{status: "applied"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  # Catch-all for unknown events
  def handle_in(event, _payload, socket) do
    Logger.warning("[MirrorChannel] Unknown event: #{event}")
    {:noreply, socket}
  end

  # -------------------------------------------------------------------
  # PubSub messages — frames from FrameIngress
  # -------------------------------------------------------------------

  @impl true
  def handle_info({:new_frame, frame_data, metadata}, socket) do
    # Push the frame to the browser. Base64 encoding lets us send binary
    # data over Phoenix's JSON-based channel transport.
    push(socket, "frame", %{
      data: Base.encode64(frame_data),
      seq: metadata.seq,
      keyframe: metadata.keyframe,
      w: Map.get(metadata, :width, 0),
      h: Map.get(metadata, :height, 0)
    })

    {:noreply, socket}
  end

  # Send the latest cached frame on join
  def handle_info(:send_latest_frame, socket) do
    case Enable.FrameStore.get_latest() do
      {data, metadata} ->
        push(socket, "frame", %{
          data: Base.encode64(data),
          seq: metadata.seq,
          keyframe: Map.get(metadata, :keyframe, true),
          w: Map.get(metadata, :width, 0),
          h: Map.get(metadata, :height, 0)
        })

      :none ->
        # No frame yet — that's fine, viewer will get the first one via PubSub
        Logger.debug("[MirrorChannel] No cached frame to send on join")
    end

    {:noreply, socket}
  end

  # Periodic stats push to viewers
  def handle_info(:push_stats, socket) do
    case Enable.FrameStore.get_stats() do
      %{} = stats ->
        push(socket, "stats", stats)

      :none ->
        :ok
    end

    schedule_stats_push()
    {:noreply, socket}
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp schedule_stats_push do
    Process.send_after(self(), :push_stats, @stats_push_interval_ms)
  end
end
