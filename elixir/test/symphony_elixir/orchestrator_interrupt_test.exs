defmodule SymphonyElixir.OrchestratorInterruptTest do
  use SymphonyElixir.TestSupport

  test "interrupt_issue stops running worker and queues immediate retry with guidance" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue = %Issue{
      id: "issue-interrupt",
      identifier: "MT-909",
      title: "Interrupt test",
      description: "Restart with guidance",
      state: "Todo"
    }

    worker =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    orchestrator_name = Module.concat(__MODULE__, :InterruptOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      if Process.alive?(worker), do: send(worker, :stop)
    end)

    initial_state = :sys.get_state(pid)

    worker_ref = Process.monitor(worker)

    :sys.replace_state(pid, fn _ ->
      %{
        initial_state
        | running: %{
            issue.id => %{
              pid: worker,
              ref: worker_ref,
              identifier: issue.identifier,
              issue: issue,
              worker_host: nil,
              workspace_path: "/tmp/workspace/MT-909",
              session_id: nil,
              last_codex_message: nil,
              last_codex_timestamp: nil,
              last_codex_event: nil,
              retry_attempt: 1,
              started_at: DateTime.utc_now()
            }
          },
          claimed: MapSet.put(initial_state.claimed, issue.id)
      }
    end)

    assert {:ok, response} = Orchestrator.interrupt_issue(orchestrator_name, "MT-909", "Use the revised API.")
    assert response.issue_id == issue.id
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 1_000

    state = :sys.get_state(pid)
    refute Map.has_key?(state.running, issue.id)
    assert retry = state.retry_attempts[issue.id]
    assert retry.guidance == "Use the revised API."
    assert retry.workspace_path == "/tmp/workspace/MT-909"
  end
end
