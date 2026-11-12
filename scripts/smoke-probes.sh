# shellcheck shell=bash
# Miniflux：sso=proxy（Remote-User）。MCP 经 mcp-proxy（/mcp/）；上游镜像（jwonder/miniflux-mcp 0.8.0）
# 的工具没标 readOnlyHint，总线会要求用户确认；实测 tools/call 对 get_categories、get_version 都挂起
# 超时（2026-11-08 两次冒烟），上游不回调用结果，插件侧只能断言 tools/list。

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

mcp_check() { # 只断言 tools/list 出现本插件工具：上游 tools/call 挂起（见文件头实测记录），调用结果断言不了
  jq -e --arg s "$SMOKE_SLUG" 'any(.[]; .name | startswith($s + "__"))' "$SMOKE_TOOLS" >/dev/null ||
    { echo "tools/list 没有 $SMOKE_SLUG 前缀工具"; return 1; }
  echo "tools/list 有本插件工具；tools/call 实测被上游挂起，见文件头"
}

# ---------- 数据 ----------
# 数据项跑在网页/身份项之前：会话还没建立，先走一遍登录跳转把核心和应用会话备进 SMOKE_JAR。
# 应用自己的接口要 X-Auth-Token，key 经 /keys 页面建（csrf 在页面里）。
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
  local base marker key out
  base="${SMOKE_WEB_URL%/}"   # 网关 web_url 带尾斜杠，直接拼会得到 //keys 这类路径，miniflux 回 404 页面
  dweb --fresh / >/dev/null || { echo "登录跳转走不通，建不了应用会话"; return 1; }
  key="$(miniflux_api_key "$SMOKE_JAR" "$base" wonton-smoke-data)" || { echo "建 API key 失败"; return 1; }
  [[ -n "$key" ]] || { echo "/keys 里没有新 key"; return 1; }
  marker="wonton-smoke-$(head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  # API key 是给应用认身份的，核心网关还要它自己的会话 Cookie，所以两个头一起带。
  out="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H "X-Auth-Token: $key" -H 'Content-Type: application/json' \
    --data "{\"title\":\"$marker\"}" "$base/v1/categories")" || { echo "建分类失败：$out"; return 1; }
  printf '%s\n%s\n' "$key" "$marker" >"$SMOKE_STATE"
}

data_check() { # 升级/重装后用写数据时的 key 读回分类（key 存在 api_keys 表，跟着数据卷活下来）
  local base marker key cats
  base="${SMOKE_WEB_URL%/}"
  dweb --fresh / >/dev/null || { echo "登录跳转走不通，建不了应用会话"; return 1; }
  {
    read -r key
    read -r marker
  } <"$SMOKE_STATE"
  [[ -n "${key:-}" && -n "${marker:-}" ]] || { echo "SMOKE_STATE 里没有 data_write 留下的标记"; return 1; }
  cats="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H "X-Auth-Token: $key" "$base/v1/categories")" ||
    { echo "读分类失败：$cats"; return 1; }
  jq -e --arg t "$marker" 'any(.[]; .title == $t)' <<<"$cats" >/dev/null ||
    { echo "标记分类不见了：$(head -c 200 <<<"$cats")"; return 1; }
}
