# wave-search-tools

ugrep / bfs 的预编译二进制，供 [wave](https://github.com/netease-lcap/wave-agent) 的 Bash 工具做 `grep` / `find` 注入使用（argv[0] 分派，与 Claude Code 同手法）。

## 为什么单独一个仓库

- **变更频率低**：ugrep/bfs 是上游稳定版本，一年可能动一次；放进 wave-agent 会让每次改工具都触发一次应用发版。
- **发布线解耦**：wave-agent 用 `pnpm -r publish` 递归发布全部非 private 包，新包混进去后漏配一次 trusted publisher 就会让整条发版失败。这里独立 OIDC、独立 tag 触发。

## 包矩阵

一个主包 + 按平台的二进制包（形态对齐 `@vscode/ripgrep`，wave 的 `runtimeDeps.ts` 表格就是按它设计的）：

| 包 | 内容 |
| --- | --- |
| `@wave/search-tools` | 解析逻辑 + `optionalDependencies` |
| `@wave/search-tools-darwin-arm64` | ugrep + bfs |
| `@wave/search-tools-darwin-x64` | ugrep + bfs |
| `@wave/search-tools-linux-x64` | ugrep + bfs |
| `@wave/search-tools-linux-arm64` | ugrep + bfs |
| `@wave/search-tools-win32-x64` | **仅 ugrep**（git bash 的 GNU find 已完整，不注入 bfs） |

## 上游版本

见 [`vendor.lock.json`](./vendor.lock.json)：来源、版本、sha256 全部固定，构建脚本只认这份 lock。

## 构建

```sh
./scripts/build.sh linux-x64      # 当前主机能直接编的目标
```

产物落在 `packages/search-tools-<target>/bin/`。
