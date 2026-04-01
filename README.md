# JPEG Encoder - シミュレーションガイド

## 1. 概要

SystemVerilogで実装されたFPGAベースラインJPEGエンコーダのシミュレーション環境。Icarus Verilog (iverilog) を使用して全モジュールのユニットテスト、統合テスト、及びBMPファイル入出力テストを実行できる。

Dual Processing Pipeline アーキテクチャにより、4:2:0モードで **1.53 clk/px** (0.652 px/clk) を達成。FHD 1920x1088 @250MHz で推定 **~78 fps** (60fps目標を30%マージンで達成)。全59テスト ALL PASS。

---

## 2. ファイル構成

```
jpegenc/layers/
├── rtl/                              RTLソースコード
│   ├── jpeg_encoder_pkg.sv           共有パッケージ（定数・型・テーブル・関数）
│   ├── jpeg_encoder_top.sv           トップレベル統合モジュール (Dual Pipeline)
│   ├── rgb2ycbcr.sv                  RGB→YCbCr色空間変換
│   ├── block_splitter.sv             ラスタ→8x8ブロック順変換 (4:4:4用)
│   ├── block_splitter_420.sv         ラスタ→MCUブロック分割 (4:2:0用、ダウンサンプリング内蔵)
│   ├── block_distributor.sv          Dual Pipeline ブロック分配 (1→2 demux)
│   ├── dct_2d.sv                     2次元DCT (8並列乗算+ジグザグ出力統合)
│   ├── quantizer.sv                  DCT係数量子化
│   ├── output_merger.sv              Dual Pipeline 出力マージ (2→1 merge)
│   ├── zigzag_scan.sv                ジグザグ走査順並べ替え (※DCTに統合済み、未使用)
│   ├── rle_encoder.sv                ランレングス符号化 + DC DPCM (ダブルバッファリング)
│   ├── huffman_encoder.sv            Huffmanエントロピー符号化
│   └── bitstream_assembler.sv        ビットパッキング + JFIFヘッダ
│
├── tb/                               テストベンチ
│   ├── tb_common/                    共通テストベンチインフラ
│   │   ├── test_utils.sv             テストユーティリティ
│   │   ├── axi_stream_driver.sv      AXI4-Streamマスタドライバ
│   │   ├── axi_stream_monitor.sv     AXI4-Streamモニタ
│   │   └── axi_stream_slave.sv       AXI4-Streamスレーブ（バックプレッシャ対応）
│   ├── tb_rgb2ycbcr.sv               RGB→YCbCr変換テスト
│   ├── tb_dct_2d.sv                  2D-DCTテスト
│   ├── tb_quantizer.sv               量子化テスト
│   ├── tb_zigzag_scan.sv             ジグザグ走査テスト
│   ├── tb_rle_encoder.sv             RLE符号化テスト
│   ├── tb_huffman_encoder.sv         Huffman符号化テスト
│   ├── tb_block_splitter.sv          ブロック分割テスト
│   ├── tb_bitstream_assembler.sv     ビットストリーム組立テスト
│   ├── tb_jpeg_encoder_top.sv        トップレベル統合テスト (4:4:4)
│   ├── tb_jpeg_encoder_top_420.sv    トップレベル統合テスト (4:2:0)
│   ├── tb_block_splitter_420.sv      4:2:0ブロック分割テスト
│   ├── tb_bitstream_assembler_420.sv 4:2:0ビットストリーム組立テスト
│   ├── tb_jpeg_perf.sv               パフォーマンス計測テスト
│   └── tb_jpeg_encoder_bmp.sv        BMP入出力エンドツーエンドテスト
│
├── sim/                              シミュレーション環境
│   ├── Makefile                      ビルド・テスト自動化
│   ├── run_sim.sh                    シミュレーション実行スクリプト
│   ├── generate_test_bmp.py          テストBMP画像生成スクリプト
│   └── test_images/                  テストBMPファイル（10ファイル）
│       ├── test_8x8_gradient.bmp     8x8 カラーグラデーション
│       ├── test_8x8_white.bmp        8x8 ソリッドホワイト
│       ├── test_8x8_red.bmp          8x8 ソリッドレッド
│       ├── test_8x8_black.bmp        8x8 ソリッドブラック
│       ├── test_16x16_gradient.bmp   16x16 カラーグラデーション
│       ├── test_16x16_checker.bmp    16x16 チェッカーボード
│       ├── test_16x8_gradient.bmp    16x8 非正方形グラデーション
│       ├── test_32x32_gradient.bmp   32x32 カラーグラデーション
│       ├── test_32x32_rainbow.bmp    32x32 レインボーバー
│       └── test_64x64_gradient.bmp   64x64 カラーグラデーション
│
└── docs/                             ドキュメント
    ├── spec.md                       仕様書・モジュール詳細
    ├── README.md                     本ドキュメント
    ├── performance.md                パフォーマンスレポート (Phase 3-5)
    └── verification_plan.md          検証計画
```

