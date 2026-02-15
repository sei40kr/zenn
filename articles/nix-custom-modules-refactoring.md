---
title: "【Nix実践】自作モジュールでNix設定をリファクタリングする"
emoji: "❄️"
type: "tech"
topics: ["nix", "dotfiles", "homemanager", "nixdarwin", "blueprint"]
published: true
---

[前回の記事](https://zenn.dev/sei40kr/articles/macos-dotfiles-nix-darwin-home-manager-blueprint)では、macOSのdotfilesをnix-darwin + home-manager + blueprintに移行する手順を解説した。
移行直後は設定ファイルもコンパクトだが、ツールや設定を追加していくうちに `home-configuration.nix` や `darwin-configuration.nix` は数百行に膨れ上がる。

本記事では、Nixのモジュールシステムを活用して肥大化した設定をリファクタリングする方法を解説する。

# 肥大化する設定ファイル

前回の記事で作成した設定に、さらにツールを追加していった結果を想像してほしい。

```nix
# hosts/my-mac/users/alice/home-configuration.nix
{ pkgs, ... }:
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
    ignores = [ ".DS_Store" ".direnv" ];
  };

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    shellAliases = {
      ll = "ls -la";
      g = "git";
      k = "kubectl";
    };
    initContent = ''
      bindkey -e
      setopt AUTO_CD
    '';
  };

  programs.neovim = {
    enable = true;
    viAlias = true;
    vimAlias = true;
    defaultEditor = true;
    extraPackages = with pkgs; [
      lua-language-server
      nil
      ripgrep
    ];
  };

  programs.starship.enable = true;
  programs.direnv.enable = true;
  programs.direnv.nix-direnv.enable = true;
  programs.fzf.enable = true;
  programs.bat.enable = true;
  programs.eza.enable = true;

  programs.gh = {
    enable = true;
    settings.git_protocol = "ssh";
  };

  services.syncthing.enable = true;

  home.packages = with pkgs; [
    fd
    jq
    yq
    tree
    curl
    wget
    htop
    nodejs
    python3
    rustup
    docker-compose
    kubectl
    terraform
    awscli2
  ];

  home.stateVersion = "25.11";
}
```

この程度ならまだ読めるが、実際にはSSH設定、GPG設定、各言語の開発環境設定などが加わり、ファイルは容易に数百行を超える。

この問題に対処するアプローチは2つある。
**ファイル分割**と**自作モジュール**である。

# アプローチ1: ファイル分割

## importとimports

Nixで別ファイルを読み込む方法は2つある。

**`import`** はNix言語の組み込み関数で、指定パスのNixファイルを式として評価する。

```nix
# ./message.nix の中身が "Hello, world!" という文字列だとする
let
  msg = import ./message.nix;
in
  msg  # => "Hello, world!"
```

`import` はファイルの中身をそのままNix式として評価するだけである。
関数が返る場合は、呼び出し側で引数を渡す。

```nix
# ./add.nix の中身が x: y: x + y という関数だとする
let
  add = import ./add.nix;
in
  add 1 2  # => 3
```

**`imports`** はモジュールシステムの属性で、モジュールのリストを受け取り、`options` と `config` を自動的にマージする。

```nix
# imports: モジュールシステムによるマージ
{ ... }:
{
  imports = [
    ./git.nix
    ./shell.nix
  ];
}
```

`import` が任意のNix式を評価する汎用的な関数であるのに対し、`imports` はモジュールの構成要素をマージする。
設定ファイルの分割には `imports` を使うのが一般的である。

## importsによるファイル分割

最もシンプルな方法は、設定を複数のファイルに分割して `imports` で読み込むことである。

```
hosts/my-mac/users/alice/
├── home-configuration.nix
├── git.nix
├── shell.nix
├── editor.nix
└── dev-tools.nix
```

```nix
# hosts/my-mac/users/alice/home-configuration.nix
{ ... }:
{
  imports = [
    ./git.nix
    ./shell.nix
    ./editor.nix
    ./dev-tools.nix
  ];

  home.stateVersion = "25.11";
}
```

```nix
# hosts/my-mac/users/alice/shell.nix
{ ... }:
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
      bindkey -e
      setopt AUTO_CD
    '';
  };

  programs.starship.enable = true;
  programs.fzf.enable = true;
}
```

ファイル分割は手軽であり、設定の見通しを改善するには十分な場合も多い。
しかし、以下の制約がある。

- **カスタマイズ性がない**: 分割したファイルは常にそのまま適用される。ホストごとに一部だけ変えたい場合に対応できない
- **依存関係が暗黙的**: ファイル間でどのオプションに依存しているか明示されない

これらの制約が問題になるときは、Nixのモジュールシステムを活用した自作モジュールが有効である。

# Nixモジュールシステムの基本

自作モジュールを作成する前に、Nixのモジュールシステムの動作を理解しておく。

## モジュールの構造

Nixモジュールは、以下の3つの要素を返す関数である。

```nix
{ config, lib, pkgs, ... }:
{
  imports = [
    # 他のモジュールのインポート
  ];

  options = {
    # このモジュールが提供するオプションの宣言
  };

  config = {
    # オプションの値に基づく実際の設定
  };
}
```

| 要素      | 役割                                           |
| --------- | ---------------------------------------------- |
| `imports` | 他のモジュールを読み込む                       |
| `options` | このモジュールが受け付けるオプションを宣言する |
| `config`  | オプションの値に基づいて、実際の設定を定義する |

:::message
Nixモジュールの本質は、`options` で宣言したインターフェースから他のモジュールの `config` やactivation scriptへの**マッピング**である。
たとえば `programs.git.enable = true` と書くと、gitモジュールが `~/.config/git/config` の生成やパッケージのインストールを行う。
自作モジュールでも同じパターンで、独自のオプションから既存モジュールの設定への変換を定義する。

<!-- textlint-disable ja-technical-writing/ja-no-mixed-period -->

:::

<!-- textlint-enable -->

これまでの記事で書いてきた設定ファイルは、`options` を省略して `config` の内容をトップレベルに書いた短縮形である。
たとえば `{ pkgs, ... }: { programs.git.enable = true; }` という記述は短縮形である。
内部的には `config.programs.git.enable = true` を設定している。

## オプションの宣言

`options` ではモジュールが受け付ける設定項目を宣言する。
各オプションには型 (`type`)、デフォルト値 (`default`)、説明 (`description`) を指定できる。

```nix
{ lib, ... }:
{
  options.modules.editor = {
    enable = lib.mkEnableOption "editor configuration";

    lsp.nix.enable = lib.mkEnableOption "Nix LSP (nil)";
    lsp.lua.enable = lib.mkEnableOption "Lua LSP";

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Additional packages available to Neovim";
    };
  };
}
```

`lib.mkEnableOption` は `lib.mkOption` のショートカットで、`type = lib.types.bool` かつ `default = false` のオプションを生成する。
Nixエコシステムでは `enable` オプションによるオン・オフの切り替えが広く使われている。
`programs.git.enable` や `services.syncthing.enable` もすべてこの仕組みである。

主要なプリミティブ型を以下に示す。

| 型              | 説明           | 例               |
| --------------- | -------------- | ---------------- |
| `types.bool`    | 真偽値         | `true`           |
| `types.str`     | 文字列         | `"hello"`        |
| `types.int`     | 整数           | `42`             |
| `types.lines`   | 複数行テキスト | `"line1\nline2"` |
| `types.path`    | ファイルパス   | `./config.nix`   |
| `types.enum`    | 列挙型         | `"zsh"`          |
| `types.package` | Nixパッケージ  | `pkgs.ripgrep`   |

また、型を組み合わせるユーティリティ型もある。

| 型                        | 説明                     | 例                   |
| ------------------------- | ------------------------ | -------------------- |
| `types.listOf T`          | Tのリスト                | `[ "a" "b" ]`        |
| `types.attrsOf T`         | Tの属性セット            | `{ key = "value"; }` |
| `types.nullOr T`          | null許容のT              | `null` or `"hello"`  |
| `types.either T U`        | TまたはU                 | `"hello"` or `42`    |
| `types.submodule { ... }` | ネストされたオプション群 | 後述                 |

型を指定しておくことで、不正な値が与えられた場合にビルド時点でエラーになる。
シェルスクリプトと異なり、評価時に検証が行われるため、デプロイ前に問題を検出できる。

## mkIfによる条件付き設定

`lib.mkIf` は、条件が真のときだけ設定を適用する関数である。
`enable` オプションと組み合わせることで、モジュールのオン・オフを制御できる。

```nix
{ config, lib, ... }:
let
  cfg = config.modules.editor;
in
{
  options.modules.editor = {
    enable = lib.mkEnableOption "editor configuration";
  };

  config = lib.mkIf cfg.enable {
    programs.neovim.enable = true;
  };
}
```

:::message
`lib.mkIf` はNix言語の `if...then...else` とは異なる仕組みである。
`if...then...else` は式を即座に評価するが、`mkIf` はモジュールシステムのマージ機構と連携した遅延条件である。
複数モジュールが同じオプションに `mkIf` で値を提供した場合、条件が評価されたうえで適切にマージされる。

<!-- textlint-disable ja-technical-writing/ja-no-mixed-period -->

:::

<!-- textlint-enable -->

:::message
`let cfg = config.modules.editor; in` は慣習的な記法で、自モジュールの設定値への参照を短くするために使う。
モジュール関数の引数 `config` はシステム全体の設定を指すため、名前の衝突を避けて `cfg` という別名を使う。
NixOS、nix-darwin、home-managerの公式モジュールでも広く使われているパターンである。

<!-- textlint-disable ja-technical-writing/ja-no-mixed-period -->

:::

<!-- textlint-enable -->

# アプローチ2: 自作モジュールの作成

ここからは、実際に自作モジュールを作成してリファクタリングを行う。

## blueprintでのモジュール配置

作成したモジュールは `modules/` ディレクトリに配置する。
blueprintがディレクトリ内のファイルを自動検出し、Flake outputsとして公開する。

```
modules/
├── darwin/            # nix-darwinモジュール
│   └── keyboard.nix
└── home/              # home-managerモジュール
    ├── development.nix
    └── editor.nix
```

blueprintによるフォルダとFlake outputsの対応は以下の通りである。

| フォルダ                    | Flake output           | インポート先               |
| --------------------------- | ---------------------- | -------------------------- |
| `modules/home/<name>.nix`   | `homeModules.<name>`   | `home-configuration.nix`   |
| `modules/nixos/<name>.nix`  | `nixosModules.<name>`  | `configuration.nix`        |
| `modules/darwin/<name>.nix` | `darwinModules.<name>` | `darwin-configuration.nix` |

`<name>.nix` の代わりに `<name>/default.nix` でも同じように扱われる。
ディレクトリ形式を使うと、モジュールが `import` する設定ファイルやスクリプトをまとめて管理できる。

```
modules/home/
├── editor.nix              # 単一ファイル形式
└── neovim/                 # ディレクトリ形式
    ├── default.nix         # モジュール本体
    └── init.lua            # Neovimの設定ファイル
```

:::message
blueprintは `modules/` 配下のファイルを自動検出してFlake outputsとして**公開する**が、ホスト設定への**自動インポートは行わない**。
使用するモジュールは、各設定ファイルの `imports` で明示的に読み込む必要がある。

<!-- textlint-disable ja-technical-writing/ja-no-mixed-period -->

:::

<!-- textlint-enable -->

## home-managerモジュール

home-managerモジュールは `modules/home/` に配置する。

### 開発環境モジュール

開発ツールのモジュールを示す。
言語ごとにオン・オフを切り替えられるようにする。

```nix
# modules/home/development.nix
{ config, lib, pkgs, ... }:
let
  cfg = config.modules.development;
in
{
  options.modules.development = {
    enable = lib.mkEnableOption "development tools";

    node.enable = lib.mkEnableOption "Node.js environment";
    python.enable = lib.mkEnableOption "Python environment";
    rust.enable = lib.mkEnableOption "Rust environment";

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Additional development packages";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = with pkgs;
      [
        ghq
        jq
        yq
        tree
        curl
        wget
      ]
      ++ lib.optionals cfg.node.enable [ nodejs ]
      ++ lib.optionals cfg.python.enable [ python3 ]
      ++ lib.optionals cfg.rust.enable [ rustup ]
      ++ cfg.extraPackages;

    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
    };

    programs.gh = {
      enable = true;
      settings.git_protocol = "ssh";
    };
  };
}
```

`lib.optionals` は条件が真のときだけリストの要素を追加する関数である。
これにより、個人マシンではRustを有効に、会社マシンではPythonを有効に、といった使い分けが可能になる。

### エディタモジュール

Neovimの設定とLSPサーバーをモジュールにまとめる例を示す。

```nix
# modules/home/editor.nix
{ config, lib, pkgs, ... }:
let
  cfg = config.modules.editor;
in
{
  options.modules.editor = {
    enable = lib.mkEnableOption "editor configuration";

    lsp = {
      nix.enable = lib.mkEnableOption "Nix LSP (nil)";
      lua.enable = lib.mkEnableOption "Lua LSP";
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Additional packages available to Neovim";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.neovim = {
      enable = true;
      viAlias = true;
      vimAlias = true;
      defaultEditor = true;
      extraPackages = with pkgs;
        [ ripgrep ]
        ++ lib.optionals cfg.lsp.nix.enable [ nil ]
        ++ lib.optionals cfg.lsp.lua.enable [ lua-language-server ]
        ++ cfg.extraPackages;
    };
  };
}
```

このモジュールの利点は以下の通りである。

- Neovim本体とLSPサーバーの設定が1ファイルに集約されている
- 言語ごとのLSPをオン・オフできる
- `extraPackages` でホスト固有のツールを追加できる
- `enable = false` (デフォルト) の場合、何も設定されない

## nix-darwinモジュール

nix-darwinモジュールは `modules/darwin/` に配置する。

```nix
# modules/darwin/keyboard.nix
{ config, lib, ... }:
let
  cfg = config.modules.keyboard;
in
{
  options.modules.keyboard = {
    enable = lib.mkEnableOption "keyboard configuration";

    keyRepeat = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = "Key repeat rate (lower is faster)";
    };

    initialKeyRepeat = lib.mkOption {
      type = lib.types.int;
      default = 15;
      description = "Delay before key repeat starts (lower is shorter)";
    };
  };

  config = lib.mkIf cfg.enable {
    system.defaults.NSGlobalDomain.KeyRepeat = cfg.keyRepeat;
    system.defaults.NSGlobalDomain.InitialKeyRepeat = cfg.initialKeyRepeat;
  };
}
```

:::message
NixOSとnix-darwinはモジュールシステムの仕組みを共有しているが、宣言されているオプションは異なる。
`system.defaults` のようなnix-darwin固有のオプションはNixOSでは宣言されていないため、このモジュールをNixOSで評価するとエラーになる。
`mkIf` で分岐しても、モジュールシステムはオプションの存在を検証するため回避できない。

<!-- textlint-disable ja-technical-writing/ja-no-mixed-period -->

:::

<!-- textlint-enable -->

## モジュールのsmoke test

自作モジュールが正しく評価できることを `nix flake check` で検証できる。
blueprintの `nix/checks/` にモジュールごとのsmoke testを定義する。

```nix
# nix/checks/home-editor.nix
{ inputs, pkgs, ... }:
(inputs.home-manager.lib.homeManagerConfiguration {
  inherit pkgs;
  modules = [
    inputs.self.homeModules.editor
    {
      home.username = "test";
      home.homeDirectory = "/home/test";
      home.stateVersion = "25.11";
      modules.editor.enable = true;
    }
  ];
}).activationPackage
```

```nix
# nix/checks/home-development.nix
{ inputs, pkgs, ... }:
(inputs.home-manager.lib.homeManagerConfiguration {
  inherit pkgs;
  modules = [
    inputs.self.homeModules.development
    {
      home.username = "test";
      home.homeDirectory = "/home/test";
      home.stateVersion = "25.11";
      modules.development.enable = true;
    }
  ];
}).activationPackage
```

nix-darwinモジュールも同様にテストできる。

```nix
# nix/checks/darwin-keyboard.nix
{ inputs, ... }:
(inputs.nix-darwin.lib.darwinSystem {
  modules = [
    inputs.self.darwinModules.keyboard
    {
      nixpkgs.hostPlatform = "aarch64-darwin";
      modules.keyboard.enable = true;
      system.stateVersion = 6;
    }
  ];
}).system
```

`nix flake check` を実行すると、これらのチェックが自動的に走る。
オプションの型エラーや未定義オプションの参照があれば検出されるため、モジュールの変更時に既存の設定との矛盾を素早く確認できる。

## モジュールを使った設定

自作モジュールをインポートして有効化した設定を示す。
まず `darwin-configuration.nix` でnix-darwinモジュールを使う。

```nix
# hosts/my-mac/darwin-configuration.nix
{ inputs, ... }:
{
  imports = [ inputs.self.darwinModules.keyboard ];

  nixpkgs.hostPlatform = "aarch64-darwin";

  modules.keyboard = {
    enable = true;
    keyRepeat = 1;
    initialKeyRepeat = 10;
  };

  system.defaults.dock.autohide = true;
  system.defaults.dock.tilesize = 48;
  system.defaults.finder.AppleShowAllExtensions = true;

  system.stateVersion = 6;
}
```

次に `home-configuration.nix` でhome-managerモジュールを使う。

```nix
# hosts/my-mac/users/alice/home-configuration.nix
{ pkgs, inputs, ... }:
{
  imports = [
    inputs.self.homeModules.editor
    inputs.self.homeModules.development
  ];

  modules.editor = {
    enable = true;
    lsp.nix.enable = true;

  modules.development = {
    enable = true;
    node.enable = true;
    rust.enable = true;
    extraPackages = with pkgs; [
      kubectl
      terraform
      awscli2
    ];
  };

  programs.git = {
    enable = true;
    userName = "Alice";
    userEmail = "alice@example.com";
    extraConfig = {
      init.defaultBranch = "main";
      push.autoSetupRemote = true;
      pull.rebase = true;
    };
    ignores = [ ".DS_Store" ".direnv" ];
  };

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    shellAliases = {
      ll = "ls -la";
      g = "git";
      k = "kubectl";
    };
    initContent = ''
      bindkey -e
      setopt AUTO_CD
    '';
  };

  programs.starship.enable = true;
  programs.fzf.enable = true;

  services.syncthing.enable = true;

  home.stateVersion = "25.11";
}
```

元の設定と比較すると、以下の改善が得られた。

- **エディタ環境の抽象化**: Neovimの設定とLSPサーバーがモジュールに集約された。必要な言語のLSPだけを有効にできる
- **開発ツールの選択的有効化**: 言語ごとにオン・オフを切り替えられる
- **ホスト設定の簡素化**:「何を有効にするか」だけを記述し、具体的なパッケージやオプションはモジュールに委譲した

別のホストでは、同じモジュールを異なるオプションで使える。

```nix
# hosts/work-mac/users/alice/home-configuration.nix
{ inputs, ... }:
{
  imports = [
    inputs.self.homeModules.editor
    inputs.self.homeModules.development
  ];

  modules.editor = {
    enable = true;
    lsp.nix.enable = true;
  };

  modules.development = {
    enable = true;
    python.enable = true;  # 会社ではPythonを使う
  };

  # ...
  home.stateVersion = "25.11";
}
```

# ファイル分割とモジュール、どちらを選ぶか

2つのアプローチは排他的でなく、組み合わせて使える。
使い分けの指針を以下に示す。

| 状況                                             | 推奨アプローチ                                       |
| ------------------------------------------------ | ---------------------------------------------------- |
| 1つのホスト・ユーザーでのみ使う設定              | ファイル分割 (`imports`)                             |
| 複数ホストで共有するが、設定は同一               | ファイルを `modules/` に配置し、各ホストでインポート |
| 複数ホストで共有し、ホストごとにカスタマイズする | 自作モジュール (`options` + `mkIf`)                  |

モジュール化する際は、まずhome-managerやnix-darwinの既製モジュールで要件を満たせないか検討する。
既製モジュールが存在しない場合や、設定の共通化など既製モジュールだけでは要件を満たせない場合に自作モジュールを作成する。
自作モジュールでは既製モジュールのオプションをラップして抽象度を上げることも、1から設定を書くこともできる。

最初はファイル分割から始め、同じ設定を複数箇所にコピーしていることに気づいたらモジュール化を検討する。
過度な抽象化は設定の見通しを悪くするため、必要になるまでモジュール化しないという判断も重要である。

また、自作モジュールは独立したFlakeとして切り出し、他のユーザーに再配布できる。
Flakeの `inputs` に追加するだけで利用可能になるため、チーム内での設定共有や、汎用的なモジュールのOSS公開にも適している。

# まとめ

Nix設定のリファクタリングには、ファイル分割と自作モジュールの2つのアプローチがある。

1. **ファイル分割**: 設定を複数ファイルに分けて `imports` で読み込む。手軽だがカスタマイズ性は限定的
2. **自作モジュール**: `options` でインターフェースを宣言し、`mkIf` で条件付き設定を定義する。複数環境での再利用やカスタマイズが可能

blueprintでは `modules/` 配下にファイルを配置するだけでFlake outputsとして公開される。
各ホスト設定から `inputs.self.homeModules.<name>` 等でインポートし、`enable = true` で有効化する。

Nixのモジュールシステムは「宣言的な設定」を「再利用可能な部品」に昇華させる仕組みである。
ただし、自作モジュールにはメンテナンスコストが伴うため、既製モジュールで事足りるならそれが一番である。
モジュール化自体が目的にならないよう注意してほしい。
まずは動く設定を作り、重複や肥大化が目立ち始めたらリファクタリングすればよい。
