defmodule Predictex.Repo do
  use Ecto.Repo,
    otp_app: :predictex,
    adapter: Ecto.Adapters.Postgres
end
