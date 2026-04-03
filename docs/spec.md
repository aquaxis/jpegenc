# JPEG Encoder 仕様書

## 1. 概要

本プロジェクトは、FPGAベースのベースラインJPEGエンコーダをSystemVerilogで実装したものである。RGB画像をリアルタイムにJPEG圧縮し、JFIF準拠のバイトストリームを出力する。

### 主要スペック

| 項目 | 仕様 |
|------|------|
| 言語 | SystemVerilog (IEEE 1800-2012) |
| 規格準拠 | ITU-T T.81 (Baseline JPEG), JFIF 1.01 |
| 色空間 | YCbCr 4:4:4 / 4:2:0 (BT.601) |
| コンポーネント数 | 1 (Y単色) または 3 (YCbCr) |
| クロマサブサンプリング | CHROMA_MODE: 444 (4:4:4) / 420 (4:2:0) |
| 最大画像サイズ | 4096 x 4096 ピクセル |
| 量子化テーブル | ITU-T.81 Annex K.1 / K.2 (Quality 50) |
| Huffmanテーブル | ITU-T.81 標準テーブル |
| 入力インタフェース | AXI4-Stream (32-bit A8R8G8B8) |
| 出力インタフェース | AXI4-Stream (8-bit JPEGバイトストリーム) |
| バックプレッシャ | 全パイプライン段で完全対応 |
| パイプライン構成 | Dual Processing Pipeline (2x DCT+Quantizer) |
| スループット (4:2:0) | 0.652 px/clk (1.53 clk/px) @512x512 |
| FHD性能推定 (4:2:0) | ~78 fps @250MHz (1920x1088) |
| テスト結果 | 59/59 ALL PASS |
| シミュレータ互換性 | Icarus Verilog 12.x |

---

## 2. パイプラインアーキテクチャ

### 2.1 全体構成

```
入力ピクセル (A8R8G8B8, 32-bit)
    │
    ▼
[Stage 1] rgb2ycbcr              ── RGB→YCbCr変換 (BT.601)
    │            24-bit {Y, Cb, Cr}
    ▼
[Stage 1.5] block_splitter       ── ラスタ→ブロック順変換
    │          (4:4:4: block_splitter, 4:2:0: block_splitter_420)
    │            24-bit {Y, Cb, Cr}
    ▼
[Stage 2] Component Mux          ── コンポーネント分離・MCU順序化 (Y→Cb→Cr)
    │            8-bit 単成分
    ▼
[Stage 3] block_distributor      ── Dual Pipeline ブロック分配 (1→2 demux)
    │            8-bit 単成分 × 2系統
    ▼
    ┌─────────────────────┬─────────────────────┐
    │  Pipeline A          │  Pipeline B          │
    │                      │                      │
    │ [Stage 4A] dct_2d    │ [Stage 4B] dct_2d    │  ── 2D-DCT (ジグザグ出力統合)
    │    16-bit signed     │    16-bit signed     │
    │        ▼              │        ▼              │
    │ [Stage 5A] quantizer │ [Stage 5B] quantizer │  ── 量子化 (Luma/Chroma選択)
    │    12-bit signed     │    12-bit signed     │
    │                      │                      │
    └──────────┬───────────┴──────────┬────────────┘
               │                      │
               ▼                      ▼
[Stage 6] output_merger          ── Dual Pipeline 出力マージ (2→1 merge)
    │            12-bit signed 量子化係数 (ジグザグ順)
    ▼
[Stage 7] rle_encoder            ── ランレングス符号化 + DC DPCM (ダブルバッファリング)
    │            16-bit {zero_run, value}
    ▼
[Stage 8] huffman_encoder        ── Huffmanエントロピー符号化
    │            32-bit {code_length, codeword}
    ▼
[Stage 9] bitstream_assembler   ── ビットパッキング + JFIFヘッダ + バイトスタッフィング
    │            8-bit JPEGバイトストリーム
    ▼
出力 JPEG ファイル
```

**注記**: Phase 5 (Dual Pipeline) アーキテクチャでは、DCTと量子化を2系統並列で処理し、output_mergerでブロック順を維持しながらマージする。RLE以降は単一パイプラインで処理することでDC DPCM予測の正確性を保証する。ジグザグスキャンはDCT出力ステージに統合されており、独立モジュールとしては使用しない。

### 2.2 データ幅の遷移

| ステージ | 出力データ幅 | 内容 |
|----------|-------------|------|
| 入力 | 32-bit | A8R8G8B8 RGBピクセル |
| rgb2ycbcr | 24-bit | {Y[23:16], Cb[15:8], Cr[7:0]} |
| block_splitter / block_splitter_420 | 24-bit | ブロック順YCbCr (4:2:0時はダウンサンプリング内蔵) |
| Component Mux | 8-bit | 単成分ピクセル値 |
| block_distributor | 8-bit x2 | Dual Pipeline分配 (交互ブロック) |
| dct_2d (x2) | 16-bit signed | DCT係数 (ジグザグ順出力統合) |
| quantizer (x2) | 12-bit signed | 量子化係数 |
| output_merger | 12-bit signed | マージ済み量子化係数 (ジグザグ順) |
| rle_encoder | 16-bit | {zero_run[15:12], value[11:0]} |
| huffman_encoder | 32-bit | {code_length[31:27], codeword[26:0]} |
| bitstream_assembler | 8-bit | JPEGバイトストリーム |

### 2.3 AXI4-Streamプロトコル

全モジュール間接続はAXI4-Streamプロトコルに準拠する。

