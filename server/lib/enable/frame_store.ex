defmodule Enable.FrameStore do
  @moduledoc """
  ETS-backed frame cache for O(1) reads of the latest screen capture.

  ## Why ETS?

  ETS (Erlang Term Storage) gives us a shared in-memory table that any process
  can read from without going through a GenServer bottleneck. This is critical
  for frame streaming — we want the Channel to read the latest frame without
  blocking the TCP ingress process.

  The table is owned by this GenServer (which does nothing but keep the table
  alive). If this process crashes, the supervisor restarts it and the table is
  recreated — we lose the cached frame, but the next TCP frame repopulates it
  instantly. Classic "let it crash" philosophy.

  ## Storage Layout

  The ETS table `:frame_store` holds two keys:
  - `:latest_frame` — `{frame_data, metadata}` for the most recent capture
  - `:stats` — running statistics (FPS, byte counts, connection info)
  """

  use GenServer

  require Logger

  # -------------------------------------------------------------------
  # Public API — these read directly from ETS, no GenServer call needed.
  # This is the beauty of ETS: concurrent readers with zero contention.
  # -------------------------------------------------------------------

  @doc """
  Store the latest frame and its metadata into ETS.

  Called by `FrameIngress` each time a new frame arrives over TCP.
  Uses `:ets.insert/2` which is atomic for single-key writes.
  """
  @spec put_frame(binary(), map()) :: true
  def put_frame(frame_data, metadata) do
    :ets.insert(:frame_store, {:latest_frame, frame_data, metadata})
  end

  @doc """
  Retrieve the latest frame. Returns `{data, metadata}` or `:none`.

  Pattern matches on the ETS lookup result — if the table is empty
  (server just started, no frames yet), we return `:none` so callers
  can handle the "no data yet" case cleanly.
  """
  @spec get_latest() :: {binary(), map()} | :none
  def get_latest do
    case :ets.lookup(:frame_store, :latest_frame) do
      [{:latest_frame, data, metadata}] -> {data, metadata}
      [] -> :none
    end
  end

  @doc """
  Store running statistics (FPS, bytes received, connection status).
  """
  @spec put_stats(map()) :: true
  def put_stats(stats) do
    :ets.insert(:frame_store, {:stats, stats})
  end

  @doc """
  Retrieve streaming statistics. Returns a map or `:none`.

  Useful for the Channel to push periodic stats to connected viewers,
  and for the debug/admin UI.
  """
  @spec get_stats() :: map() | :none
  def get_stats do
    case :ets.lookup(:frame_store, :stats) do
      [{:stats, stats}] -> stats
      [] -> :none
    end
  end

  # -------------------------------------------------------------------
  # GenServer callbacks — minimal, just owns the ETS table.
  # -------------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Creates the ETS table on init.

  Options explained:
  - `:named_table` — access by atom name instead of table reference
  - `:set` — one value per key, last write wins (perfect for "latest frame")
  - `:public` — any process can read/write (FrameIngress writes, Channel reads)
  - `read_concurrency: true` — optimizes for many concurrent readers (viewers)
  """
  @impl true
  def init(_args) do
    table =
      :ets.new(:frame_store, [
        :named_table,
        :set,
        :public,
        read_concurrency: true
      ])

    Logger.info("[FrameStore] ETS table created: #{inspect(table)}")

    {:ok, %{table: table}}
  end
end
