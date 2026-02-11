---
title: "dotfiles管理に限界を感じたらNixOSとblueprintを試してほしい"
emoji: "❄️"
type: "tech"
topics: ["nix", "nixos", "flakes", "blueprint"]
published: true
---

開発環境のセットアップを自動化するためにdotfilesリポジトリを運用している人は多い。
しかし、最大の課題はinstallerではないだろうか。
brewやaptでパッケージを入れ、シンボリックリンクを張り、シェルの設定を反映する——このセットアップスクリプトはマシンを移行するたびに壊れがちである。
OSやアーキテクチャの違い、パッケージマネージャのバージョン差異、実行順序の依存関係。
冪等性を保つためのガード処理を書き続けるうちに、installer自体が保守対象になっていく。

NixOSは宣言的なシステム構成管理と再現性の高いビルドシステムを特徴とするLinuxディストリビューションである。
dotfilesの「設定ファイルを配置する」アプローチとは異なり、パッケージとその設定を一体として宣言的に管理できる。
本記事では、Nixエコシステムの概要を解説した上で、入門者にnumtide/blueprintを強くおすすめする理由を述べる。

# Nixエコシステムの全体像

NixOSを理解するには、まずNixエコシステムを構成する複数のコンポーネントを把握する必要がある。

## Nix

