# 安全模型

狀態：實作前 threat model
日期：2026-07-15

## 1. 安全邊界

EOA delegate 到 implementation 後，implementation 能在 EOA context 執行。
account 的缺陷可能影響該地址持有的 native asset、token approval 與 protocol
position。

因此主要安全邊界是 `DefiSimplify7702Account`，不是 Go SDK。simulation 與
SDK validation 能降低操作錯誤，但無法補救 delegated code 的授權或
arbitrary-call 漏洞。

`FlowAssertions` 沒有移動資產能力，所以位於 account authority boundary
之外；但 assertion 寫錯仍可能放過不安全 flow 或拒絕安全 flow。

## 2. 必須保護的性質

implementation 必須維持：

1. 只有 delegated EOA 自己或 configured EntryPoint 能進 execution function。
2. untrusted target 無法 reenter dynamic execution。
3. patch 只改變一個通過驗證的 32-byte calldata word。
4. checkpoint delta 不包含具名 checkpoint 之前的 inventory。
5. missing、mismatched、negative delta 不會靜默變成有效 amount。
6. target 或 assertion 失敗時，execution portion 的全部 protocol 與資產變化
   都回滾。
7. custom account 與 checker 不寫 permanent storage。
8. inherited static behavior 與鎖版上游相容。
9. account checkpoint records 保持 function-local，external target frame 與後續
   dynamic invocation 都無法觀察。

## 3. 重要的非保證

### Revert 後 Delegation 仍會保留

EIP-7702 authorization 在 transaction execution 前處理。有效 delegation
indicator 不會因後續 execution 失敗而回滾。第一次交易可能 flow revert，
但 EOA 仍保持 delegated。

專案不得只宣稱「最壞只損失 gas」。精確說法是：

> execution 造成的資產與 protocol-state 變化會原子回滾；gas、nonce 仍會
> 消耗，而且新處理的 delegation 可能保留。

SDK 在第一次簽 authorization 前，必須顯示 delegation target 與持久性，並
提供測試過的 redelegation 或 clearing path。

### Simulation 不是證明

simulation 到 inclusion 之間 state 可能改變；不同 RPC 對 state override 與
trace 支援也不同。關鍵經濟邊界必須由 protocol-native limit 與 final on-chain
assertion 保護，不能只靠 simulation report。

### Gas Exhaustion 下不保證 Failure Attribution

`DynamicCallFailed` 保留完整 target revert data，v1 不會靜默截斷。惡意 target
可以回傳大到讓 caller 在 copy 與 wrap 時耗盡剩餘 gas 的 data。atomic rollback
仍成立，但 transaction 可能無法產生帶 index 的 wrapper。這是 v1 接受的
gas-griefing risk，因為已授權 target code 與 calldata 本來就能消耗 forwarded gas。
未來若加入 cap，必須用明確的 truncated-data error 並帶原始長度 metadata，不得
靜默改變目前 ABI promise。

### Assertion 繼承 Protocol Trust

Aave health-factor assertion 信任傳入 Pool 與 Aave oracle view。它不保護
oracle design risk、governance change、slow depeg，或 SDK 傳錯 Pool address。

generic assertion account binding 是防止 adapter 意外設定錯誤的 defense，不是
hard security boundary。Solidity target 可能忽略 trailing calldata，使刻意 padding
的 call 不改變 target 真正讀取的 arguments。global read 以明確的
`type(uint32).max` no-binding sentinel 支援；reviewed adapter 不得把 padding 當
implicit bypass。

### Universal Authorization 不是 Chain Allowlist

EIP-7702 authorization `chain_id == 0` 時，可在任何其他條件成立的 chain replay。
deterministic deployment 不會縮小 replay scope。delegation target 沒有 code 的
chain 可能把 delegated call 當成成功 no-op，留下 persistent 但不可用的
delegation。因此 v1 拒絕 universal authorization，只簽 active chain ID。

## 4. Threat 與 Mitigation

