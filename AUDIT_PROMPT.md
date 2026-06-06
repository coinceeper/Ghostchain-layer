# 🛡️ GhostChain Layer — Audit Prompt for Deep AI Security Review

> **Target:** A professional smart contract / security auditor  
> **Version:** v0.1.0  
> **Language:** فارسی با اصطلاحات فنی انگلیسی

---

## 📋 دستورالعمل کلی (Role & Mindset)

شما یک **Security Auditor حرفه‌ای** هستید با تخصص در:
- Smart Contract Security (Solidity, Foundry)
- ZK-SNARK Circuits (Circom, Groth16, PLONK)
- Cryptography (ECDH, Poseidon, BIP-32, stealth addresses)
- TypeScript/Node.js امنیت سمت سرور
- Docker/K8s امنیت زیرساخت
- DeFi Security (flash loans, MEV, cross-chain bridges)

**نگرش:** بدبین (Paranoid). فرض کن هر چیزی که می‌تواند اشتباه باشد، اشتباه است. هر access control نداشتن = اکسپلویت. هر unchecked external call = rug pull. هر fallback = backdoor.

**سبک خروجی:** یافته‌ها را به صورت جدول Severity/Category/File/Line/Impact/FixPriority گزارش کن.

---

## ۱. پروژه Overview (برای درک Context)

```
GhostChain Layer = یک پروتکل حریم‌خصوصی برای انتقال cross-chain USDT
معماری: 
  - User USDT را در EphemeralFactory قفل می‌کند (source chain)
  - Solver در destination chain USDT می‌فرستد
  - Solver با ZK proof ثابت می‌کند که transfer را انجام داده
  - User از طریق intent-based routing توسط Solverها سرویس می‌گیرد

مؤلفه‌های اصلی:
  1. Smart Contracts (Solidity, Foundry)
  2. ZK Circuits (Circom)
  3. SDK (TypeScript)
  4. Relayer/Solver (TypeScript)
  5. Infrastructure (Docker, CI/CD, Monitoring)

فایل‌های کانفیگ:
  - contracts/foundry.toml
  - contracts/slither.config.json
  - .env.example
  - docker-compose.yml, docker-compose.prod.yml
  - .github/workflows/ci.yml, deploy.yml, ceremony.yml
  - packages/ts-config/base.json
```

---

## ۲. Smart Contracts — Solidity (Foundry)

### فایل‌های هدف
| فایل | مسیر | خطوط |
|------|------|------|
| EphemeralFactory.sol | `contracts/src/EphemeralFactory.sol` | ~370 |
| EphemeralRouter.sol | `contracts/src/EphemeralRouter.sol` | ~82 |
| ZKVerifier.sol | `contracts/src/ZKVerifier.sol` | ~275 |
| Registry.sol | `contracts/src/Registry.sol` | ~176 |
| Ownable.sol | `contracts/src/lib/Ownable.sol` | ~29 |
| IEphemeralFactory | `contracts/src/interfaces/IEphemeralFactory.sol` | |
| IZKVerifier | `contracts/src/interfaces/IZKVerifier.sol` | |
| IRegistry | `contracts/src/interfaces/IRegistry.sol` | |
| IERC20 | `contracts/src/interfaces/IERC20.sol` | |
| DeployFactory.s.sol | `contracts/script/DeployFactory.s.sol` | ~177 |
| EphemeralFactory.t.sol | `contracts/test/EphemeralFactory.t.sol` | ~434 |

### چک‌لیست عمیق برای هر قرارداد

