# راهنمای نصب دامنه و یوزر SFTP + دیتابیس MySQL

این اسکریپت:

1. فولدر ساختار `web/public` را برای دامنه می‌سازد.
2. کاربر SFTP بدون دسترسی شل را ایجاد می‌کند.
3. دامنه را در nginx پیکربندی می‌کند.
4. دسترسی SFTP با `chroot jail` برای امنیت فراهم می‌کند.
5. یک دیتابیس MySQL و یوزر مرتبط را می‌سازد.

## اجرای اسکریپت

```bash
chmod +x setup.sh
./setup.sh


bash <(curl -s https://raw.githubusercontent.com/afshinakhgar/setupserver/master/setup.sh)


bash <(wget -qO- https://raw.githubusercontent.com/afshinakhgar/setupserver/master/setup.sh)

