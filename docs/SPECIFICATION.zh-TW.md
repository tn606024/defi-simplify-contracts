# 合約規格

狀態：v1 normative draft
日期：2026-07-13

本文的 MUST、MUST NOT、REQUIRED、SHOULD、SHOULD NOT、MAY 都是規範性要求。

## 參考來源

本合約設計來自 `defi-simplify` SDK 與產品架構：

- project source: https://github.com/tn606024/defi-simplify
- upstream account baseline：eth-infinitism account-abstraction v0.9.0
  `Simple7702Account.sol`，commit
  `b36a1ed52ae00da6f8a4c8d50181e2877e4fa410`。
- dependency 與 Base EntryPoint lock：
  `config/account-abstraction-v0.9.0.json`。
- architecture decision 與 audit evidence：ADR-001。

實作必須以此精確、未修改的 upstream commit 取得 `Simple7702Account.sol`、
`BaseAccount.sol`、EntryPoint interfaces、compiler compatibility tests 與
reproducible deployment artifacts。後續 revision 必須建立 superseding ADR 與新
deployment identity。

## 1. Build 與平台要求

- Solidity 必須鎖定與上游 account-abstraction 相容的精確 0.8.x compiler；初始
  target 為 0.8.28。
- EVM target 必須支援 EIP-1153 transient storage。
- delegated execution 的 chain 必須支援 EIP-7702。
- Foundry、dependency revision、optimizer runs、`via_ir` 與 EVM version 都
  必須 commit 且可重現。
- Base v1 必須設定 v0.9.0 EntryPoint
  `0x433709009B8330FDa32311DF1C2AFA402eD8D009`，並在 ERC-4337 使用前驗證
  runtime code hash
  `0x826b7ec542db9f3345234a25c2a6330a61f99483dedb6e6709928cc97e4e4d5d`。
- production deployment 必須 verify source 並公布 runtime code hash。
- official v1 deployment 必須使用 Foundry 預設的 Arachnid Deterministic
  Deployment Proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C`。其
  runtime code hash 必須由 ADR 鎖定，並在每條 target chain 部署前驗證。
- deployment manifest 必須記錄 factory address、factory code hash、address-family
  identifier、salt、完整 initcode hash、constructor arguments、expected address、
  deployed runtime code hash。
- constructor arguments 是 initcode 的一部分；跨鏈相同地址除了相同 factory、
  salt、initcode，也要求相同 EntryPoint constructor argument。
- selected factory 尚未以 expected code 安裝，且 canonical deployment
  transaction 尚未證明可用的 chain，不得宣稱共享 official deterministic
  address。必須使用其他 factory 的 chain 屬於不同 address family。

### SDK Integration Requirements（Cross-Repo）

以下要求適用於獨立的 `defi-simplify` Go SDK，不屬於 Solidity ABI freeze：

- v1 SDK 必須拒絕 authorization `chain_id == 0` 的 EIP-7702 authorization。
  universal authorization 不在 v1 範圍；一般 authorization 必須使用 active
  chain ID。
- SDK 必須支援 custom deployment manifest。custom manifest 必須 pin address
  與 runtime code hash，並區分 reproducible direct immutable artifact 與使用者
  自行信任的 unknown code。unknown code 不得被呈現為符合規格或已經
  project-verified。
- 同一 transaction 組合多條 logical flows 時，SDK 必須在
  `(transaction, account)` scope 產生唯一 assertion snapshot ID。
- protocol adapter 必須從 structured ABI 推導 calldata、account binding、return
  offsets，並提供 distinct-sentinel golden tests。
- cross-repo integration suite 必須測試 universal authorization rejection、
  custom manifest trust levels、generic assertion 兩種 modes，以及精確
  Go/Solidity offset agreement。

## 2. IDefiSimplify7702Account

public interface 概念如下：

```solidity
interface IDefiSimplify7702Account {
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

