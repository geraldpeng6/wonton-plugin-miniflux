# Miniflux：sso=proxy（Remote-User）。MCP 经 mcp-proxy（/mcp/）；固定的 MCP 工具定义没标 readOnlyHint，
# 总线会要求主人确认，这里只断言 tools/list 有工具。
SSO=proxy
MCP=1
SMOKE_NOTE="工具没标 readOnlyHint，仅 tools/list，未调"

web_assert() { grep -qi 'miniflux'; }   # 标准输入：应用真实页面

# 应用自己的接口要 X-Auth-Token：在主人会话里建一把 API key，再用它调应用自己的“当前用户”接口，
# 断言用户名是主人且是管理员。
identity_check() {
  local page csrf key me
  page="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -c "$SMOKE_JAR" "$SMOKE_WEB_URL/keys")" || { echo "取 /keys 失败"; return 1; }
  csrf="$(grep -oE 'data-csrf-token="[^"]+"' <<<"$page" | sed 's/.*="//; s/"//' | head -1)"
  [[ -n "$csrf" ]] || { echo "/keys 没有 csrf token"; return 1; }
  curl -sS --noproxy '*' -o /dev/null -b "$SMOKE_JAR" -c "$SMOKE_JAR" -e "$SMOKE_WEB_URL/keys" \
    --data-urlencode "csrf=$csrf" --data-urlencode "description=wonton-smoke" "$SMOKE_WEB_URL/keys/save" ||
    { echo "建 API key 失败"; return 1; }
  page="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" "$SMOKE_WEB_URL/keys")" || { echo "读回 /keys 失败"; return 1; }
  key="$(grep -oE '[A-Za-z0-9]{60,}' <<<"$page" | head -1)"
  [[ -n "$key" ]] || { echo "/keys 里没有新 key"; return 1; }
  me="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -H "X-Auth-Token: $key" -H 'Accept: application/json' "$SMOKE_WEB_URL/v1/me")" ||
    { echo "/v1/me 失败：$me"; return 1; }
  jq -e --arg u "$SMOKE_OWNER" '.username == $u and .is_admin == true' <<<"$me" >/dev/null ||
    { echo "当前用户不是主人管理员：$me"; return 1; }
}

mcp_check() { # 只断言 tools/list 出现本插件工具
  local n_mine
  n_mine="$(jq --arg s "$SMOKE_SLUG" '[.[] | select(.name | startswith($s + "__"))] | length' "$SMOKE_TOOLS")"
  [[ "$n_mine" -ge 1 ]] || { echo "tools/list 没有 $SMOKE_SLUG 前缀工具"; return 1; }
}
