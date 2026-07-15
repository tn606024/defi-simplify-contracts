# ADR-002：Account Checkpoint 使用 Function-Local Memory

狀態：accepted
日期：2026-07-15
Linear issues：IAN-47、IAN-48

## 背景

`executeBatchDynamic` 在 producer call 前立刻建立具名 ERC20 balance checkpoint，
並由同一次 invocation 的後續 calls 使用。v1 不提供 target 查詢 checkpoint 的
介面、不支援 callback 或 flash-loan receiver，而且 target 一律以 `CALL` 執行。
target 因此位於不同 call frame，永遠不需要存取 account checkpoint records。

較早的 draft 讓每個 checkpoint 以三個 EIP-1153 slots 分別保存 presence、token、
balance，並加入 transient invocation namespace。這能提供 isolation，但把只在
function frame 內使用的資料變成 cross-frame state，也需要反覆 key hashing、多次
`TSTORE`/`TLOAD`、presence slot，以及 invocation counter 或 cleanup 策略。

EIP-1153 security considerations 建議：資料不需跨越目前 call frame 時使用
memory。Weiroll 是相關 executor precedent；它在 command execution 中以 memory
array 傳遞 intermediate state。本專案採用相同的 locality 原則，但不採用 Weiroll
的 return-data piping 或 general virtual-machine semantics。

dynamic reentrancy lock 不同。它存在的目的，就是讓 reenter delegated account 的
新 frame 看見 execution 已啟動；function-local memory 無法提供這個性質。

## 決策

### Account checkpoint representation

canonical `executeBatchDynamic` implementation 以單一 function-local memory array
保存 account checkpoints。

1. 執行 calls 前，加總所有 `calls[i].checkpointsBefore.length`。
2. 配置一個 fixed-capacity checkpoint record array。
3. 追蹤已填入 record 數量。
4. 每筆已填入 record 保存 `id`、`token`、`balance`。
5. duplicate-ID 與 checkpoint lookup 只掃描已填入 prefix。

已填入長度就是 presence marker。記錄 zero balance 合法且不需要 sentinel。ID 在
一次 invocation 內仍必須全域唯一，與 token 無關。

規格定義 observable lifecycle：external target 與後續 invocation 都看不到
checkpoint records，return 或 revert 後 records 消失。canonical implementation
以 memory 達成，不需要 checkpoint transient keys、invocation counter 或 cleanup
list。

### Same-call balance cache

implementation 可以在同一 call 的 patch resolution 與 checkpoint creation 間，
依 token 只讀一次並 cache pre-call balance，因為兩個 phases 間沒有 external
call。cache 絕不跨 target `CALL`。

cached read 失敗或回傳少於 32 bytes 時，error 歸屬第一個觸發讀取的 logical
consumer：

- patch 使用
  `PatchBalanceReadFailed(callIndex, patchIndex, token, reason)`；
- checkpoint 使用
  `CheckpointBalanceReadFailed(callIndex, checkpointIndex, token, reason)`。

這條規則讓 caching 保持 implementation choice，又不改變 observable error
attribution。

### 保留的 transient state

dynamic execution reentrancy lock 保留在一個具明確 domain separation 的
EIP-1153 transient slot。authorization 後設定，reentrant frame 看得到，成功 return
前清除，revert 時回滾。

`FlowAssertions` snapshots 也繼續使用 transient storage。它們刻意要在同一
transaction 的多個 assertion calls 間存續，scope 是 `(transaction, msg.sender)`。
本 ADR 只改變 account checkpoint records。

## 曾考慮的替代方案

### 使用 invocation namespace 的 transient checkpoint slots

v1 不採用。它可行，但用 cross-frame mechanism 保存 frame-local data，並增加
hashing、slot domain、presence、invocation counter 與 cleanup complexity，卻沒有
解鎖任何支援中的行為。

### 結束時清除 transient checkpoint slots

不採用。cleanup list 會複製 checkpoint table、增加 gas，並新增 success/revert 都
必須正確的路徑。revert semantics 也無法處理同一 transaction 內多次成功
invocation 的 isolation。

### Permanent storage

不採用。它會在 EIP-7702 delegation 下產生 storage-layout collision risk，需要
lifecycle cleanup，也違反 no-custom-permanent-state 規則。

### General Weiroll-compatible VM

v1 不採用。Weiroll 是 memory-carried executor state 的良好 precedent，但
return-data registers、arbitrary command semantics 與 general-purpose composition
超出 balance-delta primitive，並擴大 audit surface。

## 後果

- invocation isolation 成為結構性性質，不依賴 key derivation 或 cleanup 正確性。
- external target 無法讀取或改變 checkpoint records。
- account checkpoint 不再占用 transient-storage key，也不會和 upstream 或未來
  delegated implementation collision。
- implementation 對已填入 records 做 linear scan。預期 v1 plan size 通常只有
  少量 checkpoints，這比反覆 hashing 與 transient access 更簡單，預期也更便宜。
- gas snapshot 必須比較代表性 single/multi-checkpoint plans。若未來 plan size 讓
  linear lookup 成為問題，只要 observable semantics 不變，更換 in-memory lookup
  structure 不需要改 ABI。
- sequential same-transaction 與 same-ID reuse tests 仍是必要 regression tests，
  即使 memory 天然提供 isolation。
- callback-capable future account 若需要 callback frame 存取 active flow state，
  必須另做新的 architecture decision。

## 參考資料

- https://eips.ethereum.org/EIPS/eip-1153#security-considerations
- https://github.com/weiroll/weiroll
- `docs/SPECIFICATION.zh-TW.md` Sections 3、5、6、15
- `docs/ARCHITECTURE.zh-TW.md` Section 4.4
- `docs/SECURITY.zh-TW.md` Section 7