---

## 3. 必要な環境

| ツール | バージョン | 用途 |
|--------|-----------|------|
| Icarus Verilog (iverilog) | 12.x | SystemVerilogコンパイル・シミュレーション |
| vvp | (iverilog付属) | シミュレーション実行 |
| Python 3 | 3.6+ | テストBMP画像生成 |
| GTKWave | (任意) | 波形ビューア |
| Make | GNU Make | ビルド自動化 |

---

## 4. シミュレーション方法

### 4.1 全テスト実行

```bash
cd sim
make test_all
```

これにより以下のテストが順次実行される:
- 8モジュールのユニットテスト（rgb2ycbcr, dct_2d, quantizer, zigzag_scan, rle_encoder, huffman_encoder, block_splitter, bitstream_assembler）
- jpeg_encoder_topの統合テスト（4:4:4）
- 4:2:0モードのテスト（block_splitter_420, bitstream_assembler_420, jpeg_encoder_top_420）
- 合計: **59テスト**

### 4.2 個別モジュールテスト

```bash
cd sim

# 利用可能なモジュール:
# rgb2ycbcr, dct_2d, quantizer, zigzag_scan,
# rle_encoder, huffman_encoder, block_splitter,
# bitstream_assembler, jpeg_encoder_top

# コンパイルのみ
make compile_<モジュール名>

# コンパイル＋実行
make test_<モジュール名>

# 例: DCTモジュールのテスト
make test_dct_2d

# 例: トップレベル統合テスト
make test_jpeg_encoder_top
```

### 4.3 パフォーマンステスト

```bash
cd sim

# === 4:4:4 モード ===
# 特定サイズのパフォーマンステスト
make test_perf PERF_W=256 PERF_H=256 PERF_COMP=3

# Full HD テスト (所要時間: iverilogで約15分)
make test_perf PERF_W=1920 PERF_H=1080 PERF_COMP=3

# === 4:2:0 モード (画像サイズは16の倍数が必須) ===
# 4:2:0 VGA テスト
make test_perf_420 PERF_W=640 PERF_H=480 PERF_COMP=3

# 4:2:0 HD テスト
make test_perf_420 PERF_W=1280 PERF_H=720 PERF_COMP=3

# 4:2:0 512x512 テスト (Phase 5 最速計測に使用)
make test_perf_420 PERF_W=512 PERF_H=512 PERF_COMP=3
```

テストベンチ `tb_jpeg_perf.sv` がグラデーション画像をオンザフライ生成し、入力/出力/合計のクロック数を計測する。Back-to-back streaming方式で`tvalid`を連続アサートし、パイプラインの真性能を計測する。

詳細な結果は `docs/performance.md` を参照。

### 4.4 BMP入出力テスト

#### テストBMP画像の生成

```bash
cd sim
make gen_test_bmp
```

