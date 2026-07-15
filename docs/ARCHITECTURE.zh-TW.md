# 架構

狀態：實作設計
日期：2026-07-15

## 1. 系統脈絡

```text
Go application
  -> defi-simplify SDK
       -> 建立 static Calls 或 checkpoint-based DynamicCalls
       -> 模擬完整 delegated execution
       -> 送出 EIP-7702 transaction 或一般 delegated-account call
            -> 使用者 delegated EOA
                 -> protocol contracts
                 -> FlowAssertions
```

Go SDK 知道 protocol ABI 與使用者意圖。account contract 只知道授權、ERC20
balance、checkpoint、calldata offset 與 call。assertion contract 只負責 read-only
post-condition。

## 2. Repo 邊界

目標 repo 結構：

```text
src/
  DefiSimplify7702Account.sol
  FlowAssertions.sol
  interfaces/
    IDefiSimplify7702Account.sol
    IFlowAssertions.sol
test/
  unit/
  fuzz/
  invariant/
  fork/
  mocks/
script/
  Deploy.s.sol
deployments/
  <chain-id>.json
docs/
  VISION.md
  ARCHITECTURE.md
  SPECIFICATION.md
  SECURITY.md
  ROADMAP.md
```

repo 要輸出 ABI JSON、implementation address、runtime code hash、compiler
settings 與 source verification metadata；不放 Go protocol adapter。

## 3. 上游 Account Baseline

`DefiSimplify7702Account` 繼承 `eth-infinitism/account-abstraction` v0.9.0
完整 commit `b36a1ed52ae00da6f8a4c8d50181e2877e4fa410` 的
`Simple7702Account`。source 是未修改的 Git submodule，其 OpenZeppelin
v5.1.0 Solidity dependency 另外鎖在
`69c8def5f222ff96f2b5beff05dfba996368aa79`。

account 以 constructor 接收 immutable EntryPoint。Base 使用 v0.9.0 EntryPoint
`0x433709009B8330FDa32311DF1C2AFA402eD8D009`，runtime code hash 為
`0x826b7ec542db9f3345234a25c2a6330a61f99483dedb6e6709928cc97e4e4d5d`。
dependency lock、compiler compatibility、license、audit evidence、inherited
risks 與 update rule 記錄在 ADR-001。目前沒有找到 v0.9-specific audit
evidence，因此不把 v0.8.0 release 的 audit 說法延伸到此 baseline。

自家合約不得複製或修改上游檔案。透過繼承保留：

- `execute` 與 `executeBatch` static path；
- self-or-EntryPoint execution authorization；
- ERC-4337 validation；
- ERC-1271 signature validation；
- ERC-721 與 ERC-1155 receiving support；
- 上游 static batch 的 `ExecuteError(index, reason)` 行為。

即使 inherited code 曾經 audit，自家 repo 仍要對最後合併 bytecode 的安全負責。

Phase 1 baseline `src/DefiSimplify7702Account.sol` 是 pinned account 的 concrete、
可 direct deployment constructor wrapper。它不定義 custom storage 或 public
surface；ABI 必須與 `Simple7702Account` 完全相同。dynamic execution 只由後續
負責該 ABI 與 behavior 的 phase 加入。

## 4. 合約元件

### 4.1 DefiSimplify7702Account

在 static compatibility baseline，custom account 只有 inherited upstream
behavior。完成版 v1 account 之後才新增一項能力：

```solidity
function executeBatchDynamic(DynamicCall[] calldata calls) external payable;
```

它沒有 owner、upgrade mechanism、protocol registry、allowlist 或 permanent
storage。授權沿用 `_requireForExecute()`。

概念資料模型：

```solidity
enum BalanceSource {
    CurrentBalance,
    CheckpointDelta
}

struct BalanceCheckpoint {
    address token;
    bytes32 id;
}

struct BalancePatch {
    address token;
    bytes32 checkpointId;
    uint32 offset;
    uint16 bps;
    BalanceSource source;
}

struct DynamicCall {
    address target;
    uint256 value;
    bytes data;
    BalanceCheckpoint[] checkpointsBefore;
    BalancePatch[] patches;
}
```

