# Bundled Dictionary Formatting Standard

本文档定义了所有预设词典的 HTML 格式规范，确保各词典在 OpenMDict 中显示风格一致。

---

## 1. 共享 CSS 设计系统

所有词典共用以下 CSS 类名和配色。每条 MDX entry 的 HTML 以 `<style>` 块开头，包裹在 `<div class="e">` 中。

### 1.1 基础容器

| 类名 | 用途 | 样式 |
|------|------|------|
| `.e` | 词条根容器 | `max-width:600px; line-height:1.5; padding:0 12px` |
| `.dir` | 语言方向标签 (e.g. 🇬🇧🇺🇸 English) | `0.8em; color:#8e8e93; border-bottom` |
| `.hw` | 词头 (headword) | `1.7em; font-weight:600; display:block` |

### 1.2 语法信息

| 类名 | 用途 | 样式 |
|------|------|------|
| `.pr` | 发音 (pronunciation) | `1.1em; color:#0071e3; italic; display:block` |
| `.et` | 词源 (etymology) | `0.85em; color:#6e6e73; display:block` |
| `.pos` | **词性徽章** (POS badge) | `0.85em; white on #aeaeb2; border-radius:3px; padding:0 5px` |
| `.mk` | 用法/标记徽章 (mark/usage) | `0.75em; #636366 on #e8e8ed; border-radius:3px` |
| `.inf` | 词形信息 (inflection/declension) | `0.95em; color:#6e6e73; display:block; margin-top:2px` |

### 1.3 释义区

| 类名 | 用途 | 样式 |
|------|------|------|
| `.sn` | 义项卡片 (sense card) | `padding:8px 10px; bg:#f8f8fa; border-radius:6px; border:1px solid #e5e5ea` |
| `.sn-hd` | 义项标题行 (sense header) | `display:flex; flex-wrap:wrap; align-items:center; gap:4px` |
| `.sn-n` / `.sn-num` | 义项序号 | `0.85em; font-weight:700; color:#8e8e93` |
| `.df` | 释义文本 (definition) | `1.1em; font-style:normal` — **释义正文永远不用斜体** |
| `.tr` | 翻译关键词 (translation) | `font-weight:600` (bold) |

### 1.4 例句与引用

| 类名 | 用途 | 样式 |
|------|------|------|
| `.ex` | 例句块 | `0.85em; color:#6e6e73; border-left:3px solid #d1d1d6; padding-left:10px` |
| `.ex-q` | 例句引文 | `font-style:italic` |
| `.ex-a` | 例句出处 (attribution) | `text-align:right; color:#8e8e93` |

### 1.5 交叉引用与特殊

| 类名 | 用途 | 样式 |
|------|------|------|
| `.syn` | 同义词 | `0.85em; color:#636366` |
| `.xr a` | 交叉引用链接 | `color:#0071e3; text-decoration:underline` |
| `.grk` | 希腊文 (Greek text) | `color:#636366` — **不用斜体，希腊字母本身已能区分** |
| `.sep` | 分隔线 | `border-top:1px solid #e5e5ea` |

### 1.6 Dark Mode

所有类均提供 `@media(prefers-color-scheme:dark)` 变体：
- `.e` → `color:#f5f5f7`
- `.sn` → `bg:#2c2c2e; border-color:#38383a`
- `.pos` → `bg:#636366`
- `.grk` → `color:#98989d`
- `.ex` → `color:#98989d; border-color:#48484a`
- `.xr a` → `color:#64d2ff`

---

## 2. 词条结构标准

### 2.1 通用结构 (所有词典)

```
┌─ .dir ─────────────────────┐  语言方向标签
├─ .hw ──────────────────────┤  词头
├─ .pr  (可选)                │  发音
├─ .et  (可选)                │  词源
├─ .pos badge(s) (可选)       │  词性徽章
├─ .inf (可选)                │  词形/变位信息
├─ .sn ──────────────────────┤  义项卡片 ×N
│  ├─ .sn-hd                  │   标题行
│  │  ├─ .pos (义项级别)       │    词性徽章
│  │  ├─ .mk (用法标记)        │    标记徽章
│  │  └─ .sn-n (序号)         │    义项序号
│  ├─ .df                     │   释义文本
│  └─ .ex (可选)              │   例句
├─ .syn (可选)                │  同义词
└─ .xr  (可选)                │  交叉引用
```