Python 3 の `generate_test_bmp.py` が `test_images/` ディレクトリに10種類のテストBMPを生成する。

#### クイックテスト（8x8グラデーション）

```bash
make test_bmp_quick
```

テストBMP生成 + 8x8グラデーション画像のエンコードテストを実行する。

#### カスタムパラメータでのテスト

```bash
make test_bmp IMG_W=<幅> IMG_H=<高さ> NUM_COMP=<成分数> \
    BMP_FILE=<入力BMPパス> JPEG_FILE=<出力JPEGパス>
```

**パラメータ一覧:**

| パラメータ | デフォルト | 説明 |
|-----------|-----------|------|
| `IMG_W` | 8 | 画像幅（8の倍数） |
| `IMG_H` | 8 | 画像高さ（8の倍数） |
| `NUM_COMP` | 3 | コンポーネント数 (1 or 3) |
| `BMP_FILE` | `test_images/test_8x8_gradient.bmp` | 入力BMPファイル |
| `JPEG_FILE` | `output_8x8.jpg` | 出力JPEGファイル |

**使用例:**

```bash
# 64x64 グラデーション画像のエンコード
make test_bmp IMG_W=64 IMG_H=64 NUM_COMP=3 \
    BMP_FILE=test_images/test_64x64_gradient.bmp \
    JPEG_FILE=output_64x64.jpg

# 32x32 レインボーバー画像のエンコード
make test_bmp IMG_W=32 IMG_H=32 NUM_COMP=3 \
    BMP_FILE=test_images/test_32x32_rainbow.bmp \
    JPEG_FILE=output_32x32_rainbow.jpg

# 16x16 チェッカーボード画像のエンコード
make test_bmp IMG_W=16 IMG_H=16 NUM_COMP=3 \
    BMP_FILE=test_images/test_16x16_checker.bmp \
    JPEG_FILE=output_16x16_checker.jpg
```

### 4.5 波形表示

```bash
# テスト実行後、VCDファイルが生成される
make wave_<モジュール名>

# 例:
make wave_dct_2d
```

GTKWaveが起動し、波形ファイル (`tb_<モジュール名>.vcd`) を表示する。

### 4.6 テスト結果レポート

```bash
make report
```

各モジュールのログファイルからPASS/FAIL結果を集計して表示する。

### 4.7 クリーンアップ

```bash
make clean
```

コンパイル済みバイナリ (`sim_*`)、波形ファイル (`*.vcd`)、ログファイル (`log_*.txt`)、出力JPEGファイル (`*.jpg`) を削除する。

---

## 5. テストBMP画像の仕様

`generate_test_bmp.py` で生成されるテストBMPファイル:

| ファイル名 | サイズ | 内容 |
|-----------|--------|------|
| `test_8x8_gradient.bmp` | 8x8 | R=x方向グラデ, G=y方向グラデ, B=128 |
| `test_8x8_white.bmp` | 8x8 | ソリッドホワイト (255,255,255) |
| `test_8x8_red.bmp` | 8x8 | ソリッドレッド (255,0,0) |
| `test_8x8_black.bmp` | 8x8 | ソリッドブラック (0,0,0) |
| `test_16x16_gradient.bmp` | 16x16 | カラーグラデーション |
| `test_16x16_checker.bmp` | 16x16 | チェッカーボード（4x4ブロック） |
| `test_16x8_gradient.bmp` | 16x8 | 非正方形グラデーション |
| `test_32x32_gradient.bmp` | 32x32 | カラーグラデーション |
| `test_32x32_rainbow.bmp` | 32x32 | 垂直レインボーカラーバー |
| `test_64x64_gradient.bmp` | 64x64 | カラーグラデーション |

BMPフォーマット: 24-bit Windows BMP (BITMAPINFOHEADER, BI_RGB, bottom-up)

---

## 6. テスト結果の見方

### 6.1 ユニットテスト

各テストベンチは `$display` で結果を出力する。ログファイルは `sim/log_<モジュール名>.txt` に保存される。

