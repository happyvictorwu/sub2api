#!/usr/bin/env bash
# =============================================================================
#  strip-upstream-ads.sh — 移除上游的赞助商与广告内容
# =============================================================================
#
#  用法：
#     ./tools/strip-upstream-ads.sh              执行
#     ./tools/strip-upstream-ads.sh --dry-run    只报告会做什么
#     ./tools/strip-upstream-ads.sh --help
#
#  做三件事：
#     1. 摘除 README.md / README_CN.md / README_JA.md 的「赞助商」整节
#     2. 移除 ProxyAdBanner 组件及其全部引用（3 处模板 + 3 处 import
#        + 1 处测试 stub + en/zh 两处 i18n 文案）
#     3. 把 assets/partners/（赞助商 logo）挪走
#
#  为什么 tools/rebrand.sh 不顺手做掉：
#     赞助商推广码（aff=SUB2API 等）是上游作者的返佣位，改掉链接里的码
#     等于冒用别人的推广位，所以 rebrand.sh 刻意保护了它们。正确做法是
#     整段删除而不是改写 —— 那是本脚本的职责。
#
#  幂等：已经处理过的项会被跳过，可以反复运行。
#  重新 fork 上游之后，跑完 rebrand.sh 再跑一次本脚本即可。
#
#  删除策略：一律 **移动到 _to_delete/**，不直接删。
#  这样你可以先过一眼再统一删除，也兼容只读挂载等无法 unlink 的环境。
#
# =============================================================================
set -euo pipefail

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  --help|-h) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "未知参数: $1（试试 --help）" >&2; exit 2 ;;
esac

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
command -v python3 >/dev/null || { echo "需要 python3，未找到" >&2; exit 1; }

export SUA_DRY="$DRY"

python3 - <<'PY'
import os, pathlib, re, shutil, sys

DRY  = os.environ.get('SUA_DRY') == '1'
TRASH = pathlib.Path('_to_delete')
done, skipped, aborted = [], [], []

def move_to_trash(src: pathlib.Path, name=None):
    dst = TRASH / (name or src.name)
    if DRY:
        done.append(f"[dry] 移动 {src} → {dst}")
        return
    TRASH.mkdir(parents=True, exist_ok=True)
    if dst.exists():
        i = 2
        while (TRASH / f"{dst.name}.{i}").exists():
            i += 1
        dst = TRASH / f"{dst.name}.{i}"
    shutil.move(str(src), str(dst))
    done.append(f"移动 {src} → {dst}")

# ---------------------------------------------------------------------------
# 1. README 赞助商整节
# ---------------------------------------------------------------------------
HEADING = re.compile(r'^## .*(赞助商|Sponsors|スポンサー)')
for name in ('README.md', 'README_CN.md', 'README_JA.md'):
    p = pathlib.Path(name)
    if not p.is_file():
        skipped.append(f"{name}: 文件不存在")
        continue
    lines = p.read_text(encoding='utf-8').split('\n')
    start = next((i for i, l in enumerate(lines) if HEADING.match(l)), None)
    if start is None:
        skipped.append(f"{name}: 赞助商节已不存在")
        continue
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith('## ')), None)
    if end is None:
        aborted.append(f"{name}: 找到赞助商标题但找不到下一个 '## ' 标题，拒绝猜测边界")
        continue
    excised = lines[start:end]
    if DRY:
        done.append(f"[dry] {name}: 将摘除 {len(excised)} 行（{start+1}..{end}）")
        continue
    arch = TRASH / 'readme-sponsors'
    arch.mkdir(parents=True, exist_ok=True)
    (arch / f'{name}.sponsors-section.md').write_text('\n'.join(excised), encoding='utf-8')
    p.write_text('\n'.join(lines[:start] + lines[end:]), encoding='utf-8')
    done.append(f"{name}: 摘除 {len(excised)} 行（原 {start+1}..{end}），已存档到 {arch}")

