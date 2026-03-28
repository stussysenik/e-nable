defmodule Enable.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      EnableWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:enable, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Enable.PubSub},

      # Frame streaming infrastructure — order matters!
      # FrameStore must start before FrameIngress (creates the ETS table).
      # FrameIngress must start before Endpoint (TCP listener ready before HTTP).
      Enable.FrameStore,
      Enable.FrameIngress,

      # Start to serve requests, typically the last entry
      EnableWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Enable.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EnableWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
