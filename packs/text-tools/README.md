# text-tools

A starter Shem tool pack. Two pure, deterministic Elixir tools with property tests.

| Tool | `run/1` input | output |
|------|---------------|--------|
| `slugify` | `%{"text" => string}` | `%{"slug" => string}` |
| `word_count` | `%{"text" => string}` | `%{"words" => n, "chars" => n, "lines" => n}` |

## Install

```bash
shem-install <git-url-of-this-repo>            # if published standalone
shem-install file:///path/to/shem packs/text-tools   # from the shem repo
```

Each tool is re-verified through Shem's graduation gate on install.
