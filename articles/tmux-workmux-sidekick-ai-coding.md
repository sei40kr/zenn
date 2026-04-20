---
title: "Claude Code × 3並列を回すターミナル環境 ― tmux + workmux + sidekick.nvim"
emoji: "🤖"
type: "tech"
topics: ["tmux", "neovim", "ai", "claudecode", "workmux"]
published: true
---

AIエージェントによるコーディングが日常になり、同時に複数のエージェントを走らせて作業する機会も増えた。
しかし、エージェントごとにシェルを立ち上げてworktreeを切り、ブランチを管理し、エディタと行き来する作業は手数が多い。

本記事では、tmuxを軸に**workmux**と**sidekick.nvim**を組み合わせ、ターミナルだけで完結するAIコーディング環境を構築する手順を解説する。

# 設計方針

構築する環境の全体像を先に示す。

| 層                  | ツール                 | 役割                                                 |
| ------------------- | ---------------------- | ---------------------------------------------------- |
| リポジトリ検出      | tmux-project           | ローカルのリポジトリを自動検出してtmux sessionを作る |
| 利用状況の可視化    | tmux-agent-usage       | ClaudeやCodexのレート上限の使用率を表示する          |
| 並列作業の整備      | workmux                | worktree + tmux pane + AIエージェント起動を統合する  |
| エディタ連携        | Neovim + sidekick.nvim | エディタから行・範囲・ファイルをプロンプトとして送る |
| Hunkレベルのgit操作 | git-surgeon            | AIにhunk単位のstage/commit/分割を非対話で任せる      |
| ペイン間の移動      | vim-tmux-navigator     | Neovim splitとtmux pane間を同じキーで移動する        |
| フォーカス表示      | tmuxのpane-border      | どのペインにフォーカスしているかを枠線で明示する     |

# tmux-projectでリポジトリをsession単位に切り替える

