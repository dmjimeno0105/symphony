defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Orchestrator, Tracker}
  alias SymphonyElixir.Linear.Client

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @orchestrator_tools %{
    "symphony_status" => %{
      "description" => "Return current Symphony polling, running worker, retry, token, and rate-limit status.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    "symphony_refresh" => %{
      "description" => "Ask Symphony to poll and reconcile tracker state now.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    "symphony_create_issue" => %{
      "description" => "Create a Linear issue for approved next work in Symphony's configured project and active state.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["title", "description"],
        "properties" => %{
          "title" => %{"type" => "string"},
          "description" => %{"type" => "string"},
          "priority" => %{"type" => ["integer", "null"]},
          "state" => %{"type" => ["string", "null"]}
        }
      }
    },
    "symphony_interrupt_worker" => %{
      "description" => "Stop a running worker by issue id or identifier and restart it immediately with amended guidance.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["issue_ref", "guidance"],
        "properties" => %{
          "issue_ref" => %{"type" => "string"},
          "guidance" => %{"type" => "string"}
        }
      }
    },
    "symphony_read_business_plan" => %{
      "description" => "Read the business plan file configured for this orchestrator session.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      "symphony_status" ->
        execute_symphony_status()

      "symphony_refresh" ->
        execute_symphony_refresh()

      "symphony_create_issue" ->
        execute_symphony_create_issue(arguments)

      "symphony_interrupt_worker" ->
        execute_symphony_interrupt_worker(arguments)

      "symphony_read_business_plan" ->
        execute_symphony_read_business_plan(opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names(opts)
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs(opts \\ []) do
    base = [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      }
    ]

    if Keyword.get(opts, :mode) == :orchestrator do
      base ++ orchestrator_tool_specs()
    else
      base
    end
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_symphony_status do
    case Orchestrator.snapshot() do
      :timeout -> failure_response(%{"error" => %{"message" => "Symphony status timed out."}})
      :unavailable -> failure_response(%{"error" => %{"message" => "Symphony orchestrator is unavailable."}})
      snapshot -> dynamic_tool_response(true, encode_payload(snapshot))
    end
  end

  defp execute_symphony_refresh do
    case Orchestrator.request_refresh() do
      :unavailable -> failure_response(%{"error" => %{"message" => "Symphony orchestrator is unavailable."}})
      response -> dynamic_tool_response(true, encode_payload(response))
    end
  end

  defp execute_symphony_create_issue(arguments) do
    with {:ok, attrs} <- normalize_create_issue_arguments(arguments),
         {:ok, issue} <- Tracker.create_issue(attrs) do
      dynamic_tool_response(true, encode_payload(%{issue: serializable_value(issue)}))
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp execute_symphony_interrupt_worker(arguments) do
    with {:ok, issue_ref, guidance} <- normalize_interrupt_arguments(arguments),
         {:ok, response} <- Orchestrator.interrupt_issue(issue_ref, guidance) do
      dynamic_tool_response(true, encode_payload(response))
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp execute_symphony_read_business_plan(opts) do
    path =
      Keyword.get(opts, :business_plan_path) ||
        Application.get_env(:symphony_elixir, :orchestrator_business_plan_path)

    with path when is_binary(path) <- path,
         {:ok, content} <- File.read(path) do
      dynamic_tool_response(true, encode_payload(%{path: path, content: content}))
    else
      nil -> failure_response(%{"error" => %{"message" => "No business plan path is configured."}})
      {:error, reason} -> failure_response(%{"error" => %{"message" => "Failed to read business plan.", "reason" => inspect(reason)}})
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_create_issue_arguments(arguments) when is_map(arguments) do
    title = Map.get(arguments, "title") || Map.get(arguments, :title)
    description = Map.get(arguments, "description") || Map.get(arguments, :description)
    priority = Map.get(arguments, "priority") || Map.get(arguments, :priority)
    state = Map.get(arguments, "state") || Map.get(arguments, :state)

    cond do
      not is_binary(title) or String.trim(title) == "" -> {:error, :missing_title}
      not is_binary(description) -> {:error, :invalid_description}
      true -> {:ok, %{title: title, description: description, priority: priority, state: state}}
    end
  end

  defp normalize_create_issue_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_interrupt_arguments(arguments) when is_map(arguments) do
    issue_ref = Map.get(arguments, "issue_ref") || Map.get(arguments, :issue_ref)
    guidance = Map.get(arguments, "guidance") || Map.get(arguments, :guidance)

    cond do
      not is_binary(issue_ref) or String.trim(issue_ref) == "" -> {:error, :missing_issue_ref}
      not is_binary(guidance) or String.trim(guidance) == "" -> {:error, :missing_guidance}
      true -> {:ok, String.trim(issue_ref), String.trim(guidance)}
    end
  end

  defp normalize_interrupt_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp serializable_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp serializable_value(%Date{} = value), do: Date.to_iso8601(value)
  defp serializable_value(%Time{} = value), do: Time.to_iso8601(value)
  defp serializable_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp serializable_value(%_{} = struct), do: struct |> Map.from_struct() |> serializable_value()

  defp serializable_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, serializable_value(nested)} end)
  end

  defp serializable_value(value) when is_list(value), do: Enum.map(value, &serializable_value/1)
  defp serializable_value(value), do: value

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp orchestrator_tool_specs do
    Enum.map(@orchestrator_tools, fn {name, spec} -> Map.put(spec, "name", name) end)
  end

  defp supported_tool_names(opts) do
    Enum.map(tool_specs(opts), & &1["name"])
  end
end
