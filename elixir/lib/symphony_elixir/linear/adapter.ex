defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Client

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @create_issue_lookup_query """
  query SymphonyResolveCreateIssueIds($projectSlug: String!, $stateName: String!) {
    project(slugId: $projectSlug) {
      id
      team {
        id
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @create_issue_mutation """
  mutation SymphonyCreateIssue($input: IssueCreateInput!) {
    issueCreate(input: $input) {
      success
      issue {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_issue(map()) :: {:ok, term()} | {:error, term()}
  def create_issue(attrs) when is_map(attrs) do
    with {:ok, title, description, priority, state_name} <- normalize_create_issue_attrs(attrs),
         {:ok, ids} <- resolve_create_issue_ids(state_name),
         {:ok, response} <- client_module().graphql(@create_issue_mutation, %{input: create_issue_input(ids, title, description, priority)}),
         true <- get_in(response, ["data", "issueCreate", "success"]) == true,
         issue_payload when is_map(issue_payload) <- get_in(response, ["data", "issueCreate", "issue"]) do
      {:ok, normalize_created_issue(issue_payload)}
    else
      false -> {:error, :issue_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_create_failed}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp normalize_create_issue_attrs(attrs) do
    title = attrs[:title] || attrs["title"]
    description = attrs[:description] || attrs["description"] || ""
    priority = attrs[:priority] || attrs["priority"]
    state_name = attrs[:state] || attrs["state"] || default_active_state()

    cond do
      not is_binary(title) or String.trim(title) == "" ->
        {:error, :missing_title}

      not is_binary(description) ->
        {:error, :invalid_description}

      not (is_nil(priority) or is_integer(priority)) ->
        {:error, :invalid_priority}

      not is_binary(state_name) or String.trim(state_name) == "" ->
        {:error, :missing_state}

      true ->
        {:ok, String.trim(title), description, priority, String.trim(state_name)}
    end
  end

  defp resolve_create_issue_ids(state_name) do
    project_slug = SymphonyElixir.Config.settings!().tracker.project_slug

    with slug when is_binary(slug) <- project_slug,
         {:ok, response} <-
           client_module().graphql(@create_issue_lookup_query, %{projectSlug: slug, stateName: state_name}),
         project_id when is_binary(project_id) <- get_in(response, ["data", "project", "id"]),
         team_id when is_binary(team_id) <- get_in(response, ["data", "project", "team", "id"]),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "project", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, %{project_id: project_id, team_id: team_id, state_id: state_id}}
    else
      nil -> {:error, :missing_linear_project_slug}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_create_lookup_failed}
    end
  end

  defp create_issue_input(ids, title, description, priority) do
    %{
      title: title,
      description: description,
      teamId: ids.team_id,
      projectId: ids.project_id,
      stateId: ids.state_id
    }
    |> maybe_put_priority(priority)
  end

  defp maybe_put_priority(input, priority) when is_integer(priority), do: Map.put(input, :priority, priority)
  defp maybe_put_priority(input, _priority), do: input

  defp normalize_created_issue(issue) do
    %SymphonyElixir.Linear.Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      priority: issue["priority"],
      state: get_in(issue, ["state", "name"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      assignee_id: get_in(issue, ["assignee", "id"]),
      labels: issue |> get_in(["labels", "nodes"]) |> label_names(),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  defp label_names(labels) when is_list(labels), do: labels |> Enum.map(& &1["name"]) |> Enum.reject(&is_nil/1)
  defp label_names(_labels), do: []

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_raw), do: nil

  defp default_active_state do
    case SymphonyElixir.Config.settings!().tracker.active_states do
      [state | _] when is_binary(state) -> state
      _ -> "Todo"
    end
  end
end
