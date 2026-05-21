{ pkgs }:

let
  inherit (pkgs) lib;

  agentLib = rec {
    validSkillName =
      name:
      builtins.isString name
      && builtins.stringLength name <= 64
      && builtins.match "[a-z0-9]([a-z0-9-]*[a-z0-9])?" name != null
      && builtins.match ".*--.*" name == null;

    validRelativePath =
      path:
      builtins.isString path
      && path != ""
      && !(lib.hasPrefix "/" path)
      && path != ".."
      && !(lib.hasPrefix "../" path)
      && !(lib.hasInfix "/../" path)
      && !(lib.hasSuffix "/.." path);

    normalizeSkillName =
      name:
      lib.toLower (
        builtins.replaceStrings
          [
            "_"
            " "
            "."
          ]
          [
            "-"
            "-"
            "-"
          ]
          name
      );

    uniqueByName =
      items:
      (
        lib.foldl'
          (
            acc: item:
            if builtins.hasAttr item.name acc.seen then
              acc
            else
              {
                seen = acc.seen // {
                  ${item.name} = true;
                };
                result = acc.result ++ [ item ];
              }
          )
          {
            seen = { };
            result = [ ];
          }
          items
      ).result;

    stringifyMetadata =
      metadata:
      lib.mapAttrs
        (
          _key: value:
          if builtins.isList value then
            lib.concatMapStringsSep "," toString value
          else
            toString value
        )
        metadata;

    renderMetadata =
      metadata:
      if metadata == { } then
        ""
      else
        "metadata:\n"
        + lib.concatStringsSep "\n" (
          lib.mapAttrsToList (key: value: "  ${builtins.toJSON key}: ${builtins.toJSON value}") metadata
        )
        + "\n";

    renderSkillMarkdown =
      skill:
      let
        metadata =
          stringifyMetadata (
            skill.metadata
            // lib.optionalAttrs (skill.tags != [ ]) {
              "agent-flake.tags" = skill.tags;
            }
          );

        allowedTools =
          if builtins.isList skill.allowedTools then
            lib.concatStringsSep " " skill.allowedTools
          else
            skill.allowedTools;

        frontmatter =
          [
            "name: ${builtins.toJSON skill.name}"
            "description: ${builtins.toJSON skill.description}"
          ]
          ++ lib.optional (skill.license != null) "license: ${builtins.toJSON skill.license}"
          ++ lib.optional
            (
              skill.compatibility != null
            ) "compatibility: ${builtins.toJSON skill.compatibility}"
          ++ lib.optional (allowedTools != "") "allowed-tools: ${builtins.toJSON allowedTools}";
      in
      "---\n"
      + lib.concatStringsSep "\n" frontmatter
      + "\n"
      + renderMetadata metadata
      + "---\n\n"
      + skill.body
      + "\n";

    mkSkill =
      { name
      , description
      , body
      , tags ? [ ]
      , packages ? [ ]
      , extraPackages ? [ ]
      , files ? { }
      , license ? null
      , compatibility ? null
      , metadata ? { }
      , allowedTools ? [ ]
      ,
      }:
        assert lib.assertMsg (validSkillName name)
          "Invalid skill name '${name}'. Use lowercase letters, numbers, and hyphens only.";
        assert lib.assertMsg (description != "") "Skill '${name}' must have a non-empty description.";
        assert lib.assertMsg (builtins.stringLength description <= 1024)
          "Skill '${name}' description must be 1024 characters or fewer.";
        let
          skillPackages = packages ++ extraPackages;
          invalidFiles = lib.filter (path: !(validRelativePath path)) (builtins.attrNames files);

          normalizedFiles =
            assert lib.assertMsg (invalidFiles == [ ])
              "Skill '${name}' has invalid relative file paths: ${lib.concatStringsSep ", " invalidFiles}";
            lib.mapAttrs
              (
                path: value:
                  if builtins.isString value then
                    pkgs.writeText (baseNameOf path) value
                  else
                    value
              )
              files;

          skill = rec {
            type = "agents.skill";
            inherit
              name
              description
              body
              tags
              license
              compatibility
              metadata
              allowedTools
              ;
            packages = skillPackages;
            path = pkgs.runCommand "agent-skill-${name}" { } (
              ''
                mkdir -p "$out/${name}"
                cp ${pkgs.writeText "${name}-SKILL.md" (renderSkillMarkdown skill)} "$out/${name}/SKILL.md"
              ''
              + lib.concatStringsSep "\n" (
                lib.mapAttrsToList
                  (
                    relativePath: source:
                      let
                        escapedPath = lib.escapeShellArg relativePath;
                      in
                      ''
                        mkdir -p "$out/${name}/$(dirname ${escapedPath})"
                        cp -R ${source} "$out/${name}/${relativePath}"
                      ''
                  )
                  normalizedFiles
              )
            );
          };
        in
        skill;

    toSkill =
      value:
      if (value.type or null) == "agents.skill" then
        value
      else
        mkSkill value;

    callNix =
      file: args:
      let
        value = import file;
      in
      if builtins.isFunction value then
        value
          (
            {
              inherit pkgs;
              agentLib = agentLib;
            }
            // args
          )
      else
        value;

    importSkill = file: args: toSkill (callNix file args);

    renderAgentBody =
      agent:
      let
        skillLines =
          if agent.skills == [ ] then
            "This agent does not compose additional skills yet."
          else
            lib.concatMapStringsSep "\n"
              (
                skill: "- `${skill.name}` - ${skill.description}"
              )
              agent.skills;

        mcpLines =
          if agent.mcps == [ ] then
            "This agent does not compose MCP packages yet."
          else
            lib.concatMapStringsSep "\n"
              (
                mcp:
                if lib.isDerivation mcp then
                  "- `${lib.getName mcp}`"
                else
                  "- `${mcp.name}`${lib.optionalString ((mcp.description or "") != "") " - ${mcp.description}"}"
              )
              agent.mcps;
      in
      ''
        # Agent profile: ${agent.name}

        ${agent.prompt}

        ## Composed skills

        ${skillLines}

        ## Composed MCP packages

        ${mcpLines}
      '';

    mkAgent =
      { name
      , description
      , prompt
      , skills ? [ ]
      , mcps ? [ ]
      , packages ? [ ]
      , extraPackages ? [ ]
      , tags ? [ ]
      , metadata ? { }
      , skillName ? "agent-${normalizeSkillName name}"
      ,
      }:
        assert lib.assertMsg (validSkillName skillName)
          "Agent '${name}' renders to invalid skill name '${skillName}'. Override skillName or use lowercase letters, numbers, and hyphens.";
        let
          agentPackages =
            packages
            ++ extraPackages
            ++ lib.concatMap (skill: skill.packages or [ ]) skills
            ++ lib.concatMap packagesOfMcp mcps;

          agent = rec {
            type = "agents.agent";
            inherit
              name
              description
              prompt
              skills
              mcps
              tags
              metadata
              skillName
              ;
            packages = agentPackages;
            asSkill = mkSkill {
              name = skillName;
              description = "Agent profile for ${name}. ${description}";
              tags = [ "agent" ] ++ tags;
              body = renderAgentBody agent;
              packages = packages;
              extraPackages = extraPackages;
              metadata = metadata // {
                "agent-flake.agent-name" = name;
              };
            };
          };
        in
        agent;

    toAgent =
      value:
      if (value.type or null) == "agents.agent" then
        value
      else
        mkAgent value;

    importAgent = file: args: toAgent (callNix file args);

    mkMcp =
      { name
      , description ? ""
      , package ? null
      , command ? null
      , args ? [ ]
      , env ? { }
      , packages ? [ ]
      , extraPackages ? [ ]
      ,
      }:
        assert lib.assertMsg (package != null || command != null)
          "MCP '${name}' must define either package or command.";
        let
          mcpPackages = lib.optionals (package != null) [ package ] ++ packages ++ extraPackages;
        in
        rec {
          type = "agents.mcp";
          inherit
            name
            description
            package
            args
            env
            ;
          command =
            if command != null then
              command
            else
              lib.getExe package;
          packages = mcpPackages;
        };

    packagesOfMcp =
      mcp:
      if lib.isDerivation mcp then
        [ mcp ]
      else
        (mcp.packages or [ ])
        ++ lib.optionals (mcp ? package && mcp.package != null) [ mcp.package ]
        ++ (mcp.extraPackages or [ ]);

    mkSkillDirectory =
      { name ? "agent-skills"
      , skills ? [ ]
      ,
      }:
      let
        selectedSkills = uniqueByName (map toSkill skills);
      in
      pkgs.runCommand name { } (
        ''
          mkdir -p "$out/skills"
        ''
        + lib.concatMapStringsSep "\n"
          (
            skill: ''
              ln -s ${skill.path}/${skill.name} "$out/skills/${skill.name}"
            ''
          )
          selectedSkills
      );

    validEnvName =
      name:
      builtins.isString name && builtins.match "[A-Za-z_][A-Za-z0-9_]*" name != null;

    renderEnvExports =
      env:
      lib.concatStringsSep "\n" (
        lib.mapAttrsToList
          (
            key: value:
            if validEnvName key then
              "export ${key}=${lib.escapeShellArg (toString value)}"
            else
              throw "Invalid environment variable name '${key}'"
          )
          env
      );

    mkWrapper =
      args:
      let
        name = args.name or (args.client or "agent-wrapper");
        client = args.client or name;
        package = args.package or (throw "mkWrapper '${name}' requires a client package");
        program = args.program or (package.meta.mainProgram or client);
        directSkills = args.skills or [ ];
        agents = map toAgent (args.agents or [ ]);
        directMcps = args.mcps or [ ];
        extraPackages = args.extraPackages or [ ];
        extraEnv = args.extraEnv or { };

        allMcps = directMcps ++ lib.concatMap (agent: agent.mcps or [ ]) agents;
        allSkills =
          uniqueByName (
            (map toSkill directSkills)
            ++ lib.concatMap (agent: map toSkill (agent.skills or [ ])) agents
            ++ map (agent: agent.asSkill) agents
          );
        skillDirectory = mkSkillDirectory {
          name = "${lib.strings.sanitizeDerivationName name}-skills";
          skills = allSkills;
        };

        runtimePackages =
          lib.unique (
            [ package ]
            ++ extraPackages
            ++ lib.concatMap (skill: skill.packages or [ ]) allSkills
            ++ lib.concatMap (agent: agent.packages or [ ]) agents
            ++ lib.concatMap packagesOfMcp allMcps
          );
      in
      pkgs.writeShellApplication {
        inherit name;
        runtimeInputs = [
          pkgs.coreutils
          pkgs.findutils
        ] ++ runtimePackages;
        text = ''
          managed_skills=${lib.escapeShellArg "${skillDirectory}/skills"}
          wrapper_name=${lib.escapeShellArg (lib.strings.sanitizeDerivationName name)}

          real_home="''${AGENT_WRAPPER_REAL_HOME:-$HOME}"
          real_xdg_config="''${AGENT_WRAPPER_REAL_XDG_CONFIG_HOME:-''${XDG_CONFIG_HOME:-$real_home/.config}}"
          real_xdg_cache="''${AGENT_WRAPPER_REAL_XDG_CACHE_HOME:-''${XDG_CACHE_HOME:-$real_home/.cache}}"
          real_xdg_state="''${AGENT_WRAPPER_REAL_XDG_STATE_HOME:-''${XDG_STATE_HOME:-$real_home/.local/state}}"
          real_xdg_data="''${AGENT_WRAPPER_REAL_XDG_DATA_HOME:-''${XDG_DATA_HOME:-$real_home/.local/share}}"
          runtime_root="''${AGENT_WRAPPER_RUNTIME_DIR:-''${XDG_RUNTIME_DIR:-''${TMPDIR:-/tmp}}/agent-flake}"

          if [ -z "$runtime_root" ] || [ "$runtime_root" = "/" ]; then
            echo "Refusing unsafe AGENT_WRAPPER_RUNTIME_DIR: '$runtime_root'" >&2
            exit 70
          fi

          uid="$(id -u 2>/dev/null || echo unknown)"
          fake_root="$runtime_root/$wrapper_name-$uid"
          fake_home="$fake_root/home"
          fake_config="$fake_root/config"

          reset_dir() {
            local dir="$1"
            case "$dir" in
              "$runtime_root"/*) ;;
              *)
                echo "Refusing to reset path outside runtime root: $dir" >&2
                exit 70
                ;;
            esac
            rm -rf -- "$dir"
            mkdir -p -- "$dir"
          }

          link_children_except() {
            local source_dir="$1"
            local target_dir="$2"
            shift 2

            [ -d "$source_dir" ] || return 0
            mkdir -p -- "$target_dir"

            local entry base excluded skip
            while IFS= read -r -d "" entry; do
              base="$(basename "$entry")"
              skip=0
              for excluded in "$@"; do
                if [ "$base" = "$excluded" ]; then
                  skip=1
                  break
                fi
              done

              if [ "$skip" -eq 0 ]; then
                ln -sfnT "$entry" "$target_dir/$base"
              fi
            done < <(find "$source_dir" -mindepth 1 -maxdepth 1 -print0)
          }

          compose_skill_dir() {
            local target_dir="$1"
            shift
            reset_dir "$target_dir"

            local source_dir skill_dir base
            for source_dir in "$@"; do
              [ -d "$source_dir" ] || continue
              while IFS= read -r -d "" skill_dir; do
                [ -f "$skill_dir/SKILL.md" ] || continue
                base="$(basename "$skill_dir")"
                ln -sfnT "$skill_dir" "$target_dir/$base"
              done < <(find "$source_dir" -mindepth 1 -maxdepth 1 -print0)
            done
          }

          mkdir -p -- "$fake_root"
          reset_dir "$fake_home"
          reset_dir "$fake_config"

          link_children_except "$real_home" "$fake_home" ".agents" ".config"
          link_children_except "$real_xdg_config" "$fake_config" "agents"

          mkdir -p -- "$fake_home/.agents" "$fake_config/agents"
          link_children_except "$real_home/.agents" "$fake_home/.agents" "skills"
          link_children_except "$real_xdg_config/agents" "$fake_config/agents" "skills"

          compose_skill_dir "$fake_home/.agents/skills" "$real_home/.agents/skills" "$managed_skills"
          compose_skill_dir "$fake_config/agents/skills" "$real_xdg_config/agents/skills" "$managed_skills"

          export AGENT_WRAPPER_NAME=${lib.escapeShellArg name}
          export AGENT_WRAPPER_CLIENT=${lib.escapeShellArg client}
          export AGENT_WRAPPER_REAL_HOME="$real_home"
          export AGENT_WRAPPER_REAL_XDG_CONFIG_HOME="$real_xdg_config"
          export AGENT_WRAPPER_REAL_XDG_CACHE_HOME="$real_xdg_cache"
          export AGENT_WRAPPER_REAL_XDG_STATE_HOME="$real_xdg_state"
          export AGENT_WRAPPER_REAL_XDG_DATA_HOME="$real_xdg_data"
          export AGENT_WRAPPER_SKILLS_DIR="$managed_skills"
          export HOME="$fake_home"
          export XDG_CONFIG_HOME="$fake_config"
          export XDG_CACHE_HOME="$real_xdg_cache"
          export XDG_STATE_HOME="$real_xdg_state"
          export XDG_DATA_HOME="$real_xdg_data"

          ${renderEnvExports extraEnv}

          exec ${lib.escapeShellArg (lib.getExe' package program)} "$@"
        '';
      };

    defaultPackage =
      attr:
      if builtins.hasAttr attr pkgs then
        builtins.getAttr attr pkgs
      else
        throw "nixpkgs does not provide '${attr}' on this system; pass package = ... explicitly";

    interfaces = {
      generic = mkWrapper;
      crush =
        args:
        mkWrapper (
          {
            client = "crush";
            package = defaultPackage "crush";
            program = "crush";
          }
          // args
        );
      aider =
        args:
        mkWrapper (
          {
            client = "aider";
            package = defaultPackage "aider-chat";
            program = "aider";
          }
          // args
        );
      copilot =
        args:
        mkWrapper (
          {
            client = "copilot";
            package = defaultPackage "github-copilot-cli";
            program = "copilot";
          }
          // args
        );
    };
  };
in
agentLib
