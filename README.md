# Agents

A Nix flake for composing agentic workflows from reusable Agent Skills, agent
profiles, MCP packages, and client wrappers.

The library currently focuses on three pieces:

1. **Skills** render to Agent Skills-compatible directories with `SKILL.md`
   frontmatter and Markdown instructions.
2. **Agents** compose prompts, skills, MCP packages, and extra packages. Each
   agent also renders as an `agent-...` skill so clients without first-class
   agents can still use the profile.
3. **Interfaces** build runnable wrappers for clients. The initial interfaces
   are `crush`, `aider`, and `copilot`.

## Mutable state model

Agent clients keep important mutable state in normal user config locations:
login state, tokens, app settings, caches, and per-client databases. The
wrappers deliberately keep that state outside the Nix store.

At startup, a wrapper creates a runtime HOME/XDG overlay under
`${XDG_RUNTIME_DIR:-/tmp}/agent-flake`. It symlinks the user's existing home and
config entries into the overlay, except for the shared skill directories:

- `~/.agents/skills`
- `$XDG_CONFIG_HOME/agents/skills`

Those skill directories are rebuilt as a composed view of the user's mutable
skills plus the Nix-managed skills for that wrapper. Nix-managed skills take
precedence on name collisions. Other mutable paths, including Copilot, Aider,
Crush, Azure CLI, Git, and SSH config, continue to point at the user's normal
locations.

## Quick start

Build the example skill directory:

```bash
nix build .#skills
```

Run one of the example wrappers:

```bash
nix run .#crush-pr-assistant
nix run .#aider-pr-assistant
nix run .#copilot-pr-assistant
```

## Defining skills

Skills can be plain Nix objects passed to `agentLib.mkSkill`, or `.nix` files
loaded with `agentLib.importSkill`. A skill can include packages that should be
available in any wrapper that composes it.

```nix
{ pkgs, agentLib }:

agentLib.mkSkill {
  name = "jq";
  description = "Use jq to parse, filter, and transform JSON.";
  tags = [ "tools" "shell" "json" ];
  extraPackages = [ pkgs.jq ];
  body = ''
    jq is available as `${pkgs.jq}/bin/jq`.

    Use it for reliable JSON filtering and validation:

    ```bash
    ${pkgs.jq}/bin/jq -e '.ok == true' result.json
    ```
  '';
}
```

The rendered skill follows the Agent Skills directory shape:

```text
jq/
└── SKILL.md
```

Tags are stored in `metadata.agent-flake.tags` because tags are not part of the
current Agent Skills frontmatter spec.

## Defining agents

Agents compose a prompt with reusable skills, MCP packages, and extra packages:

```nix
agentLib.mkAgent {
  name = "pr-assistant";
  description = "Helps inspect, summarize, and review pull requests.";
  prompt = ''
    You are a pull request assistant. Inspect diffs before making claims and
    separate confirmed findings from assumptions.
  '';
  skills = [
    skills.jq
    skills.azure-cli
  ];
  extraPackages = [ pkgs.glow ];
}
```

The agent is also rendered as an Agent Skill named `agent-pr-assistant`, which
lets clients such as Crush consume the profile through the same skill overlay.

## Building wrappers

Use an interface helper to wrap a client package with a composed set of agents
and skills:

```nix
agentLib.interfaces.crush {
  name = "crush-pr-assistant";
  agents = [ agents.pr-assistant ];
}
```

The equivalent helpers for the initial clients are:

- `agentLib.interfaces.crush`
- `agentLib.interfaces.aider`
- `agentLib.interfaces.copilot`

Each helper accepts `package = ...` and `program = ...` overrides if the client
should come from a different package source.

See [`examples/basic.nix`](./examples/basic.nix) for a complete setup.
