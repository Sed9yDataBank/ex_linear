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

  describe "fetch_issues_by_states/2" do
    test "returns empty list for empty state names" do
      assert {:ok, []} = Client.fetch_issues_by_states(@base_config, [])
    end

    test "returns error when api_key is nil" do
      assert {:error, :missing_linear_api_token} =
               Client.fetch_issues_by_states(
                 [endpoint: Config.default_endpoint(), project_slug: "ENG"],
                 ["Todo"]
               )
    end

    test "returns error when project_slug is nil" do
      assert {:error, :missing_linear_project_slug} =
               Client.fetch_issues_by_states(
                 [api_key: "key", endpoint: Config.default_endpoint()],
                 ["Todo"]
               )
    end

    test "uses request_fun from config and decodes issues" do
      set_request_fun(fn _c, payload, _headers ->
        vars = payload["variables"] || %{}
        assert vars[:projectSlug] == "ENG"
        assert vars[:stateNames] == ["Todo"]
        assert payload["query"] =~ "IssuesByProjectAndStates"

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
                     "title" => "T",
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

      assert {:ok, [%Issue{} = issue]} =
               Client.fetch_issues_by_states(@base_config, ["Todo"])

      assert issue.id == "i1"
      assert issue.identifier == "MT-1"
    end

    test "returns multiple issues with full normalization and normalizes state names" do
      # State names normalized: to_string/1 + uniq (42 -> "42", duplicate "Todo" removed)
      set_request_fun(fn _c, payload, _headers ->
        vars = payload["variables"] || %{}
        assert vars[:projectSlug] == "ENG"
        assert vars[:stateNames] == ["Todo", "In Progress", "42"]
        assert payload["query"] =~ "IssuesByProjectAndStates"

        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "issues" => %{
                 "nodes" => [
                   %{
                     "id" => "issue-a",
                     "identifier" => "MT-A",
                     "title" => "First",
                     "description" => "Desc A",
                     "priority" => 1,
                     "state" => %{"name" => "Todo"},
                     "branchName" => "feature/a",
                     "url" => "https://linear.app/team/issue/MT-A",
                     "assignee" => %{"id" => "usr-1"},
                     "labels" => %{"nodes" => [%{"name" => "Frontend"}, %{"name" => "P0"}]},
                     "inverseRelations" => %{
                       "nodes" => [
                         %{
                           "type" => "blocks",
                           "issue" => %{
                             "id" => "issue-x",
                             "identifier" => "MT-X",
                             "state" => %{"name" => "Done"}
                           }
                         }
                       ]
                     },
                     "createdAt" => "2026-01-10T09:00:00Z",
                     "updatedAt" => "2026-01-11T10:00:00Z"
                   },
                   %{
                     "id" => "issue-b",
                     "identifier" => "MT-B",
                     "title" => "Second",
                     "description" => nil,
                     "priority" => 2,
                     "state" => %{"name" => "In Progress"},
                     "branchName" => nil,
                     "url" => nil,
                     "assignee" => nil,
                     "labels" => %{"nodes" => []},
                     "inverseRelations" => %{"nodes" => []},
                     "createdAt" => nil,
                     "updatedAt" => nil
                   }
                 ],
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
               }
             }
           }
         }}
      end)

      assert {:ok, [issue_a, issue_b]} =
               Client.fetch_issues_by_states(@base_config, ["Todo", "In Progress", 42, "Todo"])

      assert issue_a.id == "issue-a"
      assert issue_a.identifier == "MT-A"
      assert issue_a.title == "First"
      assert issue_a.description == "Desc A"
      assert issue_a.priority == 1
      assert issue_a.state == "Todo"
      assert issue_a.branch_name == "feature/a"
      assert issue_a.url == "https://linear.app/team/issue/MT-A"
      assert issue_a.assignee_id == "usr-1"
      assert issue_a.labels == ["frontend", "p0"]
      assert issue_a.blocked_by == [%{id: "issue-x", identifier: "MT-X", state: "Done"}]
      assert issue_a.assignee_matches_filter == true
      assert %DateTime{year: 2026, month: 1, day: 10} = issue_a.created_at
      assert %DateTime{year: 2026, month: 1, day: 11} = issue_a.updated_at

      assert issue_b.id == "issue-b"
      assert issue_b.identifier == "MT-B"
      assert issue_b.title == "Second"
      assert issue_b.priority == 2
      assert issue_b.state == "In Progress"
      assert issue_b.assignee_id == nil
      assert issue_b.labels == []
      assert issue_b.blocked_by == []
      assert issue_b.created_at == nil
      assert issue_b.updated_at == nil
    end
  end

  describe "fetch_issue_states_by_ids/2" do
    test "returns empty list for empty ids" do
      assert {:ok, []} = Client.fetch_issue_states_by_ids(@base_config, [])
    end

    test "returns decoded issues in request order with normalization" do
      raw_issue = %{
        "id" => "issue-1",
        "identifier" => "MT-1",
        "title" => "Blocked todo",
        "description" => "Needs dependency",
        "priority" => 2,
        "state" => %{"name" => "Todo"},
        "branchName" => "mt-1",
        "url" => "https://example.org/issues/MT-1",
        "assignee" => %{"id" => "user-1"},
        "labels" => %{"nodes" => [%{"name" => "Backend"}]},
        "inverseRelations" => %{
          "nodes" => [
            %{
              "type" => "blocks",
              "issue" => %{
                "id" => "issue-2",
                "identifier" => "MT-2",
                "state" => %{"name" => "In Progress"}
              }
            },
            %{
              "type" => "relatesTo",
              "issue" => %{
                "id" => "issue-3",
                "identifier" => "MT-3",
                "state" => %{"name" => "Done"}
              }
            }
          ]
        },
        "createdAt" => "2026-01-01T00:00:00Z",
        "updatedAt" => "2026-01-02T00:00:00Z"
      }

      set_request_fun(fn _c, payload, _headers ->
        ids = (payload["variables"] || %{})[:ids]
        nodes = Enum.map(ids, fn id -> Map.put(raw_issue, "id", id) end)

        {:ok,
         %{
           status: 200,
           body: %{"data" => %{"issues" => %{"nodes" => nodes}}}
         }}
      end)

      assert {:ok, [%Issue{} = issue | _]} =
               Client.fetch_issue_states_by_ids(@base_config, ["issue-1"])

      assert issue.id == "issue-1"
      assert issue.identifier == "MT-1"
      assert issue.state == "Todo"
      assert issue.priority == 2
      assert issue.assignee_id == "user-1"
      assert issue.labels == ["backend"]
      assert issue.blocked_by == [%{id: "issue-2", identifier: "MT-2", state: "In Progress"}]
      assert issue.assignee_matches_filter == true
    end

    test "marks assignee_matches_filter false when assignee does not match filter" do
      config = @base_config ++ [assignee: "user-2"]

      raw_issue = %{
        "id" => "issue-99",
        "identifier" => "MT-99",
        "title" => "Other",
        "state" => %{"name" => "Todo"},
        "assignee" => %{"id" => "user-1"},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }

      set_request_fun(fn _c, payload, _headers ->
        ids = (payload["variables"] || %{})[:ids]
        nodes = Enum.map(ids, fn id -> Map.put(raw_issue, "id", id) end)
        {:ok, %{status: 200, body: %{"data" => %{"issues" => %{"nodes" => nodes}}}}}
      end)

      assert {:ok, [%Issue{} = issue]} =
               Client.fetch_issue_states_by_ids(config, ["issue-99"])

      refute issue.assignee_matches_filter
    end

    test "paginates by 50 and preserves order across pages" do
      issue_ids = Enum.map(1..55, &"issue-#{&1}")
      first_batch = Enum.take(issue_ids, 50)
      second_batch = Enum.drop(issue_ids, 50)

      raw_issue = fn id ->
        suffix = String.replace_prefix(id, "issue-", "")

        %{
          "id" => id,
          "identifier" => "MT-#{suffix}",
          "title" => "Issue #{suffix}",
          "state" => %{"name" => "In Progress"},
          "labels" => %{"nodes" => []},
          "inverseRelations" => %{"nodes" => []}
        }
      end

      set_request_fun(fn _c, payload, _headers ->
        ids = (payload["variables"] || %{})[:ids]
        send(self(), {:fetch_page, ids})
        nodes = Enum.map(ids, raw_issue)
        {:ok, %{status: 200, body: %{"data" => %{"issues" => %{"nodes" => nodes}}}}}
      end)

      assert {:ok, issues} = Client.fetch_issue_states_by_ids(@base_config, issue_ids)

      assert length(issues) == 55
      assert Enum.map(issues, & &1.id) == issue_ids

      assert_receive {:fetch_page, ^first_batch}
      assert_receive {:fetch_page, ^second_batch}
    end

    test "query uses neutral operation name IssuesById" do
      set_request_fun(fn _c, payload, _headers ->
        assert payload["query"] =~ "IssuesById"
        send(self(), :seen_operation)
        {:ok, %{status: 200, body: %{"data" => %{"issues" => %{"nodes" => []}}}}}
      end)

      Client.fetch_issue_states_by_ids(@base_config, ["id-1"])
      assert_receive :seen_operation
    end
  end

  describe "update_issue_state/3" do
    test "succeeds when state lookup and issueUpdate both succeed" do
      parent = self()

      set_request_fun(fn _c, payload, _headers ->
        query = payload["query"] || ""
        vars = payload["variables"] || %{}

        if query =~ "issue(" and query =~ "states(" do
          assert vars[:issueId] == "issue-1"
          assert vars[:stateName] == "Done"
          send(parent, :state_lookup_called)

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "issue" => %{
                   "team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}
                 }
               }
             }
           }}
        else
          assert query =~ "issueUpdate"
          assert vars[:issueId] == "issue-1"
          assert vars[:stateId] == "state-1"
          send(parent, :issue_update_called)
          {:ok, %{status: 200, body: %{"data" => %{"issueUpdate" => %{"success" => true}}}}}
        end
      end)

      assert :ok = Client.update_issue_state(@base_config, "issue-1", "Done")

      assert_receive :state_lookup_called
      assert_receive :issue_update_called
    end

    test "returns state_not_found when team states nodes empty" do
      set_request_fun(fn _c, _payload, _headers ->
        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "issue" => %{"team" => %{"states" => %{"nodes" => []}}}
             }
           }
         }}
      end)

      assert {:error, :state_not_found} =
               Client.update_issue_state(@base_config, "issue-1", "Missing")
    end

    test "returns issue_update_failed when issueUpdate.success is false" do
      set_request_fun(fn _c, payload, _headers ->
        if payload["query"] =~ "issueUpdate" do
          {:ok, %{status: 200, body: %{"data" => %{"issueUpdate" => %{"success" => false}}}}}
        else
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
               }
             }
           }}
        end
      end)

      assert {:error, :issue_update_failed} =
               Client.update_issue_state(@base_config, "issue-1", "Done")
    end

    test "propagates transport error from state lookup" do
      set_request_fun(fn _c, _payload, _headers -> {:error, :timeout} end)

      assert {:error, {:linear_api_request, :timeout}} =
               Client.update_issue_state(@base_config, "issue-1", "Done")
    end
  end

  describe "ExLinear.Issue" do
    test "label_names returns labels" do
      issue = %Issue{id: "1", labels: ["frontend", "infra"]}
      assert Issue.label_names(issue) == ["frontend", "infra"]
    end
  end
end
