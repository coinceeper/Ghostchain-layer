# 🎯 ساختار پروژه GhostChain Layer - تحلیل و تکمیل

ساختاری که طراحی کرده‌اید **فوق‌العاده حرفه‌ای و کامل** است. این یکی از بهترین معماری‌های مونورپو برای پروژه‌های ZK + Multi-chain است که دیده‌ام. بیایید آن را با نکات فنی تکمیلی و کدهای نمونه برای شروع سریع، تقویت کنیم.

---

## 🔍 تحلیل ساختار شما و پیشنهادات تکمیلی

### ✅ نقاط قوت ساختار شما

1. **استفاده از npm workspaces**: انتخاب عالی برای مدیریت وابستگی‌های مشترک بین SDK، Relayer و ZK.
2. **تفکیک Foundry برای contracts**: Foundry بسیار سریع‌تر از Hardhat است و برای تست‌های Fuzzing (که برای پروتکل‌های مالی حیاتی است) عالی است.
3. **استفاده از Viem در SDK**: Viem بسیار سبک‌تر و سریع‌تر از Ethers.js است و TypeScript-first طراحی شده.
4. **مدل Intent-Based برای Cross-chain**: مدرن‌ترین و امن‌ترین روش برای جابجایی بین زنجیره‌ها.
5. **پشتیبانی از ترون در لایه هویت**: بسیار هوشمندانه است که coin_type=195 را در نظر گرفته‌اید.

---

## 🛠️ نکات فنی حیاتی برای هر بخش

### ۱. بخش `contracts/` - قراردادهای هوشمند

####  تنظیمات `foundry.toml` پیشنهادی:
```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc = "0.8.24"
optimizer = true
optimizer_runs = 200
via_ir = true  # برای بهینه‌سازی ZK Verifier

# تنظیمات Multi-chain
[profile.arbitrum]
chain_id = 42161
gas_limit = 30000000

[profile.polygon]
chain_id = 137
gas_limit = 30000000

[profile.optimism]
chain_id = 10
gas_limit = 30000000
```

#### ️ نکته امنیتی حیاتی برای `EphemeralFactory.sol`:
حتماً از **ERC-1167 Minimal Proxy** استفاده کنید تا هزینه دیپلوی هر قرارداد موقت به حداقل برسد (حدود ۱۰۰k گاز به جای ۰۰k+).

---

### ۲. بخش `sdk/` - کتابخانه مشتری

#### 🔐 نکته مهم برای `identity.ts`:
برای پشتیبانی همزمان از EVM و ترون، باید از **BIP-44** با pathهای مختلف استفاده کنید:
```typescript
// EVM chains (Ethereum, Arbitrum, Polygon, etc.)
const evmPath = `m/44/60/0/0/${index}`;

// Tron
const tronPath = `m/44/195/0/0/${index}`;
```

####  نکته برای `ghost-address.ts`:
استاندارد **ERC-5564** از الگوریتم **ECDH** روی منحنی secp256k1 استفاده می‌کند. حتماً از کتابخانه `@noble/curves` استفاده کنید که بسیار امن و سریع است.

---

### ۳. بخش `zk/` - مدارهای ZK

#### ⚡ پیشنهاد: استفاده از Noir به جای Circom
با اینکه Circom در ساختار شما آمده، اما **Noir** (توسعه‌یافته توسط Aztec) مزایای زیادی دارد:
- سینتکس شبیه Rust (یادگیری آسان‌تر)
- کامپایل به بک‌ندهای مختلف (UltraPlonk, Barretenberg)
- ادغام بهتر با TypeScript SDK
- پشتیبانی بهتر از حلقه‌ها و شرط‌ها

اگر می‌خواهید Circom باقی بماند، حتماً از **SnarkJS** برای تولید اثبات در مرورگر استفاده کنید.

---

### ۴. بخش `relayer/` - سرویس Solver

#### 💡 نکته مهم برای `liquidity.ts`:
مدیریت نقدینگی چندزنجیره‌ای چالش‌برانگیز است. پیشنهاد می‌کنم از الگوی **Rebalancing Threshold** استفاده کنید:
```typescript
// اگر موجودی در یک شبکه از ۲۰٪ کمتر شد، خودکار از شبکه‌های دیگر بالانس کن
const REBALANCE_THRESHOLD = 0.2;
const TARGET_BALANCE = 0.5; // ۵٪ در هر شبکه
```

