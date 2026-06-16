defmodule Predictex.ObanConfigTest do
  use ExUnit.Case, async: true

  test "the result sync worker is registered on a 15-minute cron" do
    plugins = Application.fetch_env!(:predictex, Oban)[:plugins]

    {_mod, opts} =
      Enum.find(plugins, fn
        {Oban.Plugins.Cron, _opts} -> true
        _ -> false
      end)

    assert {"*/15 * * * *", Predictex.Workers.ResultSync} in opts[:crontab]
  end
end
