defmodule CutthroatAnagramsWeb.PageController do
  use CutthroatAnagramsWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