### 2.2 义项序号规范

| 类型 | 序号格式 | 显示方式 | 适用词典 |
|------|---------|---------|---------|
| 数字编号 | 1, 2, 3... | `.mk` 徽章 | GCIDE, WordNet, FreeDict, Kaikki, WikDict |
| 分层编号 | I, II, A, B, 1, 2, a, b | `.sn-num` 文本 | Lewis-Short, LSJ |
| 无编号 | — | 省略 `.sn-hd` | 单义项词条 |

### 2.3 词性 (POS) 显示规范

**规则：词性必须显示为 `.pos` 徽章，而非纯文本。**

| 位置 | 说明 | 示例 |
|------|------|------|
| 词条级别 | 整个词条只有一个词性时，放在 `.hw` 下方 | Lewis-Short: `ămo` → `[v. a.]` |
| 义项级别 | 不同义项有不同词性时，放在 `.sn-hd` 中 | GCIDE: `abandon` → 义项1 `[v. t.]`，义项6 `[n.]` |
| 双重 | 词条级别提供默认词性，义项级别可覆盖 | 少数复杂词条 |

---

## 3. 各类型词典特殊规范

### 3.1 英语单语 (GCIDE, WordNet, Moby Thesaurus)

**参考标准** — 其他词典应对齐此格式。

- `.dir`: `🇬🇧🇺🇸 English`
- `.pr`: 音标用蓝色斜体
- `.et`: 词源用灰色小字
- `.pos`: 义项级别 `.pos` 徽章 (v. t., n., a., adv. 等)
- `.mk`: 序号 + 用法标记 ([Obs.], [Colloq.] 等)
- `.df`: 正文 — **正体 (roman)**，不加斜体
- `.ex`: 例句 — 引文斜体，出处右对齐
- `.syn`: 同义词列表

### 3.2 双语词典 (FreeDict, Kaikki, WikDict, Wiktionary)

- `.dir`: `🇪🇸 Español → English 🇬🇧🇺🇸`
- `.pos`: 义项级别 `.pos` 徽章
- `.dm`: 领域标记 (domain, topic) — 同 `.mk` 样式
- `.df`: 翻译释义 — 正体
- `.ex-src`: 源语言例句
- `.ex-tr`: 目标语言翻译
- RTL 支持：阿拉伯语词头使用 `dir="rtl"`

### 3.3 古典语言词典 (LSJ, Lewis-Short)

Perseus TEI XML 源数据有特殊处理需求：

#### 3.3.1 斜体规则 — 核心原则：**释义正文 `.df` 不应全斜体**

| 元素 | 处理方式 | 说明 |
|------|---------|------|
| `<tr>` | `<b>bold</b>` | 翻译核心词 → 加粗 |
| `<foreign lang="greek">` | `<span class="grk">unicode</span>` | 希腊文 → 转码+着色，**不加斜体** |
| `<hi rend="ital">` | 正体文本 (不加 `<i>`) | 原版用斜体标注翻译/拉丁词，但在数字格式中不需要 |
| `<cit>/<quote>` | `"引文" (出处)` | 引用例句 → 引号+正体（古典词典引文太多，斜体会导致全篇斜体） |
| `<foreign>` (非希腊) | `<i>text</i>` | 其他外语 → 斜体 |

#### 3.3.2 Beta Code (仅 LSJ)

LSJ 的源数据使用 Perseus beta code 编码希腊文。必须全部转为 Unicode：
- 正文 `<sense>` 内容 → `elem_to_html()` 自动转换 `<foreign lang="greek">`
- `<cit>/<quote>` 引文 → 也需转换（引文中也有 beta code）
- `.sub` 行 (冠词/语法) → 也需转换 (e.g. `o(` → `ὁ`, `h(` → `ἡ`)

#### 3.3.3 词性与语法信息

**Lewis-Short:**
```html
<span class="hw">ămo</span>
<span class="pos">v. a.</span>
<span class="inf">āvi, ātum, 1</span>
```

**LSJ:**
```html
<span class="hw">ἀνήρ</span>
<span class="inf">ὁ, ἀνδρός</span>
```
LSJ 多数词条无明确 `<pos>` 标签，语法信息（冠词、词形）显示为 `.inf`。