| Threat | 必要 mitigation |
| --- | --- |
| random caller 呼叫 account execution | 每個 custom entrypoint 都使用 inherited `_requireForExecute()` |
| malicious protocol callback | authorization check 加 transient dynamic lock |
| nested self-call 污染 checkpoint | dynamic call 拒絕 `target == address(this)` |
| patch 寫到 selector、pointer、length 或其他欄位 | selector-relative alignment、bounds、sorted offsets、Go/Solidity golden tests |
| 同 token 先支出再收入導致錯誤 delta | producer call 前建立具名 checkpoint |
| 掃到 existing inventory | SDK 預設 CheckpointDelta；CurrentBalance 必須顯式使用 |
| checkpoint ID collision 或 overwrite | invocation-unique nonzero ID、populated-memory-prefix presence、duplicate rejection、function-local isolation |
| ERC20 回傳 malformed balance data | low-level staticcall 檢查 success 與 returndata length |
| multiplication overflow | full-precision `mulDiv` |
| underflow 被藏成 zero | revert `BalanceBelowCheckpoint` |
| target revert 無法定位 | `DynamicCallFailed(index, target, reason)` |
| target 巨量 revert data 耗盡 wrapper gas | 接受的 v1 non-guarantee；bounded preservation 與 OOG characterization tests；不靜默截斷 |
| router pull 少於 exact patched approval | SDK 選項附加 `approve(spender, 0)` cleanup；adapter 保留 zero-first token sequence |
| upstream storage layout 改變 | custom 無 permanent storage；每次 upstream revision 都鎖版重審 |
| SDK config 中 implementation 被替換 | 依 reviewed manifest 驗證 target 與 runtime code hash |
| proxy code hash 不變但 logic 改變 | official manifest 綁 reproducible direct immutable artifact；禁止 proxy 與 upgrade admin |
| typed assertion 檢查錯 account | typed checker 從 `msg.sender` 取得 subject |
| generic assertion 意外 encode 另一個 account | binding mode 覆寫指定 ABI word；subject-change golden test 證明 target 真的讀它 |
| generic assertion 刻意使用 ignored trailing padding | binding 明文是 guardrail，不是 authorization；compliant global read 使用 no-binding sentinel |
| generic assertion 讀到相鄰 uint word | ABI alignment、bounds checks、distinct sentinel return-word tests |
| universal authorization 被跨鏈 replay | v1 SDK 拒絕 authorization `chain_id == 0` |
| deterministic deployment metadata 被替換 | 驗證 factory address/code hash、salt、完整 initcode hash、constructor args、expected address、runtime code hash |
| 第一次 authorization flow revert | SDK 解釋 persistent delegation 並支援 clear/redelegate |

## 5. Token 假設

generic balance model 假設 `balanceOf(address)` 回傳一般 32-byte unsigned
balance。

fee-on-transfer、rebasing、callback-enabled、blocklisted、pausable、zero-first
approval token 可能有特殊行為。balance patching 使用實際觀察值，通常更能處理
fee-on-transfer，但不代表全面相容。

protocol adapter 在宣稱支援某 token 或 market 前，必須寫清楚假設並加 fork
test。需要 zero-first approve 的 token，SDK 應產生對應 sequence；預設避免
unlimited approval。即使 exact patched approval，router pull 少於 approved amount
時仍會留下 residual allowance。SDK 應提供明確 cleanup 選項，在 flow 尾端附加
`approve(spender, 0)`，並正確處理 zero-first token。合約本身不保證 allowance
cleanup。

## 6. Calldata Patching 風險

account 刻意不知道 protocol ABI，因此無法判斷 aligned word 在語意上是 amount、
offset、length，或以 32 bytes encode 的 receiver。

安全依賴四層：

1. SDK 從 structured ABI encoding 推導 offset，不能搜尋 byte pattern；
2. 合約檢查 alignment、bounds、order、source、bps；
3. golden test 逐 byte 對拍 Go offset 與 Solidity patched data；
4. 送出前模擬 exact delegated transaction。

任何手寫 offset 卻沒有 golden test 的 adapter 都不算完成。

## 7. Ephemeral State 風險

account checkpoint 使用 function-local memory records。external target 無法觀察，
同一 transaction 的後續 invocation 也會取得全新 memory。測試仍必須保留
sequential invocation、same-ID reuse、reverted target、duplicate ID 與 stale
checkpoint 嘗試，作為 observable isolation 的 regression coverage。

execution lock 與 FlowAssertions snapshots 的 lifecycle 不同，仍使用 transient
storage。key 必須和 upstream 及未來 custom feature 做 domain separation。lock
成功 return 時清除，failure 時由 revert semantics 回滾。測試必須證明已授權的
reentrant frame 看得到 lock，且成功或 revert 都不留下 stale lock。詳見 ADR-002。

## 8. EntryPoint 與 Signature 風險

v0.9.0 upstream account 的 EntryPoint 是 immutable。每次 deployment 都必須
驗證 address 與 code hash。ERC-4337 對本專案是 optional transport，但選錯
EntryPoint 仍會影響 inherited authorization path。

Base v1 鎖定 EntryPoint `0x433709009B8330FDa32311DF1C2AFA402eD8D009`
與 runtime code hash
`0x826b7ec542db9f3345234a25c2a6330a61f99483dedb6e6709928cc97e4e4d5d`。
若 address 沒有 code、chain ID 不是 8453，或 hash 改變，Base fork suite 必須
失敗。

custom contract 不得修改 upstream signature validation。更新鎖版
account-abstraction 必須重新 review 並部署新 address，不能自動升 dependency。