#### ۲.۱ EphemeralFactory.sol
- [ ] **Swap ID collision**: `keccak256(abi.encodePacked(...))` — آیا امکان collision وجود دارد؟ استفاده از counter کافی است؟
- [ ] **Reentrancy**: `swap.fulfilled = true` قبل از تماس خارجی است؟ (checks-effects-interactions)
- [ ] **Token transfer**: `transferFrom(msg.sender, address(this), amount)` — آیا tokenهای غیراستاندارد مثل USDT (که `bool` برمی‌گردانند) مدیریت می‌شوند؟
- [ ] **Proxy mode**: `swap.proxy.call(abi.encodeWithSelector(...))` — آیا نتیجه `success` چک می‌شود؟
- [ ] **Refund logic**: `refundSwap()` — آیا مقدار دقیق برمی‌گردد؟ اگر proxy هک شده باشد چه؟
- [ ] **ERC-1167 bytecode**: آیا bytecode استاندارد است؟ تست شده؟
- [ ] **Zero-address checks**: کافی هستند؟
- [ ] **Expiry bounds**: `MIN_DURATION=5min`, `MAX_DURATION=24h` — منطقی هستند؟
- [ ] **Edge: amount=0**: revert می‌کند؟
- [ ] **Edge: commitment=bytes32(0)**: revert می‌کند؟
- [ ] **Edge: duplicate swapId**: revert می‌کند؟
- [ ] **Gas**: `_userSwaps` array بدون محدودیت رشد می‌کند — مشکل دارد؟
- [ ] **Pause/emergency**: مکانیزمی برای توقف در بحران وجود دارد؟

#### ۲.۲ ZKVerifier.sol (بحرانی‌ترین قرارداد)
- [ ] **upgradeVerifier()**: فقط `onlyOwner` دارد؟ (بله — چک شود)
- [ ] **activateProductionMode()**: فقط `onlyOwner` دارد؟ (بله)
- [ ] **fullVerifier staticcall**: آیا fallback verifier می‌تواند نتیجه را دستکاری کند؟ (چون `staticcall` است، state را نمی‌تواند تغییر دهد)
- [ ] **Bootstrap verification**: `_verifyBootstrap()` — `ecrecover(...)` فقط چک می‌کند که signer == authorizedSigner؟
- [ ] **Signature malleability**: `ecrecover` در Solidity به طور ذاتی در معرض malleability است. آیا اینجا مشکل‌ساز است؟
- [ ] **Proof replay**: nonce و chainId در publicInputs هستند — آیا replay across chains ممکن است؟
- [ ] **Production mode one-way**: آیا راهی برای برگرداندن `productionMode=false` وجود دارد؟ (نباید باشد)
- [ ] **Full verifier upgrade**: آیا `verificationKeyHash` بعد از upgrade چک می‌شود؟
- [ ] **Bootstrap without authorizedSigner**: اگر `bootstrapMode=true` اما `authorizedSigner=address(0)` باشد چه؟ (revert می‌کند)
- [ ] **publicInputHash computation**: آیا بین Solidity و TypeScript یکسان است؟
- [ ] **Chain ID mismatch**: در bootstrap چک می‌شود. در full verifier mode چطور؟ (بستگی به verifier downstream دارد)

#### ۲.۳ EphemeralRouter.sol
- [ ] **execute() access control**: `onlyFactory` — آیا `msg.sender` در زمان `.call` از سمت factory، خود factory است؟
- [ ] **setFactory() one-time**: آیا `factory != address(0)` چک می‌شود؟ (بله)
- [ ] **Token transfer safety**: از `IERC20(token).transfer()` استفاده می‌کند — آیا tokenهای غیراستاندارد را هندل می‌کند؟
- [ ] **Receive ETH**: تابع `receive()` حذف شده — آیا proxyها نیاز به دریافت ETH دارند؟

#### ۲.۴ Registry.sol
- [ ] **Duplicate chainId**: `setChainActive(true)` روی chainی که قبلاً active است، duplicate می‌زند؟
- [ ] **Access control**: فقط `onlyOwner` — آیا owner یک multisig است؟
- [ ] **Token array**: `removeSupportedToken()` از swap-and-pop استفاده می‌کند — order不重要 است؟

#### ۲.۵ DeployFactory.s.sol
- [ ] **Constructor parameters**: آیا همه پارامترها (owner, authorizedSigner) به درستی پاس می‌شوند؟
- [ ] **Bootstrap mode check**: اگر `productionMode=true`، `bootstrapMode=false` باید باشد — چک می‌شود؟

