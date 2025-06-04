
---

## 📄 English Guide (`README_EN.md`)

```markdown
# SFTP + Domain + MySQL Auto Setup Script

This script automates:

1. Creating the `/web/public` structure for a given domain
2. Creating a jailed SFTP user
3. NGINX site configuration
4. Secure SFTP chroot jail setup
5. Creating a MySQL database and user

## How to Use

```bash
chmod +x setup.sh
./setup.sh



```bash

bash <(curl -s https://raw.githubusercontent.com/afshinakhgar/setupserver/master/setup.sh)

OR 
```bash

bash <(wget -qO- https://raw.githubusercontent.com/afshinakhgar/setupserver/master/setup.sh)

