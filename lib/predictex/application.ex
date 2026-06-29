defmodule Predictex.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        PredictexWeb.Telemetry,
        Predictex.Repo,
        {Oban, Application.fetch_env!(:predictex, Oban)},
        {DNSCluster, query: Application.get_env(:predictex, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Predictex.PubSub},
        # Live viewer presence ("who's watching") — rides Predictex.PubSub (ADR 0002).
        PredictexWeb.Presence,
        # Start a worker by calling: Predictex.Worker.start_link(arg)
        # {Predictex.Worker, arg},
        # Start to serve requests, typically the last entry
        PredictexWeb.Endpoint
      ] ++ capture_subscribers() ++ replay_cache() ++ [Predictex.Fifa.Players.Cache]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Predictex.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PredictexWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp capture_subscribers do
    if Application.get_env(:predictex, :start_capture_subscribers, true) do
      [Predictex.Capture.Recorder, Predictex.LiveScore.Updater]
    else
      []
    end
  end

  defp replay_cache do
    if Application.get_env(:predictex, :start_replay_cache, true) do
      [Predictex.Replay.Cache]
    else
      []
    end
  end
end
