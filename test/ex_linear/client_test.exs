defmodule ExLinear.ClientTest do
  use ExUnit.Case, async: false

  alias ExLinear.{Client, Issue}

  @base_config [
    api_key: "test-key",
    endpoint: "https://api.linear.app/graphql",
    project_slug: "ENG"
  ]

  setup do
    previous_request_fun = Application.get_env(:ex_linear, :request_fun, :__missing__)

    on_exit(fn ->
      case previous_request_fun do
        :__missing__ ->
          Application.delete_env(:ex_linear, :request_fun)

        fun ->
          Application.put_env(:ex_linear, :request_fun, fun)
      end
    end)

    :ok
  end

  defp set_request_fun(fun) do
    Application.put_env(:ex_linear, :request_fun, fun)
  end

  describe "graphql/4" do
    test "returns body on 200 when request_fun is set in application config" do
      set_request_fun(fn _c, _payload, _headers ->
        {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "viewer-1"}}}}}
      end)

      assert {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-1"}}}} =
               Client.graphql(@base_config, "query Viewer { viewer { id } }", %{})
    end

    test "returns error and logs on non-200 status" do
      set_request_fun(fn _c, _payload, _headers ->
        {:ok,
         %{
           status: 400,
           body: %{
             "errors" => [
               %{
                 "message" => "Variable \"$ids\" got invalid value",
                 "extensions" => %{"code" => "BAD_USER_INPUT"}
               }
             ]
           }
         }}
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:linear_api_status, 400}} =
                   Client.graphql(
                     @base_config,
                     "query IssuesById($ids: [ID!]!) { issues(filter: {id: {in: $ids}}) { nodes { id } } }",
                     %{ids: ["x"]}
                   )
        end)

      assert log =~ "Linear GraphQL request failed status=400"
      assert log =~ "BAD_USER_INPUT"
      assert log =~ "Variable"
    end

    test "returns error when request_fun returns error" do
      set_request_fun(fn _c, _payload, _headers -> {:error, :timeout} end)

      assert {:error, {:linear_api_request, :timeout}} =
               Client.graphql(@base_config, "query X { x }", %{})
    end

    test "returns error when api_key is nil" do
      assert {:error, {:linear_api_request, :missing_linear_api_token}} =
               Client.graphql(
                 [endpoint: "https://api.linear.app/graphql"],
                 "query X { x }",
                 %{}
               )
    end
  end

  describe "ExLinear.Issue" do
    test "label_names returns labels" do
      issue = %Issue{id: "1", labels: ["frontend", "infra"]}
      assert Issue.label_names(issue) == ["frontend", "infra"]
    end
  end
end
