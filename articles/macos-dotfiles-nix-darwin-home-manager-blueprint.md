---
title: "【Nix入門】macOSのdotfilesをnix-darwin + home-manager + blueprintに移行する"
emoji: "❄️"
type: "tech"
topics: ["nix", "dotfiles", "nixdarwin", "homemanager", "blueprint"]
published: true
---

[前回の記事](https://zenn.dev/sei40kr/articles/nix-dotfiles-blueprint)では、Nixエコシステムの全体像と、blueprintによるFlakeのboilerplate削減について解説した。
本記事はその続編として、macOSユーザーが既存のdotfilesリポジトリを **nix-darwin + home-manager + blueprint** の構成に移行する具体的な手順を解説する。

想定読者は、手書きの `install.sh` で `defaults write` やsymlink作成、`brew install` を行っているmacOSユーザーである。

# 移行前の典型的なdotfilesの構成

多くのmacOSユーザーのdotfilesには、以下のような `install.sh` が存在する。

```bash
#!/bin/bash

# Homebrewのインストール
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# CLIツールのインストール
brew install git
brew install ripgrep
brew install fd
brew install neovim

# GUIアプリのインストール
brew install --cask firefox
brew install --cask iterm2
brew install --cask visual-studio-code

# Mac App Storeアプリのインストール
brew install mas
mas install 904280696  # Things 3

# macOS設定
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock tilesize -int 48
defaults write com.apple.finder AppleShowAllExtensions -bool true
defaults write NSGlobalDomain AppleShowAllExtensions -bool true
defaults write NSGlobalDomain KeyRepeat -int 2
defaults write NSGlobalDomain InitialKeyRepeat -int 15

# symlink
ln -sf "$HOME/dotfiles/.zshrc" "$HOME/.zshrc"
ln -sf "$HOME/dotfiles/.config/nvim" "$HOME/.config/nvim"
ln -sf "$HOME/dotfiles/.config/git/config" "$HOME/.config/git/config"

# shell設定の反映
source "$HOME/.zshrc"
```

この構成には以下の問題がある。

- **冪等性がない**: 2回目の実行で意図しない挙動が起きうる。`ln -sf` は既存のsymlinkを上書きするが、ディレクトリの場合はsymlink先の中にリンクが作られるなど、edge caseが多い
- **再現性が低い**: `brew install` はバージョンを固定しないため、実行時期によって異なるバージョンがインストールされる
- **エラーハンドリングが困難**: スクリプトの途中で失敗した場合、どこまで適用されたのか判断しづらい
- **宣言的でない**: システムの「あるべき状態」ではなく「実行する手順」を記述しているため、現在の状態が設定と一致しているか確認する手段がない
- **履歴管理がない**: 設定変更の履歴が残らず、問題が起きたときに以前の状態に戻す手段がない

# Nixのインストール

まだNixをインストールしていない場合は、公式のインストールスクリプトを実行する。

```bash
sh <(curl -L https://nixos.org/nix/install)
```

nix-darwinはmulti-user installationのみサポートしている。
インストーラーの質問では必ずmulti-userを選択すること。

インストール後、shellを再起動すると `nix` コマンドが使えるようになる。
Flakeはデフォルトで有効になっている。

# blueprintプロジェクトの初期化

次に、blueprintのテンプレートを使ってプロジェクトを作成する。

```bash
mkdir my-nix-config && cd my-nix-config

# nix-darwin + home-manager共有のテンプレートで初期化
nix flake init -t github:numtide/blueprint#nixos-and-darwin-shared-homes

git init
git add .
```

macOS向けの基本的なフォルダ構造は以下のようになる。

```
.
├── flake.nix
├── hosts
│   └── my-mac           # ホスト名 (hostname -sの出力と一致させる)
│       ├── darwin-configuration.nix
│       └── users
│           └── alice    # ユーザー名
│               └── home-configuration.nix
└── modules
    └── home
        └── shared.nix   # 複数ホスト/ユーザーで共有するhome-manager設定
```

設定ファイルが2種類に分かれている点に注目してほしい。
nix-darwinはmacOSのシステム設定 (defaults、Homebrew、サービスなど) と `/etc` 以下のファイルを管理するツールであり、ユーザーレベルの設定は管理できない。
`~/.config` 以下の設定ファイルやshellの設定など、ユーザー固有の環境はhome-managerで管理する。
そのため、システム設定は `darwin-configuration.nix` に、ユーザー設定は `home-configuration.nix` に記述する。

`flake.nix` は前回の記事で紹介したとおり、blueprintにより最小限の記述で済む。

```nix
{
  description = "My macOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-25.11";

    blueprint.url = "github:numtide/blueprint";
    blueprint.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager/release-25.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nix-darwin.url = "github:nix-darwin/nix-darwin/nix-darwin-25.11";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs: inputs.blueprint { inherit inputs; };
}
```

:::message
各inputの `.inputs.nixpkgs.follows = "nixpkgs"` は、inputが内部で持つNixpkgsの参照を統一する宣言である。
`follows` はFlake作者の意図したバージョンとは異なるNixpkgsを強制するため、互換性の問題を引き起こす可能性がある。
しかし、Nixpkgsは非常に大きなリポジトリであり、重複すると `/nix/store` のストレージ消費が増大する。
同一バージョンを共有することでビルドキャッシュも有効活用でき、ビルド時間を短縮できる。
Nixpkgsのように巨大なinputに対しては `follows` するのが広く行われている慣習である。

<!-- textlint-disable ja-technical-writing/ja-no-mixed-period -->

:::

<!-- textlint-enable -->

# macOS defaults設定の移行

`install.sh` に散らばった `defaults write` コマンドは、nix-darwinの `system.defaults` で宣言的に管理できる。

```nix
# hosts/my-mac/darwin-configuration.nix
{ pkgs, ... }:
{
  # Apple Siliconの場合。Intel Macの場合は "x86_64-darwin"
  nixpkgs.hostPlatform = "aarch64-darwin";

  # Dock
  system.defaults.dock.autohide = true;
  system.defaults.dock.tilesize = 48;

  # Finder
  system.defaults.finder.AppleShowAllExtensions = true;
  system.defaults.NSGlobalDomain.AppleShowAllExtensions = true;

  # キーボード
  system.defaults.NSGlobalDomain.KeyRepeat = 2;
  system.defaults.NSGlobalDomain.InitialKeyRepeat = 15;

  system.stateVersion = 6;
}
```

`defaults write` との対応は直感的である。例えば `defaults write com.apple.dock autohide -bool true` は `system.defaults.dock.autohide = true` に対応する。

`darwin-rebuild switch` を実行すると、nix-darwinのactivation scriptがこれらの設定を自動的に適用する。
手動で `defaults write` を実行する必要はなくなる。
設定を変更したい場合は `.nix` ファイルを編集して再度 `darwin-rebuild switch` を実行するだけでよい。

# Nixpkgsからのパッケージインストール

`install.sh` の `brew install git` のようなパッケージは、Nixpkgsから直接インストールできる。
パッケージ名は以下の方法で検索できる。

- **Web**: [search.nixos.org](https://search.nixos.org/packages) でパッケージ名や説明を検索
- **CLI**: `nix search nixpkgs <キーワード>` で検索

```bash
$ nix search nixpkgs ripgrep
* legacyPackages.aarch64-darwin.ripgrep (14.1.1)
  A utility that combines the usability of The Silver Searcher with the raw speed of grep
```

パッケージの用途に応じて、以下のオプションを使い分ける。

| オプション                    | レベル       | 配置先                               | 用途                         |
| ----------------------------- | ------------ | ------------------------------------ | ---------------------------- |
| `environment.systemPackages`  | nix-darwin   | `/run/current-system/sw/bin/`        | 全ユーザー共通のパッケージ   |
| `users.users.<name>.packages` | nix-darwin   | `/etc/profiles/per-user/<name>/bin/` | 特定ユーザー向けのパッケージ |
| `home.packages`               | home-manager | `~/.nix-profile/bin/`                | ユーザー環境のパッケージ     |

個人のdotfilesでは `home.packages` を使うのが一般的である。

```nix
# hosts/my-mac/users/alice/home-configuration.nix
{
  home.packages = with pkgs; [
    ripgrep
    fd
    jq
  ];
}
```

# HomebrewとMac App Storeの宣言的管理

CLIツールはNixpkgsでカバーできるが、macOSのGUIアプリ (.app) はNixpkgsでは十分にサポートされていない。
nix-darwinの `homebrew` モジュールを使えば、Homebrew CaskやMac App Storeのアプリも宣言的に管理できる。

```nix
# hosts/my-mac/darwin-configuration.nix
{
  homebrew = {
    enable = true;

    # GUIアプリ (Homebrew Cask)
    casks = [
      "firefox"
      "iterm2"
      "visual-studio-code"
    ];

    # Mac App Storeアプリ
    masApps = {
      "Things 3" = 904280696;
    };

    # Nixpkgsにないformula
    brews = [
      # 必要に応じて追加
    ];

    # Nix設定で宣言されていないパッケージを自動削除
    onActivation.cleanup = "zap";
  };
}
```

`homebrew.onActivation.cleanup = "zap"` は重要な設定である。
これを有効にすると、`darwin-rebuild switch` 時にNix設定で宣言されていないHomebrewパッケージが自動的に削除される。
これにより、手動で `brew install` したパッケージが残り続ける問題を防ぎ、環境を常に宣言された状態に保てる。

`install.sh` の `brew install` / `brew install --cask` / `mas install` をすべてこの設定で置き換えられる。

:::message
`homebrew` モジュールはHomebrew自体のインストールは行わない。
Homebrewは事前に手動でインストールしておく必要がある。
Homebrewが見つからない場合、activation scriptでのパッケージインストールはスキップされる。

<!-- textlint-disable ja-technical-writing/ja-no-mixed-period -->

:::

<!-- textlint-enable -->

# 従来の設定ファイルをそのまま利用する方法

すべての設定をモジュールオプションに合わせて書き直す必要はない。
home-managerにはファイルをsymlinkとして配置する仕組みがあり、配置先に応じて使い分ける。

| オプション       | 配置先                    |
| ---------------- | ------------------------- |
| `home.file`      | `~/` (ホームディレクトリ) |
| `xdg.configFile` | `~/.config/`              |
| `xdg.dataFile`   | `~/.local/share/`         |

これらのオプションは共通のサブオプションを持つ。

| サブオプション | 説明                                                           |
| -------------- | -------------------------------------------------------------- |
| `source`       | リンク元のファイルまたはディレクトリのパス                     |
| `text`         | ファイルの内容を文字列で直接指定する (`source` の代わりに使用) |
| `recursive`    | `source` がディレクトリの場合、中身を再帰的にsymlinkする       |
| `executable`   | 実行権限を付与する                                             |

```nix
# hosts/my-mac/users/alice/home-configuration.nix
{ ... }:
{
  # Neovimの設定ディレクトリをまるごとsymlink (~/.config/nvim/)
  xdg.configFile."nvim" = {
    source = ./nvim;  # home-configuration.nixからの相対パス
    recursive = true;
  };

  # 個別のファイルを配置 (~/.config/starship.toml)
  xdg.configFile."starship.toml".source = ./starship.toml;

  # textで内容を直接記述 (~/.hushlogin)
  home.file.".hushlogin".text = "";

  home.stateVersion = "25.11";
}
```

`home.file` や `xdg.configFile` が適切なのは、以下のようなケースである。

- 設定が複雑で、モジュールオプションに合わせて書き直すコストが高い場合
- 対応するhome-managerモジュールが存在しない場合

既存のdotfilesから段階的に移行する場合、まずは `home.file` で配置し、余裕があるときにhome-managerモジュールへ移行するという戦略が有効である。

# home-managerモジュールを使った設定の移行

`home.file` による配置は手軽である。
しかし、home-managerにはshell統合の自動設定や型検証も備えたモジュールが用意されている。
対応するモジュールのあるツールでは、モジュールを活用するほうが利点は多い。

利用可能なモジュールとそのオプションは、以下の方法で検索できる。

- **Web**: [home-manager options search](https://home-manager-options.extranix.com/) でオプション名や説明を検索
- **CLI**: `man home-configuration.nix` でローカルのマニュアルを参照

## Git

```nix
{
  programs.git = {
    enable = true;
    userName = "Alice";
    userEmail = "alice@example.com";
    extraConfig = {
      init.defaultBranch = "main";
      push.autoSetupRemote = true;
      pull.rebase = true;
    };
    ignores = [
      ".DS_Store"
      ".direnv"
    ];
  };
}
```

`~/.config/git/config` と `~/.config/git/ignore` が自動的に生成される。

## Z-shell

nix-darwin側でもZ-shellを有効化しておく。

```nix
# hosts/my-mac/darwin-configuration.nix
{
  programs.zsh.enable = true;
}
```

home-manager側ではZ-shellの設定を記述する。

```nix
{
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    shellAliases = {
      ll = "ls -la";
      g = "git";
      k = "kubectl";
    };
    initContent = ''
      # 既存の.zshrcの内容をここに移せる
      bindkey -e
      setopt AUTO_CD
    '';
  };
}
```

`programs.zsh.enable = true` にすると、home-managerが `~/.zshrc` を管理する。
`initContent` に既存の `.zshrc` の内容をそのまま記述できるため、段階的な移行が可能である。

## Neovim

```nix
{
  programs.neovim = {
    enable = true;
    viAlias = true;
    vimAlias = true;
    defaultEditor = true;
    extraPackages = with pkgs; [
      # LSPなど、Neovimから利用する外部コマンド
      lua-language-server
      nil # Nix LSP
      ripgrep
    ];
  };
}
```

`defaultEditor = true` により、`EDITOR` 環境変数が `nvim` に設定される。
`extraPackages` で指定したパッケージはNeovimのランタイムPATHに追加される。

## Syncthing (常駐サービスの例)

home-managerのモジュールは設定ファイルの生成だけでなく、常駐サービスの管理も担う。
Linuxではsystemdユニット、macOSではLaunchAgentとしてOSごとに適切な仕組みへ変換される。

```nix
{
  services.syncthing.enable = true;
}
```

これだけの記述で、`darwin-rebuild switch` 後に以下が確認できる。

```bash
# LaunchAgentが登録されていることを確認
$ launchctl list | grep syncthing
-   0   org.nix-community.home.syncthing

# plistファイルが生成されている
$ ls ~/Library/LaunchAgents/org.nix-community.home.syncthing.plist
```

home-managerの内部ではsystemdサービスとして定義されているが、macOSではnix-darwinがlaunchdのplistへ変換する。
生成されたplistは `~/Library/LaunchAgents/` に配置される。
ユーザーはOS間の差異を意識することなく、同じ `services.syncthing.enable = true` で両方の環境を管理できる。

# 💡 shell設定の注意点

shellの設定はNix環境の根幹に関わるため、他の設定とは異なる注意点がある。

nix-darwinとhome-managerの双方で対応するshellモジュールを明示的に有効化しないと、PATHや環境変数の設定が行われず、コマンドが見つからないなどの問題が発生する。
`home.file` でshellの設定ファイルを配置しても、nix-darwinやhome-managerのshellファイルがsourceされない点は変わらない。
shellの設定は対応するモジュールで管理し、既存の設定は `initContent` などのオプションに記述するのが正しい方法である。

## nix-darwinのshellモジュールが行うこと

Bash以外のshellを使う場合、対応するshellモジュールを有効化する必要がある。
Z-shellの場合は以下のようになる。

```nix
# hosts/my-mac/darwin-configuration.nix
{
  programs.zsh.enable = true;
}
```

例えばnix-darwinの `programs.zsh` モジュールは `/etc/zshenv` と `/etc/zshrc` を生成する。

`/etc/zshenv` では `set-environment` というスクリプトを読み込む。
このスクリプトは以下を行う。

- Nixのプロファイルパス (`~/.nix-profile/bin`, `/run/current-system/sw/bin` など) をPATHに追加
- Nix関連の環境変数 (`NIX_PROFILES`, `XDG_CONFIG_DIRS` など) や `environment.sessionVariables` で指定した環境変数を設定

有効化しないとこれらの設定が読み込まれず、Nixでインストールしたコマンドが見つからないなどの問題が起きる。

## home-managerのshellモジュールが行うこと

home-managerでも同様に、対応するshellモジュールを有効化する必要がある。
Z-shellの場合は以下のようになる。

```nix
# hosts/my-mac/users/alice/home-configuration.nix
{
  programs.zsh.enable = true;
}
```

例えばhome-managerの `programs.zsh` モジュールは `~/.zshenv` と `~/.zshrc` を生成する。

`~/.zshenv` では `hm-session-vars.sh` というスクリプトを読み込む。
このスクリプトは以下を行う。

- home-managerのプロファイルパス (`~/.nix-profile/bin`) や `home.sessionPath` で指定したパスをPATHに追加
- `home.sessionVariables` で指定した環境変数を設定

有効化しないとこれらの設定が読み込まれず、home-managerで管理しているコマンドが見つからないなどの問題が起きる。

# 💡 darwin-rebuild switch後の環境変数の反映

`EDITOR` などの環境変数は `hm-session-vars.sh` で設定される。
このスクリプトは再実行防止のガードを持つため、shell起動時に一度だけ実行される。
`darwin-rebuild switch` 後に変更を反映するには、shellを再起動する必要がある。

# 💡 tmuxでの環境変数の反映

tmux上のshellは親shellの環境変数を引き継ぐため、`darwin-rebuild switch` 後に親shellごと再起動しないと変更が反映されない。
tmuxの設定で `set-environment` と `hm-session-vars.sh` のガードフラグを削除すると、新しいpaneやwindowを開くたびに最新の設定が読み込まれるようになる。

```bash
# ~/.tmux.conf
set-environment -gru __NIX_DARWIN_SET_ENVIRONMENT_DONE
set-environment -gru __HM_SESS_VARS_SOURCED
```

# 💡 プラグインの管理方法

Z-shellやNeovimのプラグイン管理には、大きく分けて3つのアプローチがある。

## 1. 従来のプラグインマネージャーをそのまま使う

既存のプラグインマネージャー (Z-shellならzinit, sheldon等、Neovimならlazy.nvim等) は、Nix環境でもそのまま動作する。
`programs.zsh.initContent` や `xdg.configFile` でプラグインマネージャーの設定を配置すればよい。

この方法は最も移行コストが低い。
ただし、プラグインのインストールがNixの管理外になるため、`darwin-rebuild switch` だけでは環境が再現できない。

## 2. Nixpkgsのプラグインパッケージを使う

NixpkgsにはZ-shellやNeovimのプラグインが多数パッケージ化されている。
home-managerのモジュールオプションから直接指定できる。

Z-shellの場合は以下のようになる。

```nix
{
  programs.zsh = {
    enable = true;
    plugins = [
      {
        name = "zsh-autosuggestions";
        src = pkgs.zsh-autosuggestions;
        file = "share/zsh-autosuggestions/zsh-autosuggestions.zsh";
      }
    ];
  };
}
```

`initContent` で直接sourceする方法もある。

```nix
{
  programs.zsh = {
    enable = true;
    initContent = ''
      source ${pkgs.zsh-autosuggestions}/share/zsh-autosuggestions/zsh-autosuggestions.zsh
    '';
  };
}
```

Neovimの場合は以下のようになる。

```nix
{
  programs.neovim = {
    enable = true;
    plugins = with pkgs.vimPlugins; [
      telescope-nvim
      nvim-treesitter.withAllGrammars
      {
        plugin = nvim-lspconfig;
        type = "lua";
        config = ''
          require("lspconfig").lua_ls.setup({})
        '';
      }
    ];
  };
}
```

プラグインのバージョンがNixpkgsで固定されるため、完全な再現性が得られる。

## 3. プラグインマネージャーからNixパッケージを読み込むハイブリッド

プラグインマネージャーにはNixが提供しない機能 (遅延ロード、イベントトリガー、依存関係の宣言など) が充実しているものがある。
プラグインのインストールはNixに任せ、ロードの制御はプラグインマネージャーに任せるハイブリッド構成も可能である。

Neovimのlazy.nvimの場合、Nixでインストールしたプラグインのパスを指定できる。

```nix
{
  programs.neovim = {
    enable = true;
    plugins = with pkgs.vimPlugins; [
      lazy-nvim
    ];
    extraLuaConfig = ''
      require("lazy").setup({
        { dir = "${pkgs.vimPlugins.telescope-nvim.outPath}", name = "telescope.nvim", lazy = true, cmd = "Telescope" },
        { dir = "${pkgs.vimPlugins.nvim-treesitter.withAllGrammars.outPath}", name = "nvim-treesitter", event = "BufRead" },
      }, {
        install = { missing = false },
      })
    '';
  };
}
```

この構成ではプラグインの再現性はNixが保証しつつ、遅延ロードによる起動速度の最適化はlazy.nvimが担当する。

# 設定の適用方法

設定が書けたら、以下のコマンドで適用する。

```bash
# ファイルをgitで追跡 (Flakeは未追跡ファイルを無視する)
git add .

# 設定を適用
darwin-rebuild switch --flake .#my-mac
```

`#my-mac` の部分は `hosts/` ディレクトリ配下のホスト名と一致させる必要がある。

初回実行時は、nix-darwinのactivation scriptが各種設定を適用するため、Dockの再起動やFinderの再起動が自動的に行われる。
一部の設定 (キーボードのリピート速度など) は、ログアウト・ログインが必要になる場合がある。

設定を変更した場合は `.nix` ファイルを編集し、再度 `darwin-rebuild switch --flake .#my-mac` を実行する。
nix-darwinは差分のみを適用するため、変更のない設定はスキップされる。

# まとめ

macOSのdotfiles移行では、以下の順序で段階的に進めるのがおすすめである。

1. **プロジェクトの初期化**: blueprintテンプレートでFlakeを作成
2. **macOS defaults**: `defaults write` を `system.defaults` に移行
3. **パッケージ**: Nixpkgsにあるものを `home.packages` などに移行
4. **Homebrew/Mac App Store**: Nixpkgsにないものを `homebrew` モジュールに移行
5. **shell設定**: `.zshrc` を `programs.zsh` に移行 (これを先にやると他のモジュールの統合が効く)
6. **その他の設定**: home-managerモジュールがあるものはモジュールを使い、ないものは `home.file` で配置

すべてを一度に移行する必要はない。
`home.file` を活用すれば既存の設定ファイルをそのまま持ち込めるため、動く状態を保ちながら少しずつNix化を進められる。

Nixエコシステムの概念やblueprintの仕組みについては、[前回の記事](https://zenn.dev/sei40kr/articles/nix-dotfiles-blueprint)を参照してほしい。