| 信号 | 説明 |
|------|------|
| `tdata` | データペイロード（幅はステージにより異なる） |
| `tvalid` | データ有効フラグ（マスター→スレーブ） |
| `tready` | 受信可能フラグ（スレーブ→マスター） |
| `tlast` | ブロック終端マーカ（64係数/ピクセルの最後） |
| `tuser` | サイドバンド情報 `{EOF, SOF}` |

- **SOF (Start of Frame)**: フレームの最初のピクセル/係数で `tuser[0]=1`
- **EOF (End of Frame)**: フレームの最後のピクセル/係数で `tuser[1]=1`
- ハンドシェイク: `tvalid && tready` で1転送が成立

### 2.4 4:2:0クロマサブサンプリング

4:2:0モード (`CHROMA_MODE=420`) では、色差成分 (Cb/Cr) を水平・垂直ともに半分の解像度にダウンサンプリングし、データ量を削減する。

#### 基本原理

- **輝度 (Y)**: フル解像度を維持（全ピクセル保持）
- **色差 (Cb/Cr)**: 水平・垂直とも半分の解像度（2x2ピクセル領域を1サンプルに集約）
- **データ削減率**: 4:4:4比で50%のデータ量削減（Y: 4ブロック、Cb: 1ブロック、Cr: 1ブロック = 6ブロック/MCU）

#### MCU構造 (4:2:0)

4:2:0モードのMCU (Minimum Coded Unit) は16x16ピクセル領域に対応する:

```
MCU (16x16 ピクセル):
┌────────┬────────┐
│ Y0     │ Y1     │    Yブロック: 8x8 × 4個 (2x2配置)
│ (8x8)  │ (8x8)  │    Cbブロック: 8x8 × 1個 (16x16領域を2x2平均)
├────────┼────────┤    Crブロック: 8x8 × 1個 (16x16領域を2x2平均)
│ Y2     │ Y3     │
│ (8x8)  │ (8x8)  │    合計: 6ブロック/MCU
└────────┴────────┘
```

- **Yブロックの出力順序**: Y0(左上) → Y1(右上) → Y2(左下) → Y3(右下)
- **MCU内ブロック出力順序**: Y0 → Y1 → Y2 → Y3 → Cb → Cr

#### 画像サイズ制約

- 4:2:0モード時: 幅・高さとも**16の倍数**であること
- 4:4:4モード時: 幅・高さとも8の倍数（従来通り）

#### ダウンサンプリング方式

2x2ピクセル平均法を使用:

```
入力2x2ピクセル:
┌─────┬─────┐
│ P00 │ P01 │
├─────┼─────┤
│ P10 │ P11 │
└─────┴─────┘

出力サンプル = (P00 + P01 + P10 + P11 + 2) >> 2
```

- **丸め**: +2の加算により四捨五入（バンカーズラウンディング相当）
- **適用対象**: Cb成分およびCr成分のみ（Y成分はダウンサンプリングなし）

---

## 3. モジュール詳細

### 3.1 jpeg_encoder_top

トップレベル統合モジュール。全サブモジュールを接続し、コンポーネントID追跡とフォーマット変換のグルーロジックを含む。

#### パラメータ

| パラメータ | 型 | デフォルト | 説明 |
|-----------|-----|-----------|------|
| `IMAGE_WIDTH` | int | 64 | 画像幅（8の倍数、4:2:0時は16の倍数） |
| `IMAGE_HEIGHT` | int | 64 | 画像高さ（8の倍数、4:2:0時は16の倍数） |
| `NUM_COMPONENTS` | int | 1 | コンポーネント数（1=Y単色, 3=YCbCr） |
| `CHROMA_MODE` | chroma_mode_t | CHROMA_444 | クロマサブサンプリングモード (CHROMA_444 / CHROMA_420) |

#### ポート

| ポート名 | 方向 | 幅 | 説明 |
|---------|------|-----|------|
| `clk` | input | 1 | システムクロック |
| `rst_n` | input | 1 | アクティブLowリセット |
| `s_axis_tdata` | input | 32 | A8R8G8B8 ピクセルデータ |
| `s_axis_tvalid` | input | 1 | 入力有効 |
| `s_axis_tready` | output | 1 | 入力受付可能 |
| `s_axis_tlast` | input | 1 | 行末マーカ |
| `s_axis_tuser` | input | 2 | `{EOF, SOF}` |
| `s_axis_tkeep` | input | 4 | バイトイネーブル |
| `m_axis_tdata` | output | 8 | JPEGバイトストリーム |
| `m_axis_tvalid` | output | 1 | 出力有効 |
| `m_axis_tready` | input | 1 | 出力受付可能 |
| `m_axis_tlast` | output | 1 | JPEGデータ終端 |
| `m_axis_tuser` | output | 2 | `{EOF, SOF}` |

#### 内部動作

- **1成分モード (`NUM_COMPONENTS=1`)**: block_splitterをバイパスし、Y成分のみ抽出してパイプラインへ直接入力
- **3成分モード (`NUM_COMPONENTS=3`)**: block_splitterでラスタ→ブロック変換後、Component Muxで1ブロック分（64ピクセル × 24bit）をバッファリングし、Y→Cb→Crの3ブロックとして順次出力
- **4:2:0モード (`CHROMA_MODE=CHROMA_420`)**: block_splitter_420を使用。MCU構造は1MCUにつき6ブロック（Y×4 + Cb×1 + Cr×1）。block_splitter_420がダウンサンプリングを内蔵し、16x16領域から Y0→Y1→Y2→Y3→Cb→Cr の順序でブロックを出力
- **Dual Processing Pipeline**: block_distributorがブロックを交互に2本のパイプライン（Pipeline A/B）に分配。各パイプラインはDCT+Quantizerを独立に持つ。output_mergerが2系統の出力をブロック順序を維持しながらマージし、単一ストリームに戻す。DC DPCM予測の正確性を保証するため、RLE以降は単一パイプラインで処理
- **コンポーネントID追跡**: 各パイプラインステージにカウンタベースの追跡ロジックを配置。`tlast`でカウンタを+1、SOFで0にリセット。量子化テーブル・Huffmanテーブルの正確な選択を保証。4:2:0モード時はY0,Y1,Y2,Y3が全て `comp_id=0`（輝度）、Cbが `comp_id=1`、Crが `comp_id=2` となる
- **EOF伝搬**: DCTモジュールが入力の任意のピクセルからEOFをキャプチャし、最初のDCT出力係数の`tuser`に載せて出力。以降RLE→huffman→BSAへ自然伝搬

