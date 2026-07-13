# 願景

狀態：預定作為新 repo 的願景文件
日期：2026-07-12

## 目的

`defi-simplify-contract` 提供 `defi-simplify` Go SDK 所需的最小鏈上執行層，
讓多步 DeFi flow 能從使用者 EOA 原子執行。

這個合約 repo 不是錢包產品、protocol router、策略市場，也不是通用工作流
VM。它是一組安全敏感的 execution primitive，服務使用 Go 建置 DeFi backend、
bot、交易系統，並自行管理簽名金鑰的工程師。

## 產品主張

完整專案同時結合三個特性：

1. Go 原生 DeFi composition。
2. EIP-7702 執行，protocol 看到的 `msg.sender` 是使用者 EOA。
3. 簽名前模擬、鏈上 post-condition 與交易原子性。

目標是讓過期報價、市況改變、protocol state 不符或 SDK 建錯 flow 時，交易
revert 且不留下半套 protocol 或資產變化。gas 與 nonce 仍會消耗；EIP-7702
authorization 已安裝的 delegation 是持久的，不會因後續 execution revert
而回滾。

## Repo 責任

這個 repo 負責：

- 鎖定版本的 `Simple7702Account` integration；
- 透過繼承 `executeBatch` 提供 EOA-native static batch baseline；
- 以 checkpoint 為基礎的 ERC20 balance calldata patching；
- 小而可組合的 post-condition assertion contracts；
- 供 Go SDK 使用的 ABI artifact 與部署 metadata；
- 鏈上 surface 的 unit、invariant、fuzz、fork 與攻擊者視角測試。

這個 repo 不負責：

- protocol calldata construction；
- route finding、報價與價格發現；
- 私鑰保管、簽名 UI 或錢包復原；
- 排程、觸發與 keeper infrastructure；
- 鏈下模擬報告與人類可讀的錯誤說明；
- protocol address registry；
- 策略獲利判斷。

以上責任屬於 Go SDK 或整合應用程式。

## Account Model 與使用者自主權

EIP-7702 同一個 EOA 同時間只有一個 active delegation target。本專案會競爭
這個 delegation slot，而不是以獨立 module 共存。建議模型是專用 operation
EOA，其唯一 active delegate 是選定的 immutable
`DefiSimplify7702Account` implementation。技術上可以使用長期 primary EOA，
但資產與 compatibility blast radius 更大。

使用者自主權來自合約小而可讀、無 admin、無 permanent state、reproducible
build，以及明確 opt-in 遷移到新地址，不來自 upgrade key。使用者可自行部署
完全相同的 direct immutable artifact，提供 code-hash-pinned custom manifest，
SDK verification semantics 不變。

v1 只使用 per-chain EIP-7702 authorization，刻意排除 universal
`chain_id == 0` authorization。

## 能力階梯

### Tier 1：Static EOA-Native Batch

使用鎖版上游 `Simple7702Account`，執行送出前就能完整確定的 calldata。

例子：

- ERC20 approve 後 Aave supply；
- approve、supply、borrow；
- repay 後 withdraw；
- exact amount 的 Morpho 或 Pendle Router calls；
- 不需要 runtime value passing 的 caller-sensitive batch。

這是正式功能，也是測試自家 account 行為的 baseline。

### Tier 2：Dynamic EOA-Native Batch

當後一個 call 必須使用前面 call 實際產生的 ERC20 amount 時，使用
`DefiSimplify7702Account`。

例子：

- borrow USDC，swap 精確的借入 delta，再 supply 實際收到的資產；
- claim reward，swap 實際 reward balance，再複利；
- 從一個 lending market withdraw，再把實收金額供應到另一個 market；
- 買入或贖回 Pendle PT，再把實際 ERC20 output 傳給下一步。

合約只讀 balance，並 patch 被明確指定的 ABI word；它不知道 Aave、Uniswap、
Morpho 或 Pendle 的商業邏輯。

### Tier 3：Guarded Execution

在 static 或 dynamic batch 尾端加入 `FlowAssertions` calls，要求 final state
符合宣告條件。

例子：

- 最終 Aave health factor 不低於門檻；
- 最終 token balance 不低於 minimum；
- token 至少增加指定 amount；
- token 減少量不超過 maximum。

### 未來：Callback Execution

Flash loan 與 direct callback protocol 需要 callback authentication 與 active-flow
commitment。這不應偷塞進 v1，而應當成新合約版本獨立設計與審查。

## Protocol 展望

只要策略的中間值能以 ERC20 balance 表示，而且 protocol interaction 是普通
ABI call，v1 generic primitive 就能涵蓋很大一類策略。

適合的範圍：

- Aave V3 supply、withdraw、borrow、repay、leverage、deleverage；
- 經 router 執行的 Uniswap exact-input swap；
- Morpho Blue lending、collateral、borrow、repay、market migration；
- Pendle Router PT buy、sell、redeem、rollover；
- ERC4626 vault、WETH、Lido wrapper 與部分 Curve exchange。

無法完整涵蓋：

- flash loan 或 direct callback；
- 只存在 return data、沒有反映到 ERC20 balance 的值；
- Uniswap V3 LP token ID 這類 NFT position identifier；
- 下一步需要精確 Morpho internal shares 的流程；
- 鏈下簽名 aggregator route 與跨鏈執行；
- v1 的 native ETH dynamic patch。

## 設計價值

- 降低 delegated code 的權力與行數。
- 除了必要的 read-only assertion，protocol knowledge 留在鏈下。
- 偏好明確語意，不讓合約猜測。
- 保留上游 static behavior。
- 使用 immutable deployment，不做 upgradeability。
- self-deployment 是一等、以 code hash 驗證的路徑。
- 失敗必須能定位到 call 與 patch index。
- 模擬是必要 UX，但不是鏈上安全邊界。
- 限制要和能力一樣醒目。

## 成功定義

第一個可信 release 不以接入多少 protocol 衡量，而要在支援的 fork 上證明：

1. 同一個 static batch 經上游與自家 account 都成功；
2. protocol 看到 EOA 為 caller；
3. checkpoint delta 不會掃到既有 inventory；
4. Aave + Uniswap 多步槓桿 flow 使用實際 intermediate amount；
5. final assertion 失敗會回滾全部 protocol 與 token 變化；
6. 非授權、reentrancy、錯誤 offset、缺 checkpoint 都以預期錯誤失敗；
7. source、compiler settings、deployment address 與 code hash 可重現。