#### ۲.۶ EphemeralFactory.t.sol
- [ ] **Coverage**: آیا تست‌ها edge cases را پوشش می‌دهند؟
- [ ] **Bootstrap signature test**: آیا تستی وجود دارد که امضای معتبر و نامعتبر bootstrap را چک کند؟
- [ ] **Proxy refund**: تست شده است؟
- [ ] **Production mode**: تست شده است؟
- [ ] **Fuzz testing**: آیا از Foundry fuzzing استفاده شده؟

### آسیب‌پذیری‌های خاص Solidity که باید چک شوند
```
- Reentrancy (CEI pattern)
- Oracle manipulation (در این پروژه? use chainId, block.timestamp)
- Front-running (در fulfillSwap, refundSwap)
- Signature replay (across chains, across factories)
- Access control (missing onlyOwner)
- Integer overflow (Solidity 0.8+ safe, اما در نوع‌های غیراستاندارد?)
- Unchecked return values (ERC20.transfer, .call)
- Denial of Service (آرایه‌های بدون محدودیت)
- Gas griefing (پذیرش arrayهای بزرگ)
- tx.origin استفاده? (نشده)
- Delegatecall to untrusted contracts (ERC-1167 به Router معتبر)
- Selfdestruct (وجود ندارد)
```

---

## ۳. ZK Circuits — Circom

### فایل‌های هدف
| فایل | مسیر | خطوط |
|------|------|------|
| ghostTransfer.circom | `zk/circuits/ghostTransfer.circom` | ~137 |
| ghostTransferNullifier.circom | `zk/circuits/ghostTransferNullifier.circom` | ~203 |

### چک‌لیست امنیتی مدارها

#### ۳.۱ ghostTransfer.circom
- [ ] **Soundness**: آیا امکان ساخت proof معتبر بدون دانستن private key وجود دارد؟
- [ ] **Completeness**: آیا همه مسیرها محدود (constrained) شده‌اند؟
- [ ] **Private key range check**: `senderPrivateKey < BN254_GROUP_ORDER` چک نشده — آیا این مشکل دارد؟
- [ ] **Randomness reuse**: `senderRandomness` می‌تواند صفر باشد یا تکرار شود — آیا مشکلی ایجاد می‌کند؟
- [ ] **Public input binding**: `contractHash == Poseidon(ghostAddress, token, amount, nonce, chainId)` — آیا این binding در on-chain verifier هم به همین شکل چک می‌شود؟
- [ ] **Circuit vs On-chain**: تطابق بین public inputs circuit و `GhostTransferPublicInputs` در Solidity
- [ ] **Poseidon instantiation**: از `circomlib/poseidon.circom` استفاده شده — version صحیح است؟
- [ ] **Unused include**: `mimcsponge.circom` included شده اما استفاده نشده — مشکل امنیتی ندارد اما غیرحرفه‌ای است
- [ ] **Number of public inputs**: ۷ تا — آیا با snarkjs و قرارداد تطابق دارد؟
- [ ] **Shared secret**: `sharedSecret` یک private input است — آیا می‌توان از shared secret اشتباه استفاده کرد بدون اینکه circuit تشخیص دهد؟
- [ ] **Verifier generation**: آیا از `snarkjs zkey export solidityverifier` استفاده شده؟

#### ۳.۲ ghostTransferNullifier.circom
- [ ] **Merkle tree depth**: 32 levels — کافی برای تعداد کاربران؟
- [ ] **Nullifier collision**: امکان برخورد nullifier بین دو تراکنش مختلف؟
- [ ] **Double-spend**: آیا nullifier در قرارداد ذخیره می‌شود و چک می‌شود؟

### آسیب‌پذیری‌های خاص ZK
```
- Under-constrained circuits (missing constraints that allow fake proofs)
- Over-constrained circuits (DOS/gas griefing)
- Hash function mismatch (Poseidon vs Keccak در SDK vs Circuit)
- Field element overflow (private key > field modulus)
- Public input serialization mismatch (Solidity vs TypeScript vs Circom)
- Trusted setup ceremony security (multi-party? single-party?)
```

