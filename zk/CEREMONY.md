# GhostChain Trusted Setup Ceremony

## چرا Ceremony مهم است؟

Groth16 ZK-SNARKها نیاز به **Trusted Setup** دارند.如果有人 تمام مراحل setup را انجام دهد، می‌تواند proof جعلی تولید کند و قفل قرارداد را باز کند. Ceremony چندنفره این ریسک را توزیع می‌کند:

> **تا زمانی که حداقل یک شرکت‌کننده صادق باشد، خروجی ceremony امن است.**

GhostChain از **مدل دو فاز** استفاده می‌کند:

### فاز ۱: Powers of Tau (عمومی - انجام شده)
فایل `powersOfTau28_hez_final_16.ptau` از **Hermez Phase 1 Ceremony** که بیش از ۱۰۰ شرکت‌کننده داشته است. این فایل universal است و برای هر مداری قابل استفاده است.

### فاز ۲: Circuit-Specific (مخصوص GhostChain)
این بخشی است که جامعه GhostChain در آن شرکت می‌کند. هر شرکت‌کننده یک `.zkey` موقت دریافت می‌کند، entropy خود را اضافه می‌کند و返回 می‌دهد.

---

## امنیت

```
امنیت = 1 - (1 / تعداد شرکت‌کنندگان)
با ۱۰ شرکت‌کننده: ۹۰٪ امن
با ۱۰۰ شرکت‌کننده: ۹۹٪ امن
```

- **Beacon نهایی**: حتی اگر همه شرکت‌کنندگان با هم تبانی کنند، beacon نهایی (مثلاً هش یک بلاک آینده بیت‌کوین) امنیت را تضمین می‌کند.
- **Verification مستقل**: هر کسی می‌تواند ceremony را independently verify کند.
- **SHA-256 هش**: هر contribution یک هش SHA-256 منحصر به فرد دارد که برای راستی‌آزمایی منتشر می‌شود.

---

## نحوه مشارکت (برای شرکت‌کنندگان)

### ۱. پیش‌نیازها
- Node.js 20+
- دسترسی به اینترنت (برای دانلود فایل‌ها)
- حداقل ۲ گیگابایت رم آزاد

### ۲. Clone پروژه

```bash
git clone https://github.com/ghostchain/ghostchain-layer.git
cd ghostchain-layer/zk
npm install
```

### ۳. دانلود Phase 1 (Powers of Tau)

```bash
node scripts/ceremony.js init
```

یا دستی:

```bash
make setup-ptau
```

### ۴. مشارکت در Ceremony

```bash
node scripts/ceremony.js contribute "Your Name/Handle"
```

نکات مهم:
- نام خود را به صورت واضح وارد کنید (می‌توانید GitHub handle یا ایمیل هم اضافه کنید)
- این فرمان ممکن است چند دقیقه طول بکشد
- خروجی: contribution hash که باید ذخیره کنید

### ۵. تأیید مشارکت خود

```bash
node scripts/ceremony.js verify-contribution "Your Name/Handle"
```

### ۶. مشاهده وضعیت

```bash
node scripts/ceremony.js status
```

---

## نحوه اجرا (برای هماهنگ‌کنندگان)

### ۱. مقداردهی اولیه

```bash
# برای هر دو مدار
node scripts/ceremony.js init

# یا برای یک مدار خاص
node scripts/ceremony.js init ghostTransfer
node scripts/ceremony.js init ghostTransferNullifier
```

### ۲. دریافت مشارکت‌ها

پس از هر contribution، فایل `.zkey` جدید در `ceremony/` ذخیره می‌شود. مشارکت‌کنندگان بعدی باید آخرین فایل را دریافت کنند.

```bash
# اضافه کردن مشارکت
node scripts/ceremony.js contribute "Participant Name"

# بررسی هش مشارکت
node scripts/ceremony.js hash ceremony/ghostTransfer_contribution_001.zkey
```

### ۳. اعمال Beacon نهایی

پس از تمام مشارکت‌ها، یک beacon اعمال کنید:

```bash
# استفاده از هش بلاک آینده بیت‌کوین یا اتریوم
node scripts/ceremony.js beacon <64-character-hex>

# یا برای توسعه (random)
node scripts/ceremony.js beacon
```

### ۴. خروجی نهایی

```bash
# استخراج Verifier قرارداد + Verification Key
node scripts/ceremony.js export
```

این فرمان تولید می‌کند:
- `contracts/src/ZKVerifierFull.sol` — verifier برای `ghostTransfer`
- `contracts/src/ZKVerifierNullifier.sol` — verifier برای `ghostTransferNullifier`
- `build/verification_key.json` — کلید تأیید
- `build/verification_key_nullifier.json` — کلید تأیید nullifier

---

## ساختار فایل‌ها

```
zk/
├── ceremony/                    # وضعیت و فایل‌های ceremony
│   ├── manifest.json            # مانیفست کامل (هش‌ها، مشارکت‌کنندگان)
│   ├── ghostTransfer.initial.zkey    # فایل اولیه
│   ├── ghostTransfer_contribution_001.zkey  # مشارکت اول
│   ├── ghostTransfer_contribution_002.zkey  # مشارکت دوم
│   ├── ghostTransfer_final.zkey        # فایل نهایی (بعد از beacon)
│   ├── ghostTransferNullifier.*.zkey   # همین ساختار برای مدار دوم
│   └── .gitkeep
├── ptau/                        # Phase 1 (git-ignored)
│   └── powersOfTau28_hez_final_16.ptau
├── scripts/
│   └── ceremony.js              # هماهنگ‌کننده ceremony
├── CEREMONY.md                  # این فایل
└── build/                       # build artifacts (git-ignored)
    ├── ghostTransfer.r1cs
    ├── ghostTransfer.wasm
    ├── verification_key.json
    └── verification_key_nullifier.json
```

---

## راستی‌آزمایی مستقل

هر کسی می‌تواند ceremony را independently تأیید کند:

```bash
# بررسی کامل
node scripts/ceremony.js verify

# بررسی یک فایل خاص
node scripts/ceremony.js verify ceremony/ghostTransfer_final.zkey

# مشاهده همه هش‌ها
node scripts/ceremony.js hash

# بررسی مشارکت یک نفر خاص
node scripts/ceremony.js verify-contribution "Alice"
```

---

## زمان‌بندی پیشنهادی

| مرحله | مدت زمان | توضیح |
|-------|----------|-------|
| اطلاع‌رسانی | ۳ روز | اعلام زمان ceremony |
| جمع‌آوری مشارکت‌ها | ۵-۷ روز | شرکت‌کنندگان entropy اضافه می‌کنند |
| Beacon نهایی | ۱ روز | منتظر هش بلاک آینده |
| استخراج و تست | ۱-۲ روز | استخراج verifier و تست |
| **کل زمان** | **~۲ هفته** | |

---

## Deploy پس از Ceremony

پس از اتمام ceremony و استخراج verifier:

1. `ZKVerifierFull.sol` و `ZKVerifierNullifier.sol` در `contracts/src/` قرار دارند
2. قرارداد `ZKVerifier` موجود را `upgradeVerifier()` کنید
3. سپس `activateProductionMode()` را فراخوانی کنید
4. این مراحل فقط از طریق multisig قابل انجام است

```bash
# Deploy با full Groth16
make deploy-mainnet
```

---

## منبع

- [SnarkJS Documentation](https://github.com/iden3/snarkjs)
- [Hermez Phase 1 Ceremony](https://blog.hermez.io/hermez-trusted-setup-completed/)
- [Powers of Tau](https://github.com/weijiekoh/perpetualpowersoftau)
