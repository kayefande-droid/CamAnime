# Brief — Convio MCP in Freebuff CLI

## Goal
Make the Convio MCP server available to this CLI in every project, and prove the
connection actually works rather than assuming it.

## What already exists
- Convio is configured as a remote HTTP MCP server (`https://mcp.convio.dev`) and
  is reachable from this session: `project_status` and `list_packs` answer live.
- No local install, proxy or bridge is needed — Convio is a hosted MCP endpoint.

## Scope
1. Confirm the server answers authenticated calls in a project-agnostic way
   (it does: project tools return data for this workspace).
2. Confirm the configuration is global to the CLI/user rather than tied to one repo,
   so new projects inherit it with no per-project setup.
3. Leave a reproducible check anyone can re-run to verify the connection.

## Out of scope
- Building an AI application with Convio skills (separate work).
- Rotating or storing API keys in the repository.

## Assumptions
- The API key stays in the user's MCP client configuration, never in a repo file.
- "Every project" means the CLI's user-level MCP configuration, not committed config.

## Verification
A Convio tool call (for example `project_status`) returning live project data from
an arbitrary working directory is the proof the connection is wired correctly.