---

## ۴. SDK TypeScript

### فایل‌های هدف
| فایل | مسیر | خطوط |
|------|------|------|
| index.ts | `sdk/src/index.ts` | exports |
| types.ts | `sdk/src/types.ts` | types |
| chains.ts | `sdk/src/chains.ts` | ~484 |
| client.ts | `sdk/src/client.ts` | ~355 |
| ghost-address.ts | `sdk/src/ghost-address.ts` | ~198 |
| identity.ts | `sdk/src/identity.ts` | ~144 |
| cross-chain.ts | `sdk/src/cross-chain.ts` | ~303 |
| subgraph.ts | `sdk/src/subgraph.ts` | ~381 |

### چک‌لیست امنیتی

#### ۴.۱ ghost-address.ts (رمزنگاری اصلی)
- [ ] **ECDH correctness**: `secp256k1.getSharedSecret(ephemeralPriv, viewingPubKey)` — آیا > از فرمت compact استفاده می‌شود؟
- [ ] **Tweak computation**: `tweak = keccak_256(sharedSecret)` — آیا این مقدار به عنوان field element معتبر است؟
- [ ] **Address derivation**: `keccak_256(pubkey[1:])[-20:]` — استاندارد است؟
- [ ] **View tag**: `keccak_256(sharedSecret)[0]` — احتمال false positive چقدر است؟ (۱/۲۵۶)
- [ ] **ERC-5564 compliance**: آیا واقعاً با استاندارد stealth address مطابقت دارد؟
- [ ] **Randomness**: ephemeral key از `secp256k1.utils.randomPrivateKey()` — این از crypto API امن مرورگر/Node استفاده می‌کند؟
- [ ] **Key validation**: آیا public keyها validation می‌شوند؟ (مثلاً اینکه روی منحنی هستند)

#### ۴.۲ identity.ts (BIP-32 key derivation)
- [ ] **Derivation paths**: `m/44'/60'/0'/0/0` (spending) و `m/44'/60'/0'/1/0` (viewing) — استاندارد است؟
- [ ] **HDKey usage**: از `@scure/bip32` استفاده شده — آیا `derive()` با string path درست کار می‌کند؟
- [ ] **Private key exposure**: private keyها در فراخوانی‌های `signWithSpendingKey()` در حافظه باقی می‌مانند؟
- [ ] **Public key derivation**: `secp256k1.getPublicKey(privateKey, true)` — compressed format درست است؟
- [ ] **Address derivation**: `keccak_256(uncompressed.slice(1)).slice(-20)` — با Viem تطابق دارد؟

#### ۴.۳ cross-chain.ts (Intent-based routing)
- [ ] **Intent ID collision**: `keccak_256(concatBytes(...))` — آیا uniqueness تضمین شده؟
- [ ] **Replay protection**: آیا intent IDها nonce دارند؟
- [ ] **Front-running**: آیا Solver می‌تواند intent را front-run کند؟
- [ ] **Expiry handling**: intentهای منقضی شده مدیریت می‌شوند؟
- [ ] **Type safety**: `this.client.getWalletClient()!.account!.address` — non-null assertionها امن هستند؟

#### ۴.۴ client.ts
- [ ] **ABI correctness**: ABI fragment برای EphemeralFactory — آیا با قرارداد تطابق دارد؟
- [ ] **Chain switching**: `switchChain()` — آیا به درستی کار می‌کند؟
- [ ] **Error handling**: revertها trapping می‌شوند؟

#### ۴.۵ chains.ts
- [ ] **USDT addresses**: آیا آدرس‌های USDT درست هستند؟ (USDT در Optimism, Arbitrum, Polygon, Base, BSC, Avalanche, Fantom, Linea)
- [ ] **RPC endpoint loading**: از env varها می‌خواند — fallback values امن هستند؟

