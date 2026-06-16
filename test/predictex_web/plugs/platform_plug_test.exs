defmodule PredictexWeb.PlatformPlugTest do
  use PredictexWeb.ConnCase, async: true

  alias PredictexWeb.PlatformPlug

  defp run(ua) do
    conn = Plug.Test.init_test_session(build_conn(), %{})
    conn = if ua, do: Plug.Conn.put_req_header(conn, "user-agent", ua), else: conn
    PlatformPlug.call(conn, PlatformPlug.init([]))
  end

  test "classifies an iPhone UA as :mobile" do
    conn = run("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Safari")
    assert Plug.Conn.get_session(conn, :platform) == :mobile
  end

  test "classifies an Android UA as :mobile" do
    conn = run("Mozilla/5.0 (Linux; Android 14; Pixel 7) Chrome Mobile")
    assert Plug.Conn.get_session(conn, :platform) == :mobile
  end

  test "classifies a desktop UA as :desktop" do
    conn = run("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/120 Safari")
    assert Plug.Conn.get_session(conn, :platform) == :desktop
  end

  test "defaults to :mobile when the User-Agent is absent" do
    conn = run(nil)
    assert Plug.Conn.get_session(conn, :platform) == :mobile
  end
end