#### 3.3.4 义项序号

使用 `.sn-num` 显示分层编号（I, II, A, B, 1, 2, a, b），保留原始层级结构。

### 3.4 CJK 词典 (CEDICT, JMdict, KANJIDIC2, Unihan, CC-Canto)

各词典有独特的显示需求（拼音、假名、笔画、部首等），使用 `CJK_READING_TAGS` 扩展中的共享类名。

#### 3.4.1 Reading Tag 样式

所有 CJK reading 使用 `.tag` 系列类名（`tag-on`, `tag-kun`, `tag-py`, `tag-ko`, `tag-vi`），渲染为圆角色块。

#### 3.4.2 假名/谚文 Paired Romaji 格式

KANJIDIC2 和 Unihan 的日语/韩语 reading 统一使用 **paired 格式**，在同一个 tag 内同时显示原文和罗马字：

| reading 类型 | 格式 | 示例 |
|-------------|------|------|
| 音読み (ON) | `<span class="tag tag-on">カタカナ romaji</span>` | `ニチ nichi` |
| 訓読み (KUN) | `<span class="tag tag-kun">ひらがな romaji</span>` | `た.べる ta.beru` |
| 한국 (Korean) | `<span class="tag tag-ko">한글 romaji</span>` | `일 il` |

- **KANJIDIC2**: 假名→罗马字使用 `shared/html.py` 的 `kana_to_romaji()`；训读保留送假名标记 (`.`, `-`)
- **Unihan**: 源数据本身是罗马字 (`kJapaneseOn`, `kJapaneseKun`)，转换为假名后与原始罗马字配对；韩语将 `kHangul`（去除 source suffix）与 `kKorean` 按位置配对
- **JMdict**: 假名后附罗马字 (Hepburn)，另有 Kanjium 音高重音标注

#### 3.4.3 拼音/粤拼

CEDICT 和 CC-Canto 使用 `.tag-py` 类显示拼音/粤拼声调，无 paired 格式需求。

### 3.5 圣经 (Bible)

使用经节结构而非义项结构，专属类名（`.sn-n` 经文编号），不套用通用标准。

---

## 4. 国旗 Emoji 规范

为避免政治敏感，使用多国旗表示语言覆盖范围：

| 语言 | 国旗 | 说明 |
|------|------|------|
| English | 🇬🇧🇺🇸 | 英国+美国（势均力敌） |
| Chinese | 🇨🇳🇹🇼 | 中国大陆+台湾（势均力敌） |
| Portuguese | 🇵🇹🇧🇷 | 葡萄牙+巴西（势均力敌） |
| Cantonese | 🇭🇰🇨🇳 | 香港+中国大陆（势均力敌） |
| Spanish | 🇪🇸 | 仅母国西班牙（拉丁美洲不放） |
| French | 🇫🇷 | 仅母国法国 |
| German | 🇩🇪 | 仅母国德国 |
| Arabic | 🇸🇦 | 仅沙特阿拉伯 |
| CJK (Unihan) | 🇨🇳🇹🇼🇭🇰🇯🇵🇰🇷 | 中日韩（漢字共用字符集） |
| Ancient Greek | 🇬🇷 | 希腊 |
| Latin | 🏛️ | 罗马柱（象征符号） |
| 其他 (JA/KO/RU/IT/TR/EL) | 单一国旗 | 语言≈单一国家时可用 |

**双旗原则**：仅在两国"势均力敌"（如英美、葡巴、陆台）时使用双国旗。若一国为明确母国（如西班牙语→西班牙），则仅用母国国旗，不放其他使用该语言的国家。

---

## 5. 构建验证清单

每个新词典构建后需验证：

1. Build 脚本无错误运行
2. MDX 文件可正确打开（抽检词条）
3. `preset-dictionaries.json` 中的 `sizeBytes` 与实际文件大小一致
4. Preview HTML 正确渲染（词头、词性徽章、释义、例句均正常显示）
5. **释义正文 `.df` 不应全斜体** — 目视检查
6. **所有 POS 显示为 `.pos` 徽章** — 不使用纯文本灰字
7. Dark mode 下配色正常

---

## 6. 共享 CSS 模块 (`scripts/shared/`)

所有 CSS 规则的 **单一真相来源 (single source of truth)** 位于 `scripts/shared/theme.py`。不再在各脚本中复制 CSS 块。