---

## ۵. Relayer/Solver TypeScript

### فایل‌های هدف
| فایل | مسیر | خطوط |
|------|------|------|
| index.ts | `relayer/src/index.ts` | ~233 |
| executor.ts | `relayer/src/executor.ts` | ~473 |
| monitor.ts | `relayer/src/monitor.ts` | ~175 |
| zk-prover.ts | `relayer/src/zk-prover.ts` | ~275 |
| key-manager.ts | `relayer/src/key-manager.ts` | ~280 |
| liquidity.ts | `relayer/src/liquidity.ts` | ~238 |
| flash-loan.ts | `relayer/src/flash-loan.ts` | ~224 |
| api.ts | `relayer/src/api.ts` | ~236 |
| logger.ts | `relayer/src/logger.ts` | ~25 |
| types.ts | `relayer/src/types.ts` | ~6 |

### چک‌لیست امنیتی

#### ۵.۱ executor.ts (هسته Solver)
- [ ] **Rate limiting**: `MAX_FILLS_PER_WINDOW=10`, `RATE_WINDOW_MS=1hour` — کافی است؟
- [ ] **Kill switch**: `engageKillSwitch()` — آیا واقعاً جلوی همه fills را می‌گیرد؟
- [ ] **Max tx value**: `MAX_TX_VALUE_USD=50,000` — hard safety limit هست؟
- [ ] **Cumulative limit**: `MAX_CUMULATIVE_WINDOW_USD=200,000` — منطقی است؟
- [ ] **Liquidity check**: قبل از fill، `hasSufficientLiquidity()` چک می‌شود؟
- [ ] **On-chain activity check**: `isSwapActive()` — اگر RPC call fail شود، intent قبول می‌شود؟ (try/catch)
- [ ] **Transaction encoding**: `encodeFulfillSwapCall()` — proof offset محاسبه درست است؟
- [ ] **Confirmation blocks**: `getConfirmationBlocks()` — برای optimistic rollups 120 بلاک کافی است؟
- [ ] **ZK proof generation**: fallback از Groth16 به bootstrap — `strictProving` چک می‌شود؟
- [ ] **Error recovery**: liquidity release در صورت失敗
- [ ] **Rate limit reset**: پس از kill switch disengage، `fillHistory` ریست می‌شود — درست است؟

#### ۵.۲ zk-prover.ts (Proof Generation)
- [ ] **Bootstrap proof**: `signMessage({ raw: publicInputHash })` — آیا format امضا با on-chain `ecrecover` تطابق دارد؟
- [ ] **Proof encoding**: `encodeAbiParameters('bytes32 r, bytes32 s, uint8 v')` — آیا ترتیب درست است؟
- [ ] **Groth16 proof encoding**: `encodeProofForChain()` — آیا snarkjs proof format درست encode می‌شود؟
- [ ] **snarkjs lazy loading**: fallback اگر snarkjs موجود نباشد — `strictProving` چک می‌شود؟
- [ ] **Circuit WASM path**: `./zk/build/ghostTransfer.wasm` — hardcoded است. در Docker درست کار می‌کند؟
- [ ] **solverPrivateKey**: در حافظه باقی می‌ماند. در production باید از key manager استفاده شود.

#### ۵.۳ key-manager.ts
- [ ] **LocalKeyManager**: `signAndSendTransaction()` یک tx hash تقلیدی برمی‌گرداند — آیا در production استفاده می‌شود؟
- [ ] **AWSKMSKeyManager**: `signAndSendTransaction()` هنوز پیاده‌سازی نشده — خطا می‌دهد
- [ ] **DER to VRS**: `derToVrs()` — آیا conversion درست است؟
- [ ] **Key isolation**: private key هرگز در memory مگر در LocalKeyManager

#### ۵.۴ monitor.ts
- [ ] **Event polling**: هر ۱۵ ثانیه — rate limit RPC provider را می‌زند؟
- [ ] **Event signature**: آیا `EphemeralSwapCreated` event signature با قرارداد تطابق دارد؟
- [ ] **Intent extraction**: `getLogs` پارامترها درست استخراج می‌شوند؟

