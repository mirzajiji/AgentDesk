# MCP integration and future server surface

Status: planned design. Source: [final architecture](final-architecture.txt), sections 37–40.
<!-- Source sections: 37,38,39,40 -->

AgentDesk consumes MCP servers as a first-class subsystem: tools, resources, prompts, transports, local process management, discovery, permissions, health and scoped logs. A plugin can use MCP internally, but a configured MCP server is not itself an authorization grant.

## Connection record and lifecycle

Store display identity, workspace/project, transport, command or endpoint, non-secret configuration, Keychain references, status and discovered capabilities. UI shows process ID where relevant, authentication, tools/resources/prompts, health and last check. Support start, stop, restart, reconnect, edit, disable, delete and test.

Launch local servers using executable/argument arrays with validated working directory/environment. Treat the executable, returned metadata and tool results as untrusted inputs. Limit resource use, redact logs, and clean up processes/streams on shutdown and failure. Changes to the discovered tool set must not silently authorize new tools.

## Calls and policy

Every tool call must establish the workspace/project scope, selected server, capability/action, environment and caller. Resolve policy before dispatch. Resource and prompt retrieval also require scope/classification checks before data enters context. Use exact request/response schemas and version negotiation according to the implemented supported MCP protocol version; do not invent wire contracts from this design page.

## AgentDesk as an MCP server

Later expose controlled operations such as list workspaces/projects/agents/skills, run predefined agents/workflows, inspect runs/steps/artifacts/changes, search memory/bugs, resolve current requirements and request approval. External MCP clients receive the same policy boundaries and sanitized projections as other clients. Exposing a tool named “run” must not create an arbitrary-shell bypass.

Test handshake/discovery, malformed messages, unavailable tools, denied calls, new capability review, server isolation, prompt/resource scope, restart failures, process cleanup and redaction. Verify disabled or disconnected servers cannot continue accepting requests through cached handles.
