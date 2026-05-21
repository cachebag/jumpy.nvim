# <p align="center"> jumpy 🐸

<p align="center">
  <b>
    Inspired by
    <a href="https://github.com/ThePrimeagen/99.git" target="_blank" rel="noopener noreferrer">
      99
    </a>:
    I, like Prime, wanted a tool to allow for <i>me</i> to still be in the driver seat if I am going to spawn an AI to edit my code.
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

Some of the existing features are to be fleshed out, but the sole purpose is to know exactly what I am letting the LLM write into my code. I have no interest in letting it change everything, and only _then_ can I go back and review every change. That being said, here are the features of jumpy:

- **inline prompt**: describe a change without leaving the buffer
- **search/replace hunks**: LLM returns only changed sections, not whole files
- **in-buffer diff review**: proposed edits shown inline with accept/reject before anything is written
- **per-hunk control**: accept, reject, or reprompt individual hunks
- **hunk navigation**: jump between proposed changes with `]h` / `[h`
- **quickfix integration**: collect pending hunks across buffers into one list
- **token-efficient**: sends only the targeted edit context, not full-file rewrites
- **multi-provider**: openrouter, openai, anthropic
- **`@lsp` context**: pull workspace symbols into the prompt when needed
- **zero context switch**: no sidebar, no terminal agent, no leaving your file

#

So the philosophy here is: yes, I still want to handwrite my code _AND_ use AI, but I prefer that I have _full_ control over what the AI is writing. 
I don't want to have to wait until it finishes in order to review its changes.

## Contributing
Very open to PRs, issues, etc.! There is no concrete set of guidelines right now. I am quite welcoming to pretty much anything [1]!

[1]: If your PR is very clearly vibe coded slop I am just gonna close it without warning.

**Some notes:**
- Your PR will be run against the checks here: [`.github/workflows/ci.yml`](https://github.com/cachebag/jumpy.nvim/blob/master/.github/workflows/ci.yml)
- I may at times use AI to review your PRs. **A human will still read your PR and have final say**

## Install

```lua
-- lazy.nvim
{
  "cachebag/jumpy",
  config = function()
    require("jumpy").setup({
      provider = "anthropic", -- or "openai", "openrouter"
    })
  end,
}
```

set your API key: `export ANTHROPIC_API_KEY="sk-ant-..."` (or `OPENAI_API_KEY`, `JUMPY_API_KEY` for openrouter).

## Use
| Keybind     | Action                                    |
| ----------- | ----------------------------------------- |
| `<leader>j` | Open prompt, type your change, hit `<CR>` |
| `]h` / `[h` | Next / previous hunk                      |
| `<leader>a` | Accept hunk                               |
| `<leader>x` | Reject hunk                               |
| `<leader>A` | Accept all hunks                          |
| `<leader>X` | Reject all hunks                          |
| `<leader>r` | Reprompt the hunk under cursor            |

## License

MIT