---

### 3.2 rgb2ycbcr

RGB→YCbCr色空間変換モジュール。BT.601/JFIF規格準拠。

#### ポート

| ポート名 | 方向 | 幅 | 説明 |
|---------|------|-----|------|
| `clk` | input | 1 | システムクロック |
| `rst_n` | input | 1 | アクティブLowリセット |
| `s_axis_tdata` | input | 32 | `{A[31:24], R[23:16], G[15:8], B[7:0]}` |
| `s_axis_tvalid` | input | 1 | 入力有効 |
| `s_axis_tready` | output | 1 | 入力受付可能 |
| `s_axis_tlast` | input | 1 | 行末マーカ |
| `s_axis_tuser` | input | 2 | `{EOF, SOF}` |
| `s_axis_tkeep` | input | 4 | バイトイネーブル |
| `m_axis_tdata` | output | 24 | `{Y[23:16], Cb[15:8], Cr[7:0]}` |
| `m_axis_tvalid` | output | 1 | 出力有効 |
| `m_axis_tready` | input | 1 | 出力受付可能 |
| `m_axis_tlast` | output | 1 | 行末マーカ |
| `m_axis_tuser` | output | 2 | `{EOF, SOF}` |

#### 変換式（固定小数点、256倍スケール）

```
Y  = ( 77*R + 150*G +  29*B + 128) >> 8
Cb = (-43*R -  85*G + 128*B + 128) >> 8 + 128
Cr = (128*R - 107*G -  21*B + 128) >> 8 + 128
```

- 3段パイプライン（乗算累積 → シフト+オフセット+クランプ → 出力）
- 全結果を [0, 255] にクランプ

---

### 3.3 chroma_downsampler

4:4:4 YCbCrピクセルのCb/Cr成分を2x2平均でダウンサンプリングするモジュール。

> **注記**: 初期設計ではrgb2ycbcrとblock_splitterの間に独立モジュールとして挿入される予定であったが、実装ではblock_splitter_420にダウンサンプリング機能が統合された。本モジュールは独立RTLとしては使用されていない。以下は設計仕様としての参考情報。

#### パラメータ

| パラメータ | 型 | デフォルト | 説明 |
|-----------|-----|-----------|------|
| `IMAGE_WIDTH` | int | 64 | 画像幅（16の倍数） |
| `IMAGE_HEIGHT` | int | 64 | 画像高さ（16の倍数） |

#### ポート

| ポート名 | 方向 | 幅 | 説明 |
|---------|------|-----|------|
| `clk` | input | 1 | システムクロック |
| `rst_n` | input | 1 | アクティブLowリセット |
| `s_axis_tdata` | input | 24 | `{Y[23:16], Cb[15:8], Cr[7:0]}` (4:4:4) |
| `s_axis_tvalid` | input | 1 | 入力有効 |
| `s_axis_tready` | output | 1 | 入力受付可能 |
| `s_axis_tlast` | input | 1 | 行末マーカ |
| `s_axis_tuser` | input | 2 | `{EOF, SOF}` |
| `m_axis_tdata` | output | 24 | `{Y[23:16], Cb[15:8], Cr[7:0]}` (Y: フル解像度、Cb/Cr: ダウンサンプリング済み) |
| `m_axis_tvalid` | output | 1 | 出力有効 |
| `m_axis_tready` | input | 1 | 出力受付可能 |
| `m_axis_tlast` | output | 1 | 行末マーカ |
| `m_axis_tuser` | output | 2 | `{EOF, SOF}` |

#### 内部動作

- **Y成分**: ダウンサンプリングなし。入力をそのまま通過させる
- **Cb/Cr成分**: 2x2ピクセル平均によるダウンサンプリング
  - 演算式: `(P00 + P01 + P10 + P11 + 2) >> 2`
- **2ラインバッファ**: 現在行と前行の2行分のCb/Crデータをバッファリングし、2x2ブロック単位で平均値を計算
- **出力タイミング**: Y成分はピクセルごとに出力、Cb/Cr成分は2x2ブロック処理完了時に出力
- **AXI4-Stream I/F**: バックプレッシャ完全対応（`tready`/`tvalid`ハンドシェイク）

---

### 3.4 block_splitter

ラスタ走査順からJPEG 8x8ブロック順への変換モジュール。

#### パラメータ

| パラメータ | 型 | デフォルト | 説明 |
|-----------|-----|-----------|------|
| `IMAGE_WIDTH` | int | 64 | 画像幅（8の倍数、4:2:0時は16の倍数） |
| `IMAGE_HEIGHT` | int | 64 | 画像高さ（8の倍数、4:2:0時は16の倍数） |
| `CHROMA_MODE` | chroma_mode_t | CHROMA_444 | クロマサブサンプリングモード (CHROMA_444 / CHROMA_420) |

#### ポート

