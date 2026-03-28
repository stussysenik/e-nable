defmodule Enable.FrameIngress do
  @moduledoc """
  GenServer TCP receiver for the Swift screen capture app.

  ## Architecture

  This GenServer listens on TCP port 9999 and accepts a single connection
  from the Swift capture app. When a connection arrives, it parses the
  binary frame protocol, stores frames in ETS via `FrameStore`, and
  broadcasts to PubSub so the Channel can push to browsers.

  ## Binary Protocol

  The Swift app sends frames using a compact binary protocol:

      <<0xDA, 0x7E, flags::8, seq::little-32, len::little-32, payload::binary-size(len)>>

  - Magic bytes `0xDA 0x7E` — frame delimiter, lets us sync after errors
  - Flags byte — bit 0: keyframe, bit 1: color mode
  - Sequence — monotonically increasing frame counter (little-endian u32)
  - Length — payload size in bytes (little-endian u32)
  - Payload — compressed frame data (PNG/raw pixels)

  Erlang's binary pattern matching makes parsing this protocol trivial
  and extremely fast — no manual byte manipulation needed.

  ## Reconnection

  The Swift app may restart (Xcode rebuild, crash, etc). When the TCP
  connection drops, we go back to accepting a new connection. The
  GenServer stays alive throughout — only the socket changes.

  ## "Let it crash" design

  If anything goes wrong with TCP, we log it and loop back to accept.
  The supervisor will restart the entire GenServer if it truly crashes.
  No defensive try/catch needed — OTP handles recovery.
  """

  use GenServer

  require Logger

  @listen_port 9999
  @stats_interval_ms 2_000

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Send a message back to the connected Swift app over the TCP socket.

  Used for forwarding touch/input events from browser viewers back to
  the Mac. Returns `:ok` or `{:error, reason}`.
  """
  @spec send_to_swift(binary()) :: :ok | {:error, term()}
  def send_to_swift(data) do
    GenServer.call(__MODULE__, {:send, data})
  end

  # -------------------------------------------------------------------
  # GenServer callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(_args) do
    # Start the TCP listener in a separate process so init doesn't block.
    # GenServer.init must return quickly — if we blocked on :gen_tcp.accept
    # here, the supervisor would timeout waiting for this child to start.
    send(self(), :listen)

    {:ok,
     %{
       listen_socket: nil,
       client_socket: nil,
       buffer: <<>>,
       # Stats tracking
       frames_received: 0,
       bytes_received: 0,
       last_stats_time: System.monotonic_time(:millisecond),
       fps: 0.0,
       bytes_per_sec: 0,
       frames_since_last_stats: 0,
       bytes_since_last_stats: 0
     }}
  end

  # --- Step 1: Open the listening socket ---

  @impl true
  def handle_info(:listen, state) do
    # TCP listen options:
    # - :binary — receive data as binaries (not charlists)
    # - active: false — we'll use :gen_tcp.recv or switch to active mode
    # - reuseaddr: true — allows quick restart without TIME_WAIT issues
    # - packet: :raw — no Erlang packet framing, we parse ourselves
    case :gen_tcp.listen(@listen_port, [
           :binary,
           active: false,
           reuseaddr: true,
           packet: :raw,
           buffer: 1_048_576
         ]) do
      {:ok, listen_socket} ->
        Logger.info("[FrameIngress] Listening on TCP port #{@listen_port}")
        # Immediately start accepting
        send(self(), :accept)
        {:noreply, %{state | listen_socket: listen_socket}}

      {:error, reason} ->
        Logger.error("[FrameIngress] Failed to listen on port #{@listen_port}: #{inspect(reason)}")
        # Retry after a delay — port might be in use
        Process.send_after(self(), :listen, 2_000)
        {:noreply, state}
    end
  end

  # --- Step 2: Accept a connection ---

  def handle_info(:accept, %{listen_socket: listen_socket} = state) do
    # :gen_tcp.accept/1 blocks, but that's fine in a GenServer —
    # it will block this process until a client connects.
    # For a production system you'd use Ranch or a Task, but for
    # a single-client protocol this is clean and simple.
    case :gen_tcp.accept(listen_socket) do
      {:ok, client_socket} ->
        Logger.info("[FrameIngress] Swift app connected!")

        # Switch to active mode — Erlang will send us {:tcp, socket, data}
        # messages as data arrives. This is more efficient than polling
        # with :gen_tcp.recv in a loop.
        :inet.setopts(client_socket, active: true)

        # Start stats reporting timer
        schedule_stats_report()

        {:noreply, %{state | client_socket: client_socket, buffer: <<>>}}

      {:error, reason} ->
        Logger.warning("[FrameIngress] Accept failed: #{inspect(reason)}")
        Process.send_after(self(), :accept, 1_000)
        {:noreply, state}
    end
  end

  # --- Step 3: Receive TCP data (active mode) ---

  def handle_info({:tcp, _socket, data}, state) do
    # Append new data to our buffer and try to parse complete frames.
    # TCP is a stream protocol — data arrives in arbitrary chunks,
    # so a single recv might contain half a frame, or three frames.
    # We accumulate in a buffer and parse greedily.
    new_buffer = state.buffer <> data
    {frames, remaining_buffer} = parse_frames(new_buffer)

    # Process each complete frame
    new_state =
      Enum.reduce(frames, state, fn frame, acc ->
        handle_frame(frame, acc)
      end)

    {:noreply, %{new_state | buffer: remaining_buffer}}
  end

  # --- TCP connection closed ---

  def handle_info({:tcp_closed, _socket}, state) do
    Logger.warning("[FrameIngress] Swift app disconnected. Waiting for reconnection...")

    update_stats_disconnected()

    # Go back to accepting — the Swift app will reconnect
    send(self(), :accept)
    {:noreply, %{state | client_socket: nil, buffer: <<>>}}
  end

  # --- TCP error ---

  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.error("[FrameIngress] TCP error: #{inspect(reason)}. Reconnecting...")
    send(self(), :accept)
    {:noreply, %{state | client_socket: nil, buffer: <<>>}}
  end

  # --- Periodic stats reporting ---

  def handle_info(:report_stats, %{client_socket: nil} = state) do
    # Not connected, don't report — but keep the timer going
    schedule_stats_report()
    {:noreply, state}
  end

  def handle_info(:report_stats, state) do
    now = System.monotonic_time(:millisecond)
    elapsed_ms = max(now - state.last_stats_time, 1)
    elapsed_sec = elapsed_ms / 1_000.0

    fps = state.frames_since_last_stats / elapsed_sec
    bps = round(state.bytes_since_last_stats / elapsed_sec)

    Logger.debug(
      "[FrameIngress] Stats: #{Float.round(fps, 1)} FPS, " <>
        "#{format_bytes(bps)}/s, " <>
        "#{state.frames_received} total frames"
    )

    Enable.FrameStore.put_stats(%{
      fps: Float.round(fps, 1),
      bytes_per_sec: bps,
      total_frames: state.frames_received,
      total_bytes: state.bytes_received,
      connected: true
    })

    schedule_stats_report()

    {:noreply,
     %{
       state
       | last_stats_time: now,
         fps: fps,
         bytes_per_sec: bps,
         frames_since_last_stats: 0,
         bytes_since_last_stats: 0
     }}
  end

  # --- Send data back to Swift ---

  @impl true
  def handle_call({:send, _data}, _from, %{client_socket: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:send, data}, _from, %{client_socket: socket} = state) do
    result = :gen_tcp.send(socket, data)
    {:reply, result, state}
  end

  # -------------------------------------------------------------------
  # Binary protocol parsing — Erlang's killer feature!
  #
  # Erlang (and Elixir) can pattern match on binary data with bit-level
  # precision. This makes parsing network protocols incredibly clean
  # compared to manual byte manipulation in C/Swift/etc.
  # -------------------------------------------------------------------

  @magic_byte_1 0xDA
  @magic_byte_2 0x7E
  @header_size 11

  defp parse_frames(buffer), do: parse_frames(buffer, [])

  defp parse_frames(buffer, acc) when byte_size(buffer) < @header_size do
    # Not enough data for a complete header — return what we have
    # and wait for more TCP data to arrive
    {Enum.reverse(acc), buffer}
  end

  defp parse_frames(
         <<@magic_byte_1, @magic_byte_2, flags::8, seq::little-32, len::little-32,
           rest::binary>> = buffer,
         acc
       ) do
    # We matched the header! Now check if we have the full payload.
    if byte_size(rest) >= len do
      # Extract the payload and continue parsing the remainder
      <<payload::binary-size(len), remaining::binary>> = rest

      frame = %{
        flags: flags,
        seq: seq,
        keyframe: Bitwise.band(flags, 0x01) == 0x01,
        color_mode: Bitwise.band(flags, 0x02) == 0x02,
        payload: payload
      }

      parse_frames(remaining, [frame | acc])
    else
      # Incomplete payload — need more data from TCP
      {Enum.reverse(acc), buffer}
    end
  end

  defp parse_frames(<<_byte, rest::binary>>, acc) do
    # Didn't match magic bytes — skip one byte and try again.
    # This handles stream re-synchronization after corruption
    # or partial data. In practice this rarely fires.
    parse_frames(rest, acc)
  end

  defp parse_frames(<<>>, acc) do
    {Enum.reverse(acc), <<>>}
  end

  # -------------------------------------------------------------------
  # Frame handling — store in ETS, broadcast to viewers
  # -------------------------------------------------------------------

  defp handle_frame(frame, state) do
    payload_size = byte_size(frame.payload)

    metadata = %{
      seq: frame.seq,
      keyframe: frame.keyframe,
      color_mode: frame.color_mode,
      timestamp: System.system_time(:millisecond),
      size: payload_size
    }

    # Store in ETS for instant reads by the Channel
    Enable.FrameStore.put_frame(frame.payload, metadata)

    # Broadcast to all connected viewers via Phoenix PubSub.
    # PubSub is a lightweight pub/sub built into Phoenix — processes
    # subscribe to topics and receive messages when someone broadcasts.
    # The Channel subscribes to "mirror:frames" on join.
    Phoenix.PubSub.broadcast(Enable.PubSub, "mirror:frames", {:new_frame, frame.payload, metadata})

    %{
      state
      | frames_received: state.frames_received + 1,
        bytes_received: state.bytes_received + payload_size,
        frames_since_last_stats: state.frames_since_last_stats + 1,
        bytes_since_last_stats: state.bytes_since_last_stats + payload_size
    }
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp schedule_stats_report do
    Process.send_after(self(), :report_stats, @stats_interval_ms)
  end

  defp update_stats_disconnected do
    Enable.FrameStore.put_stats(%{
      fps: 0.0,
      bytes_per_sec: 0,
      total_frames: 0,
      total_bytes: 0,
      connected: false
    })
  end

  defp format_bytes(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp format_bytes(bytes) when bytes >= 1_024, do: "#{Float.round(bytes / 1_024, 1)} KB"
  defp format_bytes(bytes), do: "#{bytes} B"
end
