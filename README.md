# JPEG Encoder - FPGA Baseline JPEG Encoder

SystemVerilogで実装されたFPGAベースラインJPEGエンコーダー。RGB画像をリアルタイムにJPEG圧縮し、JFIF準拠のバイトストリームを出力する。

Dual Processing Pipeline アーキテクチャにより、4:2:0モードで **1.53 clk/px** (0.652 px/clk) を達成。FHD 1920x1088 @250MHz で推定 **~78 fps** (60fps目標を30%マージンで達成)。全59テスト ALL PASS。

---

## 目次

- [1. 概要](#1-概要)
- [2. 特徴](#2-特徴)
- [3. 性能](#3-性能)
- [4. ファイル構造](#4-ファイル構造)
- [5. 必要な環境](#5-必要な環境)
- [6. 使用方法](#6-使用方法)
- [7. アーキテクチャ](#7-アーキテクチャ)
- [8. モジュール一覧](#8-モジュール一覧)
- [9. テスト結果](#9-テスト結果)
- [10. テストBMP画像の仕様](#10-テストbmp画像の仕様)
- [11. トラブルシューティング](#11-トラブルシューティング)
- [12. シミュレータの選択](#12-シミュレータの選択)
- [13. ライセンス](#13-ライセンス)

---

## 目的

本プロジェクトは、低レイテンシかつ高スループットなハードウェアJPEGエンコーダーをSystemVerilogで実現することを目的としています。FPGAでのリアルタイム画像圧縮に最適化されたアーキテクチャを提供し、AXI4-Streamインターフェースによる標準的な接続性を実現します。

---

## 1. 概要

### 主要スペック

| 項目 | 仕様 |
|------|------|
| 言語 | SystemVerilog (IEEE 1800-2012) |
| 規格準拠 | ITU-T T.81 (Baseline JPEG), JFIF 1.01 |
| 色空間 | YCbCr 4:4:4 / 4:2:0 (BT.601) |
| コンポーネント数 | 1 (Y単色) または 3 (YCbCr) |
| 最大画像サイズ | 4096 x 4096 ピクセル |
| 入力インタフェース | AXI4-Stream (32-bit A8R8G8B8) |
| 出力インタフェース | AXI4-Stream (8-bit JPEGバイトストリーム) |
| バックプレッシャ | 全パイプライン段で完全対応 |
| シミュレータ | Icarus Verilog 12.x / Verilator |

---

## 2. 特徴

- **Dual Processing Pipeline アーキテクチャ** - 2系統並列DCT処理により高解像度画像のリアルタイムエンコードを実現。Phase 5最適化で従来比4.25倍の高速化を達成。
- **YCbCr 4:4:4 / 4:2:0 クロマサブサンプリング対応** - 4:2:0モードでデータ量50%削減、処理速度約3.3倍向上。帯域制約のある映像アプリケーションに最適。
- **AXI4-Stream インターフェース** - バックプレッシャ完全対応の標準インターフェース。他のIPコアとの接続やシステムへの組み込みが容易。
- **JFIF 1.01 準拠ヘッダ自動生成** - SOI, APP0, DQT, SOF0, DHT, SOS, EOIを自動生成。標準的な画像ビューアで表示可能。
- **ITU-T.81 標準量子化・Huffmanテーブル** - Quality 50 標準テーブル内蔵。高画質と圧縮率のバランスを実現。
- **iverilog / Verilator 互換** - オープンソースツールで検証可能。商用ツールへの移植も容易。

---

## 3. 性能

### 3.1 スループット比較

| モード | clk/pixel | pixels/clock | FHD @250MHz |
|--------|-----------|--------------|-------------|
| 4:4:4 | ~4.99 | 0.200 | ~24 fps |
| **4:2:0** | **~1.53** | **0.652** | **~78 fps** |

### 3.2 Phase別性能推移

| Phase | 4:4:4 clk/px | 4:2:0 clk/px | 主な最適化 |
|-------|--------------|--------------|-----------|
| Phase 3 (ベースライン) | ~55.7 | ~29.0 | 基本パイプライン |
| Phase 4 | ~11.0 | ~6.5 | DCT並列化+ダブルバッファ+zigzag統合 |
| **Phase 5** | **~4.99** | **~1.53** | Dual Pipeline+Col/Output Overlap+DB RLE |

**Phase 3→5 合計改善: 4:2:0で19.0倍高速化** (29.0 → 1.53 clk/px)

### 3.3 リアルタイム性能 (4:2:0モード)

| 画像サイズ | @100MHz | @150MHz | @200MHz | @250MHz |
|-----------|---------|---------|---------|---------|
| 64 x 64 | 3,784 fps | 5,676 fps | 7,568 fps | 9,460 fps |
| 256 x 256 | 235 fps | 353 fps | 470 fps | 588 fps |
| 640 x 480 (VGA) | ~54 fps | ~80 fps | ~107 fps | ~134 fps |
| 1280 x 720 (HD) | 16.6 fps | 24.9 fps | **33.2 fps** | 41.5 fps |
| 1920 x 1080 (FHD) | ~7.4 fps | ~11.1 fps | ~14.8 fps | **~78 fps** |

詳細は [docs/performance.md](docs/performance.md) を参照。

---

## 4. ファイル構造

```
jpegenc/layers/
├── rtl/                              # RTLソースコード
│   ├── jpeg_encoder_pkg.sv           # 共有パッケージ（定数・型・テーブル・関数）
│   ├── jpeg_encoder_top.sv           # トップレベル統合モジュール (Dual Pipeline)
│   ├── rgb2ycbcr.sv                  # RGB→YCbCr色空間変換
│   ├── block_splitter.sv             # ラスタ→8x8ブロック順変換 (4:4:4用)
│   ├── block_splitter_420.sv         # ラスタ→MCUブロック分割 (4:2:0用)
│   ├── block_distributor.sv          # Dual Pipeline ブロック分配 (1→2 demux)
│   ├── dct_2d.sv                     # 2次元DCT (8並列乗算+ジグザグ出力統合)
│   ├── quantizer.sv                  # DCT係数量子化
│   ├── output_merger.sv              # Dual Pipeline 出力マージ (2→1 merge)
│   ├── zigzag_scan.sv                # ジグザグ走査順並べ替え (※DCTに統合済み)
│   ├── rle_encoder.sv                # ランレングス符号化 + DC DPCM
│   ├── huffman_encoder.sv            # Huffmanエントロピー符号化
│   └── bitstream_assembler.sv        # ビットパッキング + JFIFヘッダ
│
├── tb/                               # テストベンチ
│   ├── tb_common/                    # 共通テストベンチインフラ
│   │   ├── test_utils.sv             # テストユーティリティ
│   │   ├── axi_stream_driver.sv      # AXI4-Streamマスタドライバ
│   │   ├── axi_stream_monitor.sv     # AXI4-Streamモニタ
│   │   └── axi_stream_slave.sv       # AXI4-Streamスレーブ
│   ├── tb_rgb2ycbcr.sv               # RGB→YCbCr変換テスト
│   ├── tb_dct_2d.sv                  # 2D-DCTテスト
│   ├── tb_quantizer.sv               # 量子化テスト
│   ├── tb_zigzag_scan.sv             # ジグザグ走査テスト
│   ├── tb_rle_encoder.sv             # RLE符号化テスト
│   ├── tb_huffman_encoder.sv         # Huffman符号化テスト
│   ├── tb_block_splitter.sv          # ブロック分割テスト
│   ├── tb_bitstream_assembler.sv     # ビットストリーム組立テスト
│   ├── tb_jpeg_encoder_top.sv        # トップレベル統合テスト (4:4:4)
│   ├── tb_jpeg_encoder_top_420.sv    # トップレベル統合テスト (4:2:0)
│   ├── tb_block_splitter_420.sv      # 4:2:0ブロック分割テスト
│   ├── tb_bitstream_assembler_420.sv # 4:2:0ビットストリーム組立テスト
│   ├── tb_jpeg_perf.sv               # パフォーマンス計測テスト
│   └── tb_jpeg_encoder_bmp.sv        # BMP入出力エンドツーエンドテスト
│
├── sim/                              # シミュレーション環境
│   ├── Makefile                      # ビルド・テスト自動化
│   ├── run_sim.sh                    # シミュレーション実行スクリプト
│   ├── generate_test_bmp.py          # テストBMP画像生成スクリプト
│   └── test_images/                  # テストBMPファイル
│
└── docs/                             # ドキュメント
    ├── spec.md                       # 仕様書・モジュール詳細
    ├── performance.md                # パフォーマンスレポート
    └── verification_plan.md          # 検証計画
```

---

## 5. 必要な環境

| ツール | バージョン | 用途 |
|--------|-----------|------|
| Icarus Verilog (iverilog) | 12.x | SystemVerilogコンパイル・シミュレーション |
| vvp | (iverilog付属) | シミュレーション実行 |
| Python 3 | 3.6+ | テストBMP画像生成 |
| GTKWave | (任意) | 波形ビューア |
| Make | GNU Make | ビルド自動化 |

### インストール

```bash
# Ubuntu/Debian
sudo apt install iverilog python3

# macOS (Homebrew)
brew install icarus-verilog python3
```

---

## 6. 使用方法

### 6.1 ダウンロード

```bash
git clone <repository_url>
cd jpegenc/layers
```

### 6.2 全テスト実行

```bash
cd sim
make test_all
```

これにより以下のテストが順次実行される:
- 8モジュールのユニットテスト（rgb2ycbcr, dct_2d, quantizer, zigzag_scan, rle_encoder, huffman_encoder, block_splitter, bitstream_assembler）
- jpeg_encoder_topの統合テスト（4:4:4）
- 4:2:0モードのテスト（block_splitter_420, bitstream_assembler_420, jpeg_encoder_top_420）
- 合計: **59テスト**

### 6.3 個別モジュールテスト

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
```

### 6.4 パフォーマンステスト

```bash
cd sim

# === 4:4:4 モード ===
make test_perf PERF_W=256 PERF_H=256 PERF_COMP=3

# === 4:2:0 モード (画像サイズは16の倍数が必須) ===
make test_perf_420 PERF_W=512 PERF_H=512 PERF_COMP=3
```

### 6.5 BMP入出力テスト

```bash
cd sim

# テストBMP生成
make gen_test_bmp

# クイックテスト（8x8グラデーション）
make test_bmp_quick

# カスタムパラメータでのテスト
make test_bmp IMG_W=64 IMG_H=64 NUM_COMP=3 \
    BMP_FILE=test_images/test_64x64_gradient.bmp \
    JPEG_FILE=output_64x64.jpg
```

### 6.6 テスト結果レポート

```bash
make report
```

各モジュールのログファイルからPASS/FAIL結果を集計して表示。

### 6.7 波形表示

```bash
# テスト実行後、VCDファイルが生成される
make wave_<モジュール名>

# 例:
make wave_dct_2d
```

GTKWaveが起動し、波形ファイル (`tb_<モジュール名>.vcd`) を表示。

### 6.8 クリーンアップ

```bash
make clean
```

コンパイル済みバイナリ、波形ファイル、ログファイル、出力JPEGファイルを削除。

---

## 7. アーキテクチャ

### 7.1 パイプライン構成

```
入力ピクセル (A8R8G8B8, 32-bit)
    │
    ▼
[Stage 1] rgb2ycbcr ── RGB→YCbCr変換 (BT.601)
    │            24-bit {Y, Cb, Cr}
    ▼
[Stage 1.5] block_splitter / block_splitter_420 ── ラスタ→ブロック変換
    │            24-bit {Y, Cb, Cr}
    ▼
[Stage 2] Component Mux ── コンポーネント分離・MCU順序化
    │            8-bit 単成分
    ▼
[Stage 3] block_distributor ── Dual Pipeline ブロック分配 (1→2 demux)
    │            8-bit 単成分 × 2系統
    ▼
    ┌─────────────────────┬─────────────────────┐
    │  Pipeline A         │  Pipeline B         │
    │                     │                     │
    │ [Stage 4A] dct_2d   │ [Stage 4B] dct_2d  │ ── 2D-DCT (128cy/blk)
    │    16-bit signed    │    16-bit signed    │
    │        ▼            │        ▼            │
    │ [Stage 5A] quantizer│ [Stage 5B] quantizer│ ── 量子化
    │    12-bit signed    │    12-bit signed    │
    │                     │                     │
    └──────────┬──────────┴──────────┬─────────┘
               │                      │
               ▼                      ▼
[Stage 6] output_merger ── Dual Pipeline 出力マージ (2→1 merge)
    │            12-bit signed 量子化係数 (ジグザグ順)
    ▼
[Stage 7] rle_encoder ── ランレングス符号化 + DC DPCM
    │            16-bit {zero_run, value}
    ▼
[Stage 8] huffman_encoder ── Huffmanエントロピー符号化
    │            32-bit {code_length, codeword}
    ▼
[Stage 9] bitstream_assembler ── ビットパッキング + JFIFヘッダ
    │            8-bit JPEGバイトストリーム
    ▼
出力 JPEG ファイル
```

### 7.2 各ステージの役割

| ステージ | モジュール | 機能 | 遅延 |
|----------|-----------|------|------|
| 1 | rgb2ycbcr | RGB→YCbCr変換 (BT.601) | 3サイクル |
| 1.5 | block_splitter | ラスタ→8x8ブロック変換 | 8行ラインバッファ |
| 2 | Component Mux | コンポーネント分離 (Y→Cb→Cr) | 1ブロック |
| 3 | block_distributor | Dual Pipeline分配 | 1サイクル |
| 4 | dct_2d (x2) | 2D-DCT (並列処理) | 128サイクル/ブロック |
| 5 | quantizer (x2) | 量子化 | 1サイクル/係数 |
| 6 | output_merger | 出力マージ (2→1) | 1サイクル |
| 7 | rle_encoder | RLE + DC DPCM | 可変長 |
| 8 | huffman_encoder | Huffman符号化 | 可変長 |
| 9 | bitstream_assembler | JFIF出力 | 可変長 |

---

## 8. モジュール一覧

| モジュール | 機能 | 詳細 |
|-----------|------|------|
| jpeg_encoder_top | トップレベル統合 | [spec.md](docs/spec.md#31-jpeg_encoder_top) 参照 |
| rgb2ycbcr | RGB→YCbCr変換 | [spec.md](docs/spec.md#32-rgb2ycbcr) 参照 |
| block_splitter | ラスタ→ブロック変換 (4:4:4) | [spec.md](docs/spec.md#34-block_splitter) 参照 |
| block_splitter_420 | ブロック分割 (4:2:0) | [spec.md](docs/spec.md#34-block_splitter) 参照 |
| block_distributor | Dual Pipeline分配 | [spec.md](docs/spec.md#311-block_distributor) 参照 |
| dct_2d | 2次元DCT | [spec.md](docs/spec.md#35-dct_2d) 参照 |
| quantizer | 量子化 | [spec.md](docs/spec.md#36-quantizer) 参照 |
| output_merger | 出力マージ | [spec.md](docs/spec.md#312-output_merger) 参照 |
| rle_encoder | RLE符号化 | [spec.md](docs/spec.md#38-rle_encoder) 参照 |
| huffman_encoder | Huffman符号化 | [spec.md](docs/spec.md#39-huffman_encoder) 参照 |
| bitstream_assembler | JFIF出力 | [spec.md](docs/spec.md#310-bitstream_assembler) 参照 |

---

## 9. テスト結果

### 9.1 ユニットテストサマリ

| モジュール | テスト数 | 結果 |
|-----------|---------|------|
| rgb2ycbcr | 4 | PASS |
| dct_2d | 4 | PASS |
| quantizer | 4 | PASS |
| zigzag_scan | 4 | PASS |
| rle_encoder | 5 | PASS |
| huffman_encoder | 4 | PASS |
| block_splitter | 6 | PASS |
| bitstream_assembler | 4 | PASS |
| jpeg_encoder_top | 11 | PASS |
| block_splitter_420 | 6 | PASS |
| bitstream_assembler_420 | 2 | PASS |
| jpeg_encoder_top_420 | 5 | PASS |
| **合計** | **59** | **ALL PASS** |

### 9.2 画質テスト結果

| テスト画像 | MaxDiff | MeanDiff | PSNR |
|-----------|---------|----------|------|
| 8x8 gradient | 18 | 5.08 | 32.0 dB |
| 8x8 white | 1 | 1.00 | 48.1 dB |
| 16x16 gradient | 15 | 3.55 | 34.8 dB |
| 32x32 gradient | 10 | 2.67 | 37.6 dB |
| 64x64 gradient | 10 | 2.46 | 38.4 dB |

全テストでMaxDiff ≤ 18（JPEG Q50の量子化誤差範囲内）、PSNR 32.0～48.1 dB（標準的なJPEG品質）。

詳細は [docs/verification_plan.md](docs/verification_plan.md) を参照。

---

## 10. テストBMP画像の仕様

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

## 11. トラブルシューティング

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

- 画像ビューアがベースラインJPEGに対応しているか確認
- `hexdump -C output.jpg | head` でSOIマーカー (FF D8) とEOIマーカー (FF D9) が存在するか確認

---

## 12. シミュレータの選択

デフォルトではIcarus Verilog (`iverilog`) を使用するが、Verilator も選択可能:

```bash
# Icarus Verilog (デフォルト)
make test_all SIM_TOOL=iverilog

# Verilator
make test_all SIM_TOOL=verilator
```

---

## 13. ライセンス

MIT License

Copyright (c) 2026 Hidemi Ishihara

詳細は [LICENSE](LICENSE) を参照。