**[Nix](https://nixos.wiki/wiki/Nix_package_manager)** は純粋関数型パッケージマネージャである。
意外と知られていないが、 **NixパッケージマネージャはmacOSでも動作する。**
NixOSとは独立したツールであり、Homebrewと共存しながら既存の環境を壊すことなく導入できる。
従来のパッケージマネージャ (APT、Homebrewなど) と異なり、以下の特徴を持つ。

- **純粋性 (purity)**: パッケージのビルドは入力のみに依存し、同じ入力からは常に同じ出力が得られる
- **再現性 (reproducibility)**: 異なるマシンでも同一のビルド結果を再現できる
- **隔離性 (isolation)**: 各パッケージは独立したパスにインストールされ、依存関係の衝突が発生しない

Nixではすべてのパッケージが `/nix/store` 配下に、ハッシュ値を含むパスで格納される。

```
/nix/store/b6gvzjyb2pg0kjfwrjmg1vfhh54ad73z-firefox-133.0/
```

このハッシュ値はパッケージのビルドに使用されたすべての入力 (ソースコード、依存パッケージ、ビルドスクリプトなど) から計算される。
入力が1ビットでも変われば異なるハッシュ値となり、異なるパスに格納される。
これにより、複数バージョンの共存や完全なロールバックが可能になる。

## Nix言語

Nixパッケージマネージャは専用の **Nix言語** を使用する。
Nix言語は遅延評価を行う純粋な関数型言語であり、パッケージの定義やシステム構成の記述に使用される。

```nix
# 遅延評価の例: unusedは実際には評価されない
let
  unused = throw "この式は評価されない";
  used = "Hello, world!";
in
  used  # => "Hello, world!"
```

Nix言語の特徴的な点は、副作用を持たない純粋な式 (expression) のみで構成されることである。
変数の再代入や、言語レベルでの状態変更といった命令的な操作は存在しない。

## Nixpkgs

**[Nixpkgs](https://github.com/NixOS/nixpkgs)** はNixパッケージの公式リポジトリである。
LinuxおよびmacOS向けのパッケージが含まれており、GitHub上で活発にメンテナンスされている。

Nixpkgsは単なるパッケージ集ではなく、`lib` (ユーティリティ関数群)、`stdenv` (標準ビルド環境)、NixOSモジュールシステムなども提供する。

## NixOS

**[NixOS](https://nixos.org/)** はNixパッケージマネージャを基盤としたLinuxディストリビューションである。
システム全体 (カーネル、サービス、ユーザー設定など) を単一の設定ファイルで宣言的に記述できる。

```nix
# /etc/nixos/configuration.nix の例
{ pkgs, ... }:
{
  boot.loader.grub.enable = true;

  networking.hostName = "my-server";

  services.nginx.enable = true;

  users.users.alice = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  };

  environment.systemPackages = [
    pkgs.vim
    pkgs.git
  ];

  system.stateVersion = "24.11";
}
```

この設定ファイルを `nixos-rebuild switch` コマンドで適用すると、システムが宣言した状態に収束する。
内部的には、ビルドされたシステム設定全体が1つのパッケージとして `/nix/store` に格納される。
通常のパッケージと同じ仕組みでハッシュ管理され、同一の入力からは常に同一の結果が得られる。
従来のLinuxディストリビューションのように手動でパッケージをインストールし、設定ファイルを編集し、サービスを起動するという手順は不要である。

NixOSモジュールシステムが管理するのは `/etc` 以下のシステム設定やsystemdサービスなどである。
ユーザーのホームディレクトリ内の設定ファイル (dotファイルなど) は管理対象外となる。

### アトミックなアップグレードとロールバック

NixOSのもう1つの大きな特徴は **アトミックなアップグレードとロールバック** である。
システムの各世代 (generation) が `/nix/store` で保持されており、問題発生時は以前の世代へ即座に戻れる。
設定変更でシステムが起動不能になった場合でも、boot loaderのメニューから過去の世代を選んで起動できる。

重要な点として、この世代 (generation) 自体も `/nix/store` 内の1つのパッケージとして管理される。
世代はシステム全体の設定やパッケージへの参照をまとめたものであり、他のパッケージと同様にハッシュで識別される。

### activation script

NixOSでは、システム設定を適用する際に **activation script** が実行される。
これはシステムの状態を宣言された構成に収束させるためのスクリプトであり、generationパッケージ内の `activate` というパスに配置されている。

activation scriptは以下のような処理を行う。

- `/etc` 以下の設定ファイルの配置
- systemdサービスの有効化・再起動
- ユーザーやグループの作成
- ファイルシステムのパーミッション設定

純粋なNixビルドでは実現できない副作用を伴う操作を、activation scriptが担当する。

## nix-darwin

**[nix-darwin](https://github.com/nix-darwin/nix-darwin)** はmacOS向けのNixOS相当のツールである。
NixOSと同様の宣言的な構文でmacOSのシステム設定やパッケージを管理できる。

```nix
{ pkgs, ... }:
{
  environment.systemPackages = [
    pkgs.vim
  ];

  # macOS固有の設定
  system.defaults.dock.autohide = true;

  services.nix-daemon.enable = true;
}
```

注意点として、nix-darwinのモジュールはnix-darwin独自に実装されており、NixOSモジュールをそのまま使うことはできない。
たとえば `services.nginx` のようなNixOS固有のモジュールはnix-darwinには存在しない。
両者はモジュールシステムの仕組みは共通しているが、利用できるモジュールは別々に提供されている。

## home-manager

**[home-manager](https://github.com/nix-community/home-manager)** はユーザーのホームディレクトリ環境をNixで宣言的に管理するツールである。
NixOSモジュールが `/etc` 以下のシステム設定を管理するのに対し、home-managerは `~/.config` や `~/.bashrc` などユーザーディレクトリ内のファイルを管理する。

```nix
{ pkgs, ... }:
{
  home.username = "alice";
  home.homeDirectory = "/home/alice";

  # NixOSにも programs.git があるが、そちらは /etc/gitconfig に設定を生成する
  # home-managerの programs.git は ~/.config/git/config に設定を生成する
  programs.git = {
    enable = true;
    userName = "Alice";
    userEmail = "alice@example.com";
  };

  programs.zsh = {
    enable = true;
    shellAliases = {
      ll = "ls -la";
    };
  };

  home.packages = [
    pkgs.ripgrep
    pkgs.fd
  ];

  home.stateVersion = "24.11";
}
```

home-managerはNixOSだけでなく、他のLinuxディストリビューションやmacOSでも使用できる。
これにより、異なるOS間でも統一されたユーザー環境を維持できる。

home-managerも独自のactivation scriptを持ち、ホームディレクトリ内の設定ファイルのシンボリックリンク作成やサービスの起動を担う。

home-managerとnix-darwinを組み合わせることで、macOS環境でもNixOSに近い宣言的なシステム管理が可能になる。

## dotfiles管理との違い

ここまでの内容を踏まえて、従来のdotfiles管理との違いを整理する。

|                | dotfiles (stow, chezmoi等)       | Nix (NixOS + home-manager)     |
| -------------- | -------------------------------- | ------------------------------ |
| 管理対象       | 設定ファイルのみ                 | パッケージと設定ファイルの両方 |
| パッケージ導入 | brew/aptなど別途手動管理         | Nix式で宣言的に管理            |
| 再現性         | シェルスクリプト依存、壊れやすい | ロックファイルで完全に固定     |
| ロールバック   | git revertで手動対応             | 世代管理で即座に切り戻し可能   |
| 複数OS対応     | OS分岐のシェルスクリプトが必要   | 単一の設定で条件分岐可能       |

dotfilesリポジトリは手軽に始められる反面、規模が大きくなるとシェルスクリプトの保守が負担になりがちである。
Nixはこの問題を根本から解決するが、その分学習コストがかかる。
この学習コストを下げるのが、後述するblueprintである。

# Nix Flakes: 標準化されたプロジェクト構造

ここまでNixエコシステムの構成要素を紹介してきた。
しかし、これらを実際に組み合わせてプロジェクトを構成するには、もう1つ重要な仕組みがある。

## 従来の `configuration.nix` の課題

NixOSをインストールすると、システム設定は `/etc/nixos/configuration.nix` に配置される。
このファイルを編集して `nixos-rebuild switch` を実行するのが従来のワークフローである。

しかし、この方式にはいくつかの課題がある。

- **依存関係のバージョン固定がない**: `<nixpkgs>` で参照されるNixpkgsのバージョンはシステムのチャンネルに依存し、再現性が保証されない
- **複数マシンの設定を一元管理できない**: 設定を別のマシンに移植する際、Nixpkgsのバージョン差異で動作が変わりうる

dotfilesの観点で言えば、これは `install.sh` の中でバージョン指定なしに `brew install` するのと同じ問題である。

## Flakesによる解決

**[Nix Flakes](https://wiki.nixos.org/wiki/Flakes)** はNixプロジェクトの入出力を標準化する仕組みである。

:::message
Flakesは2026年現在もexperimental機能である。
使用するには `nix.conf` に `experimental-features = nix-flakes nix-command` の設定が必要である。
NixOSでは `nix.settings.experimental-features` オプションで設定できる。

<!-- textlint-disable ja-technical-writing/ja-no-mixed-period -->

:::

<!-- textlint-enable -->

Flakeは `flake.nix` ファイルで定義され、以下の要素を持つ。

- **inputs**: 依存する他のFlake (Nixpkgs、home-managerなど)
- **outputs**: このFlakeが提供するもの (パッケージ、NixOS設定、開発シェルなど)

```nix
{
  description = "My NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, home-manager, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.alice = import ./home.nix;
        }
      ];
    };
  };
}
```

Flakesにより依存関係が `flake.lock` ファイルでロックされ、完全な再現性が保証される。

### Flake化のメリット

従来の `configuration.nix` からFlakeに移行することで、以下のメリットが得られる。

- **完全な再現性**: すべての依存関係がロックファイルで固定され、どのマシンでも同一の結果が得られる。dotfilesにおける `Brewfile.lock.json` に近いが、パッケージだけでなくシステム設定全体が対象になる
- **サードパーティFlakeの容易な導入**: inputsに追加するだけで外部のFlakeを依存関係として取り込める
- **複数マシンの一元管理**: 1つのFlakeで複数ホストの設定を定義できる。会社のMacBookと自宅のNixOSを同じFlakeで管理する、といった運用が自然にできる

:::message
Flakeは `git add` されていないファイルを存在しないものとして扱う。
新しいファイルを作成した場合は、Flakeコマンドを実行する前に `git add` が必要である。

<!-- textlint-disable ja-technical-writing/ja-no-mixed-period -->

:::

<!-- textlint-enable -->

## Flakeの残る課題: boilerplateの増大

FlakesはNixプロジェクトの標準化という点で大きな進歩であるが、実際に使い始めると **boilerplateコードの多さ** に気づく。

典型的なNixOS + home-manager + nix-darwinの構成では、以下のような課題が生じる。

### モジュールの手動import

Flakeには別ファイルに定義されたモジュールやパッケージを自動的に検知する仕組みがない。
ファイルを追加するたびに手動で `import` を書くか、検知の仕組みを自前で実装する必要がある。

### NixOS/nix-darwinとhome-managerの統合

NixOS (またはnix-darwin) とhome-managerを連携させるには、home-managerモジュールを明示的にインポートし、オプションを設定する必要がある。

```nix
# flake.nix内でhome-managerを統合する例
modules = [
  ./configuration.nix
  home-manager.nixosModules.home-manager
  {
    home-manager.useGlobalPkgs = true;
    home-manager.useUserPackages = true;
    home-manager.users.alice = import ./home.nix;
  }
];
```

この統合コードをホストごとに書く必要があり、設定が冗長になりやすい。
あるいは、NixOSとhome-managerを別々に適用するワークフローを取ることになる。

### モジュールの共有と再利用

NixOSとnix-darwinでモジュールを共有したい場合や、複数ユーザー間でhome-manager設定を共有したい場合、適切な構造を自分で設計する必要がある。

### 学習コストの高さ

入門者がこれらの構造を一から理解し、適切に設計するのは困難である。
ネット上のサンプルを見ても、それぞれが独自のアプローチを採用しており、どれがベストプラクティスなのか判断しづらい。

# blueprint: フォルダ構造からの自動マッピング

**[blueprint](https://github.com/numtide/blueprint)** はNixプロジェクトの構造を標準化するライブラリである。
フォルダ構造からFlakeのoutputsを自動生成することで、boilerplateを99%削減する。

blueprintを使った `flake.nix` は驚くほどシンプルになる。

```nix
{
  description = "Sharing home-manager modules between nixos and darwin";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-unstable";

    blueprint.url = "github:numtide/blueprint";
    blueprint.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nix-darwin.url = "github:nix-darwin/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs: inputs.blueprint { inherit inputs; };
}
```

**たったこれだけである。**
outputsの定義は1行で完結する。
あとはフォルダ構造に従ってファイルを配置するだけで、blueprintが自動的にFlake outputsを生成する。

## なぜblueprintがおすすめなのか

- **ベストプラクティスの内包**: blueprintのフォルダ構造は、Nixコミュニティで長年培われてきたベストプラクティスを反映している。入門者が自分で設計を考える必要がない
- **boilerplateの削減**: Flakeを使い始めると、多くの人がモジュールの自動検出や統合の仕組みを自前で実装することになる。blueprintはこのフレームワーク部分を提供し、車輪の再発明を不要にする
- **マルチプラットフォーム対応**: NixOS、nix-darwin、home-manager、[system-manager](https://github.com/numtide/system-manager)をシームレスに統合できる。NixOSサーバーとMacBookを同じリポジトリで管理できる

## home-managerの自動統合

blueprintの大きな利点の1つは、 **home-manager設定がNixOS/nix-darwin設定に自動的に統合される** ことである。

`hosts/<hostname>/users/<user>/home-configuration.nix` にユーザー設定を配置するだけでよい。
blueprintが自動的にhome-managerモジュールをホスト設定に組み込む。
これにより、`nixos-rebuild switch` を1回実行するだけで、システム設定とユーザー設定の両方が適用される。

従来の手動設定では、NixOSとhome-managerを別々に設定を適用するか、`flake.nix` でhome-managerモジュールを明示的にインポートする必要があった。
blueprintではこの統合がフォルダ構造だけで自動的に行われる。

## 実践例: NixOSとmacOSで設定を共有する

blueprintのテンプレート `nixos-and-darwin-shared-homes` を使った構成例を見てみよう。

```
.
├── flake.nix
├── hosts
│   ├── my-darwin
│   │   ├── darwin-configuration.nix
│   │   └── users
│   │       └── me
│   │           └── home-configuration.nix
│   └── my-nixos
│       ├── configuration.nix
│       └── users
│           └── me
│               └── home-configuration.nix
└── modules
    ├── home
    │   └── home-shared.nix
    └── nixos
        └── host-shared.nix
```

### 共有されるNixOS/nix-darwinモジュール

`modules/nixos/host-shared.nix` はNixOSとnix-darwinの両方で使用できる共有モジュールである。

```nix
{ pkgs, ... }:
{
  programs.vim.enable = true;

  environment.systemPackages = [
    pkgs.btop
  ] ++ (pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.xbar ]);
}
```

`pkgs.stdenv.isDarwin` や `pkgs.stdenv.isLinux` を使ってOS固有の設定を分岐できる。

### 共有されるhome-managerモジュール

`modules/home/home-shared.nix` は複数ユーザー/複数ホスト間で共有できるhome-manager設定である。

```nix
{ pkgs, osConfig, ... }:
{
  services.ssh-agent.enable = pkgs.stdenv.isLinux;

  home.packages =
    [ pkgs.ripgrep ]
    ++ (
      pkgs.lib.optionals (osConfig.programs.vim.enable && pkgs.stdenv.isDarwin) [ pkgs.skhd ]
    );

  home.stateVersion = "24.11";
}
```

`osConfig` を通じてホストのNixOS/nix-darwin設定にアクセスできる点が特徴的である。

### ホスト固有の設定

各ホストの設定ファイルでは、共有モジュールをimportしつつ、ホスト固有の設定を追加する。

```nix
# hosts/my-nixos/configuration.nix
{ pkgs, inputs, ... }:
{
  imports = [ inputs.self.nixosModules.host-shared ];

  nixpkgs.hostPlatform = "x86_64-linux";

  boot.loader.systemd-boot.enable = true;

  networking.hostName = "my-nixos";

  time.timeZone = "Asia/Tokyo";

  users.users.me.isNormalUser = true;

  system.stateVersion = "25.11";
}
```

```nix
# hosts/my-darwin/darwin-configuration.nix
{ pkgs, inputs, ... }:
{
  imports = [ inputs.self.nixosModules.host-shared ];

  nixpkgs.hostPlatform = "aarch64-darwin";

  time.timeZone = "Asia/Tokyo";

  system.stateVersion = 6;
}
```

`inputs.self.nixosModules.host-shared` のように、blueprintが自動生成したoutputsを参照できる。

# blueprintを始める

```bash
# 新しいプロジェクトを作成
mkdir my-nixos-config && cd my-nixos-config

# blueprintテンプレートで初期化
nix flake init -t github:numtide/blueprint#nixos-and-darwin-shared-homes

# Gitリポジトリを初期化し、ファイルを追跡
git init
git add .

# 構造を確認
tree
```

設定を適用するには、以下のコマンドを実行する。

```bash
# NixOSの場合
sudo nixos-rebuild switch --flake .#<hostname>

# nix-darwinの場合
darwin-rebuild switch --flake .#<hostname>
```

# まとめ

dotfilesリポジトリの保守に疲弊しているなら、Nixへの移行は検討に値する。
パッケージと設定を一体で管理でき、ロックファイルによる完全な再現性が得られる。

一方で、NixOSの学習曲線は急峻であり、Flakesのboilerplateの多さが入門の壁となっていた。
blueprintはフォルダ構造からの自動マッピングにより、この問題を解決する。
複雑なNixの内部構造を理解する前に、まず動くシステムを構築できる。
理解が深まるにつれて、徐々に高度な設定へ移行していけばよい。

dotfilesの次のステップとして、blueprintから始めてみてほしい。

---

**参考リンク**

- [numtide/blueprint (GitHub)](https://github.com/numtide/blueprint)
- [NixOS公式サイト](https://nixos.org/)
- [nix.dev (公式学習リソース)](https://nix.dev/)
