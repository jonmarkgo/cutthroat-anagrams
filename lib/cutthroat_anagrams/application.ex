defmodule CutthroatAnagrams.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CutthroatAnagramsWeb.Telemetry,
      CutthroatAnagrams.Repo,
      {DNSCluster, query: Application.get_env(:cutthroat_anagrams, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: CutthroatAnagrams.PubSub},
      {Registry, keys: :unique, name: CutthroatAnagrams.GameRegistry},
      CutthroatAnagrams.GameSupervisor,
      # Start to serve requests, typically the last entry
      CutthroatAnagramsWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CutthroatAnagrams.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CutthroatAnagramsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
