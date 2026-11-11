# aegis-runtime

<!-- languages -->
[English](README.md) · **简体中文**
<!-- /languages -->

aegis-runtime 是一个用 Rust 编写的智能体运行时。它构建出一个程序：`aegis`。该程序运行一个本地网关（端口 18096 上的 WebSocket、服务器发送事件和 REST）、一个认领并运行排队任务的心跳循环、一个感知依赖关系的任务工作流，以及 SQLite 存储。使用 `--inference http` 时，它会把模型调用发送到本地的 OpenAI 兼容模型服务器。默认值 `--inference embedded` 是一个模拟实现：它不加载任何模型，并忽略 `--model-path` 和 `--tokenizer-path`。

## 它在 AIEN 中的位置

aegis-runtime 是 [AienOS](https://github.com/aien-dev/aienix) 的一个附属组件，AienOS 是 AIEN 的核心树。它位于自己的仓库中，并在一个边界处接入核心。

- [aien-dev/aien-protocols-mv](https://github.com/aien-dev/aien-protocols-mv)：共享的协议 crate。本仓库需要检出它才能构建（见“构建”）。
- [aien-dev/aien-sovereign-core-mv](https://github.com/aien-dev/aien-sovereign-core-mv)：生产运行时。它还包含 Spark 测试工具（`tools/aien-test`、`tools/aien-local-ci`）。
- [aien-dev/aien-receipts](https://github.com/aien-dev/aien-receipts)：Spark 在这里发布本仓库的已签名测试结果。

## 状态（2026-10-19）

- **Pre-alpha，版本 0.2.0**（`Cargo.toml`）。
- **不属于 WHOLE-SYSTEM-E2E v1 发布**（Drake，2026-10-10）。aien-sovereign-core 中的生产运行时承担强制性的能力检查、审批台、效果授权和失败即关闭的行为，WHOLE-SYSTEM-E2E 在那里对它们进行测量。
- **0.2.0 尚无已发布版本。** GitHub 发布版 `v0.1.0`（2026-09-20）发布于从 OpenClaw 更名之前。`v0.2.0` 是 2026-09-19 的一个未发布草稿。
- **`main` 上的近期变更：** 移除了 Modular MAX 和 Mojo（#49，2026-10-15）。Spark 成为测试评判器（#51，2026-10-16）。rustls 因四项安全公告更新至 0.23.46（#66，2026-10-18）。托管的测试工作流已被移除，因此 Spark 现在是唯一运行测试的地方（#69，2026-10-18）。
- **2026-10-19 已合并：** docs/PIPELINE.md 将第 3 阶段描述为已完成（#71），并且 `.crumb` 文件不再存储生成的数据；碎屑工具会按需计算这些数据（#70）。
- **进行中，尚未进入 `main`：** 委托任务工作流的 G1 至 G6 工作（拉取请求 #60 至 #65，在议题 #53 中跟踪）。

## 架构

```
                                  +-----------------------------+
                                  |   atlas-vault client        |
                                  |   (no secrets on disk)      |
                                  +--------------+--------------+
                                                 |
+---------------------------+     +--------------v--------------+     +-----------------------------+
|   Axum control plane      |     |     Heartbeat engine        |     |  Local model seat (optional)|
|   - port 18096            | <-> |     - tick loop [1]         | <-> |  - port 18006               |
|   - WebSocket and SSE     |     |     - claims queued tasks   |     |  - any OpenAI-compatible    |
|   - REST API              |     |     - runs and records them |     |    server                   |
+---------------------------+     +--------------+--------------+     +-----------------------------+
                                                 |
                                  +--------------v--------------+
                                  |   Rust vector math          |
                                  |   SQLite (WAL mode)         |
                                  +-----------------------------+
```

[1] 对于 `aegis heartbeat`，节拍间隔为 30 秒；对于 `aegis serve`，节拍间隔为 60 秒，除非设置了 `--heartbeat-secs`（`aegis <command> --help`）。

## 核心子系统

1. **Axum 控制平面**（`src/gateway.rs`）。
   WebSocket（`/ws`、`/api/v1/ws`）、服务器发送事件（`/api/v1/events`、`/events`），以及端口 18096 上的 REST：`/health`、`/api/v1/health`、`/api/v1/chat`、`/api/v1/agent/run`、`/api/v1/heartbeat/tick`、`/api/v1/tasks`、`/api/v1/skills`、`/api/v1/skills/execute`、`/api/v1/shell`、`/api/v1/discord/relay`，另有 OpenAI 风格的 `/v1/chat/completions` 和 `/v1/models`，以及 `/v1/probe`。
   只有当终止文本非空、结束原因为 `stop` 且没有终止性工具失败时，智能体运行才会返回 `status: "completed"`。由配置的重试策略恢复的失败尝试不计为终止性失败。被截断（`length`）、文本为空以及受轮次预算限制的结果均为 `incomplete`；推理返回空的 choices 数组属于执行错误，而不是合成出来的答案。生产者和工作流适配器共用同一个终止性工具失败分类器。HTTP 200 表示这次运行返回了结果，并不表示其目标已经完成。WebSocket `agent_result` 消息携带相同的顶层状态，并保留 `result.completed`；执行错误仍为 `agent_error`。

2. **心跳引擎**（`src/heartbeat.rs`）。
   一个轮询循环：在运行每个待处理任务之前先认领该任务，并发出一个脉冲凭证。只有成功的动作才会成为 `completed` 任务和 `task_completed` 转录事件。不健康的模型检查、被拒绝或失败的 shell 执行、失败的记忆写入以及未知的任务类型，都会成为 `failed` 任务，错误写入 `result`，并产生一个 `task_failed` 事件。失败的任务不会自动重试。只要任一动作、任务持久化操作或队列读取/认领失败，脉冲就是 `degraded`，否则为 `nominal`；`actions_dispatched` 统计的是已认领的动作，而不是成功完成的次数。
   认领携带新的所有者 ID 和认领 ID。完成/失败更新要求存在匹配的运行中认领，并拒绝第二次终止写入。任务状态和一个具有唯一标识的事件在单个 SQLite 事务（`task_terminal_events`）中提交。JSONL 是这些已存储事件的可重试投影；消费者应按 `event_id` 去重。被中断的尾部追加会在重试前被丢弃。转录导出或心跳凭证写入失败会使返回或广播的脉冲降级，但不会撤销已提交的任务结果。如果心跳凭证的 JSONL 投影失败，会在凭证事务提交之前把该凭证及其 SQLite 行改为 `degraded`，与返回的凭证、广播以及碎屑命令向量保持一致。

   持久化失败时，数据库所有者会为后续脉冲保留原始结果，替换心跳引擎之后也是如此。只会重试持久化，绝不会重试任务执行。刷出一个被保留的失败或取消会使该脉冲降级，即使它没有派发任何新工作。取消会保留 `abandoned: outcome unknown`；动作中的 panic 会变成失败，不会终止心跳循环。在打开时以及每次扫描待处理工作之前，一个按所有者划分、与所有者生命周期一致的 `flock` 用于区分存活的所有者和被遗弃的运行中认领，其中包括在本数据库句柄打开之后才死亡的对等进程。已死亡所有者的认领会以 `abandoned: outcome unknown` 变为失败，只发生一次，不会重放。锁文件位于规范数据库旁边的 `<database>.task-owners` 下，在所有者仍可能引用它们时不会被删除。
   
   缺少所有者/认领元数据的旧版运行中行，在正常打开时会失败即关闭。操作员必须先停止使用此数据库的**所有**进程，包括不持有所有者锁的旧二进制文件，并让它们保持停止状态，直到迁移退出。然后在重启运行时之前运行 `aegis migrate-legacy-tasks --db-path /absolute/path/to/aegis.sqlite --quiescent`。这一显式确认不会替你停止服务。迁移还会拒绝已检测到的存活所有者，并且绝不会创建缺失的数据库。它保留旧版任务的标识、负载和创建时间，分配迁移所有者/认领 ID，并以原子方式将每个未知的运行中任务标记为 `failed`，附带 `abandoned: outcome unknown` 以及一个唯一事件。它绝不会执行或重新排队这些任务；重新运行它也不会产生重复的终止事件。修复转录路径后，重新运行同一命令即可重试失败的转录投影。
   
   每个模型健康检查动作都有 15 秒的截止时间，包括后端的 `check_health` future。直接 HTTP 回退路径也有连接截止时间和请求总截止时间。超时会记录一个结果未知的失败，且不重放；后续脉冲可以处理其他任务。


3. **本地模型席位推理**（可选，`src/inference.rs`）。
   使用 `--inference http` 时，请求会发送到由 `--model-url` 指定的 OpenAI 风格端点（默认 `http://127.0.0.1:18006/v1/chat/completions`），模型名为 `atlas-lightning-omni`。不使用该选项时，由模拟后端（来自 aien-protocols 的 `MockInferenceClient`）应答。此时 `aegis status` 会将后端报告为 `mock-protocol-model`；该输出中的“NativeTransformer”一词指的是这个模拟实现，而不是真实模型。

   端口 18006 以前是 Modular MAX 的服务端点。排队中的 `model_health` 心跳任务（或仍以旧名 `max_health` 排队的任务）会通过配置的后端检查模型席位；如果没有设置后端，则直接轮询 `http://127.0.0.1:18006/v1/models`，并报告端口 18006 上是否有任何服务应答。本项目在其生产路径上不使用 MAX 或 CUDA（2026-10-02 的决定）；aien-sovereign-core 中的生产运行时通过 AIEN 自己的 Omega 核函数运行其 GPU 路径。

4. **向量数学**（`src/vector_math.rs`）。
   用纯 Rust 实现余弦相似度、香农熵、线性投影和温度缩放。

5. **密钥解析**（`src/vault.rs`）。
   不使用明文密钥文件。`VaultResolver` 向 `atlas-vault` 获取密钥，然后将值保存在内存中。它是该提供方的客户端，而不是 TPM（一种硬件安全芯片）。仅当 `AIEN_DEV_SECRET_FALLBACK=1` 时才读取进程环境。输出会用 `[REDACTED_BY_ATLAS_VAULT]` 脱敏。

6. **SQLite 持久化**（`src/persistence/`）。
   一个以预写日志（WAL）模式运行的嵌入式 SQLite 存储，因此任务和消息的写入在崩溃后依然保留。

7. **任务工作流与失败处理。**
   一个感知依赖关系的任务工作流（[docs/WORKFLOW-DAG.md](docs/WORKFLOW-DAG.md)），以及带有效果安全重试规则的结构化智能体失败记录（[docs/FAILURE-PROVENANCE.md](docs/FAILURE-PROVENANCE.md)）。

## 构建

### 前提条件

- 稳定版 Rust 工具链（`cargo`）。该 crate 使用 2021 版次。
- 在本仓库旁边检出 [aien-dev/aien-protocols-mv](https://github.com/aien-dev/aien-protocols-mv)，放在名为 `aien-protocols` 的文件夹中。`Cargo.toml` 有六个指向 `../aien-protocols/crates/` 的路径依赖。
- 可选：端口 18006 上的一个 OpenAI 兼容模型服务器（即本地模型席位），仅用于 `--inference http`。
- Linux。Spark 上的测试运行在 aarch64（Grace Blackwell GB10）上。发布工作流（`.github/workflows/release.yml`）构建 Linux x86_64 版本。

### 获取代码并编译

```bash
git clone https://github.com/aien-dev/aegis-runtime-mv aegis-runtime
git clone https://github.com/aien-dev/aien-protocols-mv aien-protocols
cd aegis-runtime
cargo build --release
```

### 运行网关

```bash
# Operator token: at least 32 printable characters, kept out of the repo.
export AEGIS_OPERATOR_TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
./target/release/aegis serve --port 18096
```

安全默认设置：
- 网关只监听 127.0.0.1。任何其他地址都需要 `--bind <ip> --allow-non-loopback-bind`。
- 除少数只读的 `GET` 路由（`/health`、`/api/v1/health`、`/v1/models`、`/api/v1/skills`、`/api/v1/events`、`/events`）之外，每个路由都需要操作员令牌，以 `Authorization: Bearer <token>` 或 `X-Aegis-Operator-Token: <token>` 的形式发送。这包括 `/api/v1/shell`、`/api/v1/skills/execute`、任务列表（`GET /api/v1/tasks`，其记录包含命令文本和输出）、其他所有 `POST` 请求以及 WebSocket。未配置令牌时，这些路由会拒绝所有请求。令牌也可以来自 `--operator-token-file <path>`。
- 技能和 shell 命令只能从允许列表中运行：已注册的技能名称；对于 shell，仅限 `git status`、`git diff`、`git log -1 --oneline`、`ls`。
- `write_file` 相对于一个持有的工作区目录描述符，逐级打开每个目录和末端文件。符号链接以及多重链接或非常规的目标文件会被拒绝；嵌套目录在该描述符树内部创建。这种隔离只适用于 `write_file`，不适用于任意 shell 命令。
- 每次技能调用和 shell 调用都会运行探针门控。`AIEN_PROBE_ENFORCE` 接受大于 0.5 且不超过 1.0 的数值，只能提高阈值；其他任何值都会保持默认值 0.5，因此它无法关闭门控。

### CLI 命令

`aegis --help` 列出 `serve`、`tick`、`heartbeat`、`ask`、`agent`、`simd` 和 `status`。以下示例在构建文件夹中运行：

```bash
# Run a single heartbeat tick
./target/release/aegis tick

# Run the heartbeat loop on its own (30 second default)
./target/release/aegis heartbeat

# Send one prompt to the inference backend (add --inference http to reach the local model seat)
./target/release/aegis ask "Analyze system health and pending tasks"

# Run an agent task with multi-turn tool calling (default 8 turns)
./target/release/aegis agent "Summarize the repository status" --max-turns 8

# Show runtime status
./target/release/aegis status

# Print a small vector math evaluation
./target/release/aegis simd --steps 10
```

使用存储的命令会在当前文件夹中写入 `aegis.sqlite`，除非设置了 `--db-path`。

## 测试

完整测试套件，按 Spark 的运行方式：

```bash
cargo test -- --test-threads=1
```

2026-10-19，该套件在 Spark 上于提交 `08ea496` 通过了 158 个测试（55 个库测试，外加 `tests/*.rs` 中的 103 个）。

向量数学函数会对照解析参考值以及 `tests/fixtures/simd_math_vectors.json` 中已提交的向量进行检查：

```bash
cargo test --lib vector_math::tests::test_analytical_parity
```

### 门禁以及证据存放位置

每个决定合并的测试都在 DGX Spark 上运行，而不是在 GitHub 上（[docs/PIPELINE.md](docs/PIPELINE.md)）。门禁就是 `tests/gates/` 中的文件。每个门禁都用一个步骤词调用 `tests/gates/run.sh`，因此你可以手动运行其中任何一个：

```bash
tests/gates/run.sh fmt
tests/gates/run.sh check
tests/gates/run.sh clippy
tests/gates/run.sh test
tests/gates/run.sh zero-disk-secrets
tests/gates/run.sh anti-slop
```

`.aien/always` 列出在每次提交时运行的门禁：`AEGIS-ZERO-DISK-SECRETS` 和 `AEGIS-ANTI-SLOP`。碎屑检查已停用（DRA-97，2026-11-07）：没有任何门禁或工作流运行 `crumb verify`，现有的 `.crumb` 文件作为历史保留。

Spark 对每个结果签名，并将其发布到 [aien-dev/aien-receipts](https://github.com/aien-dev/aien-receipts/tree/main/aegis-runtime)，每个被测试的提交对应一个文件夹。唯一必需的 GitHub 检查 `AIEN Verification` 会验证该已签名结果。

## 许可

版权所有 (c) 2026 Drake Stapleton <aien@aienos.com> 及 AIEN 贡献者。由 Drake Stapleton 与 AIEN 合作编写。

依据 GNU Affero 通用公共许可证 v3.0 或更高版本（AGPL-3.0-or-later）授予许可。参见 [LICENSE](LICENSE)。项目价值观载于不具约束力的 [COVENANT.md](COVENANT.md)，该文件既不授予也不限制任何法律权利。

## 人类主导的智能体工程

开发遵循人类主导的智能体工程（HDAE）：由人类定义目标、架构、约束、验收标准和停止点；智能体在这些边界内实现、执行检查、诊断失败并进行修订。人工评审对主张、验收和发布决定负责。这种开发方法不同于运行时的自主任务执行。

有关该方法的文档说明以及一个系统软件案例研究，请参阅 https://doi.org/10.5281/zenodo.23682548 收录的 Gregory M. Kurtzer，*Ginux: Building an Independent Kernel That Runs Linux Userspace through Human-Directed Agentic Engineering*（2026）。