每個 `DynamicCall` 的順序：

```text
驗證 call 與 patch metadata
  -> 把 call.data 從 calldata 複製到 memory
  -> 從更早 calls 建立的 checkpoint resolve 每個 patch
  -> 以目前 ERC20 balance 記錄 checkpointsBefore
  -> 帶 value CALL target
  -> 繼續，或以 DynamicCallFailed(index, target, reason) revert
```

同一 call 內先 resolve patch，再於真正 CALL 前建立 checkpoint。patch 不能引用
同一 call 宣告的 checkpoint。若 patch 要使用 call N 的 output，checkpoint 應
放在 call N 前，並由 call N+1 或之後使用。

### 4.2 為什麼 Checkpoint 必須在 Flow 中間

單一 flow-start snapshot 對常見槓桿 flow 是錯的：

```text
起始 WETH balance = 1.0
supply 1.0 WETH   -> current balance = 0
swap borrowed USDC -> current balance = 0.8 WETH
```

flow-start delta 是 `0.8 - 1.0`，結果為負數，但 swap 明明產生了 0.8 WETH。
正確 baseline 是 swap 前立刻建立 WETH checkpoint。具名 in-flow checkpoint 也
允許同一 token 在一筆交易裡有多組互不干擾的 delta。

範例排程：

```text
[0] supply WETH
[1] checkpoint USDC "borrow-output"; borrow USDC
[2] 以 USDC delta since "borrow-output" approve Router
[3] checkpoint WETH "swap-output"; swap USDC delta
[4] supply WETH delta since "swap-output"
[5] assert final Aave health factor
```

### 4.3 Patch 語意

`offset` 從 `DynamicCall.data` 的 byte 0 起算；四 bytes function selector 位於
offset 0 到 3。v1 每次 patch 一個 ABI-aligned 32-byte word，越界或未對齊就
revert。

`bps` 分母是 10,000：

```text
10,000 = 100%
 5,000 = 50%
   100 = 1%
     1 = 0.01%
```

patch amount 為 `floor(base * bps / 10_000)`，使用 full-precision mul/div。
`base` 是目前完整 balance，或 `currentBalance - checkpointBalance`。

balance percentage 是跨 calls 依序組合，不是同一 call 內跨 patches 組合。第一個
consumer call 若花掉 delta 的 50%，後一個 consumer 使用 10,000 bps 花剩餘
50%。同一 target call 前 resolve 的兩個 patches 都看到相同 pre-call balance。

implementation 可以在同一 call 的 patch resolution 與 checkpoint creation 間，
依 token cache 一份 pre-call balance。error attribution 歸屬第一個觸發讀取的
patch 或 checkpoint。cache 在 target `CALL` 前結束，後續 call 會看到更新後的
chain state。

`token` 明確指定要讀哪個 ERC20：

```solidity
IERC20(token).balanceOf(address(this))
```

EIP-7702 delegated execution 中，`address(this)` 就是使用者 EOA。

### 4.4 Function-Local 與 Transient State

account checkpoint records 使用 function-local memory。implementation 先加總
所有 `checkpointsBefore.length`，配置 fixed-capacity record array，並追蹤已填入
長度。每筆 record 包含 opaque ID、token、balance；duplicate 與 lookup 只 linear
scan 已填入 prefix。對 v1 plan size 而言，這比每筆 record 做多次 hash 與
transient slot access 更簡單也更便宜。

function-local memory 讓 checkpoint isolation 成為結構性保證：external target
frame 無法查詢 records，後續 dynamic invocation 取得全新 array，return 或 revert
後 records 直接消失。已填入長度是無歧義的 presence marker，即使記錄 balance
為 zero 也成立。因此 account 不需要 checkpoint invocation counter、transient
checkpoint keys 或 cleanup list。

