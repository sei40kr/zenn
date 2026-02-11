{ inputs, pkgs, ... }:
let
  treefmtEval = inputs.treefmt.lib.evalModule pkgs ../treefmt.nix;
  textlintRules = [
    pkgs.textlint-rule-preset-ja-technical-writing
    pkgs.textlint-rule-preset-ja-spacing
  ];
  nodePath = builtins.concatStringsSep ":" (map (p: "${p}/lib/node_modules") textlintRules);
  textlint = pkgs.writeShellScriptBin "textlint" ''
    export NODE_PATH="${nodePath}''${NODE_PATH:+:$NODE_PATH}"
    exec ${pkgs.textlint}/bin/textlint "$@"
  '';
in
inputs.git-hooks.lib.${pkgs.stdenv.hostPlatform.system}.run {
  src = inputs.self;
  hooks = {
    treefmt = {
      enable = true;
      package = treefmtEval.config.build.wrapper;
    };
    textlint = {
      enable = true;
      name = "textlint";
      entry = "${textlint}/bin/textlint";
      files = "\\.md$";
      types = [ "markdown" ];
    };
  };
}