    function executeBatchDynamic(DynamicCall[] calldata calls) external payable;
}
```

implementation 必須透過 ERC-165 宣告 custom interface，同時保留 inherited
account 支援的全部 interface。

## 3. Construction 與 State

account 必須繼承鎖版 `Simple7702Account`，不得修改上游 source。

以 v0.9.0 baseline 為例：

```solidity
constructor(IEntryPoint entryPoint) Simple7702Account(entryPoint) {}
```

implementation 不得定義 permanent storage variable；允許 constant 與
immutable。checkpoint state 與 execution lock 必須使用 domain-separated key
的 transient storage。

合約不得 upgradeable，也不得有 owner、admin、withdrawal function、protocol
registry 或 protocol allowlist。

deployed account 與 `FlowAssertions` target 必須是 direct immutable contract，
不得是 proxy。runtime code-hash match 本身不能證明 target 不是 proxy；official
manifest 必須把 code hash 綁到 reproducible direct-deployment artifact 與 verified
source。

## 4. Authorization

`executeBatchDynamic` 在讀取或改變 execution state 前，必須先呼叫 inherited
`_requireForExecute()`。

允許的路徑只有：

- `msg.sender == address(this)`，也就是一般 EOA-to-self delegated transaction；
- deployment 時選定的 immutable EntryPoint。

v1 不得新增第二套 signature scheme、nonce、role、session key 或 relayer
authorization。

## 5. Dynamic Execution Lock

`executeBatchDynamic` 必須使用 transient reentrancy lock。

- lock 已設定時進入，必須 revert `DynamicExecutionReentered()`。
- authorization 後、處理 calls 前設定 lock。
- 成功 return 前清除 lock。
- revert 會自然回滾 lock write。
- dynamic call 的 `target == address(this)` 時必須 revert，避免已授權但建錯的
  plan 形成 nested self-execution。

inherited static `execute` 與 `executeBatch` 行為不因本條規格改變。

## 6. Checkpoint Model

每個 `BalanceCheckpoint` 在其所屬 call 的 patches resolve 完成後、真正呼叫
target 前，記錄當下 ERC20 balance。resolve patch 不會改變 chain state。

要求：

- `token` 不得為 zero address。
- `id` 不得為 zero。
- 同一次 `executeBatchDynamic` invocation 內，ID 必須全域唯一，與 token 無關。
- patch 不得使用同一 call 宣告的 checkpoint；resolve patch 時只看得到更早
  calls 建立的 checkpoint。
- duplicate ID 必須 revert
  `CheckpointAlreadyExists(callIndex, checkpointIndex, id)`。
- token balance 必須以 `STATICCALL balanceOf(address(this))` 讀取。
- call 失敗或 return data 少於 32 bytes，必須 revert
  `BalanceReadFailed(token, reason)`。
- checkpoint presence、token、value 必須放在三組 domain-separated transient
  slots。
- 同一 transaction 的後續 invocation 不得觀察到前一次 invocation 的 checkpoint
  state。implementation 可以清除 checkpoint slots，或把 transient invocation
  counter 納入 checkpoint key derivation。這是 observable isolation requirement，
  不是指定 cleanup mechanism。

checkpoint ID 是 SDK 產生的 opaque identifier，跨 transaction 沒有意義。

## 7. Patch Model

### 7.1 Offset

`offset` 從 `DynamicCall.data` 開頭起算，包含 function selector。

每個 patch：

- `offset` 必須至少為 4；
- `(offset - 4) % 32` 必須等於 0；
- `uint256(offset) + 32` 必須小於等於 `data.length`；
- 同一 call 的 patches 必須依 offset 嚴格遞增。

違反時必須回傳帶 index 的 custom error。嚴格排序可以不用 O(n squared) 掃描
就拒絕 duplicate；SDK 負責在 encode 前排序。

合約必須先把 `data` 複製到 memory 再 patch，不得把 Solidity calldata 當成
可寫 memory。

### 7.2 Basis Points

`bps` 必須介於 1 到 10,000，超出時 revert
`InvalidBps(callIndex, patchIndex, bps)`。

resolved amount：

```text
floor(base * bps / 10_000)
```

implementation 必須使用 full-precision `mulDiv`，避免 intermediate
multiplication overflow。

percentage 以每次 patch 當下看得到的 balance 為 base。跨不同 calls 時，較早
call 若真的消耗 token，後一個 patch 看到的 base 就會縮小。例如把 delta 平分給
兩個 consumer calls，第一個使用 5,000 bps，第二個使用 10,000 bps 消耗剩餘
delta。同一 call 的多個 patches 都看到相同 pre-call balance，因為 patch
resolution 之間沒有 token consumption。

### 7.3 CurrentBalance

`CurrentBalance` 模式：

- `checkpointId` 必須為 zero；
- `base` 是 patch 當下的 `IERC20(token).balanceOf(address(this))`。

這個模式會明確包含 account 既有 inventory。

### 7.4 CheckpointDelta

`CheckpointDelta` 模式：

- `checkpointId` 必須非 zero，且已在同 invocation 的更早位置建立；
- checkpoint token 必須等於 `patch.token`；
- `base = currentBalance - checkpointBalance`；
- current balance 小於 checkpoint 時，必須 revert
  `BalanceBelowCheckpoint(token, checkpointId, current, checkpoint)`。

missing checkpoint 與 token mismatch 必須是不同 custom error。implementation
不得把負 delta 靜默 clamp 成 zero。

### 7.5 Patched Word

resolved unsigned integer 必須只覆寫 `offset` 起始的 32 bytes，其他 calldata
byte 不得改變。

合約可以 resolve 出 zero amount；是否接受 zero 由 protocol call 或明確
assertion 決定，v1 不加入 generic non-zero policy。

## 8. Call Execution

calls 必須依 array order 執行，以 EVM `CALL` 帶入宣告的 `value` 與剩餘 gas。

每個 `calls[i].value` 從 delegated account 的 native balance 支付。implementation
不得要求 `sum(calls[i].value) <= msg.value`；`msg.value` 不是 batch spending
budget。account balance 不足時由 underlying call failure 與 atomic revert 處理。

每個 call 前必須：

1. 拒絕 zero target；
2. 拒絕 `target == address(this)`；
3. 使用更早 checkpoints，依序驗證並套用 patches；
4. 依序建立該 call checkpoints；
5. 以 patched memory 呼叫 target。

v1 丟棄成功 call 的 return data。

任一 call 失敗必須 revert：

```solidity
error DynamicCallFailed(uint256 index, address target, bytes reason);
```

`reason` 必須保留 target 完整 revert data。即使 dynamic batch 只有一個 call，
也使用 wrapper，讓 SDK decode 一致。

empty batch 必須 revert `EmptyDynamicBatch()`。

## 9. Account 必要 Errors

名稱可在 ABI freeze 前調整一次，但 final contract 必須提供等價的 indexed
information：

```solidity
error EmptyDynamicBatch();
error DynamicExecutionReentered();
error InvalidTarget(uint256 callIndex, address target);
error InvalidCheckpointToken(uint256 callIndex, uint256 checkpointIndex);
error InvalidCheckpointId(uint256 callIndex, uint256 checkpointIndex);
error CheckpointAlreadyExists(uint256 callIndex, uint256 checkpointIndex, bytes32 id);
error CheckpointNotFound(uint256 callIndex, uint256 patchIndex, bytes32 id);
error CheckpointTokenMismatch(uint256 callIndex, uint256 patchIndex, bytes32 id, address expected, address actual);
error InvalidPatchToken(uint256 callIndex, uint256 patchIndex);
error InvalidPatchOffset(uint256 callIndex, uint256 patchIndex, uint256 offset, uint256 dataLength);
error UnsortedPatchOffset(uint256 callIndex, uint256 patchIndex, uint256 previous, uint256 current);
error InvalidBps(uint256 callIndex, uint256 patchIndex, uint256 bps);
error UnexpectedCheckpointId(uint256 callIndex, uint256 patchIndex, bytes32 id);
error BalanceReadFailed(address token, bytes reason);
error BalanceBelowCheckpoint(address token, bytes32 id, uint256 current, uint256 checkpoint);
error DynamicCallFailed(uint256 index, address target, bytes reason);
```

inherited static execution errors 維持不變。

## 10. IFlowAssertions

v1 interface 概念如下：

```solidity
interface IFlowAssertions {
    function snapshotBalance(address token, bytes32 checkpointId) external;

