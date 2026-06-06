# GhostChain Frontend Demo

این دمو یک رابط ساده برای مشاهده وضعیت `EphemeralFactory` روی Arbitrum Sepolia یا Base Sepolia است.

## اجرای دمو

1. از پوشه ریشه repo به `frontend/` بروید:

```bash
cd frontend
```

2. سرور محلی را اجرا کنید:

```bash
python3 -m http.server 5173
```

3. صفحه را باز کنید:

`http://localhost:5173`

4. MetaMask را وصل کنید و آدرس قرارداد `EphemeralFactory` را وارد کنید.

5. یک `swapId` معتبر وارد کنید و وضعیت swap را بررسی کنید.

## چه کاری انجام می‌دهد

- اتصال با MetaMask
- خواندن یک `swap` از contract
- بررسی وضعیت فعال بودن یک swap با `isSwapActive`

## نکات

- این دمو برای بررسی وضعیت قرارداد است و نیازی به پکیج‌های npm ندارد.
- برای اجرای آن باید از طریق یک سرور محلی استفاده کنید، نه با باز کردن مستقیم فایل HTML.
