#!/usr/bin/env bash
# =============================================================================
#  rebrand.sh — 把上游 Sub2API 的品牌串换成 brand.conf 里定义的你自己的品牌
# =============================================================================
#
#  用法：
#     ./tools/rebrand.sh              应用改动
#     ./tools/rebrand.sh --dry-run    只列出会改哪些文件，不写盘
#     ./tools/rebrand.sh --verify     检查还有哪些漏网的品牌串
#     ./tools/rebrand.sh --help
#
#  设计要点：
#   * 幂等 —— 所有规则都以「上游原始字面值」为左手边，跑一次和跑十次结果相同。
#     重新 fork 上游后再跑一次即可，不需要「旧品牌 → 新品牌」的迁移。
#   * 保护名单 —— Go module path、协议端点、第三方服务地址、赞助商推广码
#     一律不动。详见下面 PROTECT 数组和 REBRAND.md。
#   * 只处理 git 跟踪的文本文件，二进制和 lock 文件自动跳过。
#   * macOS / Linux 通用（用 perl 而非 sed -i，后者 BSD 与 GNU 语义不同）。
#
# =============================================================================
set -euo pipefail

MODE=apply
case "${1:-}" in
  --dry-run) MODE=dry ;;
  --verify)  MODE=verify ;;
  --help|-h)
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  "") ;;
  *) echo "未知参数: $1（试试 --help）" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------- 定位仓库根
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

command -v perl >/dev/null || { echo "需要 perl，未找到" >&2; exit 1; }
command -v git  >/dev/null || { echo "需要 git，未找到"  >&2; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "$ROOT 不是 git 仓库" >&2; exit 1; }

[ -f brand.conf ] || { echo "找不到 $ROOT/brand.conf" >&2; exit 1; }
# shellcheck disable=SC1091
. ./brand.conf

# ---------------------------------------------------------------- 校验与派生
: "${BRAND_NAME:?brand.conf 里 BRAND_NAME 不能为空}"
: "${BRAND_SLUG:?brand.conf 里 BRAND_SLUG 不能为空}"
: "${BRAND_ENV_PREFIX:?brand.conf 里 BRAND_ENV_PREFIX 不能为空}"

case "$BRAND_SLUG" in
  *sub2api*) echo "BRAND_SLUG 不能包含 'sub2api'，否则替换会自我循环" >&2; exit 1 ;;
esac
printf '%s' "$BRAND_SLUG" | grep -qE '^[a-z0-9][a-z0-9-]*$' \
  || { echo "BRAND_SLUG 只允许小写字母、数字、连字符：$BRAND_SLUG" >&2; exit 1; }
printf '%s' "$BRAND_ENV_PREFIX" | grep -qE '^[A-Z][A-Z0-9_]*$' \
  || { echo "BRAND_ENV_PREFIX 只允许大写字母、数字、下划线：$BRAND_ENV_PREFIX" >&2; exit 1; }

BRAND_DOMAIN=${BRAND_DOMAIN:-}
BRAND_SUPPORT_EMAIL=${BRAND_SUPPORT_EMAIL:-}
BRAND_DOCKER_IMAGE=${BRAND_DOCKER_IMAGE:-}
BRAND_TAGLINE=${BRAND_TAGLINE:-AI API Gateway}
BRAND_GITHUB_REPO=${BRAND_GITHUB_REPO:-}
BRAND_RENAME_PATHS=${BRAND_RENAME_PATHS:-0}
BRAND_REWRITE_READMES=${BRAND_REWRITE_READMES:-1}
BRAND_RENAME_ENV_VARS=${BRAND_RENAME_ENV_VARS:-0}

# 派生默认值一律用 RFC 2606 保留域名，肉眼可辨认是占位符
[ -n "$BRAND_DOMAIN" ]        || BRAND_DOMAIN="${BRAND_SLUG}.example.com"
[ -n "$BRAND_SUPPORT_EMAIL" ] || BRAND_SUPPORT_EMAIL="support@${BRAND_DOMAIN}"
[ -n "$BRAND_DOCKER_IMAGE" ]  || BRAND_DOCKER_IMAGE="${BRAND_SLUG}"
[ -n "$BRAND_GITHUB_REPO" ]   || BRAND_GITHUB_REPO="Wei-Shaw/sub2api"