| ポート名 | 方向 | 幅 | 説明 |
|---------|------|-----|------|
| `clk` | input | 1 | システムクロック |
| `rst_n` | input | 1 | アクティブLowリセット |
| `s_axis_tdata` | input | 24 | `{Y[23:16], Cb[15:8], Cr[7:0]}` |
| `s_axis_tvalid` | input | 1 | 入力有効 |
| `s_axis_tready` | output | 1 | 入力受付可能 |
| `s_axis_tlast` | input | 1 | 行末マーカ |
| `s_axis_tuser` | input | 2 | `{EOF, SOF}` |
| `m_axis_tdata` | output | 24 | `{Y, Cb, Cr}` ブロック順 |
| `m_axis_tvalid` | output | 1 | 出力有効 |
| `m_axis_tready` | input | 1 | 出力受付可能 |
| `m_axis_tlast` | output | 1 | ブロック終端（64ピクセルごと） |
| `m_axis_tuser` | output | 2 | `{EOF, SOF}` |

#### 内部動作

- **ラインバッファ**: IMAGE_WIDTH x 8行分を格納（4:4:4モード時）
- **ステートマシン**: ST_WRITE（8行充填） → ST_READ（ブロック出力）
- **ブロック順序**: 左→右のブロック列順、次に次の8行ストリップ
- SOF/EOFをライト時にキャプチャし、リード時に伝搬

#### 4:2:0モード時の動作 (block_splitter_420.sv)

4:2:0モードでは専用のblock_splitter_420モジュールを使用する。ダウンサンプリングを内蔵し、16x16 MCU単位でブロック分割を行う。

- **ラインバッファ**: IMAGE_WIDTH x 16行分のYデータ + ダウンサンプリング済みCb/Crバッファ
- **ダウンサンプリング**: 2x2平均法で Cb/Cr をダウンサンプリング（`(P00 + P01 + P10 + P11 + 2) >> 2`）
- **ブロック出力順序**: Y0(左上8x8) → Y1(右上8x8) → Y2(左下8x8) → Y3(右下8x8) → Cb(8x8) → Cr(8x8)
- **ダブルバッファリング**: ピンポンバッファ方式（`wr_sel`/`rd_sel`）により、書込と読出を並行動作。次の16行の書込と現在のMCUブロック読出がオーバーラップ可能
- **パラメータ切り替え**: jpeg_encoder_topが`CHROMA_MODE`パラメータにより使用するblock_splitterを選択
  - `CHROMA_444`: block_splitter.sv（8x8ブロック単位、Y→Cb→Cr 3ブロック/MCU）
  - `CHROMA_420`: block_splitter_420.sv（16x16 MCU、6ブロック/MCU）

---

### 3.5 dct_2d

8x8ブロック2次元離散コサイン変換（Type II）モジュール。

#### ポート

| ポート名 | 方向 | 幅 | 説明 |
|---------|------|-----|------|
| `clk` | input | 1 | システムクロック |
| `rst_n` | input | 1 | アクティブLowリセット |
| `s_axis_tdata` | input | 8 | 8-bit unsigned 単成分ピクセル |
| `s_axis_tvalid` | input | 1 | 入力有効 |
| `s_axis_tready` | output | 1 | 入力受付可能 |
| `s_axis_tlast` | input | 1 | ブロック終端 |
| `s_axis_tuser` | input | 2 | `{EOF, SOF}` |
| `m_axis_tdata` | output | 16 | 16-bit signed DCT係数 |
| `m_axis_tvalid` | output | 1 | 出力有効 |
| `m_axis_tready` | input | 1 | 出力受付可能 |
| `m_axis_tlast` | output | 1 | ブロック終端（係数63） |
| `m_axis_tuser` | output | 2 | `{EOF, SOF}` |

#### 内部動作

- **アーキテクチャ**: 入力 → レベルシフト(-128) → 行方向1D-DCT（8並列乗算+加算ツリー） → 列方向1D-DCT（Col/Output Overlap） → ジグザグ順出力
- **DCT係数**: 14-bit固定小数点（16384倍スケール）
- **8並列乗算**: 各行/列に対して8個の乗算器で並列MAC演算、加算ツリーで集約（Phase 4最適化）
- **ダブルバッファリング**: ピンポンバッファ方式で入力受信と行DCT計算をオーバーラップ（Phase 4最適化）
- **ステートマシン**: ST_IDLE → ST_INPUT (64ピクセル受信) → ST_ROW_DCT (8行×8出力=64係数) → ST_COL_AND_OUTPUT (列DCTと出力を並行、128サイクル)
- **Col/Output Overlap** (Phase 5): 列方向DCTと出力を同一ステートで並行実行。列DCTの計算結果を即座にジグザグ順で出力。ブロック処理時間: 128サイクル/ブロック（定常状態）
- **ジグザグスキャン統合** (Phase 4): DCT出力ステージで`ZIGZAG_ORDER`マッピングに従って係数を読み出すことにより、独立したzigzag_scanモジュールを不要化
- **EOF伝搬**: `saved_eof`レジスタで入力の任意ピクセルからEOFをキャプチャし、最初の出力係数の`tuser`に含めて出力

---

### 3.6 quantizer

DCT係数量子化モジュール。JPEG標準量子化テーブルを使用。

#### ポート

