بله، در ساختار فعلی شما، شبکه‌ها به صورت **Hardcode** (آربیتروم، پالیگان، اپتیمیسم و ترون) تعریف شده‌اند و برای پشتیبانی از **تمام** بلاکچین‌های EVM-based (مثل BSC، Avalanche، Base، Fantom، Linea و ده‌ها شبکه دیگر) به صورت یکپارچه و داینامیک، نیاز به تغییراتی دارید تا معماری شما **Chain-Agnostic** (مستقل از زنجیره) شود.

در اینجا راهنمای کامل و فنی برای تبدیل پروژه به یک سیستم یکپارچه که به صورت خودکار از تمام شبکه‌های EVM پشتیبانی کند، آورده شده است:

---

### 🌐 راهنمای یکپارچه‌سازی تمام شبکه‌های EVM-Based

برای اینکه پروژه شما بدون نیاز به تغییر کد اصلی، از هر شبکه EVM جدیدی پشتیبانی کند، باید از الگوی **"پیکربندی مبتنی بر داده" (Data-Driven Configuration)** استفاده کنید.

#### گام ۱: ایجاد منبع حقیقت واحد (Single Source of Truth)
به جای پخش کردن Chain IDها در کدها، یک فایل مرکزی بسازید. خوشبختانه کتابخانه `Viem` این کار را برای ما انجام داده است.

1. در پوشه `sdk/src` یک فایل به نام `chains.ts` بسازید:
```typescript
// sdk/src/chains.ts
import { 
  mainnet, arbitrum, polygon, optimism, base, bsc, avalanche, 
  fantom, linea, zkSync, scroll, mantle 
  // و هر شبکه دیگری که Viem پشتیبانی می‌کند
} from 'viem/chains';
import type { Chain } from 'viem';

// دیکشنری تمام شبکه‌های پشتیبانی شده
export const SUPPORTED_CHAINS: Record<number, Chain> = {
  [mainnet.id]: mainnet,
  [arbitrum.id]: arbitrum,
  [polygon.id]: polygon,
  [optimism.id]: optimism,
  [base.id]: base,
  [bsc.id]: bsc,
  [avalanche.id]: avalanche,
  [fantom.id]: fantom,
  [linea.id]: linea,
  // اضافه کردن شبکه‌های جدید فقط با افزودن یک خط به این آبجکت!
};

export function getChainById(chainId: number): Chain {
  const chain = SUPPORTED_CHAINS[chainId];
  if (!chain) throw new Error(`Chain ID ${chainId} is not supported`);
  return chain;
}
```

#### گام ۲: به‌روزرسانی لایه SDK (Viem Client)
کلاینت Viem باید به صورت داینامیک بر اساس Chain ID پیکربندی شود.

```typescript
// sdk/src/client.ts
import { createPublicClient, createWalletClient, custom, http } from 'viem';
import { getChainById } from './chains';

export class GhostChainClient {
  private chainId: number;

  constructor(chainId: number) {
    this.chainId = chainId;
    // بررسی می‌کند که آیا شبکه در لیست پشتیبانی هست یا خیر
    getChainById(chainId); 
  }

  public getPublicClient() {
    const chain = getChainById(this.chainId);
    return createPublicClient({
      chain,
      transport: http(), // می‌توانید RPC اختصاصی برای هر شبکه تنظیم کنید
    });
  }

  public getWalletClient(provider: any) {
    const chain = getChainById(this.chainId);
    return createWalletClient({
      chain,
      transport: custom(provider),
    });
  }
}
```

#### گام ۳: به‌روزرسانی لایه قراردادهای هوشمند (Foundry)
در Foundry، به جای نوشتن پروفایل جداگانه برای هر شبکه، از **Environment Variables** و **Scripts** داینامیک استفاده کنید.

1. **تغییر `foundry.toml`:**
```toml
# foundry.toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
# حذف پروفایل‌های هاردکد شده

[rpc_endpoints]
# استفاده از متغیرهای محیطی برای RPCها
ethereum = "${RPC_ETHEREUM}"
arbitrum = "${RPC_ARBITRUM}"
base = "${RPC_BASE}"
bsc = "${RPC_BSC}"
# هر شبکه جدید فقط نیاز به اضافه کردن یک خط در .env دارد
```

2. **نوشتن اسکریپت Deploy داینامیک (`script/Deploy.s.sol`):**
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/EphemeralFactory.sol";

