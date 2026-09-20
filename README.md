# Luna Primary Engineer

日本語 | [English](README.en.md)

Codex Desktop / CLI向けのソフトウェア開発ワークフローです。GPT-5.6 Lunaを主担当にして、調査・実装・テストまで進めます。必要なときだけ、Claude CodeのOpusに変更を読み取り専用でレビューさせます。

## こんな人に向いています

- Codexに調査から実装、テストまで一貫して任せたい
- 実装を別モデルの視点でも確認したい
- Claudeが使えないときも、Codex内でレビューを続けたい
- 不要な抽象化や依存を増やさず、変更をシンプルに保ちたい

## 開発の背景

この構成は、Codexを主な開発環境として使いながら、手元のClaude Team（Standard）も活用したいという実際の事情から始まりました。Codex Plusの利用枠は実装に集中させたかったのですが、Lunaで実装した内容のレビューをCodex内でTerraやSolに回すと、レビューだけでも5時間単位の利用枠を大きく消費します。

そこで、調査・実装・テスト・統合はCodexのLunaに任せ、必要なときだけClaude CodeのOpusを独立した読み取り専用レビュアーとして使う構成にしました。Codexを中心に据えたまま、別モデルの視点も取り入れるのが、このワークフローの出発点です。

## セットアップ

### 必要なもの

- Codex DesktopまたはCodex CLI
- Bash
- Git（実装をシンプルに保つ補助スキルPonytailを自動取得する場合）
- Claude Codeと有効な認証（Opusレビューを使う場合のみ）

Claude Codeは任意です。Claudeがなくても、Codex内のフォールバックレビュアーを使えます。

### インストール

```bash
git clone https://github.com/k3komatsu/luna-primary-engineer-with-opus-review.git
cd luna-primary-engineer-with-opus-review
bash scripts/install.sh
```

インストーラーは、Codexが読み込むスキルと関連エージェントをユーザー領域に配置します。既存の同名スキルは置き換えられます。Ponytailは既定で[GitHubのリポジトリ](https://github.com/DietrichGebert/ponytail)から取得します。

既にPonytailをローカルに用意している場合は、次のように指定できます。

```bash
LUNA_PRIMARY_ENGINEER_PONYTAIL_SOURCE=/path/to/ponytail bash scripts/install.sh
```

`CODEX_HOME`を設定している場合は、関連エージェントとPonytailの配置先にその値が使われます。

インストール後、Codex Desktopは再起動し、Codex CLIは新しいセッションを開始してください。その後、セッションで次を入力します。

```text
$luna-primary-engineer
```

Codexの設定は、GPT-5.6 Luna / Reasoning: Max / Service tier: Fastを推奨します。

### 更新

```bash
git pull --ff-only origin master
bash scripts/install.sh
```

更新後も、Codex Desktopでは再起動、Codex CLIでは新しいセッションの開始が必要です。

## 仕組み

普段の作業はCodexのLunaが担当します。大きな変更や判断が難しい変更では、Claude CodeのOpusを追加のレビュアーとして使えます。

```text
依頼
 ↓
Codex / Luna
 ├─ 調査・計画・実装・テスト
 └─ 必要に応じてClaude Code / Opusのレビュー
```

Ponytailは、必要な変更だけに集中し、不要な抽象化や依存を増やさないための補助スキルです。

## Opusによるレビュー

実装に別モデルの意見が欲しいとき、Claude CodeのOpusが変更を読み取り専用でレビューします。実装の見落としや設計上の懸念を、Lunaとは別の視点から確認するための機能です。

通常はCodexセッションで「この変更をOpusにもレビューさせて」と依頼するだけで使えます。Claude Codeをレビュー開始前に利用できない場合は、Codex内のフォールバックレビュアーを使えます。Opusのレビュー開始後は、結果が返るまで別のレビュアーへ自動で切り替えません。

修正後は、指摘の重要度・修正範囲・回帰リスクを評価します。いずれかが高ければ、追加のユーザー確認なしに初回レビューのOpusセッションを続けて再レビューします。3項目すべてが低ければ再レビューを省略し、Lunaが実行した確認と省略理由を報告します。ネットワーク障害、結果不備、プロセス消失などの技術的な再実行には、引き続きユーザー確認が必要です。

レビューには数分かかることがあります。ClaudeのAPI・ストリーム待機時間は既定で10分です。レビュー結果はClaudeのstdoutではなく、指定した結果ファイルを検証して採用します。stdout/stderrは診断用に別保存されるため、stdoutが空でも完全な結果ファイルがあれば成功します。レビュー状態はリポジトリ内の`tmp/luna-primary-engineer/reviews/`に保存されます。

レビューパケットは従来どおり単一ファイルで渡せます。レビュープロンプトも状態に残したい場合は、`review-packet.md`と任意の`review-prompt.md`を含む入力ディレクトリを渡します。スクリプトが両方を空の状態ディレクトリへコピーするため、状態ディレクトリを先に作ってプロンプトを置く必要はありません。既存の状態データを守るため、事前に内容がある状態ディレクトリは引き続き拒否されます。入力バンドルの2ファイルは空でない通常ファイルにし、シンボリックリンクは使用しません。

通常の`start`と`resume`は完了まで待つ同期実行です。待機を呼び出し側から切り離す必要がある場合だけ、`start-background`または`resume-background`を使い、`status`で同じ状態を確認します。一度起動したOpusプロセスは停止しません。runnerとClaudeのPIDが両方消え、結果もない場合、`status`はユーザー確認が必要な失敗として報告し、自動再実行しません。`RUNNER_ALIVE`または`CLAUDE_ALIVE`が`unknown`の場合は、sandboxに`ps`を拒否されています。実行権限を昇格して`status`を再実行します。詳細は[Claude連携のリファレンス](references/claude-integration.md)を参照してください。

## 困ったとき

### スキルが読み込まれない

Codex Desktopを完全に再起動するか、Codex CLIで新しいセッションを開始してから、`$luna-primary-engineer`を実行してください。

### Claudeが使えない

Claude Codeがインストール済みか、認証できる状態かを確認します。

```bash
command -v claude
claude auth status
claude doctor
```

Claudeを使わずにCodex内のフォールバックレビュアーを使う場合は、次を設定します。

```bash
export LUNA_PRIMARY_ENGINEER_CLAUDE=off
```

`ANTHROPIC_API_KEY`が設定されている場合、Claude CodeがAPI課金の認証経路を使う可能性があります。意図した認証方法か確認してください。

### `Request timed out` でレビューが止まる

`claude auth status` が成功しても、CodexのsandboxからAnthropic APIへ接続できるとは限りません。実際のOpusレビューでは、コマンドをネットワーク利用可能な実行へ権限昇格する許可が必要になることがあります。必要な場合はレビュー開始前に許可を取得します。レビュー state が `stage=blocked`、`blocked_reason=network` になった場合は、利用者が再試行を明示的に許可したうえで、ネットワーク利用可能なコマンド実行環境から同じ state を再試行します。

```bash
bash scripts/claude-review.sh retry STATE_DIR
```

対話型TTYやClaude daemonへ切り替えても、実行環境のネットワーク制限は解決しません。