dynamic execution lock 仍使用具 domain separation 的 EIP-1153 transient key。
checkpoint record 不同，lock 必須讓企圖 reenter account 的新 call frame 看見。
account 在成功 return 前清除 lock；revert 會回滾 transient write。
FlowAssertions snapshot 仍是 transaction-scoped transient state，不受此
account-specific decision 影響。邊界與 alternatives 記錄於 ADR-002。

### 4.5 FlowAssertions

`FlowAssertions` 獨立部署，由 delegated EOA 以一般 CALL 呼叫，因此
`msg.sender` 是被檢查的使用者 account。

它具備以下特性：

- 無 owner；
- 不可升級；
- 無 permanent storage；
- 沒有移動資產的 function；
- transient checkpoint 以 `msg.sender`、token、checkpoint ID 為 key。

v1 assertions：

```solidity
snapshotBalance(address token, bytes32 checkpointId)
assertBalanceAtLeast(address token, uint256 minimum)
assertBalanceIncreaseAtLeast(address token, bytes32 checkpointId, uint256 minimumDelta)
assertBalanceDecreaseAtMost(address token, bytes32 checkpointId, uint256 maximumDelta)
assertAaveHealthFactorAtLeast(address pool, uint256 minimumHealthFactor)
assertStaticCallUint256AtLeast(target, data, accountOffset, returnOffset, minimum)
assertStaticCallUint256AtMost(target, data, accountOffset, returnOffset, maximum)
```

assertion 都是普通 call，因此 upstream static batch 與 custom dynamic batch 都能
使用，不需要把 checker 耦合進 account。

generic assertion 有兩種明確模式。一般 `accountOffset` 會把指定 calldata word
覆寫為 `msg.sender`；`type(uint32).max` sentinel 執行不修改 calldata 的 global
read。account binding 是 adapter guardrail，不是 authorization boundary，因為
target 可能忽略尾端 calldata，使 padding 繞過 target 真正讀取的 argument。
compliant global adapter 必須使用 sentinel，不能用 padding。input 與 return
offset 必須由 ABI 推導並有 golden test。assertion snapshot 維持
`(transaction, msg.sender)` scope，同一 snapshot 可供多個 assertions 使用；組合
多條 logical flows 時由 SDK namespace IDs。

兩個 v1 contracts 都不 emit custom events。observability 由 receipt、protocol 與
token events、trace 提供。

## 5. Execution Modes

```text
Direct EOA
  one call；EOA caller；沒有 multi-call atomicity

Simple7702Account static batch
  exact calldata；EOA caller；atomic；custom risk 最低

DefiSimplify7702Account static batch
  繼承 exact-calldata behavior；用於 compatibility test

DefiSimplify7702Account dynamic batch
  checkpoint delta 與 full-balance patch；EOA caller；atomic

Legacy Multicall
  external contract caller；atomic；不是 EOA-native
```

Static batch 仍是一等功能。只有至少一個 amount 必須在鏈上 resolve 時才選
dynamic execution。

## 6. Capability Detection

SDK 應執行：

1. 讀 EOA code 並解析 EIP-7702 delegation indicator；
2. 對照 chain deployment manifest 的 delegation target；
3. 驗證 target runtime code hash；
4. 驗證 official target 對應 reproducible direct immutable artifact，不能把 proxy
   code hash 當成 immutable logic；
5. 以 ERC-165 `supportsInterface` 檢查 custom dynamic interface；
6. 根據 built flow requirements 選擇 static 或 dynamic encoding。

version string 不是安全身分；對已知 direct artifact，deployment address 與 runtime
code hash 才是。SDK 也接受 custom deployment manifest，但必須區分 reproducibly
verified artifact 與 user-trusted unknown code。

## 7. Protocol 相容性