| ポート名 | 方向 | 幅 | 説明 |
|---------|------|-----|------|
| `clk` | input | 1 | システムクロック |
| `rst_n` | input | 1 | アクティブLowリセット |
| `component_id` | input | 2 | コンポーネントID (0=Y, 1=Cb, 2=Cr) |
| `s_axis_tdata` | input | 16 | 16-bit signed DCT係数 |
| `s_axis_tvalid` | input | 1 | 入力有効 |
| `s_axis_tready` | output | 1 | 入力受付可能 |
| `s_axis_tlast` | input | 1 | ブロック終端 |
| `s_axis_tuser` | input | 2 | `{EOF, SOF}` |
| `m_axis_tdata` | output | 12 | 12-bit signed 量子化係数 |
| `m_axis_tvalid` | output | 1 | 出力有効 |
| `m_axis_tready` | input | 1 | 出力受付可能 |
| `m_axis_tlast` | output | 1 | ブロック終端 |
| `m_axis_tuser` | output | 2 | `{EOF, SOF}` |

#### 内部動作

- **テーブル選択**: comp_id=0 → Luma (ITU-T.81 K.1), comp_id=1,2 → Chroma (ITU-T.81 K.2)
- **量子化**: `Q_coeff = DCT_coeff / Q_table[index]` (ゼロ方向への切り捨て)
- **インデックスカウンタ**: 0-63をトラッキング、ブロック境界でリセット

---

### 3.7 zigzag_scan

ジグザグ走査順並べ替えモジュール。

> **注記 (Phase 4以降)**: ジグザグスキャン機能はdct_2dの出力ステージに統合済み。本モジュール (`zigzag_scan.sv`) はRTLとして残存するが、jpeg_encoder_top では使用されない。dct_2dが量子化係数をジグザグ順で直接出力するため、独立したモジュールとしてのインスタンス化は不要。

#### ポート

| ポート名 | 方向 | 幅 | 説明 |
|---------|------|-----|------|
| `clk` | input | 1 | システムクロック |
| `rst_n` | input | 1 | アクティブLowリセット |
| `s_axis_tdata` | input | 12 | 12-bit signed 量子化係数（ラスタ順） |
| `s_axis_tvalid` | input | 1 | 入力有効 |
| `s_axis_tready` | output | 1 | 入力受付可能 |
| `s_axis_tlast` | input | 1 | ブロック終端 |
| `s_axis_tuser` | input | 2 | `{EOF, SOF}` |
| `m_axis_tdata` | output | 12 | 12-bit 係数（ジグザグ順） |
| `m_axis_tvalid` | output | 1 | 出力有効 |
| `m_axis_tready` | input | 1 | 出力受付可能 |
| `m_axis_tlast` | output | 1 | ブロック終端 |
| `m_axis_tuser` | output | 2 | `{EOF, SOF}` |

#### 内部動作

- **バッファ**: 64エントリのブロックバッファ（ラスタ順で格納）
- **ステートマシン**: ST_WRITE (64係数受信) → ST_READ (ジグザグ順出力)
- **アドレスマッピング**: `ZIGZAG_ORDER(rd_cnt)` 関数で読み出しアドレスを生成

---

### 3.8 rle_encoder

ランレングス符号化モジュール。DC DPCM符号化とAC係数のゼロラン符号化を行う。

#### ポート

| ポート名 | 方向 | 幅 | 説明 |
|---------|------|-----|------|
| `clk` | input | 1 | システムクロック |
| `rst_n` | input | 1 | アクティブLowリセット |
| `component_id` | input | 2 | コンポーネントID (DC予測値選択用) |
| `s_axis_tdata` | input | 12 | 12-bit signed 量子化係数（ジグザグ順） |
| `s_axis_tvalid` | input | 1 | 入力有効 |
| `s_axis_tready` | output | 1 | 入力受付可能 |
| `s_axis_tlast` | input | 1 | ブロック終端 |
| `s_axis_tuser` | input | 2 | `{EOF, SOF}` |
| `m_axis_tdata` | output | 16 | `{zero_run[15:12], value[11:0]}` |
| `m_axis_tvalid` | output | 1 | 出力有効 |
| `m_axis_tready` | input | 1 | 出力受付可能 |
| `m_axis_tlast` | output | 1 | ブロック終端（EOBまたは最後のAC） |
| `m_axis_tuser` | output | 2 | `{EOF, SOF}` |

#### 内部動作

- **DC DPCM**: Y/Cb/Cr各成分に独立した前値予測器（SOFでリセット）
- **ACゼロラン**: 連続ゼロをカウントし、(run, value) シンボルを出力
- **ZRLシンボル**: ゼロランが15を超える場合 (15, 0) を出力
- **EOBシンボル**: ブロック残りが全てゼロの場合 (0, 0) を出力
- **ダブルバッファリング** (Phase 5): ピンポンバッファ方式で入力FSM (IN_IDLE/IN_RECEIVE) と出力FSM (OUT_IDLE/OUT_SCAN_AC/OUT_EMIT_EOB) が独立動作。次ブロックの受信と現ブロックのRLE出力をオーバーラップ可能
- **ステートマシン**: 入力側: IN_IDLE → IN_RECEIVE、出力側: OUT_IDLE → OUT_EMIT_DC → OUT_SCAN_AC → OUT_EMIT_ZRL/OUT_EMIT_AC → OUT_EMIT_EOB

---

### 3.9 huffman_encoder

Huffmanエントロピー符号化モジュール。JPEG標準テーブル（4テーブル: DC/AC x Luma/Chroma）を使用。

#### ポート

