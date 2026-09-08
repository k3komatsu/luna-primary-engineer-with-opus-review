# Luna Primary Engineer

日本語 | [English](README.en.md)

Codex Desktop / CLI向けのソフトウェア開発ワークフローです。GPT-5.6 Lunaを主担当にし、必要なときだけClaude CodeのOpusを読み取り専用レビューとして使います。

## こんな人に向いています

- Codexに調査、実装、テストまで一貫して任せたい
- 大きな変更を、別モデルの視点でも確認したい
- Claudeが使えないときも、Codex内でレビューを続けたい
- 不要な抽象化や依存を増やさず、変更範囲を絞りたい

## セットアップ

### 必要なもの

- Codex DesktopまたはCodex CLI
- Bash
- Ponytailをダウンロードする場合はGit
- Opusレビューを使う場合はClaude Codeと有効な認証

Claude Codeは任意です。Claudeがなくても、Codex内の`luna_reviewer`を使えます。

### インストール

```bash
git clone https://github.com/k3komatsu/luna-primary-engineer-with-opus-review.git
cd luna-primary-engineer-with-opus-review
bash scripts/install.sh
```

既にチェックアウト済みなら、そのディレクトリで`bash scripts/install.sh`を実行してください。

インストーラーは次の場所を更新します。

| 対象 | 既定の場所 | 内容 |
|---|---|---|
| スキル | `~/.agents/skills/luna-primary-engineer` | Codexが読み込むスキルとヘルパー |
| カスタムエージェント | `$CODEX_HOME/agents`（通常は`~/.codex/agents`） | `luna_worker`、`luna_reviewer`、`sol_advisor`、`astra_expert` |
| Ponytail | `$CODEX_HOME/luna-primary-engineer/deps/ponytail` | 実装Workerが使う補助スキル |

同名の既存スキルは、チェックアウト内の内容で置き換えられます。`CODEX_HOME`を設定している場合は、カスタムエージェントとPonytailの配置先にその値が使われます。

Ponytailのローカルチェックアウトを使う場合は、`skills/ponytail/SKILL.md`を含むディレクトリを指定します。

```bash
LUNA_PRIMARY_ENGINEER_PONYTAIL_SOURCE=/path/to/ponytail bash scripts/install.sh
```

インストール後はCodex Desktopを再起動して新しいセッションを開始し、次を入力します。

```text
$luna-primary-engineer
```

推奨設定はGPT-5.6 Luna、Max reasoning、Fast service tierです。

### 更新と確認

```bash
git pull --ff-only origin master
bash scripts/install.sh
bash scripts/doctor.sh
bash scripts/self-test.sh
```

## どう動くか

メインのCodexセッションが、要件の確認から実装・テストまでを担当します。必要な変更だけ、Opusに独立レビューを依頼します。

```text
要件
  ↓
Codex / Luna Primary Engineer
  ├─ 調査・計画・実装・テスト
  └─ 必要に応じてClaude Opusの読み取り専用レビュー
          ↓
       指摘を修正 → 新しいレビュー
```

Ponytailは、不要な抽象化や依存を避け、必要十分な変更に集中するための実装方針です。

## 役割

| 役割 | 使いどころ |
|---|---|
| Primary Engineer | 通常の調査、実装、テスト、統合を行うメインのCodexセッション |
| Claude Reviewer | Opusによる独立した読み取り専用レビュー |
| Claude Panel | 難しい設計判断を複数の観点から検討するパネル |
| `luna_worker` | 並列実行の価値がある、分離された実装作業 |
| `luna_reviewer` | Claude Codeが使えない場合の読み取り専用レビュー |
| `sol_advisor` | LunaとOpusだけでは決めきれない狭い技術判断 |
| `astra_expert` | 影響が大きく、極めて難しい最終判断 |

通常はPrimary Engineerだけで作業を完結させます。Workerや専門家は、追加の独立性や並列性に明確な価値がある場合だけ使います。

## Opusレビュー

### 通常レビュー

レビュー対象を`review-packet.md`にまとめます。変更目的、受け入れ条件、守るべき制約、変更ファイル、実行済みチェック、既知の懸念を含めてください。

```markdown
# Review packet

## Change goal / acceptance criteria
変更の目的と完了条件

## Relevant invariants / architecture constraints
守るべき契約、制約、状態遷移

## Changed files and compact diff/hunks
変更ファイルと重要な差分

## Focused surrounding code if needed
確認に必要な周辺コード

## Tests/checks run and results
実行済みのテストと結果

## Known compromises / open concerns
既知の妥協点と懸念
```

レビューを開始します。状態ディレクトリには、実行状態と結果が保存されます。初回実行ごとに新しいディレクトリを指定してください。

```bash
bash scripts/claude-review.sh start review-packet.md /tmp/luna-review-1 reviewer-1
```

後から状態や結果を確認する場合は次を使います。

```bash
bash scripts/claude-review.sh status /tmp/luna-review-1
bash scripts/claude-review.sh collect /tmp/luna-review-1
```

結果は、次の5見出しをすべて含む場合だけ有効です。

```text
VERDICT: PASS | CHANGES_REQUIRED | PASS_WITH_RISK
BLOCKERS:
NONBLOCKING:
TEST_GAPS:
PREVIOUS_FINDINGS:
```

