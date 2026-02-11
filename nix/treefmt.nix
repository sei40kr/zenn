{ pkgs, ... }:
let
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
{
  projectRootFile = "flake.nix";

  programs.nixfmt.enable = true;

  settings.formatter.textlint = {
    command = "${textlint}/bin/textlint";
    options = [ "--fix" ];
    includes = [
      "articles/*.md"
      "books/**/*.md"
    ];
  };
}