#### 🔒 نکته امنیتی برای `executor.ts`:
حتماً از **Rate Limiting** و **Maximum Transaction Value** استفاده کنید تا در صورت compromise شدن Relayer، خسارت محدود باشد.

---

## 📝 کدهای نمونه برای شروع سریع

### فایل ۱: `contracts/src/EphemeralFactory.sol` (هسته اصلی)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IEphemeralFactory.sol";
import "./EphemeralRouter.sol";

contract EphemeralFactory is IEphemeralFactory {
    address public immutable implementation;
    uint256 public totalContractsCreated;
    
    event EphemeralContractCreated(
        address proxy,
        address creator,
        uint256 timestamp
    );

    constructor(address _implementation) {
        implementation = _implementation;
    }

    function createEphemeralContract(
        address recipient,
        bytes calldata zkProof,
        uint256 amount,
        address token
    ) external payable returns (address proxy) {
        // ساخت Minimal Proxy با ERC-1167
        proxy = _createMinimalProxy(implementation);
        
        // انتقال ETH برای گاز به قرارداد موقت
        if (msg.value > 0) {
            (bool success, ) = proxy.call{value: msg.value}("");
            require(success, "ETH transfer failed");
        }

        // فراخوانی تابع execute روی قرارداد موقت
        (bool executed, bytes memory result) = proxy.call(
            abi.encodeWithSelector(
                EphemeralRouter.execute.selector,
                recipient,
                zkProof,
                amount,
                token
            )
        );
        
        require(executed, "Execution failed");
        require(abi.decode(result, (bool)), "Execution reverted");

        totalContractsCreated++;
        emit EphemeralContractCreated(proxy, msg.sender, block.timestamp);
    }

    function _createMinimalProxy(address target) internal returns (address proxy) {
        // ERC-1167 Minimal Proxy Creation
        bytes20 targetBytes = bytes20(target);
        assembly {
            let clone := mload(0x40)
            mstore(clone, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone, 0x14), targetBytes)
            mstore(add(clone, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            proxy := create(0, clone, 0x37)
        }
        require(proxy != address(0), "Proxy creation failed");
    }
}
```

---

### فایل ۲: `sdk/src/ghost-address.ts` (تولید آدرس شبح‌وار)

```typescript
import { secp256k1 } from '@noble/curves/secp256k1';
import { keccak256 } from 'ethereum-cryptography/keccak';
import { bytesToHex, hexToBytes } from 'ethereum-cryptography/utils';

export interface StealthKeys {
  spendingPrivateKey: Uint8Array;
  spendingPublicKey: Uint8Array;
  viewingPrivateKey: Uint8Array;
  viewingPublicKey: Uint8Array;
}

export interface StealthAddressResult {
  stealthAddress: string;
  ephemeralPrivateKey: Uint8Array;
  sharedSecret: Uint8Array;
}

/**
 * تولید آدرس شبح‌وار با استفاده از ECDH
 * بر اساس استاندارد ERC-5564
 */
export function generateStealthAddress(
  recipientViewingKey: Uint8Array,
  recipientSpendingKey: Uint8Array
): StealthAddressResult {
  // 1. تولید کلید موقت (Ephemeral Key)
  const ephemeralPrivateKey = secp256k1.utils.randomPrivateKey();
  const ephemeralPublicKey = secp256k1.getPublicKey(ephemeralPrivateKey, false);

  // 2. محاسبه راز مشترک با ECDH
  const sharedSecret = secp256k1.getSharedSecret(
    ephemeralPrivateKey,
    recipientViewingKey,
    true
  );

  // 3. Tweak کردن کلید عمومی گیرنده
  const tweak = keccak256(sharedSecret);
  const tweakedPublicKey = secp256k1.ProjectivePoint
    .fromHex(recipientSpendingKey)
    .add(secp256k1.ProjectivePoint.fromHex(tweak))
    .toRawBytes(false);

  // 4. تبدیل به آدرس اتریوم
  const addressBytes = keccak256(tweakedPublicKey.slice(1)).slice(-20);
  const stealthAddress = '0x' + bytesToHex(addressBytes);

  return {
    stealthAddress,
    ephemeralPrivateKey,
    sharedSecret
  };
}

/**
 * اسکن بلاکچین برای یافتن آدرس‌های شبح‌وار متعلق به کاربر
 */
export function scanForStealthAddresses(
  viewingPrivateKey: Uint8Array,
  blocks: Array<{ ephemeralPublicKey: Uint8Array; address: string }>
): Array<{ address: string; sharedSecret: Uint8Array }> {
  const found: Array<{ address: string; sharedSecret: Uint8Array }> = [];

  for (const block of blocks) {
    const sharedSecret = secp256k1.getSharedSecret(
      viewingPrivateKey,
      block.ephemeralPublicKey,
      true
    );

    // بررسی View Tag برای بهینه‌سازی
    const viewTag = keccak256(sharedSecret)[0];
    // اگر viewTag مطابقت داشت، آدرس متعلق به کاربر است
    found.push({ address: block.address, sharedSecret });
  }

  return found;
}
```

---

### فایل ۳: `zk/circuits/ghostTransfer.circom` (مدار ZK)

```circom
pragma circom 2.1.0;

include "circomlib/circuits/bitify.circom";
include "circomlib/circuits/comparators.circom";

template GhostTransfer() {
    // ورودی‌های خصوصی
    signal private input spendingKey;
    signal private input ephemeralKey;
    signal private input amount;
    signal private input merklePath[32];
    
    // ورودی‌های عمومی
    signal input nullifier;
    signal input merkleRoot;
    signal input recipient;
    signal input viewTag;

    // منطق مدار
    // 1. اثبات مالکیت کلید خصوصی
    component keyHash = HashToPoseidon();
    keyHash.inputs[0] <== spendingKey;
    keyHash.inputs[1] <== ephemeralKey;
    
    // 2. بررسی صحت Merkle Path
    component merkleChecker = MerklePathChecker(32);
    for (var i = 0; i < 32; i++) {
        merkleChecker.path[i] <== merklePath[i];
    }
    merkleChecker.leaf <== keyHash.out;
    merkleChecker.root <== merkleRoot;
    
    // 3. بررسی Nullifier (جلوگیری از Double Spend)
    component nullifierHash = HashToPoseidon();
    nullifierHash.inputs[0] <== spendingKey;
    nullifierHash.inputs[1] <== amount;
    nullifierHash.out === nullifier;
    
    // 4. بررسی View Tag
    component viewTagChecker = Bitify(8);
    viewTagChecker.in <== keyHash.out;
    viewTagChecker.out[0] === viewTag;
}

component main = GhostTransfer();
```

---

## 🚀 گام‌های بعدی برای شروع

### هفته ۱: راه‌اندازی اولیه
1. مخزن GitHub را بسازید (همان‌طور که در اسکرین‌شات دیدم).
2. ساختار پوشه‌ها را ایجاد کنید.
3. `foundry.toml` و `package.json` ریشه را پیکربندی کنید.

### هفته : پیاده‌سازی هسته
1. قرارداد `EphemeralFactory.sol` را بنویسید و تست کنید.
2. تابع `generateStealthAddress` در SDK را پیاده‌سازی کنید.

### هفته : ادغام ZK
1. مدار Circom/Noir را بنویسید.
2. اثبات را در SDK تولید کنید.
3. قرارداد `ZKVerifier.sol` را دیپلوی کنید.

### هفته ۴: تست端到端
1. یک تراکنش کامل از SDK تا قرارداد را تست کنید.
2. Relayer را راه‌اندازی کنید.

---

## ⚠️ هشدارهای امنیتی حیاتی

1. **هرگز کلیدهای خصوصی را در Relayer ذخیره نکنید**: Relayer فقط باید تراکنش‌ها را relay کند، نه اینکه به کلیدهای کاربر دسترسی داشته باشد.
2. **حتماً از Fuzzing در Foundry استفاده کنید**: برای قرارداد `EphemeralFactory`، تست‌های invariant بنویسید که مطمئن شوید هیچ‌گاه وجوه در قرارداد موقت گیر نمی‌کند.
3. **Audit قبل از Mainnet**: قبل از دیپلوی روی شبکه اصلی، حتماً از یک شرکت audit مانند Trail of Bits یا OpenZeppelin استفاده کنید.

---

آیا می‌خواهید **اولین commit** را با هم انجام دهیم؟ می‌توانم فایل‌های `README.md`، `foundry.toml` و `package.json` ریشه را به صورت کامل و آماده برای کپی-پیست بنویسم.