拙作の[tmux-project](https://github.com/sei40kr/tmux-project)は、`prefix + g` でfzf-tmux popupを開くtmuxプラグインである。
設定したベースディレクトリ配下から検出したリポジトリの一覧をインクリメンタル検索できる。
選んだリポジトリに対応する専用のtmux session (そのリポジトリをcwdとする) が存在すればswitch、なければ新規作成する。

```tmux
# ~/.tmux.conf
set -g @plugin 'sei40kr/tmux-project'
```

`@project-base-dirs` にスキャン対象のディレクトリを登録すれば、配下のリポジトリは自動で候補に入る。
tmuxinatorのようにプロジェクトごとに定義ファイルを用意する必要はなく、**新しくリポジトリをcloneするたびに設定を追記しなくてよい**のが大きな利点である。

エントリは `<path>:<depth>` 形式で書く。
depthを省略すると、rooterの有無を問わずそのディレクトリ自身を常に候補に含める (例: `~/.dotfiles`)。

特に[ghq](https://github.com/x-motemen/ghq)との相性がよい。
ghqはリポジトリを `$(ghq root)/<host>/<owner>/<repo>` という一貫した構造にcloneするため、リポジトリは `GHQ_ROOT` から必ず3階層下に並ぶ。
`@project-base-dirs` のdepthに `3` を指定 (`${GHQ_ROOT}:3`) すれば、ghq管理下の全リポジトリが候補に揃う。

```tmux
# ~/.tmux.conf
set -g @project-base-dirs "${GHQ_ROOT}:3,${HOME}/.dotfiles"
set -g @project-rooters ".git,.hg,package.json,Cargo.toml,flake.nix"
```

`@project-rooters` に挙げたマーカーのどれかを含むディレクトリがリポジトリとして認識される。
作業が「1リポジトリ = 1 session」に揃うため、session名を見ればどのリポジトリで何をしているかが一意に決まる。

# tmux-agent-usageでレート上限の使用率を見える化する

ClaudeとCodexのサブスクリプションにはレート上限があり、これを超えると一定時間はリクエストを受け付けない。
作業が止まってから気づく事態を避けるため、[tmux-agent-usage](https://github.com/raine/tmux-agent-usage)を入れてtmuxのstatus barに使用率を常時表示する。

```tmux
set -g @agent-usage-providers "codex claude"
set -g @plugin 'raine/tmux-agent-usage'
```

プロバイダごとの使用率が色分けで並ぶ。
「あとどのくらい使えるか」が常に視界に入るため、重い作業の投入タイミングを判断しやすくなる。

# workmuxで並列作業を量産する

## add/openでworktreeと作業用tmux paneを一度に立ち上げる

[workmux](https://github.com/raine/workmux)はgit worktreeとtmux pane、AIエージェントの起動を1コマンドに束ねるツールである。
初回だけ `workmux setup` でステータス追跡用のhookとskillを入れておけば、あとは `add`/`open` で作業を生やす運用に乗せられる。

- `workmux add <branch>` — 新規のgit worktreeを作り、指定ブランチをチェックアウトし、設定したレイアウトとhookを適用したtmux paneを開く
- `workmux open <name>` — 既存worktreeに対して同じレイアウトのtmux paneを開き直す (既存paneがあればそこにswitch)

worktreeは既定でリポジトリの兄弟に `<project>__worktrees/` というディレクトリを作り、その配下に `<branch>/` として配置される。
親ディレクトリは設定 `worktree_dir` で変更可能。

筆者の常用パターンは以下の3つである。

```bash
# PRレビュー用にworktreeを切る
workmux add --pr 1234

# 新規ブランチで作業する。ブランチ名はLLMがプロンプトから自動生成
workmux add -A -p "Implement login flow with OAuth"

# 既存worktreeに戻る
workmux open login-flow
```

`--pr` はPR番号を与えるだけでbase、branch、worktreeを整えてくれるため、レビュー用のローカル再現が1コマンドで済む。
新規作業では `--auto-name` (`-A`) と `--prompt` (`-p`) の組み合わせが便利である。
プロンプトからLLMがブランチ名を生成し、その本文はエージェントの初期プロンプトとして投入される。
ブランチ名生成に使うモデルとsystem promptは `auto_name.model` / `auto_name.system_prompt` で差し替えられる。
`feat/*`・`fix/*` のprefixを強制したい、snake_caseを使いたい、といったプロジェクト固有の命名規則にも寄せられる。
頻出するコマンドはエイリアスにしておくと手数が減る。

```bash
alias wm='workmux'
alias wmaap='workmux add -Ap'
```

`wmaap` を定義しておけば、プロンプト1本で「ブランチ切り+worktree作成+エージェント起動」が起動する。

```bash
wmaap "Implement login flow with OAuth"
# -> workmux add -A -p "Implement login flow with OAuth"
```

## .workmux.yamlでペインレイアウトを宣言する

プロジェクト直下に `.workmux.yaml` を置くと、`add`/`open` したときに生成されるtmux paneのレイアウトをプロジェクトごとに宣言できる。
tmuxinatorでプロジェクトごとのtmux構成を宣言するのと同じ発想だが、工程がworktree生成と統合されている点が差分である。

```yaml
# .workmux.yaml
panes:
  - command: <agent>
    focus: true
  - split: horizontal
    command: clear
```

`<agent>` は設定したエージェントコマンド (例: `claude`) に展開される。
テスト用のwatcherやdevサーバー用のペインを追加してもよい。

`post_create` hookも宣言でき、worktree作成直後に任意のコマンドを走らせられる。
依存パッケージのインストール (`pnpm install` など) や `.env` の生成のような、新しいworktreeで毎回必要になる初期化コマンドを仕込んでおくとよい。
`add` 直後からエージェントがすぐ作業に入れる。

## sidebarを常駐させて並列作業を俯瞰する

並列で走るエージェントの状態を把握する手段として、workmuxは次の2つを提供する。

- `workmux dashboard` — 全sessionの全エージェントを一覧するフルスクリーンのTUI。diffレビューやエージェントへのコマンド送信ができ、キー1-9で目当てのエージェントのtmux paneへジャンプできる
- `workmux sidebar` — 全tmux windowの左端に常駐するtmux paneで、各エージェントの状態、project/worktree名、経過時間をライブ表示する

筆者のおすすめは**sidebarをtmuxに常駐させておく**運用である。

```bash
workmux sidebar  # 常駐paneをトグル
```

sidebarに並ぶアイコンを眺めるだけでどのエージェントが入力待ちになったかが視界の端で把握できる。
sidebar上で `j`/`k` でエントリを選び `Enter` を押すと、そのエージェントが走っているtmux paneに一発でジャンプできるため、入力待ちに気づいてから対応に移るまでの距離が短い。
腰を据えて全貌を見たいときは `workmux dashboard` のフルスクリーンTUIを開き、diffプレビューとあわせて確認するという使い分けが合っている。

## 同梱のClaude Code skillでエージェントに作業を委譲する

`workmux setup` は、ステータス追跡用のhookに加えてClaude Code向けのskillセットも `~/.claude/skills/` に配置する。
メインエージェントは、以下のskillを通じてworktree単位の下位エージェントへ作業を委譲できる。

- `/worktree` — 新しいworktreeを切って下位エージェントを起動し、タスクを委譲する
- `/coordinator` — メインエージェントを調整役として、複数のworktreeエージェントに並列でタスクを割り振る
- `/merge` — 完了したworktreeを `workmux merge` で本流に取り込む
- `/rebase` — worktreeをベースブランチに追従させる
- `/open-pr` — worktreeの変更をPRとして発行する

「メインブランチ側のエージェントがプランを立て、worktreeを切って下位エージェントに並列で実装させる」というコーディネーター型の運用が、会話内のslash commandだけで回る。

# Neovim + sidekick.nvimでエディタから文脈を送る

## tmux integrationを有効化する

[sidekick.nvim](https://github.com/folke/sidekick.nvim)は、Neovimから別ペインで走るAI CLIにプロンプトを送り込むためのプラグインである。
mux backendをtmuxに切り替えると、エージェントプロセスをNeovim split内のterminal modeではなく、外部のtmux paneとして管理できるようになる。

```lua
{
  "folke/sidekick.nvim",
  opts = {
    cli = {
      mux = {
        enabled = true,
        backend = "tmux",
      },
    },
  },
}
```

workmuxが立ち上げたエージェントペインと自然に接続でき、エディタとエージェントが別ペインで独立して動くという運用が実現する。

## 開いているファイルや選択範囲をプロンプトに載せる

sidekick.nvimの最大の旨味は、エディタのコンテキストをそのままプロンプトに埋め込めることである。

- `{file}` — 現在のバッファ
- `{line}` — カーソル行
- `{selection}` — ビジュアル選択範囲
- `{function}` / `{class}` — Treesitterで検出した関数やクラス
- `{diagnostics}` — LSPの診断結果

これらを含んだ事前定義プロンプトもデフォルトで用意されている。

```lua
prompts = {
  explain  = "Explain {this}",
  fix      = "Can you fix {this}?",
  tests    = "Can you write tests for {this}?",
  review   = "Can you review {file} for any issues or improvements?",
  refactor = "Please refactor {this} to be more maintainable",
}
```

ビジュアルモードで範囲を選び、`<leader>ap` でプロンプトピッカーを開き、`refactor` を選択するだけで、選択範囲がプロンプトに埋め込まれてエージェントに送信される。
特に**AIが書いたコードを自分でレビューするとき**に効く。
該当の関数や行を選択して「ここの分岐は本当に必要か」「この条件は逆ではないか」といった指摘を引用付きで投げられるため、エディタ上でコードを読む流れを崩さずに議論を継続できる。
「このブロックをテストしたい」「この関数を説明してほしい」といった日常の問い合わせも、コピペなしで完結する。

# git-surgeonでhunk単位のgit操作をAIに任せる

AIにまとまった作業を振ると、しばしば複数の関心事が1つのdiffに混ざる。
これを人間がstageで切り分けるのは手数が多く、AIに `git add -p` を直接叩かせるのも対話が成立しづらい。

[git-surgeon](https://github.com/raine/git-surgeon)はhunkにIDを振り、非対話で指定のhunkをstage/unstage/discard、あるいはfixup/squash/splitできる補助ツールである。
git-surgeon本体に加えて、Claude Code向けのskill (`~/.claude/skills/git-surgeon/`) も同梱されている。
CLIの使い方が `SKILL.md` にまとまっており、エージェントが自然にhunk IDを引いてstage/commit/分割を実行できる。

AIエージェントに「ロジックの変更だけをstageし、ログ追加は別コミットに回せ」といった指示が可能になり、AIがコミット分割を主導できるようになる。

「まとめて作業してからコミットを分ける」というワークフローを崩さずに、AIの提案した変更を論理単位で切り出せる。

# vim-tmux-navigatorでpane間を同じキーで渡り歩く

Neovim splitとtmuxペインの移動が別キーなのは思考が途切れるし、tmuxのデフォルトのpane移動 (`<prefix>` + `h/j/k/l` など) が2ストローク必要なのも煩わしい。
[vim-tmux-navigator](https://github.com/christoomey/vim-tmux-navigator)は両者をまとめて扱い、同じ1ストロークのキーでNeovim splitとtmux paneの境界をまたいで移動できるようにする。

デフォルトのキーバインドは `C-h/j/k/l` だが、多くのshellは `C-h` をbackspaceに割り当てているため入力と衝突する。
筆者は `Alt-h/j/k/l` にリマップしている。

```vim
" init.vim 側
let g:tmux_navigator_no_mappings = 1
nnoremap <silent> <M-h> :TmuxNavigateLeft<CR>
nnoremap <silent> <M-j> :TmuxNavigateDown<CR>
nnoremap <silent> <M-k> :TmuxNavigateUp<CR>
nnoremap <silent> <M-l> :TmuxNavigateRight<CR>
```

Luaで設定する場合は以下のようになる。

```lua
-- init.lua 側
vim.g.tmux_navigator_no_mappings = 1
local opts = { silent = true }
vim.keymap.set("n", "<M-h>", "<Cmd>TmuxNavigateLeft<CR>", opts)
vim.keymap.set("n", "<M-j>", "<Cmd>TmuxNavigateDown<CR>", opts)
vim.keymap.set("n", "<M-k>", "<Cmd>TmuxNavigateUp<CR>", opts)
vim.keymap.set("n", "<M-l>", "<Cmd>TmuxNavigateRight<CR>", opts)
```

tmux側も同じキーに合わせる。
下記は[vim-tmux-navigatorのREADME](https://github.com/christoomey/vim-tmux-navigator#add-a-snippet)にある推奨スニペットをAlt系に書き換えたものである。

```tmux
# ~/.tmux.conf
is_vim="ps -o state= -o comm= -t '#{pane_tty}' \
    | grep -iqE '^[^TXZ ]+ +(\\S+\\/)?g?(view|l?n?vim?x?|fzf)(diff)?$'"

bind-key -n M-h if-shell "$is_vim" "send-keys M-h" "select-pane -L"
bind-key -n M-j if-shell "$is_vim" "send-keys M-j" "select-pane -D"
bind-key -n M-k if-shell "$is_vim" "send-keys M-k" "select-pane -U"
bind-key -n M-l if-shell "$is_vim" "send-keys M-l" "select-pane -R"
```

Neovim内のsplit、workmuxが作ったエージェントペイン、汎用シェルペインの三者を、同じ `Alt-h/j/k/l` で行き来できる。
「エディタで書いて、エージェントにプロンプトを送り、隣のシェルで `git status` を覗く」という流れがキー4〜5打で回る。

# pane-borderでフォーカスを視覚化する

複数ペインを高速に渡り歩くと、「今どのペインに居るのか」が時々わからなくなる。
tmuxのpane-borderに色とラベルを付けてフォーカスを可視化しておく。

```tmux
# ~/.tmux.conf
set -g pane-border-format ' #{?pane_active,#[fg=#7aa2f7#,bold],#[fg=#565f89]}#{pane_index}: (#{pane_current_command})#{?pane_title, #{pane_title},} '
set -g pane-border-indicators off
set -g pane-border-status top
```

ペイン上部にindexと起動中のコマンド名が並び、アクティブペインだけハイライトされる。
キー移動のあとにわずかに視線を上げるだけで現在位置と各ペインの役割を同時に把握できる。

# 補足: cmuxを採用しなかった理由

AIエージェントを束ねるGUIツールとしては[cmux](https://github.com/manaflow-ai/cmux)がメジャーだが、今回の構成では採用しなかった。
理由は2つある。
1つ目は、マウス操作を前提とするUIがキー入力だけで済ませたい筆者の好みと合わないこと。
2つ目は、現時点でLinux版が提供されていないため、NixOSを常用する筆者にとって仕事と私物で操作感が割れてしまうことである。

# まとめ

本記事では、tmuxを中心に据えたターミナル完結のAIコーディング環境を組み上げる手順を示した。

1. **リポジトリ切り替え**: tmux-projectで `prefix + g` からリポジトリをfuzzy検索し、「1リポジトリ = 1 session」で切り替える
2. **レート上限の可視化**: tmux-agent-usageでClaudeとCodexの使用率をtmuxのstatus barに常時表示する
3. **並列作業**: workmuxの `add`/`open` でworktree + pane + エージェントの起動を1コマンドに束ね、sidebarを常駐させて入力待ちのエージェントを俯瞰する
4. **エディタ連携**: sidekick.nvimのtmux integrationで、開いているバッファや選択範囲をそのままエージェントへのプロンプトに載せる
5. **コミット整理**: git-surgeonでhunk単位のstage/commit/分割をAIに委譲する
6. **ペイン移動**: vim-tmux-navigator + Alt-h/j/k/lへのリマップで、Neovim splitとtmux paneを同じ1ストロークでまたぐ
7. **フォーカス表示**: pane-borderに色とラベルを付けて現在位置を視覚化する

AIエージェント向けの専用GUI環境を入れずとも、既存のtmux + Neovimの上に薄く道具を積み重ねるだけで、並列のAIコーディングは十分に回せる。
キーボード中心の操作を守りたい人、複数環境で同じ操作感を維持したい人にとって、この構成は自然な選択肢になるはずだ。