| ポート名 | 方向 | 幅 | 説明 |
|---------|------|-----|------|
| `clk` | input | 1 | システムクロック |
| `rst_n` | input | 1 | アクティブLowリセット |
| `component_id` | input | 2 | コンポーネントID (テーブル選択) |
| `s_axis_tdata` | input | 16 | `{zero_run[15:12], value[11:0]}` |
| `s_axis_tvalid` | input | 1 | 入力有効 |
| `s_axis_tready` | output | 1 | 入力受付可能 |
| `s_axis_tlast` | input | 1 | ブロック終端 |
| `s_axis_tuser` | input | 2 | `{EOF, SOF}` |
| `m_axis_tdata` | output | 32 | `{code_length[31:27], codeword[26:0]}` |
| `m_axis_tvalid` | output | 1 | 出力有効 |
| `m_axis_tready` | input | 1 | 出力受付可能 |
| `m_axis_tlast` | output | 1 | ブロック終端 |
| `m_axis_tuser` | output | 2 | `{EOF, SOF}` |

#### 内部動作

- **DCエンコーディング**: カテゴリベースのルックアップ + 振幅ビット付加
- **ACエンコーディング**: (run/size) シンボルルックアップ + 振幅ビット付加
- **EOB**: ACシンボル 0x00
- **テーブル選択**: comp_id=0 → Lumaテーブル, comp_id=1,2 → Chromaテーブル
- **負の振幅**: 1の補数でエンコード
- **is_dcフラグ**: ブロック最初のシンボルをDCとして識別、`tlast`でリセットして次ブロックに備える

---

### 3.10 bitstream_assembler

ビットストリーム組立モジュール。可変長Huffman符号語をバイトストリームにパッキングし、JFIFヘッダとバイトスタッフィングを付加。

#### パラメータ

| パラメータ | 型 | デフォルト | 説明 |
|-----------|-----|-----------|------|
| `JFIF_ENABLE` | int | 1 | JFIFヘッダ生成の有効/無効 |
| `IMAGE_WIDTH` | int | 8 | ヘッダに記録する画像幅 |
| `IMAGE_HEIGHT` | int | 8 | ヘッダに記録する画像高さ |
| `NUM_COMPONENTS` | int | 1 | コンポーネント数 (1 or 3) |
| `CHROMA_MODE` | chroma_mode_t | CHROMA_444 | クロマサブサンプリングモード (CHROMA_444 / CHROMA_420) |

#### ポート

| ポート名 | 方向 | 幅 | 説明 |
|---------|------|-----|------|
| `clk` | input | 1 | システムクロック |
| `rst_n` | input | 1 | アクティブLowリセット |
| `s_axis_tdata` | input | 32 | `{codeword[31:5], code_length[4:0]}` |
| `s_axis_tvalid` | input | 1 | 入力有効 |
| `s_axis_tready` | output | 1 | 入力受付可能 |
| `s_axis_tlast` | input | 1 | ブロック終端 |
| `s_axis_tuser` | input | 2 | `{EOF, SOF}` |
| `m_axis_tdata` | output | 8 | JPEGバイトストリーム |
| `m_axis_tvalid` | output | 1 | 出力有効 |
| `m_axis_tready` | input | 1 | 出力受付可能 |
| `m_axis_tlast` | output | 1 | JPEGファイル終端 |
| `m_axis_tuser` | output | 2 | `{EOF, SOF}` |

#### 内部動作

- **ビットアキュムレータ**: 64-bitシフトレジスタでビットパッキング
- **バイトスタッフィング**: エントロピーデータ中の 0xFF の後に 0x00 を挿入
- **JFIFヘッダ生成**: SOF受信時に以下のマーカーを順次出力
  - SOI (0xFFD8) → APP0 (JFIF) → DQT (Luma量子化テーブル) → DQT (Chroma量子化テーブル, 3成分時) → SOF0 → DHT (4テーブル) → SOS
- **EOF処理**: 残余ビットを1でパディングし、EOIマーカー (0xFFD9) を出力

#### 4:2:0モード時のSOF0ヘッダ

`CHROMA_MODE=CHROMA_420` の場合、SOF0ヘッダのコンポーネント定義が以下のように変更される:

| 成分 | コンポーネントID | サンプリングファクタ | バイト値 | 量子化テーブル |
|------|----------------|-------------------|---------|---------------|
| Y | 1 | H=2, V=2 | 0x22 | テーブル0 |
| Cb | 2 | H=1, V=1 | 0x11 | テーブル1 |
| Cr | 3 | H=1, V=1 | 0x11 | テーブル1 |

#### 入力フォーマット変換

jpeg_encoder_top のグルーロジックで以下の変換を行う:
```
Huffman出力:  {code_length[31:27], codeword[26:0]}
BSA入力:      {codeword[31:5], code_length[4:0]}
変換:         bsa_in_tdata = {huff_tdata[26:0], huff_tdata[31:27]}
```

---

### 3.11 block_distributor

Dual Processingパイプライン用ブロック分配モジュール。1系統の入力ストリームを2系統に交互分配する（1→2 AXI4-Stream demux）。

#### ポート

| ポート名 | 方向 | 幅 | 説明 |
|---------|------|-----|------|
| `clk` | input | 1 | システムクロック |
| `rst_n` | input | 1 | アクティブLowリセット |
| `s_axis_tdata` | input | 8 | 8-bit 単成分ピクセル |
| `s_axis_tvalid` | input | 1 | 入力有効 |
| `s_axis_tready` | output | 1 | 入力受付可能 |
| `s_axis_tlast` | input | 1 | ブロック終端 |
| `s_axis_tuser` | input | 2 | `{EOF, SOF}` |
| `m_axis_a_tdata` | output | 8 | Pipeline A 出力データ |
| `m_axis_a_tvalid` | output | 1 | Pipeline A 出力有効 |
| `m_axis_a_tready` | input | 1 | Pipeline A 受付可能 |
| `m_axis_a_tlast` | output | 1 | Pipeline A ブロック終端 |
| `m_axis_a_tuser` | output | 2 | Pipeline A `{EOF, SOF}` |
| `m_axis_b_tdata` | output | 8 | Pipeline B 出力データ |
| `m_axis_b_tvalid` | output | 1 | Pipeline B 出力有効 |
| `m_axis_b_tready` | input | 1 | Pipeline B 受付可能 |
| `m_axis_b_tlast` | output | 1 | Pipeline B ブロック終端 |
| `m_axis_b_tuser` | output | 2 | Pipeline B `{EOF, SOF}` |

