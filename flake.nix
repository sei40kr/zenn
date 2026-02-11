{
  description = "Zenn content repository";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-25.11";
    blueprint = {
      url = "github:numtide/blueprint";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    inputs.blueprint {
      inherit inputs;
      prefix = "nix";
    };
}
