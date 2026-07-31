# Design: static-build-ffmpeg workflow

- **Date:** 2026-07-31
- **Author:** daniel
- **Status:** Approved (Approach B — see revision below)
- **Related:** `.github/workflows/static-build-rsync.yml`(参考模板)

## 0. 修订记录

**2026-07-31 — 改为方案 B(全量从源码编译)。** 原方案 A(用 Alpine `-dev` 静态包)经实测不可行:Alpine 不为所有库提供静态归档 `.a`(`libass` 完全没有 `.a`,既无 `libass-static` 子包,`libass-dev` 也不含 `.a`;freetype/harfbuzz/fontconfig 等虽有 `-static` 子包,但 `harfbuzz` 的传递依赖 glib→pcre2/util-linux/libffi 静态链不可靠)。`ffmpeg` 的 `require_pkg_config` 是"编译+静态链接"测试,任何缺失的 `.a` 都会让 `--enable-libX` 配置失败(CI 实测在 `libass` 处报 `not found using pkg-config`)。改为**全部编解码/文本渲染库从源码编译为静态归档**到 `/opt/ff`,使静态链接链自洽(与 johnvansickle 静态 ffmpeg 一致)。构建脚本:`scripts/build-ffmpeg-static.sh`。

## 1. 目标

新增一个 GitHub Actions workflow,在 CI 中**从源码静态编译 ffmpeg**(Linux amd64),产物为完全静态链接的 `ffmpeg` / `ffprobe` 二进制 + SHA256 校验,作为 artifact 上传。形态上对齐现有的 `static-build-rsync.yml`(手动触发、Alpine 容器、从源码编译、静态链接、打包上传)。

## 2. 关键决策(brainstorming 结论)

| 维度 | 决策 |
|---|---|
| 功能档位 | **标准 GPL 构建**(从源码编译 ffmpeg,编解码库用 Alpine 静态包提供) |
| 编解码/功能库 | x264、x265、libvpx、aom(AV1)、libmp3lame、libopus、libvorbis、libtheora、libwebp、libass、freetype |
| 不含 | fdk-aac(non-free),故**不**设 `--enable-nonfree`;产物许可为 **GPL** |
| 架构 | 仅 amd64(与 rsync 一致),artifact 名 `ffmpeg-linux-amd64-static` |
| 构建方式 | **方案 B**:单阶段 `alpine:3.20` 容器,**全部编解码/文本渲染库从源码编译为静态归档**到 `/opt/ff`,再编译 ffmpeg 本体(见 `scripts/build-ffmpeg-static.sh`)。apk 仅用于安装构建工具链 |
| ffmpeg 版本 | 固定 **8.1.2 "Hoare"**(2026-06-17,当前最新稳定版),workflow 顶部用 `env.VERSION` 变量便于升级 |

## 3. 不做(YAGNI)

- 不构建 arm64(后续可加 matrix)。
- 不发布 GitHub Release(与 rsync 一致,只产 artifact)。
- 不构建 ffplay(无 SDL,默认不产出,符合预期)。
- 不启用 fdk-aac(non-free);不含 libpng/brotli/bzip2(freetype 用 `--without-*` 关闭,减少传递依赖)。

## 4. workflow 设计

### 4.1 文件与触发

- 路径:`.github/workflows/static-build-ffmpeg.yml`
- `name: static-build-ffmpeg`
- 触发:`on: workflow_dispatch`(与 rsync 一致)
- `runs-on: ubuntu-latest`,`container: alpine:3.20`
- 顶部 `env.VERSION: "8.1.2"`

### 4.2 步骤

**Step 1 — 安装构建依赖**

```text
apk add --no-cache \
  build-base pkgconf nasm yasm tar xz wget \
  x264-dev x265-dev libvpx-dev aom-dev lame-dev opus-dev \
  libvorbis-dev libtheora-dev libwebp-dev libass-dev freetype-dev \
  fribidi-dev harfbuzz-dev fontconfig-dev libogg-dev
```

- `nasm`/`yasm`:ffmpeg 自身 SIMD 汇编需要。
- 后三行 `fribidi/harfbuzz/fontconfig/libogg` 为 libass/vorbis/theora 的传递依赖;静态链接时显式安装更稳。
- 不需要 rsync 那套 `autoconf/automake/perl/python3`(ffmpeg 用自带 configure shell 脚本,非 autotools)。

**Step 2 — 下载 ffmpeg 源码**

```text
wget https://ffmpeg.org/releases/ffmpeg-${VERSION}.tar.xz
tar -xf ffmpeg-${VERSION}.tar.xz
```

**Step 3 — 配置 + 编译**

```text
cd ffmpeg-${VERSION}
./configure \
  --disable-debug --disable-doc \
  --disable-shared --enable-static \
  --enable-gpl --enable-version3 \
  --enable-libx264 --enable-libx265 --enable-libvpx --enable-libaom \
  --enable-libmp3lame --enable-libopus --enable-libvorbis --enable-libtheora \
  --enable-libwebp --enable-libass --enable-libfreetype \
  --extra-cflags="-static" \
  --extra-ldflags="-static" \
  --extra-ldexeflags="-static" \
  --pkg-config-flags="--static"
make -j"$(nproc)"
```

**Step 4 — 校验**

```text
strip ffmpeg ffprobe
file ffmpeg ffprobe
ldd ffmpeg ffprobe || true          # 期望:无动态依赖(not a dynamic executable)
./ffmpeg -version | head -20        # 期望:版本行 + 各 --enable-lib* 出现
./ffmpeg -hide_banner -codecs | grep -E 'libx264|libx265|libvpx|libaom|libmp3lame|libopus' | head
```

**Step 5 — 打包**

```text
mkdir -p dist
cp ffmpeg-${VERSION}/ffmpeg ffmpeg-${VERSION}/ffprobe dist/
sha256sum dist/ffmpeg dist/ffprobe > dist/SHA256SUMS
```

**Step 6 — 上传 artifact**

```yaml
uses: actions/upload-artifact@v4
with:
  name: ffmpeg-linux-amd64-static
  path: dist/
```

## 5. 风险与缓解

- **musl 下静态链接编解码库**:可能需要补 `--extra-libs`(如 `-lpthread -lm -ldl`)或个别传递依赖 `-dev` 包。缓解:Step 4 用 `ldd`/`file` 强制校验"完全静态";若 `ldd` 报动态依赖,再按报错补包/补 flags。实现计划中列为"构建后必须验证"的硬性检查。
- **x265/aom 静态包体积大**:仅链接不编译,影响可接受;`make` 主要耗时在 ffmpeg 本体。
- **许可**:含 GPL 库,产物为 GPL。在 workflow 文件顶部加注释说明。

## 6. 验收标准

- workflow 在 GitHub Actions 上手动触发可成功跑完。
- 下载的 artifact 中 `ffmpeg`、`ffprobe` 经 `file` 为 `statically linked`,`ldd` 无动态依赖。
- `./ffmpeg -version` 显示 8.1.2,且 `--enable-libx264/x265/vpx/aom/mp3lame/opus/vorbis/theora/webp/ass/freetype` 均出现。
- `SHA256SUMS` 与两个二进制匹配。
