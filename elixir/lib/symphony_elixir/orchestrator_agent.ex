defmodule SymphonyElixir.OrchestratorAgent do
  @moduledoc """
  Runs the user-facing top-level Codex orchestrator chat.
  """

  require Logger

  alias SymphonyElixir.{Codex.AppServer, Codex.DynamicTool, Config, Orchestrator}

  @workspace_name "orchestrator"

  @spec start_async(Path.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_async(business_plan_path, opts \\ []) when is_binary(business_plan_path) do
    Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
      run(business_plan_path, opts)
    end)
  end

  @spec run(Path.t(), keyword()) :: :ok | {:error, term()}
  def run(business_plan_path, opts \\ []) when is_binary(business_plan_path) do
    expanded_business_plan_path = Path.expand(business_plan_path)
    Application.put_env(:symphony_elixir, :orchestrator_business_plan_path, expanded_business_plan_path)

    with {:ok, business_plan} <- File.read(expanded_business_plan_path),
         {:ok, workspace} <- ensure_workspace(),
         {:ok, session} <-
           AppServer.start_session(
             workspace,
             dynamic_tool_specs: DynamicTool.tool_specs(mode: :orchestrator)
           ) do
      try do
        chat_loop(session, expanded_business_plan_path, business_plan, opts)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp chat_loop(session, business_plan_path, business_plan, opts) do
    first_prompt = initial_prompt(business_plan_path, business_plan)
    issue = orchestrator_issue()

    IO.puts("Symphony orchestrator chat started. Type Ctrl+C to exit.")

    with {:ok, _turn} <- run_orchestrator_turn(session, first_prompt, issue, opts) do
      read_user_turns(session, issue, opts)
    end
  end

  defp read_user_turns(session, issue, opts) do
    case IO.gets("\nsymphony> ") do
      :eof ->
        :ok

      {:error, reason} ->
        {:error, reason}

      input ->
        case String.trim(input) do
          "" ->
            read_user_turns(session, issue, opts)

          "exit" ->
            :ok

          "quit" ->
            :ok

          prompt ->
            case run_orchestrator_turn(session, prompt, issue, opts) do
              {:ok, _turn} -> read_user_turns(session, issue, opts)
              {:error, reason} -> {:error, reason}
            end
        end
    end
  end

  defp run_orchestrator_turn(session, prompt, issue, opts) do
    AppServer.run_turn(
      session,
      prompt,
      issue,
      on_message: Keyword.get(opts, :on_message, &print_codex_message/1),
      tool_executor: fn tool, arguments ->
        DynamicTool.execute(tool, arguments,
          mode: :orchestrator,
          business_plan_path: Application.get_env(:symphony_elixir, :orchestrator_business_plan_path)
        )
      end
    )
  end

  defp initial_prompt(business_plan_path, business_plan) do
    status =
      case Orchestrator.snapshot() do
        :timeout -> "Symphony status timed out."
        :unavailable -> "Symphony orchestrator is unavailable."
        snapshot -> Jason.encode!(snapshot, pretty: true)
      end

    """
    You are the long-lived Symphony orchestrator agent.

    Your job is to help the operator turn the business plan into concrete Linear issues and supervise worker Codex sessions through Symphony.

    Before creating any issue, summarize the likely next work and ask the operator "what's next?" or ask for approval/amendments. Do not edit the business plan file. Amendments are expressed through created Linear issues and worker guidance.

    Use these Symphony tools when needed:
    - symphony_status: inspect active workers and retries.
    - symphony_refresh: request a new polling/reconcile pass.
    - symphony_create_issue: create approved work in the configured Linear project and active state.
    - symphony_interrupt_worker: stop and immediately restart a running worker with amended guidance.
    - symphony_read_business_plan: re-read the configured business plan.

    Business plan path:
    #{business_plan_path}

    Business plan:
    #{business_plan}

    Current Symphony status:
    #{status}
    """
  end

  defp ensure_workspace do
    workspace =
      Config.settings!().workspace.root
      |> Path.join(".symphony")
      |> Path.join(@workspace_name)
      |> Path.expand()

    File.mkdir_p!(workspace)
    {:ok, workspace}
  end

  defp orchestrator_issue do
    %{
      id: "symphony-orchestrator",
      identifier: "SYMPHONY-ORCHESTRATOR",
      title: "Symphony orchestrator"
    }
  end

  defp print_codex_message(%{event: :notification, payload: %{"method" => "item/agentMessage/delta"} = payload}) do
    payload
    |> get_in(["params", "delta"])
    |> print_delta()
  end

  defp print_codex_message(%{event: :notification, payload: %{"method" => "item/agentMessage/delta", "params" => %{"delta" => delta}}}) do
    print_delta(delta)
  end

  defp print_codex_message(%{event: :turn_completed}) do
    IO.puts("")
  end

  defp print_codex_message(%{event: :turn_ended_with_error, reason: reason}) do
    IO.puts("\nCodex turn failed: #{inspect(reason)}")
  end

  defp print_codex_message(message) do
    Logger.debug("Orchestrator Codex message: #{inspect(message)}")
    :ok
  end

  defp print_delta(delta) when is_binary(delta) do
    IO.write(delta)
    :ok
  end

  defp print_delta(_delta), do: :ok
end
