defmodule ExLinear.ClientTest do
  use ExUnit.Case, async: false

  alias ExLinear.{Client, Config, Issue}

  @base_config [
    api_key: "test-key",
    endpoint: Config.default_endpoint(),
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
                 [endpoint: Config.default_endpoint()],
                 "query X { x }",
                 %{}
               )
    end
  end

  describe "fetch_candidate_issues/1" do
    test "returns error when api_key is nil" do
      assert {:error, :missing_linear_api_token} =
               Client.fetch_candidate_issues(
                 endpoint: Config.default_endpoint(),
                 project_slug: "ENG",
                 active_states: ["Todo"]
               )
    end

    test "returns error when project_slug is nil" do
      assert {:error, :missing_linear_project_slug} =
               Client.fetch_candidate_issues(
                 api_key: "key",
                 endpoint: Config.default_endpoint(),
                 active_states: ["Todo"]
               )
    end

    test "returns decoded issues using project_slug and active_states from config" do
      config =
        @base_config ++
          [project_slug: "ENG", active_states: ["Todo", "In Progress"]]

      set_request_fun(fn _c, payload, _headers ->
        vars = payload["variables"] || %{}
        assert vars[:projectSlug] == "ENG"
        assert vars[:stateNames] == ["Todo", "In Progress"]
        assert payload["query"] =~ "IssuesByProjectAndStates"

        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "issues" => %{
                 "nodes" => [
                   %{
                     "id" => "issue-1",
                     "identifier" => "MT-1",
                     "title" => "Candidate",
                     "state" => %{"name" => "Todo"},
                     "labels" => %{"nodes" => []},
                     "inverseRelations" => %{"nodes" => []}
                   }
                 ],
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
               }
             }
           }
         }}
      end)

      assert {:ok, [%Issue{} = issue]} = Client.fetch_candidate_issues(config)
      assert issue.id == "issue-1"
      assert issue.identifier == "MT-1"
      assert issue.state == "Todo"
    end

    test "paginates by page and merges issues in order" do
      config = Keyword.merge(@base_config, project_slug: "P1", active_states: ["Todo"])

      first_page_nodes = [
        %{
          "id" => "a",
          "identifier" => "MT-A",
          "title" => "A",
          "state" => %{"name" => "Todo"},
          "labels" => %{"nodes" => []},
          "inverseRelations" => %{"nodes" => []}
        }
      ]

      second_page_nodes = [
        %{
          "id" => "b",
          "identifier" => "MT-B",
          "title" => "B",
          "state" => %{"name" => "Todo"},
          "labels" => %{"nodes" => []},
          "inverseRelations" => %{"nodes" => []}
        }
      ]

      set_request_fun(fn _c, payload, _headers ->
        vars = payload["variables"] || %{}
        send(self(), {:fetch_page, vars[:after], vars[:projectSlug], vars[:stateNames]})

        if vars[:after] == nil do
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "issues" => %{
                   "nodes" => first_page_nodes,
                   "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor-2"}
                 }
               }
             }
           }}
        else
          assert vars[:after] == "cursor-2"

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "issues" => %{
                   "nodes" => second_page_nodes,
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }}
        end
      end)

      assert {:ok, issues} = Client.fetch_candidate_issues(config)
      assert length(issues) == 2
      assert Enum.map(issues, & &1.id) == ["a", "b"]
      assert Enum.map(issues, & &1.identifier) == ["MT-A", "MT-B"]

      assert_receive {:fetch_page, nil, "P1", ["Todo"]}
      assert_receive {:fetch_page, "cursor-2", "P1", ["Todo"]}
    end

    test "with assignee \"me\" calls viewer then issues and applies assignee filter" do
      Process.delete(:viewer_sent)

      config =
        @base_config ++
          [project_slug: "P", active_states: ["Todo"], assignee: "me"]

      set_request_fun(fn _c, payload, _headers ->
        query = payload["query"] || ""
        is_viewer = query =~ "ViewerCurrent" or (query =~ "viewer" and not (query =~ "issues"))

        if is_viewer and Process.get(:viewer_sent) != true do
          Process.put(:viewer_sent, true)
          send(self(), :viewer_called)
          {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "usr-me"}}}}}
        else
          send(self(), :issues_called)

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "issues" => %{
                   "nodes" => [
                     %{
                       "id" => "i1",
                       "identifier" => "MT-1",
                       "title" => "Mine",
                       "state" => %{"name" => "Todo"},
                       "assignee" => %{"id" => "usr-me"},
                       "labels" => %{"nodes" => []},
                       "inverseRelations" => %{"nodes" => []}
                     }
                   ],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }}
        end
      end)

      assert {:ok, [%Issue{} = issue]} = Client.fetch_candidate_issues(config)
      assert issue.id == "i1"
      assert issue.assignee_id == "usr-me"
      assert issue.assignee_matches_filter == true

      assert_receive :viewer_called, 1_000
      assert_receive :issues_called, 1_000
    end

    test "with assignee \"me\" returns error when viewer request fails" do
      config =
        @base_config ++
          [project_slug: "P", active_states: ["Todo"], assignee: "me"]

      set_request_fun(fn _c, _payload, _headers ->
        {:error, :timeout}
      end)

      assert {:error, {:linear_api_request, :timeout}} = Client.fetch_candidate_issues(config)
    end
  end

  describe "ExLinear.Issue" do
    test "label_names returns labels" do
      issue = %Issue{id: "1", labels: ["frontend", "infra"]}
      assert Issue.label_names(issue) == ["frontend", "infra"]
    end
  end
end