EntryPoint address 不禁止作為 dynamic target：inherited `depositTo` 是合法的 account
funding 操作。delegated account 對 pinned v0.9 EntryPoint 呼叫 `handleOps` 時，因
caller 是帶 code 的 delegated account，會先被 EntryPoint 自己的 `Reentrancy()`
modifier 拒絕。這條 real-path test 不會碰到 account lock；另以 configured mock
EntryPoint 從已授權路徑 reenter，證明 account transient lock 回傳
`DynamicExecutionReentered()`。

pinned repo 內 2025 年 3 月 Spearbit report 早於 v0.9 implementation commit。
目前沒有找到 v0.9-specific audit evidence，BaseScan 也沒有列出 selected
EntryPoint 的 submitted audit。因此本專案不把 v0.9 baseline 標示為 audited。
commit comparison、license obligations、release-note risks 與 update rule 見
ADR-001。

official v1 deployment 使用 Foundry 預設 Arachnid factory
`0x4e59b44847b379578588920cA78FbF26c0B4956C`，但 factory、salt、完整
initcode 都是 security identity。initcode 包含 immutable EntryPoint constructor
argument，所以跨鏈相同地址也要求相同 EntryPoint argument。EntryPoint address
與 code hash 都必須驗證。

factory availability 是 chain-level prerequisite。要求 EIP-155 replay protection
的 chain 可能無法接受原始 keyless deployment transaction。factory code 或可用
canonical installation path 驗證前，專案不得承諾該 chain 使用 official address。
Safe Singleton Factory deployment 屬於另一個 address family，不能保留
Arachnid-derived address。

runtime code-hash verification 本身不能證明 target 不是 proxy。official manifest
必須指向 reproducibly built direct immutable artifact。custom manifest 可以 pin
user-deployed code，但 SDK 必須把 unknown code 與 verified project artifact 分開
標示。

## 9. 操作建議

正式 audit 與 production maturity 前：

- 使用資金有限的專用 operation EOA；
- 先 fork/testnet，再用小額 real transaction；
- 獨立驗證 implementation address 與 runtime code hash；
- delegated EOA 避免保留無關高價值 approval 或 asset；
- 設定 protocol deadline、slippage bound、final assertion；
- leverage 與其他 MEV-sensitive transaction 在 chain/provider 支援時使用 private
  order flow，並明寫 provider trust 與 inclusion assumptions；
- 監控 delegation state 與 implementation availability；
- 保留測試過的 redelegate-to-zero 或 redelegate-to-safe-implementation 路徑。

self-deployment 透過 custom manifest 支援。相同 deterministic factory、salt、
initcode 會重現相同地址；相同 direct artifact 若以其他方式部署，可以重現
runtime code 但不一定重現地址。self-deployment 改變部署者，不改變 immutable
verified code 的要求。

## 10. Verification Gates

完成以下項目以前不得宣稱 production-ready：

- 完整 unit、fuzz、invariant、adversarial、fork suite；
- Slither 且 findings 已人工審查；
- patch byte isolation 與 amount math property tests；
- 對上游的 differential static tests；
- source verification 與 reproducible deployment；
- deterministic deployment manifest reproduction 與 factory code-hash checks；
- account/assertions direct-artifact 與 no-proxy verification；
- generic assertion bound/global-mode 與 padding-bypass distinct-sentinel golden
  tests；
- cross-repo SDK 證明拒絕 universal authorization 的 tests；
- 對 inherited + custom combined bytecode 的獨立安全審查；
- 公開 unresolved assumption 與 accepted risk。

上游 audit 不等於 audit 本 extension。獨立審查完成前，repo 必須標示 custom
account 為 unaudited。

## 11. 安全參考資料

- reference project: https://github.com/tn606024/defi-simplify
- Simple7702Account v0.9.0 pinned source: https://github.com/eth-infinitism/account-abstraction/blob/b36a1ed52ae00da6f8a4c8d50181e2877e4fa410/contracts/accounts/Simple7702Account.sol
- Base EntryPoint v0.9.0 verification: https://basescan.org/address/0x433709009B8330FDa32311DF1C2AFA402eD8D009#code
- EIP-7702 security considerations: https://eips.ethereum.org/EIPS/eip-7702#security-considerations
- EIP-1153 security considerations: https://eips.ethereum.org/EIPS/eip-1153#security-considerations
- Foundry `cast create2` default deployer: https://getfoundry.sh/cast/reference/cast-create2
- Arachnid Deterministic Deployment Proxy: https://github.com/Arachnid/deterministic-deployment-proxy
- Safe Singleton Factory: https://github.com/safe-fndn/safe-singleton-factory
- Solidity transient-storage guidance: https://docs.soliditylang.org/en/latest/contracts.html#transient-storage
- account-abstraction releases: https://github.com/eth-infinitism/account-abstraction/releases
