{ inputs, pkgs, ... }:
let
  pre-commit-check = import ./checks/pre-commit-check.nix { inherit inputs pkgs; };
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
pkgs.mkShell {
  packages = [
    pkgs.zenn-cli
    textlint
  ];

  shellHook = ''
    ${pre-commit-check.shellHook}
  '';
}
