# wave-search-tools

[ugrep](https://github.com/Genivia/ugrep) / [bfs](https://github.com/tavianator/bfs) 的预编译二进制，供 [wave](https://github.com/netease-lcap/wave-agent) 的 Bash 工具做 `grep` / `find` 注入（argv[0] 分派，与 Claude Code 同手法）。

按平台拆成 optionalDependencies，`pnpm add wave-search-tools` 只会拉当前平台那一个：

| 平台 | 包 | 内容 |
| --- | --- | --- |
| linux-x64 / linux-arm64 | `-linux-x64` / `-linux-arm64` | ugrep + bfs，全静态（musl 也能跑） |
| macOS (Intel / Apple Silicon) | `-darwin-x64` / `-darwin-arm64` | ugrep + bfs |
| Windows | `-win32-x64` | 仅 ugrep（git bash 自带的 GNU find 已完整） |

## 用法

```js
const { resolveSearchTools } = require("wave-search-tools")

const tools = resolveSearchTools(require)
// 当前平台 → { ugrep: ".../bin/ugrep", bfs: ".../bin/bfs" }
// 不支持的平台 → null
```

包只负责给出路径，不替调用方决定怎么用。二进制带执行位（`bin` 字段声明），可以直接 `spawn`。

## 版本与构建

上游版本固定在 `vendor.lock.json`（来源 + sha256），构建在 CI 上跑五个平台，详见仓库 README。