| Protocol 形狀 | v1 狀態 | 原因 |
| --- | --- | --- |
| Aave V3 一般 Pool call | 支援 | input/output 是 ERC20 balance，final HF 可讀 |
| Uniswap router exact-input swap | 支援 | runtime input 可 patch，router 檢查 `amountOutMinimum` |
| Morpho Blue 一般 lending call | 支援 | asset amount 可由 ERC20 balance 表示 |
| Morpho internal-share piping | 部分 | shares 是 protocol accounting，不一定是 ERC20 balance |
| Pendle Router PT operation | adapter test 後支援 | amount word 可能巢狀，但仍 ABI-aligned |
| ERC4626、WETH、Lido wrapper | adapter test 後支援 | ERC20 in/out model |
| Uniswap V3 LP NFT management | dynamic 不支援 | 後續 call 可能需要 return token ID |
| Flash loan 與 direct callback | 不支援 | 需要 authenticated callback state machine |
| Native ETH dynamic amount | v1 不支援 | balance source 僅 ERC20；使用 WETH |
| Cross-chain 與 off-chain signed route | 不在範圍 | trust 與 lifecycle 不同 |

protocol-specific slippage 與 deadline 仍是普通 calldata。account 不應取代 router
或 protocol 原生保護。

## 8. Deployment Model

account 與 `FlowAssertions` 必須透過 Foundry 預設的 Arachnid Deterministic
Deployment Proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C` 部署成
direct immutable contracts。只有 factory、salt、完整 initcode 都相同時，跨鏈
deployment address 才相同；initcode 包含 immutable EntryPoint constructor
argument。使用者 delegate EOA 到 account implementation。

跨鏈地址一致是有前提的，不是 universal guarantee。某 chain 被列入 official
address family 前，Phase 0 必須驗證 factory 已以 pinned code hash 存在，或其
canonical deployment transaction 能被該 chain 接受。無法安裝 legacy keyless
factory 的 chain 可以使用 Safe Singleton Factory 等 maintained alternative，
但必須屬於不同 address family 與 manifest。

每份 deployment manifest 必須包含：

- chain ID；
- implementation 與 assertion address；
- runtime code hash；
- CREATE2 factory address 與 code hash；
- address-family identifier；
- salt、完整 initcode hash、constructor arguments；
- upstream account-abstraction commit；
- EntryPoint address、version、code hash；
- Solidity 與 Foundry version；
- optimizer 與 EVM settings；
- source verification link；
- deployment transaction hash。

target 不得是 proxy，也不使用 upgrade admin。新版本部署到新的 implementation
或 assertion address；使用者自行決定是否 redelegate 或選擇新 checker。舊
assertion versions 可永久共存。

self-deployment 是一等路徑。SDK 接受 custom manifest，套用相同 address 與
code-hash verification。相同 initcode 經相同 factory 與 salt 會得到相同地址；
相同 direct artifact 以其他方式部署，runtime code hash 可以相同但地址不同。

v1 SDK 只簽 per-chain EIP-7702 authorization，拒絕 authorization
`chain_id == 0`。EIP-7702 同一時間只有一個 delegation target，因此建議使用
active delegate 唯一為本 account implementation 的專用 EOA。

## 9. 參考資料

- EIP-7702: https://eips.ethereum.org/EIPS/eip-7702
- EIP-1153: https://eips.ethereum.org/EIPS/eip-1153
- Weiroll: https://github.com/weiroll/weiroll
- Foundry `cast create2` default deployer: https://getfoundry.sh/cast/reference/cast-create2
- Arachnid Deterministic Deployment Proxy: https://github.com/Arachnid/deterministic-deployment-proxy
- Safe Singleton Factory: https://github.com/safe-fndn/safe-singleton-factory
- account-abstraction releases: https://github.com/eth-infinitism/account-abstraction/releases
- Simple7702Account v0.9.0: https://github.com/eth-infinitism/account-abstraction/blob/v0.9.0/contracts/accounts/Simple7702Account.sol
- BaseAccount v0.9.0: https://github.com/eth-infinitism/account-abstraction/blob/v0.9.0/contracts/core/BaseAccount.sol
