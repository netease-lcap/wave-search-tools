# wave-search-tools

ugrep / bfs 的预编译二进制，供 [wave-agent](https://github.com/netease-lcap/wave-agent) 的 Bash 工具做 `grep` / `find` 注入使用（argv[0] 分派，与 Claude Code 同手法）。

## 为什么单独一个仓库

- **变更频率低**：ugrep/bfs 是上游稳定版本，一年可能动一次；放进 wave-agent 会让每次改工具都触发一次应用发版。
- **发布线解耦**：wave-agent 用 `pnpm -r publish` 递归发布全部非 private 包，新包混进去后没配 trusted publisher 就会让整条发版失败。

发版频率这么低，没有配 OIDC，发布是本地手动执行（见文末）。

## 包矩阵

一个主包 + 按平台的二进制包（形态对齐 `@vscode/ripgrep`，wave 的 `runtimeDeps.ts` 表格就是按它设计的）：

| 包 | 内容 |
| --- | --- |
| `wave-search-tools` | 解析逻辑 + `optionalDependencies` |
| `wave-search-tools-darwin-arm64` | ugrep + bfs |
| `wave-search-tools-darwin-x64` | ugrep + bfs |
| `wave-search-tools-linux-x64` | ugrep + bfs |
| `wave-search-tools-linux-arm64` | ugrep + bfs |
| `wave-search-tools-win32-x64` | **仅 ugrep**（git bash 的 GNU find 已完整，不注入 bfs） |

## 上游版本

见 [`vendor.lock.json`](./vendor.lock.json)：来源、版本、sha256 全部固定，构建脚本只认这份 lock。

bfs 额外静态链接了 **oniguruma**（同样由 lock 固定）。原因：bfs 自带的正则方言只有 POSIX，而 GNU `find` 的 `-regex` 默认是 emacs flavour（`\|` 表示或），不补这一层的话 `find . -regex '.*\.\(js\|ts\)'` 会静默返回空结果。静态链接是为了不要求目标机器上装 `libonig`。wave-agent 侧因此会给 `find` 注入 `-regextype findutils-default`，**0.1.0 的二进制没有这份能力，注入会让 `find` 直接报 "Unsupported regex type"**——两边版本要一起升。

## 构建

```sh
./scripts/build.sh linux-x64      # 当前主机能直接编的目标
```

产物落在 `packages/search-tools-<target>/bin/`。CI（`.github/workflows/build.yml`）在 push 时跑全部五个目标并各自上传 artifact。

几条踩过的坑写在 `scripts/build.sh` 注释里：CPU 基线要钉死（否则老 CPU SIGILL）、bfs 的 `LDFLAGS` 必须给 `configure` 而非 `make`、macOS 不能传 `--enable-static`、bfs 的 configure 找不到依赖时只是静默降级（所以构建脚本断言 `BFS_WITH_ONIGURUMA`）。

## 发布

```sh
gh run download <run-id> -D .artifacts   # 拉取五个平台的构建产物
./scripts/assemble.sh .artifacts         # 复制回各平台包的 bin/
pnpm -r publish --access public --no-git-checks --otp=<code>
```

`--otp` 是认证 app 的 6 位 code。`pnpm -r publish` 按依赖顺序发布，平台包先于主包，所以主包的 `optionalDependencies` 能解析到已存在的版本。