contract DeployGhostChain is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);

        // دیپلوی کردن Implementation
        EphemeralRouter implementation = new EphemeralRouter();
        
        // دیپلوی کردن Factory
        EphemeralFactory factory = new EphemeralFactory(address(implementation));

        vm.stopBroadcast();

        console.log("Deployed on Chain ID:", block.chainid);
        console.log("Factory Address:", address(factory));
    }
}
```
*نحوه اجرا برای هر شبکه:*
`forge script script/Deploy.s.sol --rpc-url base --broadcast` (بدون نیاز به تغییر کد!)

#### گام ۴: به‌روزرسانی لایه Relayer/Solver
رلیر باید بتواند به صورت همزمان به ده‌ها شبکه متصل شود و رویدادها (Events) را رصد کند. از الگوی **Chain Monitor** استفاده کنید.

```typescript
// relayer/src/monitor.ts
import { createPublicClient, http } from 'viem';
import { SUPPORTED_CHAINS } from '../../sdk/src/chains';

export class MultiChainMonitor {
  private clients: Map<number, any>;

  constructor() {
    this.clients = new Map();
    this.initializeChains();
  }

  private initializeChains() {
    // به صورت خودکار برای تمام شبکه‌های تعریف شده در SDK کلاینت می‌سازد
    for (const [chainId, chain] of Object.entries(SUPPORTED_CHAINS)) {
      const client = createPublicClient({
        chain,
        transport: http(process.env[`RPC_${chain.name.toUpperCase()}`]),
      });
      this.clients.set(Number(chainId), client);
      console.log(`Initialized monitor for ${chain.name}`);
    }
  }

  public async startMonitoring() {
    for (const [chainId, client] of this.clients.entries()) {
      client.watchContractEvent({
        address: process.env.FACTORY_ADDRESS, // آدرس فکتوری در آن شبکه
        eventName: 'EphemeralContractCreated',
        onLogs: (logs) => this.handleIntent(chainId, logs),
      });
    }
  }
}
```

#### گام ۵: مدیریت RPCها و Environment Variables
برای اینکه همه چیز یکپارچه کار کند، یک فایل `.env.example` استاندارد بسازید:

```bash
# .env.example
PRIVATE_KEY=0x...

# RPC Endpoints (از سرویس‌هایی مثل Alchemy, Infura, QuickNode)
RPC_ETHEREUM=https://eth-mainnet.g.alchemy.com/v2/...
RPC_ARBITRUM=https://arb-mainnet.g.alchemy.com/v2/...
RPC_BASE=https://base-mainnet.g.alchemy.com/v2/...
RPC_BSC=https://bsc-dataseed.binance.org/
RPC_POLYGON=https://polygon-rpc.com/

# آدرس‌های قراردادهای دیپلوی شده در هر شبکه
FACTORY_ADDRESS_ETHEREUM=0x...
FACTORY_ADDRESS_ARBITRUM=0x...
FACTORY_ADDRESS_BASE=0x...
```

---

### 🎯 نتیجه نهایی این تغییرات

با اعمال این ۵ گام، معماری شما به این ویژگی‌ها دست می‌یابد:

1. **افزودن شبکه جدید در ۳۰ ثانیه:** برای اضافه کردن مثلاً شبکه `Mantle` یا `Blast`، فقط کافیست نام آن را به `SUPPORTED_CHAINS` در فایل `chains.ts` اضافه کنید و RPC آن را در `.env` بگذارید. بقیه سیستم (SDK، Relayer، Deploy Script) به صورت خودکار آن را شناسایی می‌کنند.
2. **حذف کدهای تکراری:** دیگر نیازی نیست برای هر شبکه `if/else` بنویسید.
3. **یکپارچگی کامل:** آدرس‌های شبح‌وار (Stealth Addresses) و کلیدهای BIP-44 برای تمام این شبکه‌ها از یک `Spending Key` واحد مشتق می‌شوند، اما `Chain ID` به عنوان بخشی از `path` یا `namespace` در نظر گرفته می‌شود تا تداخل پیش نیاید.

این ساختار، پروژه شما را از یک "پروتکل چند زنجیره‌ای محدود" به یک **"زیرساخت حریم خصوصی جهانی برای تمام اکوسیستم EVM"** تبدیل می‌کند.