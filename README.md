Here’s a clean **GitHub README.md** for your TAK Server installer project.
It includes clear usage instructions, security considerations, and customization options.

---

````markdown
# TAK Server Auto Installer (Rocky Linux 8/9)

This repository provides a **one-shot installer script** (`tak-install.sh`) to fully set up a TAK (Tactical Assault Kit) server on **Rocky Linux 8/9**.

The script automates:
- Installing dependencies (Java 17, PostgreSQL 15, firewalld, etc.)
- Configuring PostgreSQL for TAK
- Installing TAK RPMs
- Setting up certificates and truststores
- Enabling HTTPS + Admin UI with client cert authentication
- Generating an **admin client certificate** and Windows-ready `.pfx`
- Opening necessary firewall ports
- Starting TAK services
- Printing a full summary of connection details

This allows you to go from a clean Rocky Linux machine to a working TAK server with **one command**.

---

## Features

| Feature                            | Status |
|-----------------------------------|--------|
| Automated dependency install       | ✅ |
| PostgreSQL 15 auto-config          | ✅ |
| TAK RPM install                     | ✅ |
| Admin UI with client cert auth     | ✅ |
| Root CA + truststore generation    | ✅ |
| Automatic admin cert + PFX export  | ✅ |
| Firewall configuration (firewalld) | ✅ |
| Federation block disabled by default | ✅ |
| Secure defaults (strong passwords required) | ✅ |

---

## Usage

### 1. Prepare the environment
- **Start with a clean Rocky 8/9 machine** (VM, bare-metal, or cloud).
- Ensure you have root or `sudo` access.
- Download or copy the TAK server RPM (e.g., `takserver-5.5-RELEASE38.noarch.rpm`) to the server.

### 2. Run the script
Clone this repository and execute the installer:

```bash
git clone https://github.com/<your-username>/tak-server-installer.git
cd tak-server-installer
sudo bash tak-install.sh --rpm /path/to/takserver-5.5-RELEASE38.noarch.rpm
````

---

## Output Example

At the end of a successful run, you’ll see:

```
============================================================
✅ TAK install/config complete (best effort)
------------------------------------------------------------
Java:        openjdk version "17.0.16"
PostgreSQL:  psql (PostgreSQL) 15.5
DB:          tak (owner tak) on port 5432
Ports:       TLS 8089, HTTPS 8443, Cert 8446
Truststore:  /opt/tak/certs/files/truststore-root.jks (pass: atakatak)
Admin PFX:   /opt/tak/certs/files/admin-fixed.pfx
PFX pass:    atakatak

Service:     systemctl status takserver
Logs:        /opt/tak/logs/takserver-*.log

Open UI:     https://<server-ip>:8443
             (Import admin-fixed.pfx on Windows; password: atakatak)
============================================================
```

---

## Windows Client Setup

The script generates a ready-to-use Windows client certificate bundle:

```
/opt/tak/certs/files/admin-fixed.pfx
```

To use it:

1. Copy `admin-fixed.pfx` and `ca.pem` to your Windows machine:

   ```powershell
   scp root@<server-ip>:/opt/tak/certs/files/admin-fixed.pfx C:\Users\<YourName>\Downloads\
   scp root@<server-ip>:/opt/tak/certs/ca.pem C:\Users\<YourName>\Downloads\
   ```
2. Open `certmgr.msc` → **Personal → Certificates → Import**
3. Import `admin-fixed.pfx` with password `atakatak` (or whatever you configured).

   * Check **"Mark this key as exportable"** during import.
4. Import `ca.pem` into **Trusted Root Certification Authorities**.
5. Restart Chrome or Edge and open:
   `https://<server-ip>:8443`
6. When prompted, select the **TAK Admin** certificate.

---

## Default Credentials and Security

**IMPORTANT: Change all default passwords immediately after installation.**

| Item                | Default Value    | Location to Change                         |
| ------------------- | ---------------- | ------------------------------------------ |
| PostgreSQL User     | `tak`            | `TAK_DB_USER` environment variable         |
| PostgreSQL Password | `StrongPassHere` | `TAK_DB_PASS` environment variable         |
| PFX Export Password | `atakatak`       | `PFX_PASS` environment variable            |
| Root CA Password    | `atakatak`       | `/opt/tak/certs/files/truststore-root.jks` |

### How to override during install:

You can set strong, custom values on the command line:

```bash
sudo TAK_DB_PASS='SuperSecret123!' \
     PFX_PASS='UltraSecure456!' \
     bash tak-install.sh --rpm /path/to/takserver.rpm
```

### Security recommendations:

1. **Rotate the database password** regularly.
2. **Secure the admin PFX** — treat it like a master key.
3. Once the PFX is imported into Windows, delete it from the server:

   ```bash
   sudo rm -f /opt/tak/certs/files/admin-fixed.pfx
   ```
4. Consider disabling root SSH after initial setup:

   ```bash
   sudo nano /etc/ssh/sshd_config
   ```

   Change:

   ```
   PermitRootLogin prohibit-password
   ```

   Then restart SSH:

   ```bash
   sudo systemctl restart sshd
   ```

---

## Firewall Rules

The script automatically opens required ports using `firewalld`:

| Port | Purpose                           |
| ---- | --------------------------------- |
| 8089 | TAK TLS                           |
| 8443 | Admin UI (HTTPS with client auth) |
| 8446 | Cert Auth port                    |

To verify:

```bash
sudo firewall-cmd --list-ports
```

---

## Logs and Troubleshooting

View TAK logs:

```bash
sudo ls -l /opt/tak/logs
sudo tail -f /opt/tak/logs/takserver-api.log
```

Check service status:

```bash
sudo systemctl status takserver
```

---

## Advanced Customization

| Variable         | Default        | Purpose                   |
| ---------------- | -------------- | ------------------------- |
| `TAK_DB_NAME`    | tak            | Database name             |
| `TAK_DB_USER`    | tak            | Database username         |
| `TAK_DB_PASS`    | StrongPassHere | Database password         |
| `PG_PORT`        | 5432           | PostgreSQL port           |
| `TAK_TLS_PORT`   | 8089           | TLS port                  |
| `TAK_HTTPS_PORT` | 8443           | HTTPS port (Admin UI)     |
| `TAK_CERT_PORT`  | 8446           | Cert Auth port            |
| `PFX_PASS`       | atakatak       | Password for exported PFX |

Example:

```bash
sudo TAK_DB_PASS='ChangeMe!' TAK_TLS_PORT=9443 bash tak-install.sh --rpm takserver.rpm
```

---

## Disclaimer

This script is provided **as-is** without warranty.
**You are responsible for securing your server**, especially:

* Managing certificates safely
* Rotating passwords regularly
* Restricting network access to trusted devices

---

## License

MIT License © 2025 Your Name

```

---

### Key Notes
- This README clearly documents **how to run**, **how to customize**, and **how to secure** the deployment.
- It emphasizes **security hygiene**, like changing defaults, deleting sensitive files, and managing SSH access.
- The table structure makes it easy to scan quickly for relevant environment variables and defaults.
```
