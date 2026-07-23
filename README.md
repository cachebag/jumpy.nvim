# <p align="center"> jumpy 🐸

<p align="center">
  <b>
    Inspired by
    <a href="https://github.com/ThePrimeagen/99.git" target="_blank" rel="noopener noreferrer">
      99
    </a>
  </b>
</p>

<br>

<img width="1309" height="888" alt="image" src="https://github.com/user-attachments/assets/519cb828-5a3f-4e6d-8173-5c427c414b41" />
<img width="1333" height="899" alt="image" src="https://github.com/user-attachments/assets/8204f5a0-d764-4a56-8e0a-7c10ab9d74b2" />
<img width="1301" height="888" alt="image" src="https://github.com/user-attachments/assets/a6ab3ab6-487b-461f-ac2c-67240795216d" />

#

The main difference between jumpy and other tools, like 99, are:

| feature | jumpy | 99 | avante / sidekick | codecompanion inline | claude code / aider |
|---|---|---|---|---|---|
| Interaction model | Inline prompt → hunks in buffer | search / visual / vibe → qfix or inline replace | Sidebar chat → apply | Inline edit → accept/reject | CLI agent → full file writes |
| Review granularity | Per-hunk accept/reject | Per-result (search) or selection replace (visual) | Per-file or per-suggestion | Per-change | Post-hoc (git diff) |
| Context switch | None: you stay in buffer | Minimal; qfix for search | Sidebar opens | Minimal | Leave editor or split terminal |
| LLM output format | Search/replace blocks | CLI provider output (opencode, claude, etc.) | Full file / patch | Full file | Full file via temp |
| Token efficiency | High (only changed lines sent back) | Mode-dependent; visual is targeted | Lower (full context) | Lower | Lower |
| Scope | Single targeted edit | Selection edit, project search, agentic work | Multi-file refactors, chat | Single edit or chat | Whole-project agentic tasks |

#

- **inline prompt**: describe a change without leaving the buffer
- **multi-line prompt + history**: `<C-CR>` submits, `<CR>` adds a newline, `<Up>`/`<Down>` recall earlier prompts
- **async & parallel prompts**: requests run in the background; each response lands in its own buffer (`:JumpyCancel` aborts everything in flight)
- **multi-file prompts**: `@mention` several files in one prompt and review the cross-file hunks
- **search/replace hunks**: the LLM returns only changed sections, not whole files
- **in-buffer diff review**: proposed edits shown inline with accept/reject before anything is written
- **per-hunk control**: accept, reject, or reprompt individual hunks
- **hunk navigation**: jump between proposed changes with `]h` / `[h`
- **quickfix integration**: collect pending hunks across buffers into one list
- **session sidebar**: a panel logging every prompt and its per-file hunk outcomes; jump to, accept/reject, and reprompt from one place (`:JumpySidebar`)
- **persistent sessions**: sessions are saved per project root and can be reopened later (`:JumpySessions`)
- **`@lsp` context**: pull workspace symbols into the prompt when needed
- **multi-provider**: openrouter, openai, Anthropic API, Claude Code subscriptions

## Install

```lua
-- lazy.nvim
{
  "cachebag/jumpy",
  config = function()
    require("jumpy").setup({
      provider = "anthropic", -- or "openai", "openrouter", "claude_code"
    })
  end,
}
```

Set your API key: `export ANTHROPIC_API_KEY="sk-ant-..."` (or `OPENAI_API_KEY`, `JUMPY_API_KEY` for openrouter).

### Claude Code / Max

Claude Pro and Max subscribers can use Jumpy without an API key. Install Claude Code,
run `claude login`, then:

```lua
require("jumpy").setup({
  provider = "claude_code",
  model = "sonnet", -- optional: uses your Claude Code model selection
})
```

Jumpy runs Claude Code non-interactively (tools, MCP servers, and session persistence
disabled) and remains the only process that can apply changes. It removes
`ANTHROPIC_API_KEY` from the child process so an inherited key cannot switch a
subscription user to API billing. Set `claude_code_command` if `claude` is not on `PATH`.

## Use

| Keybind           | Action                                              |
| ----------------- | --------------------------------------------------- |
| `<leader>j`       | Open prompt                                          |
| `<C-CR>`          | Submit prompt (insert mode); `<CR>` inserts newline |
| `<CR>`            | Submit prompt (normal mode)                          |
| `<Up>` / `<Down>` | Cycle prompt history (session)                      |
| `]h` / `[h`       | Next / previous hunk                                 |
| `<leader>a`       | Accept hunk                                          |
| `<leader>x`       | Reject hunk                                          |
| `<leader>A`       | Accept all hunks                                     |
| `<leader>X`       | Reject all hunks                                     |
| `<leader>r`       | Reprompt the hunk under cursor                       |
| `<leader>q`       | Review pending hunks in quickfix                     |
| `<leader>s`       | Toggle the session sidebar                           |

In the quickfix list, `a` accepts and `x` rejects the selected hunk, advancing to
the next pending hunk (including hunks in other files). `:JumpyCancel` cancels every
request currently in flight.

### Session sidebar

`:JumpySidebar` (`<leader>s`) toggles a panel logging every prompt and the hunks it
proposed, with each hunk's status. `:JumpySessions` reopens a saved session (sessions
are persisted per project root under `stdpath("data")/jumpy/sessions/`; reopened ones
are read-only).

Cycle through a session's hunks with `<Tab>` / `<S-Tab>`: each one is previewed in
the buffer with a yellow inline before/after overlay — including hunks you've already
accepted — so you can see exactly what changed without leaving the sidebar.

Configure where it opens (handy if a left-side file tree is in the way):

```lua
require("jumpy").setup({
  sidebar = {
    position = "left", -- or "right"
    width = 42,
  },
})
```

| Key             | Action                                                     |
| --------------- | ---------------------------------------------------------- |
| `<CR>`          | Open the file + hunk under the cursor (focus the editor)   |
| `<Tab>` / `<S-Tab>` | Cycle to the next / prev hunk and preview it inline    |
| `a` / `x`       | Accept / reject the hunk (or all pending on a file)        |
| `r`             | Reprompt the hunk under the cursor                         |
| `R`             | Clear the current session                                  |
| `q` / `<Esc>`   | Close the sidebar                                          |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT
