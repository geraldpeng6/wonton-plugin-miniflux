# shellcheck shell=bash
# Miniflux：sso=proxy（Remote-User）。MCP 经 mcp-proxy（/mcp/）；上游镜像的 MCP 工具没标 readOnlyHint，
# 总线会要求用户确认，所以不走 MCP_TOOL 那条路，mcp_check 里直接调只读工具。

web_assert() { grep -qi 'miniflux'; }   # 标准输入：应用真实页面

# 应用自己的接口要 X-Auth-Token：在用户会话里建一把 API key，再用它调应用自己的“当前用户”接口，
# 断言用户名是用户且是管理员。
identity_check() {
  local page csrf key me base
  base="${SMOKE_WEB_URL%/}"   # 网关 web_url 带尾斜杠，直接拼会得到 //keys 这类路径，miniflux 回 404 页面
  page="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -c "$SMOKE_JAR" "$base/keys")" || { echo "取 /keys 失败"; return 1; }
  csrf="$(grep -oE 'data-csrf-token="[^"]+"' <<<"$page" | sed 's/.*="//; s/"//' | head -1)"
  [[ -n "$csrf" ]] || { echo "/keys 没有 csrf token"; return 1; }
  curl -sS --noproxy '*' -o /dev/null -b "$SMOKE_JAR" -c "$SMOKE_JAR" -e "$base/keys" \
    --data-urlencode "csrf=$csrf" --data-urlencode "description=wonton-smoke" "$base/keys/save" ||
    { echo "建 API key 失败"; return 1; }
  page="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" "$base/keys")" || { echo "读回 /keys 失败"; return 1; }
  key="$(grep -oE '[A-Za-z0-9]{60,}' <<<"$page" | head -1)"
  [[ -n "$key" ]] || { echo "/keys 里没有新 key"; return 1; }
  me="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -H "X-Auth-Token: $key" -H 'Accept: application/json' "$base/v1/me")" ||
    { echo "/v1/me 失败：$me"; return 1; }
  jq -e --arg u "$SMOKE_OWNER" '.username == $u and .is_admin == true' <<<"$me" >/dev/null ||
    { echo "当前用户不是用户管理员：$me"; return 1; }
}

mcp_check() { # tools/list 有本插件工具，再真实调一次只读工具 get_categories（默认分类 All 一定在）
  local tools tool out
  tools="${E2E_TOOLS:-${SMOKE_TOOLS:-}}"
  jq -e --arg s "${E2E_SLUG:-${SMOKE_SLUG:-}}" 'any(.[]; .name | startswith($s + "__"))' "$tools" >/dev/null ||
    { echo "tools/list 没有 ${E2E_SLUG:-${SMOKE_SLUG:-}} 前缀工具"; return 1; }
  tool="$(jq -r --arg s "${E2E_SLUG:-${SMOKE_SLUG:-}}" \
    '[.[] | select(.name == $s + "__get_categories")][0].name // empty' "$tools")"
  if [[ -z "$tool" ]]; then
    echo "tools/list 里没有 get_categories，现有：$(jq -r '.[].name' "$tools" | tr '\n' ' ')"
    return 1
  fi
  out="$(mcp call "${E2E_MCP_URL:-${SMOKE_MCP_URL:-}}" "$tool" '{}')" ||
    { echo "调用只读工具 $tool 失败：$(head -c 300 <<<"$out")"; return 1; }
  grep -q 'All' <<<"$out" || { echo "$tool 结果里没有默认分类 All：$(head -c 300 <<<"$out")"; return 1; }
}

# ---------- 数据钩子（e2e 六项冒烟用）----------
# 数据项跑在网页/身份项之前（套件先装旧 tag 就写数据），web_url 和会话都还没有：自己拿。
# 核心会话走 /_wonton/login；应用接口要 X-Auth-Token，key 经 /keys 页面建（csrf 在页面里）。
smoke_base_url() { printf '%s' "${E2E_BASE:-${SMOKE_BASE:-}}"; }
smoke_token() { printf '%s' "${E2E_TOKEN:-${SMOKE_TOKEN:-}}"; }

smoke_core_login() { # <jar> <插件地址>：先拿核心会话 Cookie，再走一次插件首页的登录跳转——
  # 网关的会话 Cookie 要落在插件主机上，应用的登录链和接口才认（两步都要，少一步后面全是 401）。
  local base token
  base="${E2E_BASE:-${SMOKE_BASE:-}}"
  token="${E2E_TOKEN:-${SMOKE_TOKEN:-}}"
  [[ -n "$base" && -n "$token" && -n "${2:-}" ]] || { echo "没有核心地址、主人令牌或插件地址"; return 1; }
  curl -sS --noproxy '*' -o /dev/null -b "$1" -c "$1" \
    --data-urlencode "token=$token" "$base/_wonton/login" &&
    curl -sS --noproxy '*' -o /dev/null -L -b "$1" -c "$1" -H 'Accept: text/html' "${2%/}/"
}

smoke_web_url() { # <插件 id>：从核心 API 查插件 web_url，剥到 scheme://host（应用都在根路径）
  local list
  list="$(curl -sS --noproxy '*' --fail-with-body -H "Authorization: Bearer $(smoke_token)" \
    "$(smoke_base_url)/_wonton/api/plugins")" || return 1
  jq -rn --arg id "$1" --arg json "$list" \
    '$json | fromjson | .plugins[] | select(.id==$id) | .web_url // ""' | sed -E 's#^(https?://[^/]+).*#\1#'
}

smoke_marker() { # <名字>：标记文件路径（SMOKE_STATE 是文件不是目录，标记放同名的 .d 目录里）
  local d="${SMOKE_STATE:-${TMPDIR:-/tmp}}.d"
  mkdir -p "$d" && printf '%s' "$d/$1"
}

smoke_app_url() { # 数据钩子用的应用地址：先取套件已设的（尾斜杠归一化），没有就自己查
  local u="${E2E_WEB_URL:-${SMOKE_WEB_URL:-}}"
  [[ -n "$u" ]] || u="$(smoke_web_url "${E2E_NAME_ID:-${SMOKE_PLUGIN_ID:-}}")" || return 1
  [[ -n "$u" ]] || { echo "查不到插件 web_url"; return 1; }
  printf '%s' "${u%/}"
}

miniflux_api_key() { # <jar> <base> <description>：在 /keys 建一把 API key，输出 token
  local page csrf
  page="$(curl -sS --noproxy '*' -b "$1" -c "$1" "$2/keys")" || return 1
  csrf="$(grep -oE 'data-csrf-token="[^"]+"' <<<"$page" | sed 's/.*="//; s/"//' | head -1)"
  [[ -n "$csrf" ]] || { echo "/keys 没有 csrf token"; return 1; }
  curl -sS --noproxy '*' -o /dev/null -b "$1" -c "$1" -e "$2/keys" \
    --data-urlencode "csrf=$csrf" --data-urlencode "description=$3" "$2/keys/save" || return 1
  page="$(curl -sS --noproxy '*' -b "$1" "$2/keys")" || return 1
  grep -oE '[A-Za-z0-9]{60,}' <<<"$page" | head -1
}

data_write() { # 建一把 API key，用它建一个带随机标记的分类（用户数据在 postgres，跨升级/重装持久）
  local jar base marker key out
  jar="${E2E_JAR:-${SMOKE_JAR:-}}"
  base="$(smoke_app_url)" || return 1
  smoke_core_login "$jar" "$base" || { echo "核心会话建不了"; return 1; }
  key="$(miniflux_api_key "$jar" "$base" wonton-smoke-data)" || return 1
  [[ -n "$key" ]] || { echo "/keys 里没有新 key"; return 1; }
  marker="wonton-smoke-$(head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  # API key 是给应用认身份的，核心网关还要它自己的会话 Cookie，所以两个头一起带。
  out="$(curl -sS --noproxy '*' --fail-with-body -b "$jar" -H "X-Auth-Token: $key" -H 'Content-Type: application/json' \
    --data "{\"title\":\"$marker\"}" "$base/v1/categories")" || { echo "建分类失败：$out"; return 1; }
  printf '%s\n%s\n' "$key" "$marker" >"$(smoke_marker miniflux-category)"
}

data_check() { # 升级/重装后用写数据时的 key 读回分类（key 存在 api_keys 表，跟着数据卷活下来）
  local base marker key cats jar
  base="$(smoke_app_url)" || return 1
  jar="${E2E_JAR:-${SMOKE_JAR:-}}"
  smoke_core_login "$jar" "$base" || { echo "核心会话建不了"; return 1; }
  {
    read -r key
    read -r marker
  } <"$(smoke_marker miniflux-category)" 2>/dev/null
  [[ -n "${key:-}" && -n "${marker:-}" ]] || { echo "没有 data_write 留下的标记"; return 1; }
  cats="$(curl -sS --noproxy '*' --fail-with-body -b "$jar" -H "X-Auth-Token: $key" "$base/v1/categories")" ||
    { echo "读分类失败：$cats"; return 1; }
  jq -e --arg t "$marker" 'any(.[]; .title == $t)' <<<"$cats" >/dev/null ||
    { echo "标记分类不见了：$(head -c 200 <<<"$cats")"; return 1; }
}