`CHANGES_REQUIRED`の場合は、修正内容を`fix-delta.md`にまとめて再レビューします。

```bash
bash scripts/claude-review.sh resume /tmp/luna-review-1 fix-delta.md
```

`resume`は保存済みのClaude会話を再開するものではありません。元のパケット、前回の結果、修正差分を新しいClaude呼び出しへ渡します。`PASS_WITH_RISK`の場合は、残ったリスクを確認して受け入れるか判断します。

### 高リスク変更のデュアルレビュー

セキュリティ、認証、破壊的なデータ操作、並行性、公開プロトコル、ABI、広範な互換性変更など、第二意見の価値が高い場合に使います。通常レビューより時間とOpus使用量が増えます。

```bash
bash scripts/claude-review.sh dual-start review-packet.md /tmp/luna-dual-review
bash scripts/claude-review.sh dual-status /tmp/luna-dual-review
bash scripts/claude-review.sh dual-advance /tmp/luna-dual-review
bash scripts/claude-review.sh dual-collect /tmp/luna-dual-review
```

2人のレビューは順番に実行され、互いの結果を見ずに同じパケットを独立に評価します。

### Opusアドバイザリーパネル

通常のコードレビューではなく、難しい設計判断を複数の観点で考える場合に使います。2〜6個の役割ファイル（`.md`または`.txt`）を用意します。

```text
roles/
  analyst.md
  skeptic.md
  lifecycle.md
```

```bash
bash scripts/claude-panel.sh start context.md roles /tmp/luna-panel
bash scripts/claude-panel.sh status /tmp/luna-panel
bash scripts/claude-panel.sh advance /tmp/luna-panel
bash scripts/claude-panel.sh collect /tmp/luna-panel
```

特定の役割へ追加質問をする場合は、完了済みのブランチと差分ファイルを渡します。

```bash
bash scripts/claude-panel.sh followup /tmp/luna-panel/analyst delta.md
```

## 実行と安全境界

Claudeレビューとパネルはフォアグラウンドで実行され、完了までコマンドが待機します。数分かかることは正常です。実行中に重複起動せず、止める場合は実行中のターミナルで`Ctrl-C`を押します。

Claude呼び出しには次の制約を設定します。

```text
--model opus
--effort xhigh（パネルはmax）
--permission-mode dontAsk
--permission-prompts none
--tools "Read,Glob,Grep"
--disallowedTools "mcp__*"
--disable-slash-commands
--no-chrome
--no-session-persistence
```

Claudeはリポジトリを読み取って結果を返しますが、ファイル編集、MCP呼び出し、サブエージェントの起動は行いません。完了は、プロセスの終了コードと結果ファイルの契約で判断します。

## 設定

| 変数 | 既定値 | 意味 |
|---|---|---|
| `LUNA_PRIMARY_ENGINEER_CLAUDE` | `auto` | `auto`は認証確認後にClaudeを使用、`on`は事前確認を省略、`off`はLunaレビューへ切り替え |
| `LUNA_PRIMARY_ENGINEER_CLAUDE_MODEL` | `opus` | 通常レビューのClaudeモデル |
| `LUNA_PRIMARY_ENGINEER_CLAUDE_REVIEW_EFFORT` | `xhigh` | 通常レビューの推論強度 |
| `LUNA_PRIMARY_ENGINEER_CLAUDE_PANEL_EFFORT` | `max` | パネルの推論強度 |
| `CODEX_HOME` | `~/.codex` | カスタムエージェントと依存関係の基準ディレクトリ |
| `LUNA_PRIMARY_ENGINEER_PONYTAIL_SOURCE` | 未設定 | インストール時に使うローカルPonytailチェックアウト |

`ANTHROPIC_API_KEY`が設定されている場合、Claude CodeがAPI課金の認証経路を使う可能性があります。

## トラブルシューティング

### スキルが読み込まれない

インストール後にCodex Desktopを完全に再起動し、新しいセッションで`$luna-primary-engineer`を実行します。

### Claudeが使えない

```bash
command -v claude
claude auth status
claude doctor
```

Claudeを使わずにフォールバックレビューへ切り替える場合は、次を設定します。

```bash
export LUNA_PRIMARY_ENGINEER_CLAUDE=off
```

### 状態ディレクトリを再利用できない

初回実行の証拠があるディレクトリは、別の初回実行には使えません。既存の状態には`status`、`collect`、`resume`を使い、新しい初回実行には新しいディレクトリを指定します。

## リポジトリ構成

```text
README.md                         日本語の利用ガイド
README.en.md                      English guide
SKILL.md                          Codexが読むスキル本体
VERSION                           パッケージバージョン
agents/openai.yaml                スキルの表示情報
codex-agents/                     カスタムエージェント定義
scripts/install.sh                インストーラー
scripts/doctor.sh                 インストール先の診断
scripts/self-test.sh              軽量な自己テスト
scripts/claude-*.sh               Claudeレビュー・パネル・状態ヘルパー
references/                       詳細な設計・運用・レビュー資料
```

## 開発者向けチェック

```bash
bash -n scripts/*.sh
bash scripts/self-test.sh
git diff --check
```

## バージョン

現在のバージョンは`VERSION`に記載されています。
