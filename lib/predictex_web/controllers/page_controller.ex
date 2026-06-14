defmodule PredictexWeb.PageController do
  use PredictexWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
