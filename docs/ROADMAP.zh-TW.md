# 路線圖

狀態：實作順序
日期：2026-07-12

## Phase 0：Repo 與 Dependency Freeze

交付項目：

- 建立 Foundry repo、CI、format、lint、coverage、gas snapshot；
- 放入英文與繁體中文文件；
- 鎖定 account-abstraction release 與完整 commit；
- 記錄 license obligations；
- 選定並驗證 EntryPoint version；
- 鎖定 Foundry 預設 Arachnid factory
  `0x4e59b44847b379578588920cA78FbF26c0B4956C`、runtime code hash、salt policy；
- 建立 deployment manifest schema；
- 定義 official、verified self-deployed、user-trusted custom manifest trust levels；
- 以 ADR-001 記錄上游版本與 audit evidence。

離開條件：

- 可重現 build 未修改的 upstream `Simple7702Account`；
- fork test 證明 direct delegated static batch execution；
- 每條 target chain 驗證 pinned factory code 已存在，或 canonical deployment
  transaction 可被接受；
- 需要 Safe Singleton Factory 或其他 maintained alternative 的 chain 明確分類為
  不同 address family；
- deployment script、address prediction、manifest、Foundry tooling configuration
  使用同一 factory。

## Phase 1：Static Compatibility Baseline

交付項目：

- 先做沒有 dynamic function 的最小 inherited `DefiSimplify7702Account`；
- differential test `execute`、`executeBatch`、ERC-1271、receiver interface、
  failure wrapping；
- EIP-7702 self-call 與 EntryPoint authorization tests；
- Base fork 上跑 approve、Aave supply、borrow；
- 證明 Aave 看到 user EOA，不是 Multicall；
- deployment 與 runtime code-hash tooling。

離開條件：custom account 是已驗證、沒有 behavior drift 的 static superset。

## Phase 2：Dynamic Checkpoint Engine

交付項目：

- freeze `IDefiSimplify7702Account` ABI；
- 實作 `executeBatchDynamic`；
- checkpoint presence、token、value、domain separation；
- transient invocation isolation，不要求 checkpoint cleanup list；
- current-balance 與 checkpoint-delta sources；
- full-precision bps math；
- indexed custom errors 與 nested revert preservation；
- reentrancy lock 與 self-target rejection；
- unit、fuzz、invariant、adversarial、gas tests；
- 輸出供 Go SDK 使用的 Solidity golden vectors。

關鍵離開測試：

- 先花 existing WETH，再收到 swap output，下一步只消耗 swap output；
- 同 token 多個 checkpoint 互不干擾；
- Go-generated offset 只 patch 預期 ABI word；
- malformed ERC20、offset、source、bps、checkpoint reference 都 revert。

## Phase 3：FlowAssertions v1

交付項目：

- freeze `IFlowAssertions` ABI；
- balance snapshot 與三種 balance assertion；
- Aave health-factor assertion；
- 有明確 bound/global modes 的 generic staticcall `uint256` at-least/at-most
  assertions；
- custom-error ABI 與 SDK decode fixtures；
- transaction-scoped assertion snapshot ID namespacing；
- explicit no-custom-events policy tests；
- padding-bypass documentation tests 證明 account binding 是 guardrail，並測試
  sanctioned global-read sentinel；
- static、dynamic batch integration tests；
- 強制 final assertion failure，證明 total rollback。

離開條件：assertion 加在 upstream static batch 或 custom dynamic batch 後都能
得到相同行為。

## Phase 4：Protocol Proofs

protocol 相容性必須靠 end-to-end fork test 證明，不能只靠 ABI 理論。

順序：

1. ERC20、WETH、Aave V3、Uniswap exact-input single。
2. Lido wstETH wrapper 與 E-Mode flagship loop，v1 限定走 DEX
   WETH-to-wstETH swap route；WETH unwrap 後直接呼叫 Lido
   `submit{value: ...}` 與 native ETH value patching 一起 deferred。
3. Morpho Blue lending 與 Aave-to-Morpho migration。
4. Pendle PT buy、sell、redeem、rollover。
5. 部分 Curve stable exchange 與 ERC4626 adapter。

每個 protocol addition 必須有：

- 一條新解鎖的 flow；
- successful fork test；
- forced safety failure test；
- 使用 dynamic patch 時的 ABI offset golden fixture；
- token、router、deadline、slippage、receiver assumptions 文件。

## Phase 5：Release Hardening

交付項目：

- Slither 與人工審查 findings；
- 實務上最大化 branch 與 error-path coverage；
- invariant campaign report 與 gas report；
- 支援 chain 的 reproducible deployment dry run；
- deterministic CREATE2、per-chain factory availability、address family、
  self-deployment manifest reproduction；
- independent security review；
- 修正後完整 regression 與 differential tests；
- verified immutable deployment；
- signed 或 reviewed deployment manifest；
- `v1.0.0` ABI 與 source tag；
- SDK pin address 與 runtime code hash。

第一次 production release 在完成獨立 audit 與累積實際使用前，仍要標示 high
risk。

## 未來版本：Callback Account

flash loan、direct Uniswap callback、一筆完成的 migration 屬於新合約版本。
只有 v1 fork coverage 穩定且完成小額 real transaction 後才開始設計。

未來設計必須包含：

- active flow hash 或 commitment；
- authenticated callback initiator 與 protocol；
- callback type 與 expected asset validation；
- single-use callback state；
- repayment assertion；
- reentrancy interaction analysis；
- 獨立 audit boundary。

不得靜默改變 v1 implementation behavior。使用者透過 delegate 到新 immutable
address 明確 opt in。

## 延後能力

- non-ERC20 value 的 return-data patching。
- NFT position ID 與 Uniswap V3 LP management。
- Morpho internal-share value piping。
- policy/session-key module。
- ERC-7579 adapter。
- native ETH dynamic source。
- off-chain aggregator quote。
- cross-chain flow coordination。

每一項都必須先有一條 v1 無法安全表示的真實 flow 才值得加入；protocol 數量
本身不是理由。
