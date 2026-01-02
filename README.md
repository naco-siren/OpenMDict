# MDictPOC

MDict MDX/MDD Parser - Proof of Concept

## 项目结构

```
MDictPOC/
├── Package.swift           # Swift Package 配置
├── Sources/
│   ├── CLZ/               # C 代码 (miniLZO)
│   │   ├── include/
│   │   │   ├── lzoconf.h
│   │   │   ├── minilzo.h
│   │   │   └── module.modulemap
│   │   └── minilzo.c
│   └── MDict/             # Swift 代码
│       ├── main.swift          # CLI 入口
│       ├── BinaryReader.swift  # 二进制读取
│       ├── Decompressor.swift  # zlib/LZO 解压
│       ├── RIPEMD128.swift     # 加密解密
│       └── MDictReader.swift   # 主解析器
└── README.md
```

## 编译运行

```bash
cd MDictPOC

# 编译
swift build

# 运行 - 查看字典信息
swift run mdict-poc /path/to/MyDict.mdx

# 查词
swift run mdict-poc /path/to/MyDict.mdx lookup hello

# 前缀搜索
swift run mdict-poc /path/to/MyDict.mdx search happ

# 列出词条
swift run mdict-poc /path/to/MyDict.mdx list 50
```

## 支持情况

| 特性 | 状态 |
|------|------|
| MDX v2.0 | ✅ 支持 |
| MDX v1.2 | ⚠️ 部分支持 |
| MDX v3.0 | ❌ 不支持 |
| zlib 压缩 | ✅ 支持 |
| LZO 压缩 | ✅ 支持 |
| Encrypted=0 | ✅ 支持 |
| Encrypted=2 | ✅ 支持 (自动解密) |
| Encrypted=1,3 | ❌ DRM 不支持 |
| MDD 资源 | 🚧 待实现 |

## 已知限制

1. **DRM 加密 (Encrypted=1 或 3)**：需要用户提供密钥，暂不支持
2. **v3.0 格式**：MdxBuilder 4.x 产生的新格式，结构不同
3. **Record Block 缓存**：当前每次 lookup 都重新读取，未做缓存

## 技术笔记

### MDX 文件结构

```
┌─ Header Section ─────────────┐
│  4 bytes: header_length (BE) │
│  N bytes: XML (UTF-16LE)     │
│  4 bytes: adler32 checksum   │
├─ Keyword Section ────────────┤
│  Summary (40 bytes for v2)   │
│  Keyword Index (compressed)  │
│  Keyword Blocks (compressed) │
├─ Record Section ─────────────┤
│  Summary                     │
│  Record Blocks (compressed)  │
└──────────────────────────────┘
```

### 压缩格式

每个压缩块的结构：
- 4 bytes: compression type (0=none, 1=LZO, 2=zlib)
- 4 bytes: adler32 checksum (BE)
- N bytes: compressed data

### 加密

**Encrypted=2 (Index Encryption)**:
- 只加密 keyword index 块
- 密钥从 checksum 派生: `key = ripemd128(checksum + "\x95\x36\x00\x00")`
- 解密算法: nibble swap + XOR chain

## License

MIT (仅限本 POC 代码)

LZO 库: GPLv2 (原作者 Markus F.X.J. Oberhumer)
