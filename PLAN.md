# Plan — Convio MCP in Freebuff CLI

Pattern: a single remote MCP endpoint plus a repeatable handshake check. There is
no prompt, retrieval or agent layer to build — Convio does the tool work, the CLI
does the calling.

## Tasks (build order)

1. **Confirm the endpoint and transport.** Hosted Streamable-HTTP MCP at
   `https://mcp.convio.dev`, bearer-token auth, no local server.
   *Verify:* `convio` tool calls answer in-session (`project_status` returns live
   stage data) — done.

2. **Confirm the configuration is user-level, not per-repo.** "Available in every
   project" means the CLI's user-scope MCP config, so a new project inherits it
   with no setup.
   *Verify:* list where the server is registered; a fresh directory in this
   session can still call a Convio tool. If it is registered per-project, move it
   to user scope.

3. **Add a re-runnable connectivity check.** `scripts/check-convio-mcp.sh` performs
   an MCP `initialize` handshake with `CONVIO_API_KEY` from the environment.
   *Verify:* run with a valid key → `200` + MCP `result`; with a bad key → `401`
   and a non-zero exit.

4. **Keep the key out of the repository.** Key lives only in the MCP client config
   (or an env var for the check script).
   *Verify:* grep the tracked tree for the key prefix and the pasted placeholder;
   both absent; `.gitignore` covers any local env file used.

5. **Document the one-time setup.** Short section in `BRIEF.md` or the repo README
   naming the config entry, the key's home, and the check command.
   *Verify:* follow the steps from a clean shell and get a passing check.

## Stage checkpoints

- Scaffold — no app to scaffold; each task above is a config/doc change. Call
  `next_stage` once tasks 1–5 are done.
- Build the AI core — not applicable (no prompts, tools or retrieval to author).
- Security review — the only asset is the API key; covered by task 4.
- Test thoroughly — task 3's script is the test.
- Ship — the "deploy" is the committed config/doc changes.