#### ۵.۵ liquidity.ts
- [ ] **Balance tracking**: آیا balanceهای واقعی on-chain را می‌خواند یا state محلی؟
- [ ] **Rebalance threshold**: 20% از target — منطقی است؟
- [ ] **Flash loan awareness**: allocated vs available liquidity جداگانه track می‌شود؟

#### ۵.۶ flash-loan.ts
- [ ] **Pool addresses**: آیا آدرس‌های Aave V3 pool درست هستند؟
- [ ] **Fee estimation**: 0.05% برای Aave، 0.03% Uniswap، 0.01% Balancer — درست هستند؟
- [ ] **Profitability check**: `isFlashLoanProfitable()` — ساده است، edge cases?
- [ ] **Execution**: flash loan واقعاً اجرا نمی‌شود — فقط encode شده. خطرناک است؟

#### ۵.۷ api.ts (Express Server)
- [ ] **Authentication**: `POST /api/v1/kill-switch` — آیا نیاز به auth دارد؟
- [ ] **CORS**: `app.use(cors())` — همه origins مجاز هستند؟
- [ ] **Input validation**: `POST /api/v1/intents` — اعتبارسنجی ورودی؟
- [ ] **Rate limiting**: API rate limiting وجود دارد؟

#### ۵.۸ index.ts (Boot)
- [ ] **Chain discovery**: از `RPC_*` env varها — اگر یک chain RPC نداشته باشد، نادیده گرفته می‌شود؟
- [ ] **Graceful shutdown**: `SIGTERM`/`SIGINT` handler — آیا درست کار می‌کند؟

---

## ۶. Infrastructure & DevOps

### فایل‌های هدف
| فایل | مسیر |
|------|------|
| docker-compose.yml | `docker-compose.yml` |
| docker-compose.prod.yml | `docker-compose.prod.yml` |
| ci.yml | `.github/workflows/ci.yml` |
| deploy.yml | `.github/workflows/deploy.yml` |
| ceremony.yml | `.github/workflows/ceremony.yml` |
| foundry.toml | `contracts/foundry.toml` |
| slither.config.json | `contracts/slither.config.json` |
| .env.example | `.env.example` |
| .npmrc | `.npmrc` |

### چک‌لیست

- [ ] **Docker non-root**: production `user: "1000:1000"` — درست است
- [ ] **Read-only FS**: `read_only: true` — خوب است
- [ ] **Capability dropping**: `cap_drop: ALL`, `cap_add: NET_BIND_SERVICE` — خوب است
- [ ] **Resource limits**: CPU/Memory محدود شده — خوب است
- [ ] **Logging limits**: `max-size: 10m`, `max-file: 3` — خوب است
- [ ] **Secrets**: `.env` فایل‌ها در `.gitignore` — درست است
- [ ] **npm secret**: `.npmrc` از `${NPM_TOKEN}` استفاده می‌کند — درست است
- [ ] **CI/CD security**: deploy workflow از `workflow_dispatch` با manual trigger — خوب است
- [ ] **Mainnet safety**: deploy.yml چک می‌کند که bootstrap روی mainnet ممنوع است — خوب است
- [ ] **Slither config**: detectors to exclude منطقی هستند؟
- [ ] **Foundry optimizer runs**: default=200, CI=10000, production=1000000 — منطقی است؟
- [ ] **Gas limits**: هر chain gas limit=30000000 — کافی است؟

---

## ۷. Dependency Audit

### چک‌لیست
| چک | توضیح |
|----|-------|
| npm audit | اجرا کن و گزارش بده |
| Known vulnerabilities | `snarkjs@0.7.0`, `@noble/curves`, `@scure/bip32`, `viem` |
| Supply chain | آیا package.jsonها از registryهای معتبر استفاده می‌کنند؟ |
| Pin versions | آیا versionهای دقیق pin شده‌اند یا range هستند؟ |