# ---------------------------------------------------------------------------
# 2. ProxyAdBanner 组件与全部引用
# ---------------------------------------------------------------------------
# 用「去掉首尾空白后精确匹配整行」的方式定位，这样即使上游调整了缩进也照样命中。
LINE_TARGETS = {
    'frontend/src/components/account/EditAccountModal.vue': [
        '<ProxyAdBanner />',
        "import ProxyAdBanner from '@/components/common/ProxyAdBanner.vue'"],
    'frontend/src/components/account/CreateAccountModal.vue': [
        '<ProxyAdBanner />',
        "import ProxyAdBanner from '@/components/common/ProxyAdBanner.vue'"],
    'frontend/src/views/admin/ProxiesView.vue': [
        '<ProxyAdBanner />',
        "import ProxyAdBanner from '@/components/common/ProxyAdBanner.vue'"],
    'frontend/src/components/account/__tests__/CreateAccountModal.spec.ts': [
        'ProxyAdBanner: true,'],
}
for f, targets in LINE_TARGETS.items():
    p = pathlib.Path(f)
    if not p.is_file():
        skipped.append(f"{f}: 文件不存在")
        continue
    lines = p.read_text(encoding='utf-8').split('\n')
    keep, removed = [], 0
    for l in lines:
        if l.strip() in targets:
            removed += 1
            continue
        keep.append(l)
    if removed == 0:
        skipped.append(f"{f}: ProxyAdBanner 引用已移除")
        continue
    if DRY:
        done.append(f"[dry] {f}: 将移除 {removed} 行引用")
        continue
    p.write_text('\n'.join(keep), encoding='utf-8')
    done.append(f"{f}: 移除 {removed} 行引用")

# i18n 文案：admin.proxies.ad.{inline}
for loc in ('en', 'zh'):
    f = f'frontend/src/i18n/locales/{loc}/admin/resources.ts'
    p = pathlib.Path(f)
    if not p.is_file():
        skipped.append(f"{f}: 文件不存在")
        continue
    src = p.read_text(encoding='utf-8')
    # 只匹配单层、仅含 inline 一个键的 ad 块，避免误伤同名嵌套结构
    pat = re.compile(r'\n[ \t]*ad: \{\n[ \t]*inline: [^\n]*\n[ \t]*\},')
    if not pat.search(src):
        skipped.append(f"{f}: admin.proxies.ad 文案已移除")
        continue
    if DRY:
        done.append(f"[dry] {f}: 将移除 admin.proxies.ad 文案")
        continue
    p.write_text(pat.sub('', src, count=1), encoding='utf-8')
    done.append(f"{f}: 移除 admin.proxies.ad 文案")

# 组件文件本身
comp = pathlib.Path('frontend/src/components/common/ProxyAdBanner.vue')
if comp.is_file():
    move_to_trash(comp)
else:
    skipped.append("ProxyAdBanner.vue: 已移除")

# ---------------------------------------------------------------------------
# 3. 赞助商 logo 资源
# ---------------------------------------------------------------------------
partners = pathlib.Path('assets/partners')
if partners.is_dir():
    n = sum(1 for _ in partners.rglob('*') if _.is_file())
    move_to_trash(partners, 'partners')
    done[-1] += f"（{n} 个文件）"
else:
    skipped.append("assets/partners: 已移除")

# ---------------------------------------------------------------------------
print()
if done:
    print("已处理：")
    for d in done: print("  ✔", d)
if skipped:
    print("已是目标状态，跳过：")
    for s in skipped: print("  ·", s)
if aborted:
    print("需要人工处理：")
    for a in aborted: print("  ⚠", a)
    sys.exit(1)
if not done:
    print("没有需要处理的内容。")
PY

# ---------------------------------------------------------------- 残留检查
echo
echo "── 残留检查 ──────────────────────────────────────────────"
LEFT=$(grep -rn 'ProxyAdBanner\|proxies\.ad\|assets/partners\|sub2api\.io/proxyip' \
         frontend/src backend README*.md docs 2>/dev/null || true)
if [ -z "$LEFT" ]; then
  echo "✅ 无残留引用。"
else
  echo "⚠️  仍有引用："
  printf '%s\n' "$LEFT" | head -20
fi
echo "──────────────────────────────────────────────────────────"

if [ "$DRY" = "0" ]; then
  cat <<'EOF'

已移动到 _to_delete/ 的内容请自行过目后删除：
  rm -rf _to_delete

改动后建议验证：
  pnpm --dir frontend run typecheck
  pnpm --dir frontend run test
EOF
fi
