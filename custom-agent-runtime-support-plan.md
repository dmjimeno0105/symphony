# Custom Agent Runtime Support Plan

## Summary

Add configurable runtimes for the top-level orchestrator and worker agents so Symphony can run
Codex, Claude Code, or other CLI/app-server compatible agents independently.

Codex app-server remains the default and the first fully supported runtime because it already
provides the thread/turn protocol, dynamic tools, approval handling, and structured events Symphony
depends on.

## Key Changes

- Introduce an `AgentRuntime` boundary with:
  - `start_session(workspace, opts)`
  - `run_turn(session, prompt, issue_or_context, opts)`
  - `stop_session(session)`
- Move current `SymphonyElixir.Codex.AppServer` usage behind a `codex_app_server` runtime adapter.
- Add separate workflow config for worker and orchestrator runtimes:

  ```yaml
  runtimes:
    worker:
      kind: codex_app_server
      command: codex app-server
      model: gpt-5.5
    orchestrator:
      kind: codex_app_server
      command: codex app-server
      model: gpt-5.5
  ```

- Preserve existing `codex.*` config as backward-compatible shorthand for both runtimes.
- Route worker sessions through the selected worker runtime in `AgentRunner`.
- Route the top-level orchestrator session through the selected orchestrator runtime in
  `OrchestratorAgent`.

## Runtime Types

- `codex_app_server`
  - Full support for current Symphony behavior.
  - Supports dynamic tools, approvals, token/rate-limit events, session ids, and worker status.
- `generic_cli`
  - Future fallback for CLIs like Claude Code, DeepSeek CLIs, or other command-line agents.
  - Supports prompt-in / output-out execution.
  - Does not support Symphony dynamic tools unless the provider exposes a compatible tool protocol.
- Model names should be opaque provider-specific strings.
  - Examples: `gpt-5.5`, `claude-opus-4.7`, `deepseek-v4-flash`.
  - Symphony should pass model values through to the runtime adapter rather than hardcoding provider
    enums.

## Interface Behavior

- Orchestrator and worker agents may use different runtimes.
- Dynamic tools are enabled only for runtimes that declare tool-call support.
- Dashboard/session metadata should include:
  - runtime kind
  - model
  - command
  - process id when available
  - session id when available
  - token/rate-limit data when available
- If a runtime does not expose Codex-style event data, unavailable fields should remain `nil`.

## Test Plan

- Config parsing tests for:
  - explicit `runtimes.worker`
  - explicit `runtimes.orchestrator`
  - fallback from existing `codex.*` config
- Adapter tests proving the Codex runtime sends the same JSON-RPC payloads as the current
  implementation.
- Agent runner tests proving worker runtime selection is used.
- Orchestrator agent tests proving orchestrator runtime selection is independent from worker
  runtime selection.
- Failure tests for:
  - unsupported runtime kind
  - missing command
  - runtime startup failure
  - runtime turn failure

## Assumptions

- Codex app-server remains the only v1 runtime with full Symphony dynamic-tool support.
- Non-Codex CLIs should be added through adapters only after their execution and tool protocols are
  known.
- Runtime model names are treated as provider-specific strings and passed through unchanged.
- The first implementation should avoid changing orchestration semantics; it should only make the
  execution backend configurable.