```
[PASS] テスト名 - 説明
[FAIL] テスト名 - 説明
```

### 6.2 BMP入出力テスト

テストベンチ (`tb_jpeg_encoder_bmp.sv`) は以下を出力する:

1. **エンコード結果**: 出力JPEGファイルのバイト数
2. **品質比較**: 入力画像とJPEGデコード画像の差分
   - **MaxDiff**: 全ピクセルの最大差分値
   - **MeanDiff**: 全ピクセルの平均差分値
   - **PSNR**: ピーク信号対雑音比 (dB)

JPEG Q50（標準品質）での期待値:
- MaxDiff ≤ 20 程度
- PSNR ≥ 30 dB

---

## 7. シミュレータの選択

デフォルトではIcarus Verilog (`iverilog`) を使用するが、Verilator も選択可能:

```bash
# Icarus Verilog (デフォルト)
make test_all SIM_TOOL=iverilog

# Verilator
make test_all SIM_TOOL=verilator
```

---

## 8. トラブルシューティング

### iverilog が見つからない

```bash
# Ubuntu/Debian
sudo apt install iverilog

# macOS (Homebrew)
brew install icarus-verilog
```

### Python 3 が見つからない

テストBMP生成に Python 3 が必要:
```bash
sudo apt install python3
```

### シミュレーションがタイムアウトする

- テストベンチのパラメータと入力データのサイズが一致しているか確認
- `IMAGE_WIDTH`, `IMAGE_HEIGHT`, `NUM_COMPONENTS` のパラメータがコンパイル時と実行時で一致しているか確認

### 出力JPEGファイルが正しく表示されない

<<<<<<< HEAD
- 画像ビューアがベースラインJPEGに対応しているか確認
- `hexdump -C output.jpg | head` でSOIマーカー (FF D8) とEOIマーカー (FF D9) が存在するか確認
=======
- `--to` : 送信先エージェント（必須）
- `--type` : メッセージタイプ（instruction, report, question, answer, status, error, complete）（必須）
- `--message` : メッセージ本文（必須）
- `--from` : 送信者名（デフォルト: coo）
- `--priority` : 優先度（low, normal, high, urgent）（デフォルト: normal）

### 監視モード

```bash
pnpm run monitor
```

バックグラウンドでエージェントの正常性を監視し、異常検出時にログを出力します。Ctrl+Cで終了。

### リアルタイム実行状況表示

```bash
pnpm run live
```

全14エージェントの実行状況をターミナル上にダッシュボード形式で表示します。一定間隔（デフォルト3秒）で自動更新されます。

各エージェントについて以下の情報が表示されます:

- **セッション名**: tmuxセッション名
- **役割**: エージェントの役職
- **状態**: 稼働中 / 停止
- **最新アクティビティ**: 各エージェントが現在行っている作業内容

オプション:

- `--interval <ms>` : 更新間隔をミリ秒で指定（デフォルト: 3000）

```bash
# 5秒間隔で更新
pnpm run live -- --interval 5000
```

Ctrl+Cで終了。

> **`monitor` との違い**: `monitor`はバックグラウンドでの正常性監視（異常検出時にログ出力）を行うのに対し、`live`は人間が視覚的に全エージェントの状況をリアルタイムで把握するためのダッシュボードです。

### エージェントへの接続

```bash
# プロデューサーに接続
tmux attach -t producer

# ディレクターに接続
tmux attach -t director

# セッションからデタッチ: Ctrl+b d
```

### セッション一覧

```bash
tmux ls
```

## エージェント構成

| 部門 | 役職 | セッション名 | 人数 |
|------|------|--------------|------|
| 統括 | プロデューサー | producer | 1 |
| 統括 | ディレクター | director | 1 |
| デザイン | リードデザイナー | lead_design | 1 |
| デザイン | デザイナー | designer_1, designer_2 | 2 |
| プログラム | リードプログラマー | lead_prog | 1 |
| プログラム | プログラマー | programmer_1〜5 | 5 |
| QA | QAリード | lead_qa | 1 |
| QA | テスター | tester_1, tester_2 | 2 |
| **合計** | | | **14** |