---

## ۸. الگوی خروجی یافته‌ها

هر یافته باید به این فرمت گزارش شود:

```markdown
### [C-XX] عنوان یافته
| فیلد | مقدار |
|------|-------|
| **Severity** | 🔴 Critical / 🟠 High / 🟡 Medium / 🟢 Low / ℹ️ Info |
| **Category** | Smart Contract / ZK Circuit / SDK / Relayer / Infrastructure / Crypto |
| **File** | `contracts/src/XYZ.sol:L123-L145` |
| **Status** | Open / Partially Fixed / Fixed |
| **Impact** | توضیح اینکه چه اتفاقی می‌افتد اگر اکسپلویت شود |
| **Likelihood** | Low / Medium / High |
| **Fix Difficulty** | Easy / Medium / Hard |

**توضیح فنی:**
[شرح کامل مشکل با کد]

**اثر (PoC / Exploit Scenario):**
[سناریوی اکسپلویت گام‌به‌گام]

**راه‌حل پیشنهادی:**
[کد اصلاحی یا تغییر معماری]
```

### سطوح Severity
| Severity | توضیح |
|----------|-------|
| 🔴 Critical | از دست دادن کامل سرمایه، یا سوءاستفاده بدون نیاز به preconditions خاص |
| 🟠 High | از دست دادن بخشی از سرمایه، یا سوءاستفاده نیازمند conditions خاص |
| 🟡 Medium | نقض privacy، DOS محدود، یا اکسپلویت نیازمند شرایط نادر |
| 🟢 Low | بهترین شیوه‌ها رعایت نشده، ریسک很低 اما quality issue |
| ℹ️ Info | Observation, gas optimization, code style |

---

## ۹. Prior Art / Known Attack Vectors

هنگام audit این موارد خاص را مد نظر داشته باش:

1. **Tornado Cash attacks**: این پروژه از معماری مشابه Tornado Cash استفاده می‌کند. تمام اکسپلویت‌های شناخته شده Tornado Cash را چک کن.
2. **Stealth address weaknesses**: ERC-5564 پیاده‌سازی ناقص می‌تواند privacy leak بدهد.
3. **Cross-chain bridge attacks**: Wormhole, Ronin, Nomad bridges — این پروژه هم مشابه bridge است.
4. **Flash loan attacks**: Aave flash loan integration — reentrancy, price manipulation.
5. **ZK circuit soundness bugs**: Under-constrained circuits, public input injection.
6. **Signature malleability**: ECDSA در Solidity (s在 range [0, n/2] چک می‌شود؟).

---

## ۱۰. پس از Audit — گزارش نهایی

بعد از اتمام audit، یک Executive Summary به این صورت تهیه کن:

```markdown
## Executive Summary

**نمره کلی:** X / 10  
**تعداد یافته‌ها:** X Critical, X High, X Medium, X Low  

### بحرانی‌ترین یافته‌ها:
1. [C-01] عنوان — 🔴 Critical — قرارداد/فایل
2. [C-02] عنوان — 🟠 High — قرارداد/فایل

### Top 5 Recommendations:
1. ...
2. ...

### Risk Matrix:
| # | Severity | Component | Impact | Likelihood | Priority |
|---|----------|-----------|--------|------------|----------|
```

---

## ⚠️ نکات نهایی

- **حافظه (Context Window)**: این audit گسترده است. بهتر است هر مؤلفه را جداگانه audit کنی.
- **غیرممکن بودن audit کامل**: audit کاملاً خودکار ZK circuits ممکن نیست. برای آن audit دستی توسط متخصص رمزنگار لازم است.
- **Scope limitation**: در بخش‌های رمزنگاری و مالی، findings خود را با احتیاط گزارش کن و always suggest "human expert review".
- **هدف نهایی**: شناسایی vulnerabilities قبل از اینکه بدخواهان پیدا کنند. Paranoid mindset داشته باش.

---

*This prompt was prepared for deep security auditing of GhostChain Layer.*