    function assertBalanceAtLeast(
        address token,
        uint256 minimum
    ) external view;

    function assertBalanceIncreaseAtLeast(
        address token,
        bytes32 checkpointId,
        uint256 minimumDelta
    ) external view;

    function assertBalanceDecreaseAtMost(
        address token,
        bytes32 checkpointId,
        uint256 maximumDelta
    ) external view;

    function assertAaveHealthFactorAtLeast(
        address pool,
        uint256 minimumHealthFactor
    ) external view;

    function assertStaticCallUint256AtLeast(
        address target,
        bytes calldata data,
        uint32 accountOffset,
        uint32 returnOffset,
        uint256 minimum
    ) external view;

    function assertStaticCallUint256AtMost(
        address target,
        bytes calldata data,
        uint32 accountOffset,
        uint32 returnOffset,
        uint256 maximum
    ) external view;
}
```

### 10.1 Assertion Identity

所有 balance read 必須檢查 `msg.sender`。API 不得接收任意 account parameter，
避免 SDK 不小心 assert 錯帳戶。

snapshot key 必須包含 `msg.sender` 與 checkpoint ID，並分開儲存 presence、
token、value。

`snapshotBalance` 必須拒絕 zero token、zero checkpoint ID，以及同 sender 在
目前 transaction 的 duplicate ID。snapshot ID 以 sender 為 scope，不同 account
可安全使用相同 ID。

assertion snapshot 刻意維持 transaction-scoped，成功 assertion 不 consume 或
clear snapshot。cross-repo SDK namespacing requirement 定義在 Section 1 的
integration subsection。這個 lifecycle 刻意不同於 account checkpoint invocation
isolation，讓同一 snapshot 可以支援多個 assertions。

### 10.2 Balance Assertions

- `assertBalanceAtLeast`：current balance 大於等於 `minimum` 時通過。
- `assertBalanceIncreaseAtLeast`：使用 saturating increase；current 小於
  checkpoint 時 actual increase 為 zero，actual 至少等於 `minimumDelta` 時通過。
- `assertBalanceDecreaseAtMost`：使用 saturating decrease；current 大於
  checkpoint 時 actual decrease 為 zero，actual 不超過 `maximumDelta` 時通過。
- missing checkpoint 或 token mismatch 必須在 threshold evaluation 前 revert。

failure error 必須包含 token、actual value 或 delta、required bound。

### 10.3 Aave Health Factor

`assertAaveHealthFactorAtLeast` 必須呼叫傳入的 Aave-compatible Pool
`getUserAccountData(msg.sender)`，比較回傳 health factor 與
`minimumHealthFactor`。

function 不得使用另一套 oracle；結果刻意採用 Pool 自身的 account 與 oracle
view。

失敗必須包含 pool、actual health factor、minimum health factor。

### 10.4 可選 Account Binding 的 Generic Uint256 Assertions

generic assertions 是固定位置 `uint256` protocol read 的窄橋接能力。
`accountOffset` 明確選擇兩種模式：

- `accountOffset == type(uint32).max` 是 global-read mode，不修改 input calldata。
- 其他值是 account-binding mode，在 `STATICCALL` 前把指定 ABI word 覆寫為
  `msg.sender`。

兩個 generic functions 都必須：

1. 拒絕 zero target 與 `target == address(this)`；
2. 要求 call data 至少四 bytes；
3. 當 `accountOffset != type(uint32).max` 時，要求 `accountOffset >= 4`、
   `(accountOffset - 4) % 32 == 0`、
   `uint256(accountOffset) + 32 <= data.length`；
4. 把 `data` 複製到 memory，且只在 account-binding mode 把
   `accountOffset` 的 word 覆寫成 zero-left-padded `msg.sender`；
5. 以 patched data 執行 `STATICCALL`；
6. 要求 `returnOffset % 32 == 0` 且
   `returnOffset + 32 <= returndata.length`；
7. 只把該 return word 解讀為 `uint256` 並套用指定 bound。

account binding 是 adapter-safety guardrail，不是 authorization boundary。若
Solidity target 的 ABI decoder 忽略尾端 calldata，caller 可以 append unused word，
再把 `accountOffset` 指向它，而 target 仍讀取未修改的真正 arguments。因此
global read 是受支援能力，但 compliant adapter 必須使用明確的
`type(uint32).max` sentinel，不能使用 padding bypass。account-bound adapter
test 必須證明更換 bound subject 會改變 selected result。

protocol adapter 依 Section 1 的 cross-repo ABI 與 golden-test requirements。
binding-mode fixture 必須為 real account word、appended padding、selected return
word、adjacent return words 設定互不相同的值；global-mode fixture 涵蓋 rate、
account-independent conversion 或 quote read。

generic assertion failure 必須在適用時包含 target、selector、offsets、actual
value、bound。SDK 負責把 low-level context 還原成 protocol 語意。

### 10.5 Assertion 必要 Errors

final ABI 必須提供以下等價資訊：

```solidity
error InvalidAssertionToken(address token);
error InvalidAssertionCheckpointId(bytes32 id);
error AssertionCheckpointAlreadyExists(address account, bytes32 id);
error AssertionCheckpointNotFound(address account, bytes32 id);
error AssertionCheckpointTokenMismatch(address account, bytes32 id, address expected, address actual);
error AssertionBalanceReadFailed(address token, bytes reason);
error BalanceBelowMinimum(address token, uint256 actual, uint256 minimum);
error BalanceIncreaseTooSmall(address token, bytes32 id, uint256 actualDelta, uint256 minimumDelta);
error BalanceDecreaseTooLarge(address token, bytes32 id, uint256 actualDelta, uint256 maximumDelta);
error AaveAccountDataReadFailed(address pool, bytes reason);
error AaveHealthFactorTooLow(address pool, uint256 actual, uint256 minimum);
error InvalidAssertionTarget(address target);
error InvalidAssertionCallData(uint256 dataLength);
error InvalidAssertionAccountOffset(uint256 offset, uint256 dataLength);
error InvalidAssertionReturnOffset(uint256 offset, uint256 returnDataLength);
error AssertionStaticCallFailed(address target, bytes4 selector, uint256 accountOffset, bytes reason);
error StaticCallUint256BelowMinimum(address target, bytes4 selector, uint256 accountOffset, uint256 returnOffset, uint256 actual, uint256 minimum);
error StaticCallUint256AboveMaximum(address target, bytes4 selector, uint256 accountOffset, uint256 returnOffset, uint256 actual, uint256 maximum);
```

## 11. FlowAssertions State 與權限

`FlowAssertions` 必須：

- 無 owner 或 admin；
- 無 upgrade path；
- 無 permanent storage；
- 無 payable asset-moving method；
- 任何 account 都能呼叫；
- snapshot 僅使用 transient state；
- 使用 custom error，不用 string revert。

## 12. Event Policy

`DefiSimplify7702Account` v1 與 `FlowAssertions` v1 不得 emit custom execution
或 assertion events。v1 observability surface 是 transaction receipt、target
protocol events、token events、traces。

## 13. Static Compatibility

以下 inherited behavior 必須和鎖版上游維持 ABI compatibility：

- `execute(address,uint256,bytes)`；
- `executeBatch(BaseAccount.Call[])`；
- `validateUserOp`；
- `isValidSignature`；
- upstream interfaces 的 `supportsInterface`；
- token receiver callbacks；
- fallback 與 receive behavior。

test suite 必須把相同 static call array 分別送進 upstream 與 custom account，
比較 final state 與 failure attribution。

## 14. v1 明確不做

v1 不支援：

- dynamic native-asset balance 或 call-value patching；
- 從 return data patch；
- arbitrary arithmetic expression；
- signed integer 或 negative delta；
- callback 或 flash-loan receiver；
- delegatecall target；
- protocol allowlist 或 policy engine；
- session key；
- account-level batch deadline；
- protocol-native read 以外的 oracle assertion；
- authorization `chain_id == 0` 的 EIP-7702 universal authorization；
- upgradeability。

protocol calldata 仍可包含自己的 deadline、slippage limit、price bound、
referral code、receiver address 與 safeguards。

## 15. Acceptance Tests

implementation 至少必須通過：

- self、configured EntryPoint、random caller、malicious callback caller 的
  authorization tests；
- 對鎖版 upstream 的 static compatibility tests；
- one-call 與 many-call success tests；
- call failure index 與 nested revert decode tests；
- checkpoint create、consume、duplicate、missing、token mismatch、invocation
  isolation、same-token multi-checkpoint tests；
- same-call checkpoint reference 在 target execution 前失敗；
- 同 token 先支出再收入的 existing-inventory tests；
- current-balance explicit sweep tests；
- bps boundary 與 `mulDiv` property tests；
- offset lower-bound、alignment、upper-bound、sorting，以及與 Go-generated
  calldata 逐 byte 對拍的 golden tests；
- malformed 與 reverting ERC20 `balanceOf` tests；
- self-target 與 dynamic reentrancy tests；
- FlowAssertions success 與 forced-failure tests；
- assertion snapshot zero、duplicate、missing、token-mismatch tests；
- 同一 transaction 兩條 logical assertion flows 使用 namespaced snapshot IDs；
- generic assertion bound/global modes、account-word replacement、explicit
  no-binding sentinel、documented padding bypass、input/return offset bounds、
  adjacent sentinel return words、staticcall failure、兩種 comparison direction；
- deterministic deployment address calculation、factory code-hash validation、
  manifest reproduction、direct-artifact verification、custom manifest tests；
- 成功 v1 execution 不 emit custom account 或 assertion events；
- Aave + Uniswap fork flow，並驗證 final HF failure rollback；
- 宣稱相容前完成 Morpho 與 Pendle adapter-level fork tests；
- representative static 與 dynamic batch gas snapshots。
