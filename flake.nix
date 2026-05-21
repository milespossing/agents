{
  description = "Composable Nix wrappers for agentic clients, skills, agents, and MCPs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = lib.genAttrs systems;
      pkgsFor = system:
        import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg:
            builtins.elem (lib.getName pkg) [
              "crush"
              "github-copilot-cli"
            ];
        };
    in
    {
      lib = forAllSystems (
        system:
        import ./lib {
          pkgs = pkgsFor system;
        }
      );

      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          agentLib = self.lib.${system};
          example = import ./examples/basic.nix { inherit pkgs agentLib; };
        in
        example.wrappers
        // {
          default = example.wrappers.crush-pr-assistant;
          skills = example.skillDirectory;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          agentLib = self.lib.${system};
          testSkill = agentLib.mkSkill {
            name = "json-tool";
            description = "Use a lightweight JSON tool in wrapper validation.";
            tags = [ "test" ];
            body = "This is a small validation skill.";
          };
          testAgent = agentLib.mkAgent {
            name = "test-agent";
            description = "Validates agent rendering.";
            prompt = "Use composed skills when relevant.";
            skills = [ testSkill ];
          };
          testSkillDirectory = agentLib.mkSkillDirectory {
            name = "rendered-agent-skills-check-input";
            skills = [
              testSkill
              testAgent.asSkill
            ];
          };
          fakeClient = pkgs.writeShellApplication {
            name = "fake-agent-client";
            runtimeInputs = [ pkgs.gnugrep ];
            text = ''
              test "$AGENT_WRAPPER_REAL_HOME" != "$HOME"
              test "$AGENT_WRAPPER_REAL_XDG_CONFIG_HOME" != "$XDG_CONFIG_HOME"

              test -f "$HOME/.agents/skills/user-skill/SKILL.md"
              test -f "$HOME/.agents/skills/json-tool/SKILL.md"
              test -f "$XDG_CONFIG_HOME/agents/skills/config-skill/SKILL.md"
              test -f "$XDG_CONFIG_HOME/agents/skills/json-tool/SKILL.md"
              test -f "$XDG_CONFIG_HOME/copilot/config.yaml"

              grep -q "small validation skill" "$HOME/.agents/skills/json-tool/SKILL.md"
              grep -q "small validation skill" "$XDG_CONFIG_HOME/agents/skills/json-tool/SKILL.md"
            '';
          };
          fakeWrapper = agentLib.interfaces.generic {
            name = "fake-agent-wrapper";
            client = "fake";
            package = fakeClient;
            program = "fake-agent-client";
            skills = [ testSkill ];
          };
        in
        {
          rendered-skills = pkgs.runCommand "rendered-agent-skills-check" { } ''
            test -f ${testSkillDirectory}/skills/json-tool/SKILL.md
            test -f ${testSkillDirectory}/skills/agent-test-agent/SKILL.md
            ${pkgs.gnugrep}/bin/grep -q 'name: "json-tool"' ${testSkillDirectory}/skills/json-tool/SKILL.md
            ${pkgs.gnugrep}/bin/grep -q 'metadata:' ${testSkillDirectory}/skills/json-tool/SKILL.md
            touch "$out"
          '';

          wrapper-overlay = pkgs.runCommand "wrapper-overlay-check" { } ''
            real_home="$TMPDIR/real-home"
            real_config="$TMPDIR/real-config"
            mkdir -p \
              "$real_home/.agents/skills/user-skill" \
              "$real_home/.agents/skills/json-tool" \
              "$real_config/agents/skills/config-skill" \
              "$real_config/copilot"

            cat > "$real_home/.agents/skills/user-skill/SKILL.md" <<'EOF'
            ---
            name: user-skill
            description: User skill from mutable state.
            ---
            user skill
            EOF

            cat > "$real_home/.agents/skills/json-tool/SKILL.md" <<'EOF'
            ---
            name: json-tool
            description: Shadowed user skill.
            ---
            user version
            EOF

            cat > "$real_config/agents/skills/config-skill/SKILL.md" <<'EOF'
            ---
            name: config-skill
            description: Config skill from mutable state.
            ---
            config skill
            EOF

            echo "oauth_token: mutable" > "$real_config/copilot/config.yaml"

            HOME="$real_home" \
              XDG_CONFIG_HOME="$real_config" \
              AGENT_WRAPPER_RUNTIME_DIR="$TMPDIR/runtime" \
              ${fakeWrapper}/bin/fake-agent-wrapper

            touch "$out"
          '';
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
