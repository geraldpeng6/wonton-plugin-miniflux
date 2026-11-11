# Miniflux

开发流程见[插件开发指南](https://github.com/wontonapp/wonton-docs/blob/main/develop.md)。

把 Miniflux 装进云吞：用户订阅、过滤和阅读 RSS，Bot 经 MCP 列出未读、搜索和标记已读。数据库是插件里的
PostgreSQL，网页经网关代登录直接进用户账号。

## 镜像

| 镜像 | 许可证 | 用途 |
| --- | --- | --- |
| `miniflux/miniflux` | Apache-2.0 | 应用，上游官方镜像 |
| `postgres` | PostgreSQL License | 数据库和写 API key 的一次性服务，上游官方镜像 |
| `jwonder/miniflux-mcp` | MIT | MCP 服务，Miniflux 没有官方 MCP，用社区实现（只发布 amd64） |
| `ghcr.io/tbxark/mcp-proxy` | MIT | 给 MCP 补上 Bearer 令牌，并按名单只放出读和标记已读的工具 |

## 图标

`icon.png` 取自 Miniflux 2.3.5 的官方 `maskable-icon-512.png`，未使用图片模型生成；来源、版权、处理方式、上游 Apache-2.0 全文和商标说明见 [NOTICE](NOTICE)。

Miniflux 名称及标志为其权利人的商标。本插件原样使用该标志，仅用于标识所集成的应用，不改变配色或比例，
不表示与 Miniflux 官方存在合作关系，也不表示获得其赞助或背书。

## Bot 能做什么

Bot 只拿到读和标记用的工具：看订阅和条目、搜索、标记已读、加星、刷新。建删订阅、用户和 API key 都不给。

`get_feed`、`get_category_feeds`、`get_entry`、`get_feed_entry`、`get_category_entry` 会带出订阅的认证配置
（HTTP 认证用户名和明文密码、Cookie、代理地址、webhook），白名单不开放它们；保留的列表工具
（`get_feeds`、`get_entries`、`get_feed_entries`、`get_category_entries`）只返回摘要，不含这些字段。
订阅地址会出现在摘要里，不要把密码或访问令牌直接写进 URL。

- `update_entry_status` 还能把条目设成 `removed`：Miniflux 里是永久隐藏，网页上没法恢复。

## 先跑起来

```bash
scripts/dev.sh up
scripts/dev.sh install
```

`up` 在本机起一套云吞并打印它的地址，用 `scripts/dev.sh token` 输出的用户令牌登录；`install` 列出插件要的权限，确认后
装上并打印插件网页的地址，打开就是 Miniflux 的未读页，不用再登录。

## 仓库里有什么

| 路径 | 内容 |
| --- | --- |
| `docker-compose.yml` | 插件本身：compose 加上 `x-wonton` 清单 |
| `icon.png` | 商店图标 |
| `screenshots/` | 商店详情页里的截图 |
| `scripts/check.sh` | 检查插件包，规则和安装时一样 |
| `scripts/dev.sh` | 开发环境：起一套云吞，装、重装、卸载插件，看日志 |
| `scripts/smoke-probes.sh` | `scripts/dev.sh smoke` 对这个插件逐项的探测 |
| `scripts/publish.sh` | 发布一个版本：构建自己的镜像、按摘要写回、打 tag、推送 |
| `AGENTS.md` | 给人和 AI 编程代理的规则 |
| `LICENSE`、`NOTICE` | 插件许可证、上游 Apache-2.0 许可证和商标声明 |