# ---------------------------------------------------------------- 收集目标文件
# git ls-files 天然排除 .git、node_modules、dist 等被忽略的路径
FILELIST=$(mktemp); trap 'rm -f "$FILELIST"' EXIT
git ls-files -z --cached --others --exclude-standard >"$FILELIST"

export B_NAME="$BRAND_NAME"      B_SLUG="$BRAND_SLUG"
export B_PREFIX="$BRAND_ENV_PREFIX" B_DOMAIN="$BRAND_DOMAIN"
export B_EMAIL="$BRAND_SUPPORT_EMAIL" B_REPO="$BRAND_GITHUB_REPO"
export B_IMAGE="$BRAND_DOCKER_IMAGE"  B_TAGLINE="$BRAND_TAGLINE"
export B_MODE="$MODE"                 B_READMES="$BRAND_REWRITE_READMES"
export B_RENAME_ENV="$BRAND_RENAME_ENV_VARS"

# ---------------------------------------------------------------- 主替换程序
perl -0777 - "$FILELIST" <<'PERL'
use strict;
use warnings;

my $NAME    = $ENV{B_NAME};
my $SLUG    = $ENV{B_SLUG};
my $PREFIX  = $ENV{B_PREFIX};
my $DOMAIN  = $ENV{B_DOMAIN};
my $EMAIL   = $ENV{B_EMAIL};
my $REPO    = $ENV{B_REPO};
my $IMAGE   = $ENV{B_IMAGE};
my $TAGLINE = $ENV{B_TAGLINE};
my $MODE    = $ENV{B_MODE};
my $READMES = $ENV{B_READMES};

# ---------------------------------------------------------------------------
#  保护名单：这些字面值一律不改。每一条都有具体理由。
# ---------------------------------------------------------------------------
my @PROTECT = (
  # 协议端点。用来向【上游其他 sub2api 站点】查询本 Key 的计费元数据，
  # 是跨站点约定的路径。改了就无法和上游中转站互通。
  #
  # 注意这里不能写成 '/v1/sub2api/billing'：路由注册处写的是
  #   gateway.GET("/sub2api/billing", ...)      // /v1 来自 group 前缀
  # 只保护带 /v1 的写法会漏掉真正的注册点，导致端点被改名。
  'sub2api/billing',

  # prompt 审计快照里的内部分隔符。改了会导致已入库的历史快照无法解析。
  'SUB2API_PROMPT_AUDIT_PRIORITY_END',

  # 第三方在线工具，管理后台「TLS 指纹」弹窗里直接链出去的真实站点。
  'tls.sub2api.org',

  # 第三方广告/服务链接，不是本项目的品牌。
  'sub2api.io/proxyip',
  'novada.com/?sub2api/',

  # 别人的开源仓库。
  'github.com/ckken/sub2api-mobile',
  'github.com/touwaeriol/sub2apipay',

  # 赞助商推广码。改了链接失效，且等于冒用别人的返佣位。
  'aff=SUB2API',
  'promo=SUB2API',
  '?ref=sub2api',
  'invite/SUB2API',
  'code=SUB2API',
);

# 正则形式的保护规则。
my @PROTECT_RE;

