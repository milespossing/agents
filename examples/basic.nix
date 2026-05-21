{ pkgs, agentLib }:

let
  skills = rec {
    jq = agentLib.mkSkill {
      name = "jq";
      description = "Use jq to inspect, transform, and validate JSON from shell commands and files.";
      tags = [
        "tools"
        "shell"
        "json"
      ];
      extraPackages = [ pkgs.jq ];
      body = ''
        jq is available in this wrapper as `${pkgs.jq}/bin/jq`.

        Use it when command output or files are JSON and the task needs reliable filtering,
        projection, validation, or transformation. Prefer `jq -e` when the command should fail
        if a predicate is false or a field is missing.

        Examples:

        ```bash
        ${pkgs.jq}/bin/jq '.items[] | {name, status}' response.json
        ${pkgs.jq}/bin/jq -e '.ok == true' result.json
        ```
      '';
    };

    azure-cli = agentLib.mkSkill {
      name = "azure-cli";
      description = "Use Azure CLI for Azure resource inspection and automation when az commands are requested or needed.";
      tags = [
        "tools"
        "cloud"
        "azure"
      ];
      extraPackages = [ pkgs.azure-cli ];
      compatibility = "Requires Azure CLI login state in the user's normal Azure config directory.";
      body = ''
        Azure CLI is available in this wrapper as `${pkgs.azure-cli}/bin/az`.

        Use the user's existing Azure CLI login state. Do not place credentials in generated
        files or the Nix store. For read-only investigation, prefer commands with explicit
        output formats:

        ```bash
        ${pkgs.azure-cli}/bin/az account show --output json
        ${pkgs.azure-cli}/bin/az resource list --output json
        ```

        Pipe JSON output through `${pkgs.jq}/bin/jq` when selecting fields.
      '';
    };
  };

  agents = {
    pr-assistant = agentLib.mkAgent {
      name = "pr-assistant";
      description = "Helps inspect, summarize, and review pull requests with structured command-line tooling.";
      prompt = ''
        You are a pull request assistant. Focus on the requested review task, inspect diffs
        before making claims, and separate confirmed findings from assumptions. Prefer concise
        summaries and include exact files, commands, or checks when they materially support the
        result.
      '';
      skills = [
        skills.jq
        skills.azure-cli
      ];
      extraPackages = [ pkgs.glow ];
    };
  };

  skillDirectory = agentLib.mkSkillDirectory {
    name = "example-agent-skills";
    skills = [
      skills.jq
      skills.azure-cli
      agents.pr-assistant.asSkill
    ];
  };

  commonWrapperArgs = {
    agents = [ agents.pr-assistant ];
  };
in
{
  inherit skills agents skillDirectory;

  wrappers = {
    crush-pr-assistant = agentLib.interfaces.crush (
      commonWrapperArgs
      // {
        name = "crush-pr-assistant";
      }
    );

    aider-pr-assistant = agentLib.interfaces.aider (
      commonWrapperArgs
      // {
        name = "aider-pr-assistant";
      }
    );

    copilot-pr-assistant = agentLib.interfaces.copilot (
      commonWrapperArgs
      // {
        name = "copilot-pr-assistant";
      }
    );
  };
}
