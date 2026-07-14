# ADR-001：鎖定 account-abstraction v0.9.0 與 Base EntryPoint

狀態：accepted
日期：2026-07-13
Linear issue：IAN-44

## 背景

`DefiSimplify7702Account` 將繼承 upstream `Simple7702Account`。此 dependency
決定 account authorization、ERC-4337 validation、signature check、static
execution、receiver interfaces、fallback behavior 與 immutable EntryPoint。
moving dependency 或未驗證 EntryPoint 會在沒有明確決策的情況下改變 security
boundary 與最終 bytecode。

## 決策

### 上游 revision 與 lock

canonical upstream dependency 為：

- repository：`https://github.com/eth-infinitism/account-abstraction.git`；
- release：`v0.9.0`；
- 完整 commit：`b36a1ed52ae00da6f8a4c8d50181e2877e4fa410`；
- local path：未修改的 Git submodule `lib/account-abstraction`。

upstream lock 將 `@openzeppelin/contracts` resolve 到 v5.1.0。本 repo 另外把
這個 transitive Solidity dependency 鎖在 commit
`69c8def5f222ff96f2b5beff05dfba996368aa79`，路徑為
`lib/openzeppelin-contracts`。

`config/account-abstraction-v0.9.0.json` 是 machine-readable dependency lock
與 Base identity record。若 submodule checkout、committed gitlink 或 upstream
working tree 不符合 lock，`script/check-account-abstraction-revision.sh` 會失敗；
CI 在編譯前執行此檢查。

custom account 必須透過 remapping 繼承 upstream source。不得複製、patch 或
vendor 修改過的 `Simple7702Account`、`BaseAccount`、interfaces 或 receiver
behavior。

### Compiler compatibility

upstream v0.9.0 使用 Solidity `0.8.28`。其公開 EntryPoint build settings 為
Cancun、via-IR、optimizer enabled、1,000,000 optimizer runs。BaseScan 對 Base
deployment 顯示 exact source match，使用 Solidity
`0.8.28+commit.7893614a`、Cancun 與 1,000,000 optimizer runs。

本 repo 以固定 toolchain（Solidity 0.8.28、Prague、via-IR、200 optimizer
runs）編譯未修改的 upstream `EntryPoint`、`Simple7702Account`、`BaseAccount`、
inherited interfaces、ERC-1271、ERC-165、ERC-721/ERC-1155 receivers、fallback
與 receive behavior。這證明 source compatibility；因 build settings 刻意不同，
不宣稱 local EntryPoint artifact 與 upstream deployment byte-identical。

最終 custom account bytecode 使用 repo settings。改 upstream revision 或 repo
compiler settings 都會產生新的 artifact identity，必須重新 review。

### Base EntryPoint identity

Base mainnet 是唯一 v1 target：

- chain ID：`8453`；
- EntryPoint version：`v0.9.0`；
- address：`0x433709009B8330FDa32311DF1C2AFA402eD8D009`；
- runtime code hash：
  `0x826b7ec542db9f3345234a25c2a6330a61f99483dedb6e6709928cc97e4e4d5d`；
- EntryPoint constructor arguments：無；
- `Simple7702Account` constructor argument：上述 immutable `IEntryPoint`；
- verification：上述地址在 BaseScan 為 exact-match source。

expected runtime hash 於 2026-07-13 由 Base RPC bytecode 計算，並由
`test/fork/BaseEntryPoint.t.sol` 驗證。測試要求 Base chain ID、non-empty code
與精確 runtime hash。本紀錄不定義後續 account/assertion deployment manifest
schema。

### Release 與 audit evidence

v0.9.0 release 新增的 EntryPoint 行為包括 paymaster signature、block-number
validity range、account 已存在時忽略 non-empty `initCode`、execution-time
UserOperation hash access，以及 EIP-7702 initialization observability。bundler
必須明確支援 v0.9；account code 不得假設 non-empty `initCode` 代表首次使用。

目前沒有證據允許本專案宣稱 v0.9.0 tag 或其 EntryPoint deployment 已 audit。
v0.9.0 tag 內最新報告是 2025 年 3 月 Spearbit review，列出的
account-abstraction review commit 為 `ed8a5c79`、final review commit 為
`57f9a8d7`；v0.9 implementation 後來才由 `f54584e` 引入。BaseScan 也顯示
v0.9 EntryPoint address 沒有 submitted security audit。

upstream v0.8.0 release 曾描述 `Simple7702Account` 已 audit；該說法不延伸到
v0.9.0，也不延伸到本專案合併 inherited 與 custom code 後的 bytecode。在取得
新證據與獨立 review 前，本專案把 v0.9 baseline 與 custom account 都視為
unaudited。

### License obligations

upstream repo root license 是 GPL-3.0，各 Solidity source 則依自己的 SPDX
identifier。在本 revision，`Simple7702Account.sol`、`BaseAccount.sol`、
`IEntryPoint.sol` 與相關 interfaces/utilities 是 MIT；`EntryPoint.sol` 是
GPL-3.0。OpenZeppelin Contracts v5.1.0 是 MIT。

必須保留 source SPDX notice 與 upstream license text。散布 GPL EntryPoint
source 或 compiled artifact 時，必須履行適用的 GPL-3.0 obligations。production
artifact composition 或 distribution method 改變時，專案必須重新做 license
review；本 ADR 是工程紀錄，不是法律意見。

### 已知 inherited risks

- `Simple7702Account` 允許自身或 immutable EntryPoint 執行；選錯 EntryPoint
  會改變 authorization boundary。
- signature validity 會從 supplied hash recover delegated EOA 本身；沒有獨立
  owner 或 recovery authority。
- account 刻意接受 ETH、unknown fallback call 與 ERC-721/ERC-1155 transfer。
  送入的 asset 依賴 delegated EOA 持續可執行或 redelegate。
- upstream static execution 與 revert wrapping 必須保持不變。即使 upstream
  未變，後續 custom behavior 仍可能使既有 audit assumption 失效。
- runtime code-hash verification 只證明 checked address 的 bytecode identity，
  不證明 EntryPoint logic 或 bundler behavior 安全。

### 更新規則

dependency 不得自動更新。新的 upstream commit、tag、EntryPoint address、
compiler setting 或 transitive Solidity dependency 都必須：

1. 建立新的或 superseding ADR，review release notes、diff、license 與 audit；
2. 更新 locks 與 unmodified-upstream compilation tests；
3. 逐 chain 驗證 EntryPoint address 與 runtime hash；
4. 跑完整 differential、fork、security regression tests；
5. 部署新的 custom account address，由使用者明確 redelegate。

existing deployment 繼續鎖在原始 immutable EntryPoint 與 bytecode。dependency
update 不得重用 established deployment identity。

## 後果

build 需要 checkout 兩個 Git submodules，因此體積增加，但 dependency identity
可 review 且由 CI enforce。Base RPC verification 與 deterministic default test
suite 分離。IAN-45 可以繼承這個精確 upstream source 實作 minimal custom
account；該 issue 不得替換 dependency 或改變 inherited behavior。

## 參考資料

- https://github.com/eth-infinitism/account-abstraction/releases/tag/v0.9.0
- https://github.com/eth-infinitism/account-abstraction/tree/b36a1ed52ae00da6f8a4c8d50181e2877e4fa410
- https://github.com/eth-infinitism/account-abstraction/blob/b36a1ed52ae00da6f8a4c8d50181e2877e4fa410/audits/SpearBit%20Account%20Abstraction%20Security%20Review%20-%20Mar%202025.pdf
- https://basescan.org/address/0x433709009B8330FDa32311DF1C2AFA402eD8D009#code