### 6.1 模块结构

```
scripts/shared/
  __init__.py      # 导出: esc, get_css, pack_mdx, generate_preview
  theme.py         # Layer 1: CSS 组合系统 (core + extensions + presets)
  html.py          # Layer 2: HTML 工具函数 (esc, wrap_entry, kana_to_romaji 等)
  build.py         # Layer 3: 构建工具 (pack_mdx, generate_preview, write_mdict_source)
```

### 6.2 CSS 组合 API

```python
from shared.theme import get_css, PRONUNCIATION, EXAMPLES, SYNONYMS

# 使用命名扩展
CSS = get_css(PRONUNCIATION, EXAMPLES, SYNONYMS)

# 使用预设
CSS = get_css(*BILINGUAL)

# 带脚本特有样式
CSS = get_css(*BILINGUAL, extra_light='.alt{color:#6e6e73}', extra_dark='.alt{color:#98989d}')
```

**Core 规则** (自动包含): `.e`, `.dir`, `.hw`, `.sn`, `.sn+.sn`, `.sn-hd`, `.pos`, `.mk`, `.sep`

**命名扩展** (按需选用):

| 扩展名 | 类名 | 适用词典 |
|--------|------|---------|
| `PRONUNCIATION` | `.pr` | GCIDE, WordNet |
| `ETYMOLOGY` | `.et` | GCIDE |
| `INFLECTION` | `.inf` | Perseus, GCIDE |
| `DEFINITION` | `.df`, `.tr` | GCIDE, Perseus |
| `SENSE_NUMBER` | `.sn-num` | Perseus |
| `SENSE_NUMBER_INLINE` | `.sn-n` | WordNet, Bible |
| `EXAMPLES` | `.ex`, `.ex-q`, `.ex-a` | GCIDE, WordNet, Perseus |
| `EXAMPLES_BILINGUAL` | `.ex`, `.ex-src`, `.ex-tr` | Kaikki, FreeDict |
| `SYNONYMS` | `.syn` | GCIDE |
| `CROSSREF` | `.xr a` | GCIDE, Perseus |
| `GREEK_TEXT` | `.grk` | Perseus |
| `DOMAIN_BADGE` | `.dm` | Kaikki, FreeDict |
| `TAG_BADGE` | `.tg` | Kaikki |
| `GLOSS` | `.gl` | Kaikki, FreeDict, Wiktionary |
| `ORDERED_LIST` | `.d`, `.d li`, `.d a` | CEDICT, CC-Canto, WikDict |
| `ROMANIZATION` | `.rm` | Kaikki |
| `NESTED_SENSES` | `.sn .sn` | Perseus |
| `CJK_READING_TAGS` | `.tag`, `.tag-on/kun/py/ko/vi` | JMdict, KANJIDIC2, Unihan |

**预设 (Presets)**:
- `WESTERN_MONO` = PRONUNCIATION + ETYMOLOGY + DEFINITION + EXAMPLES + SYNONYMS + CROSSREF
- `BILINGUAL` = GLOSS + ORDERED_LIST + DOMAIN_BADGE + TAG_BADGE + EXAMPLES_BILINGUAL
- `CLASSICAL` = INFLECTION + DEFINITION + SENSE_NUMBER + EXAMPLES + GREEK_TEXT + CROSSREF + NESTED_SENSES

### 6.3 构建工具 API

```python
from shared.html import esc                    # HTML 转义 (&, <, >)
from shared.html import kana_to_romaji         # 假名→罗马字 (Hepburn)
from shared.html import split_morae            # 假名→mora 分割
from shared.build import pack_mdx              # 打包 MDX (title, desc, entries → .mdx)
from shared.build import generate_preview      # 生成预览 HTML
from shared.build import write_mdict_source    # 写入 MDict 源文本
```

### 6.4 新词典开发模板

```python
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR))

from shared.theme import get_css, PRONUNCIATION, DEFINITION, EXAMPLES
from shared.html import esc
from shared.build import pack_mdx, generate_preview

CSS = get_css(PRONUNCIATION, DEFINITION, EXAMPLES)
# 或: CSS = get_css(*WESTERN_MONO)
# 或带自定义: CSS = get_css(DEFINITION, extra_light='.custom{...}', extra_dark='.custom{...}')
```