#### 内部動作

- **ブロック交互分配**: `sel`レジスタで分配先を管理。`tlast`検出で `sel` をトグルし、次ブロックを反対側のパイプラインへ分配
- **SOF分配**: SOFの付いた最初のブロックはPipeline Aに送出
- **バックプレッシャ**: 選択されたパイプラインの`tready`を入力側に伝搬。非選択側パイプラインの`tvalid`は常に0

---

### 3.12 output_merger

Dual Processingパイプラインの出力マージモジュール。2系統の量子化係数ストリームをブロック順序を維持しながら1系統にマージする（2→1 merge）。

#### パラメータ

| パラメータ | 型 | デフォルト | 説明 |
|-----------|-----|-----------|------|
| `DATA_WIDTH` | int | 12 | データ幅 |
| `FIFO_DEPTH` | int | 192 | 各パイプライン用FIFOの深さ（3ブロック分） |

#### ポート

| ポート名 | 方向 | 幅 | 説明 |
|---------|------|-----|------|
| `clk` | input | 1 | システムクロック |
| `rst_n` | input | 1 | アクティブLowリセット |
| `s_axis_a_tdata` | input | DATA_WIDTH | Pipeline A 入力データ |
| `s_axis_a_tvalid` | input | 1 | Pipeline A 入力有効 |
| `s_axis_a_tready` | output | 1 | Pipeline A 受付可能 |
| `s_axis_a_tlast` | input | 1 | Pipeline A ブロック終端 |
| `s_axis_a_tuser` | input | 2 | Pipeline A `{EOF, SOF}` |
| `s_axis_b_tdata` | input | DATA_WIDTH | Pipeline B 入力データ |
| `s_axis_b_tvalid` | input | 1 | Pipeline B 入力有効 |
| `s_axis_b_tready` | output | 1 | Pipeline B 受付可能 |
| `s_axis_b_tlast` | input | 1 | Pipeline B ブロック終端 |
| `s_axis_b_tuser` | input | 2 | Pipeline B `{EOF, SOF}` |
| `m_axis_tdata` | output | DATA_WIDTH | マージ出力データ |
| `m_axis_tvalid` | output | 1 | マージ出力有効 |
| `m_axis_tready` | input | 1 | マージ出力受付可能 |
| `m_axis_tlast` | output | 1 | ブロック終端 |
| `m_axis_tuser` | output | 2 | `{EOF, SOF}` |

#### 内部動作

- **Dual FIFO**: Pipeline A/B それぞれに深さ192エントリ（3ブロック分=192係数）のFIFOを内蔵。各エントリはデータ+tlast+tuserを含む
- **ブロック単位アービトレーション**: `rd_sel`で読み出し元を管理。A→B→A→B の順で交互にブロック全体（64係数）を読み出し
- **tlast検出**: 出力側で`tlast`を検出したら`rd_sel`をトグルし、次ブロックを反対側FIFOから読み出し
- **バックプレッシャ**: FIFOフルで入力側に`tready=0`を返す。FIFOエンプティで出力側に`tvalid=0`を返す
- **ブロック順序保証**: block_distributorがA→B→A→B順に分配し、output_mergerが同じ順序で読み出すことで、元のブロック順序を正確に復元

---

## 4. パッケージ (jpeg_encoder_pkg.sv)

### 4.1 定数定義

#### 画像パラメータ
| 定数名 | 値 | 説明 |
|--------|-----|------|
| `MAX_IMAGE_WIDTH` | 4096 | 最大画像幅 |
| `MAX_IMAGE_HEIGHT` | 4096 | 最大画像高さ |
| `BLOCK_SIZE` | 8 | DCTブロックサイズ |
| `BLOCK_PIXELS` | 64 | 1ブロックのピクセル数 |
| `NUM_COMPONENTS` | 3 | 最大コンポーネント数 |

#### 4:2:0用定数
| 定数名 | 値 | 説明 |
|--------|-----|------|
| `BLOCKS_PER_MCU_420` | 6 | 4:2:0モード時の1MCUあたりブロック数 |
| `MCU_WIDTH_420` | 16 | 4:2:0モード時のMCU幅（ピクセル） |
| `MCU_HEIGHT_420` | 16 | 4:2:0モード時のMCU高さ（ピクセル） |

#### データ幅パラメータ
| 定数名 | 値 | 説明 |
|--------|-----|------|
| `PIXEL_WIDTH` | 8 | ピクセルビット幅 |
| `RGB_DATA_WIDTH` | 32 | RGB入力幅 (A8R8G8B8) |
| `YCBCR_DATA_WIDTH` | 24 | YCbCr幅 |
| `DCT_COEFF_WIDTH` | 12 | DCT係数幅 |
| `QUANT_COEFF_WIDTH` | 12 | 量子化係数幅 |
| `RLE_DATA_WIDTH` | 24 | RLEデータ幅 |
| `HUFF_DATA_WIDTH` | 32 | Huffmanデータ幅 |
| `STREAM_DATA_WIDTH` | 8 | 出力ストリーム幅 |

### 4.2 型定義

