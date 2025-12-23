defmodule Aria2Api.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias Aria2Api.Router

  @opts Router.init([])

  describe "health check" do
    test "GET /health returns 200" do
      conn =
        conn(:get, "/health")
        |> Router.call(@opts)

      assert conn.status == 200
      assert %{"status" => "healthy"} = Jason.decode!(conn.resp_body)
    end
  end

  describe "unmatched routes" do
    test "returns 404 for unknown paths" do
      conn =
        conn(:get, "/unknown")
        |> Router.call(@opts)

      assert conn.status == 404
    end
  end
end