# 内部环境变量名（SUB2API_XXX）。默认不改名 —— 它们不对外可见，
# 改了只会让你搜上游 issue、对照上游文档时全部失配。
# 想改就在 brand.conf 里设 BRAND_RENAME_ENV_VARS=1。
if (($ENV{B_RENAME_ENV} // '0') ne '1') {
  push @PROTECT_RE, qr/\b[A-Z0-9_]*SUB2API_[A-Z0-9_]+\b/;
}

# 本次要插入的新值，一律保护。
# 关键在于 BRAND_GITHUB_REPO 通常形如 "you/sub2api" —— 仓库名本身就含
# sub2api。不保护的话第 6 步通用规则会把它改成 "you/slothwatching"，
# 于是脚本第二次运行的结果和第一次不同，幂等性直接失效。
# 按长度降序，先掩长的（EMAIL 里含 DOMAIN，反了会切成两半）。
for my $v (sort { length($b) <=> length($a) } grep { defined && length } ($REPO, $IMAGE, $DOMAIN, $EMAIL)) {
  push @PROTECT_RE, qr/\Q$v\E/;
}

# 掩码表：把「不能动的原文」和「插入的新值」都换成 \x00 哨兵，
# 等所有规则跑完再还原 —— 这样通用规则既碰不到保护名单，
# 也不会把刚插进去的新值（比如仓库名 happyvictorwu/sub2api）二次替换。
my @vault;
sub stash { push @vault, $_[0]; return "\x00V" . $#vault . "\x00"; }

my ($changed, $scanned, @hits) = (0, 0);

open(my $fh, '<:raw', $ARGV[0]) or die "无法读取文件清单: $!";
my $listing = do { local $/; <$fh> };
close $fh;

FILE: for my $file (split /\0/, $listing) {
  next unless length $file;
  next unless -f $file;

  # 自己不改自己。strip-upstream-ads.sh 也必须排除：它的 grep 模式里写着
  # 'sub2api\.io/proxyip'（带正则转义的点），不在保护名单的字面匹配范围内，
  # 会被通用规则改坏。
  next if $file =~ m{^(brand\.conf|tools/rebrand\.sh|tools/strip-upstream-ads\.sh|REBRAND\.md)$};
  # 已经标记待删的内容不再处理
  next if $file =~ m{^_to_delete/};
  # lock 文件与校验和：内容由工具生成，且 go.sum 里的路径必须与 go.mod 一致
  next if $file =~ m{(^|/)(go\.sum|pnpm-lock\.yaml|package-lock\.json|yarn\.lock)$};
  # 图片等二进制资产
  next if $file =~ m{\.(png|jpe?g|gif|ico|webp|woff2?|ttf|eot|pdf|zip|gz|tar)$}i;
  # README 可选跳过
  next if $READMES eq '0' && $file =~ m{^README(_[A-Z]{2})?\.md$};

  open(my $in, '<:raw', $file) or next;
  my $orig = do { local $/; <$in> };
  close $in;
  next unless defined $orig;
  next if $orig =~ /\x00/;   # 含 NUL，按二进制处理，跳过

  $scanned++;
  local $_ = $orig;
  @vault = ();

  my $is_svc = ($file =~ m{^backend/internal/service/[^/]+\.go$} && $file !~ /_test\.go$/);

  # --- 0. 掩掉保护名单 -----------------------------------------------------
  for my $p (@PROTECT) {
    my $q = quotemeta $p;
    s/$q/stash($p)/ge;
  }
  for my $re (@PROTECT_RE) {
    s/($re)/stash($1)/ge;
  }

  # --- 1. 指向上游仓库的 URL 改指到你的 fork -------------------------------
  s{https://github\.com/Wei-Shaw/sub2api}        {stash("https://github.com/$REPO")}ge;
  s{https://github\.com/weishaw/sub2api}         {stash("https://github.com/$REPO")}ge;
  s{https://raw\.githubusercontent\.com/Wei-Shaw/sub2api}
                                                 {stash("https://raw.githubusercontent.com/$REPO")}ge;
  s{https://api\.github\.com/repos/Wei-Shaw/sub2api}
                                                 {stash("https://api.github.com/repos/$REPO")}ge;
  s{repos=Wei-Shaw/sub2api}                      {stash("repos=$REPO")}ge;
  s{\#Wei-Shaw/sub2api}                          {stash("#$REPO")}ge;

  # --- 2. Go module path ---------------------------------------------------
  # 上一步已把所有指向上游仓库网页的 https:// 链接改指到你的 fork，
  # 因此此刻还剩的 github.com/Wei-Shaw/sub2api 一律是 Go 包路径 —— 保护。
  #
  # 注意这条规则必须对【所有文件类型】生效，不能只管 .go：
  # backend/.golangci.yml 的 depguard 规则里就写着完整包路径
  #   pkg: github.com/Wei-Shaw/sub2api/internal/repository
  # 改坏了不会报错，只会让「service 不许 import repository」这条
  # 架构约束静默失效 —— 属于最难发现的那类破坏。
  s{github\.com/Wei-Shaw/sub2api}{stash("github.com/Wei-Shaw/sub2api")}ge;

  # 其余裸的 Wei-Shaw/sub2api 是文档引用，改指到你的仓库。
  s{Wei-Shaw/sub2api}{stash($REPO)}ge;

  # --- 3. Docker 镜像 -------------------------------------------------------
  s{weishaw/sub2api}{stash($IMAGE)}ge;

  # --- 4. 域名与邮箱 --------------------------------------------------------
  s{support\@sub2api\.org}{stash($EMAIL)}ge;
  s{sub2api\.org}{stash($DOMAIN)}ge;

  # --- 5. service 包：把站点名兜底默认值改成可运行时覆盖的 brandName() -------
  # 这些是 site_name 数据库设置取不到值时的兜底，走函数才能被 BRAND_NAME
  # 环境变量覆盖（改品牌不必重新编译）。const 块里的字面值无法调用函数，
  # 会落到第 6 步做纯字面替换。
  if ($is_svc) {
    s{"Sub2API Subscription "}          {brandName() + " Subscription "}g;
    s{"Sub2API " \+ amountStr}          {brandName() + " " + amountStr}g;
    s{siteName := "Sub2API"}            {siteName := brandName()}g;
    s{siteName = "Sub2API"}             {siteName = brandName()}g;
    s{SettingKeySiteName, "Sub2API"\)}  {SettingKeySiteName, brandName())}g;
    s{(SettingKeySiteName:\s+)"Sub2API",}{$1brandName(),}g;
    s{return "Sub2API"(?=\s*$)}         {return brandName()}gm;
  }

  # --- 5b. 页面标题副标题 ----------------------------------------------------
  # 只改 <title> 构造处，不碰 README 里作为描述文字出现的同一短语。
  # 三处：frontend/index.html、frontend/vite.config.ts、backend/internal/web/embed_on.go
  s{ - AI API Gateway</title>}{stash(" - $TAGLINE</title>")}ge;

  # --- 6. 通用字面替换 ------------------------------------------------------
  s{Sub2API}{$NAME}g;
  s{Sub2Api}{$NAME}g;
  s{SUB2API}{$PREFIX}g;
  s{sub2api}{$SLUG}g;

  # --- 7. 重新生成两个文件里的编译期兜底值 -----------------------------------
  if ($file eq 'backend/internal/branding/branding.go') {
    s{(defaultName\s*=\s*)"[^"]*"}   {$1 . '"' . $NAME . '"'}e;
    s{(defaultTagline\s*=\s*)"[^"]*"}{$1 . '"' . $TAGLINE . '"'}e;
  }
  if ($file eq 'frontend/src/brand.ts') {
    s{(FALLBACK_NAME\s*=\s*)'[^']*'}   {$1 . "'" . $NAME . "'"}e;
    s{(FALLBACK_TAGLINE\s*=\s*)'[^']*'}{$1 . "'" . $TAGLINE . "'"}e;
  }

  # --- 8. 还原掩码 ----------------------------------------------------------
  s{\x00V(\d+)\x00}{$vault[$1]}ge;

  next if $_ eq $orig;

  $changed++;
  push @hits, $file;
  next if $MODE ne 'apply';

  open(my $out, '>:raw', $file) or die "无法写入 $file: $!";
  print $out $_;
  close $out;
}

if ($MODE eq 'dry') {
  print "[dry-run] 扫描 $scanned 个文件，将修改 $changed 个：\n";
  print "  $_\n" for @hits;
} elsif ($MODE eq 'apply') {
  print "扫描 $scanned 个文件，已修改 $changed 个。\n";
}
PERL

# ---------------------------------------------------------------- 路径重命名
if [ "$MODE" = "apply" ] && [ "$BRAND_RENAME_PATHS" = "1" ]; then
  echo "重命名带品牌的路径（BRAND_RENAME_PATHS=1）…"
  # 深的先改，避免父目录改名后子路径失效
  git ls-files | grep 'sub2api' | awk '{print length, $0}' | sort -rn | cut -d' ' -f2- \
  | while read -r p; do
      [ -e "$p" ] || continue
      np=$(printf '%s' "$p" | sed "s|sub2api|${BRAND_SLUG}|g")
      [ "$p" = "$np" ] && continue
      mkdir -p "$(dirname "$np")"
      git mv "$p" "$np" 2>/dev/null && echo "  $p → $np" || true
    done
fi

# ---------------------------------------------------------------- 残留检查
if [ "$MODE" = "verify" ] || [ "$MODE" = "apply" ]; then
  echo
  echo "── 残留检查 ──────────────────────────────────────────────"
  LEFT=$(git grep -nI --untracked -E 'Sub2API|Sub2Api|SUB2API|sub2api' -- . \
    | grep -v 'github.com/Wei-Shaw/sub2api' \
    | grep -v 'sub2api/billing' \
    | grep -v 'SUB2API_PROMPT_AUDIT_PRIORITY_END' \
    | grep -v 'tls\.sub2api\.org' \
    | grep -v 'sub2api\.io/proxyip' \
    | grep -v 'novada\.com/?sub2api/' \
    | grep -v 'ckken/sub2api-mobile' \
    | grep -v 'touwaeriol/sub2apipay' \
    | grep -v -E 'aff=SUB2API|promo=SUB2API|\?ref=sub2api|invite/SUB2API|code=SUB2API' \
    | grep -v -E '^(brand\.conf|tools/rebrand\.sh|tools/strip-upstream-ads\.sh|REBRAND\.md):' \
    | grep -v -E '^_to_delete/' \
    | grep -v -E '^(go\.sum|.*/go\.sum|pnpm-lock\.yaml):' \
    | grep -vF "$BRAND_GITHUB_REPO" \
    | { if [ "$BRAND_RENAME_ENV_VARS" = "1" ]; then cat; else grep -v -E '[A-Z0-9_]*SUB2API_[A-Z0-9_]+'; fi; } || true)

  # 硬断言：这两处一旦被改坏，都不会立刻报错，但后果很严重
  FAIL=0
  if ! grep -q '^module github\.com/Wei-Shaw/sub2api$' backend/go.mod; then
    echo "❌ backend/go.mod 的 module 行被改动了 —— Go 包路径不该变，见 REBRAND.md" >&2
    FAIL=1
  fi
  if [ -f backend/.golangci.yml ] && ! grep -q 'github\.com/Wei-Shaw/sub2api/internal/repository' backend/.golangci.yml; then
    echo "❌ backend/.golangci.yml 的 depguard 包路径被改动了 —— 架构约束会静默失效" >&2
    FAIL=1
  fi
  [ "$FAIL" = "1" ] && exit 1

  if [ -z "$LEFT" ]; then
    echo "✅ 没有未受保护的残留品牌串。"
  else
    echo "⚠️  以下位置仍含品牌串，请人工确认是否需要处理："
    printf '%s\n' "$LEFT" | head -40
    n=$(printf '%s\n' "$LEFT" | wc -l | tr -d ' ')
    [ "$n" -gt 40 ] && echo "  …（共 $n 处）"
  fi
  echo "──────────────────────────────────────────────────────────"
fi

if [ "$MODE" = "apply" ]; then
  cat <<EOF

完成。品牌 = ${BRAND_NAME} / ${BRAND_SLUG}

下一步：
  git diff --stat                     看改动范围
  cd backend && go build ./...        确认后端能编译
  pnpm --dir frontend run typecheck   确认前端类型通过

接着跑这个，清掉上游的赞助商与广告（本脚本刻意不动它们，
因为改写别人的推广码等于冒用返佣位，正确做法是整段删除）：
  ./tools/strip-upstream-ads.sh

之后仍需人工处理的只剩一件：
  * assets/logo.svg 与 frontend/public/logo.svg 是上游的图形标识，
    换成你自己的 logo 文件。
EOF
fi