```systemverilog
typedef enum logic [1:0] {
    COMP_Y  = 2'd0,     // 輝度（Y）
    COMP_CB = 2'd1,     // 色差（Cb）
    COMP_CR = 2'd2      // 色差（Cr）
} component_id_t;

typedef enum logic {
    CHROMA_444 = 1'b0,  // 4:4:4 クロマサブサンプリングなし
    CHROMA_420 = 1'b1   // 4:2:0 クロマサブサンプリング
} chroma_mode_t;
```

### 4.3 関数

| 関数名 | 説明 |
|--------|------|
| `QUANT_TABLE_LUMA(idx)` | 輝度量子化テーブル値の取得 (ITU-T.81 K.1) |
| `QUANT_TABLE_CHROMA(idx)` | 色差量子化テーブル値の取得 (ITU-T.81 K.2) |
| `ZIGZAG_ORDER(idx)` | ジグザグ走査順マッピングの取得 |
| `DC_HUFF_LUMA(cat)` | 輝度DC Huffmanテーブル（カテゴリ0-11） |
| `DC_HUFF_CHROMA(cat)` | 色差DC Huffmanテーブル（カテゴリ0-11） |
| `AC_LUMA_BITS(idx)` | 輝度AC Huffman BITS配列 |
| `AC_LUMA_HUFFVAL(idx)` | 輝度AC Huffman HUFFVAL配列 |
| `AC_CHROMA_BITS(idx)` | 色差AC Huffman BITS配列 |
| `AC_CHROMA_HUFFVAL(idx)` | 色差AC Huffman HUFFVAL配列 |
| `get_category(value)` | 係数値からJPEGカテゴリ（0-11）を算出 |
| `get_amplitude_bits(value, cat)` | 振幅を追加ビットとしてエンコード |
| `build_huff_table_entry(...)` | BITS/HUFFVALからAC Huffmanテーブルエントリを構築 |

---

## 5. JFIFヘッダ構造

bitstream_assemblerが生成するJFIFヘッダの構成:

```
SOI マーカー            [0xFFD8]
APP0 (JFIF)            [0xFFE0] + JFIF識別子、バージョン1.01、72DPI
DQT (輝度テーブル)      [0xFFDB] + テーブルID=0、64値（ジグザグ順）
DQT (色差テーブル)      [0xFFDB] + テーブルID=1、64値（3成分モード時のみ）
SOF0                    [0xFFC0] + 8bit精度、画像サイズ、コンポーネント定義
DHT (輝度DC)            [0xFFC4] + クラス=0、ID=0、BITS/HUFFVAL
DHT (輝度AC)            [0xFFC4] + クラス=1、ID=0、BITS/HUFFVAL
DHT (色差DC)            [0xFFC4] + クラス=0、ID=1、BITS/HUFFVAL（3成分モード時）
DHT (色差AC)            [0xFFC4] + クラス=1、ID=1、BITS/HUFFVAL（3成分モード時）
SOS                     [0xFFDA] + スキャンヘッダ
[エントロピーデータ]     バイトスタッフィング付き
EOI マーカー            [0xFFD9]
```

### SOF0コンポーネント定義

#### 4:4:4モード (CHROMA_444)

| 成分 | コンポーネントID | サンプリングファクタ | バイト値 | 量子化テーブル |
|------|----------------|-------------------|---------|---------------|
| Y | 1 | H=1, V=1 | 0x11 | テーブル0 |
| Cb | 2 | H=1, V=1 | 0x11 | テーブル1 |
| Cr | 3 | H=1, V=1 | 0x11 | テーブル1 |

#### 4:2:0モード (CHROMA_420)

| 成分 | コンポーネントID | サンプリングファクタ | バイト値 | 量子化テーブル |
|------|----------------|-------------------|---------|---------------|
| Y | 1 | H=2, V=2 | 0x22 | テーブル0 |
| Cb | 2 | H=1, V=1 | 0x11 | テーブル1 |
| Cr | 3 | H=1, V=1 | 0x11 | テーブル1 |

### SOSテーブル割り当て

| 成分 | DC Huffmanテーブル | AC Huffmanテーブル |
|------|-------------------|-------------------|
| Y | テーブル0 | テーブル0 |
| Cb | テーブル1 | テーブル1 |
| Cr | テーブル1 | テーブル1 |

---

## 6. 検証結果

### 6.1 ユニットテスト

| モジュール | テスト数 | 結果 |
|-----------|---------|------|
| rgb2ycbcr | 4 | ALL PASS |
| dct_2d | 4 | ALL PASS |
| quantizer | 4 | ALL PASS |
| zigzag_scan | 4 | ALL PASS |
| rle_encoder | 5 | ALL PASS |
| huffman_encoder | 4 | ALL PASS |
| block_splitter | 6 | ALL PASS |
| bitstream_assembler | 4 | ALL PASS |
| jpeg_encoder_top | 11 | ALL PASS |
| block_splitter_420 | 6 | ALL PASS |
| bitstream_assembler_420 | 2 | ALL PASS |
| jpeg_encoder_top_420 | 5 | ALL PASS |
| **合計** | **59** | **ALL PASS** |

### 6.2 BMP入力画質テスト

| テスト画像 | MaxDiff | MeanDiff | PSNR |
|-----------|---------|----------|------|
| 8x8 gradient | 18 | 5.08 | 32.0 dB |
| 8x8 white | 1 | 1.00 | 48.1 dB |
| 16x16 gradient | 15 | 3.55 | 34.8 dB |
| 32x32 gradient | 10 | 2.67 | 37.6 dB |
| 64x64 gradient | 10 | 2.46 | 38.4 dB |

全テストでMaxDiff ≤ 18（JPEG Q50の量子化誤差範囲内）、PSNR 32.0～48.1 dB（標準的なJPEG品質）。