## ディレクトリ構造

```
layers/
├── .layers/                   # Layers固有コンテンツ統合ディレクトリ
│   ├── src/                   # TypeScriptソースコード
│   │   ├── index.ts           # CLIエントリーポイント
│   │   ├── agents/            # エージェント管理
│   │   │   ├── AgentManager.ts
│   │   │   ├── types.ts
│   │   │   └── index.ts
│   │   ├── communication/     # メッセージング
│   │   │   ├── MessageBroker.ts
│   │   │   ├── TmuxTransport.ts
│   │   │   ├── types.ts
│   │   │   └── index.ts
│   │   ├── tmux/              # tmux操作
│   │   │   ├── TmuxController.ts
│   │   │   ├── ShellExecutor.ts
│   │   │   ├── types.ts
│   │   │   └── index.ts
│   │   ├── monitoring/        # 監視・ログ
│   │   │   ├── Monitor.ts
│   │   │   ├── Logger.ts
│   │   │   └── index.ts
│   │   └── config/
│   │       └── agents.json    # エージェント設定
│   ├── dist/                  # ビルド成果物（自動生成）
│   ├── prompts/               # エージェントプロンプト
│   │   ├── producer.md
│   │   ├── director.md
│   │   ├── lead_design.md
│   │   ├── lead_prog.md
│   │   ├── lead_qa.md
│   │   ├── designer.md
│   │   ├── programmer.md
│   │   └── tester.md
│   └── logs/                  # エージェント作業ログ（自動生成）
├── logs/                      # システムログファイル
├── package.json
├── tsconfig.json
├── pnpm-lock.yaml
└── README.md
```

## 設定ファイル

### agents.json

各エージェントの設定は `.layers/src/config/agents.json` で管理されます。

```json
{
  "sessionName": "producer",
  "role": "producer",
  "superior": null,
  "subordinates": ["director"],
  "promptFile": ".layers/prompts/producer.md",
  "permissionMode": "dangerouslySkip"
}
```

### エージェントプロンプト

各エージェントの行動指針は `.layers/prompts/` 配下のMarkdownファイルで定義されています。

## トラブルシューティング

### セッションが起動しない

```bash
# tmuxの確認
tmux -V

# Claude Codeの確認
claude --version

# pnpmの確認
pnpm --version
```

### メッセージが届かない

```bash
# セッションの確認
tmux ls

# 特定セッションの内容確認
tmux capture-pane -t producer -p
```

### エージェントが応答しない

```bash
# セッションの再起動
tmux kill-session -t <session_name>
pnpm run start
```

### ビルドエラー

```bash
# node_modulesを再インストール
rm -rf node_modules
pnpm install

# ビルド
pnpm run build
```

## 技術的な制約

### Claude Codeのbash実行制約

Claude Codeがbashコマンドを実行する際、`;`や`&&`で連結された複数コマンドの後半が実行されない場合があります。

**対策**: エージェントプロンプトでは、メッセージ送信とEnter送信を別々のbashコマンドブロックとして実行するよう指示しています。

```bash
# コマンド1: メッセージ送信
tmux send-keys -t "target" 'メッセージ'
```

```bash
# コマンド2: Enter送信（必ず別のbash実行で）
tmux send-keys -t "target" Enter
```

## 注意事項

- 14エージェント同時稼働は大量のAPI呼び出しを発生させます
- 必要なエージェントのみを稼働させることを推奨します
- `--dangerously-skip-permissions`の使用は本番環境では非推奨です
- Anthropic APIには5時間あたりの利用制限があります

## ライセンス

MIT
>>>>>>> 53d59a608fda032808e9553c14f4ad5bd472b5c3
