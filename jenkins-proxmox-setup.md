# Jenkins on Proxmox: Controller + Worker Setup

Setup for a Jenkins controller and one worker/agent node, both running as LXC containers on a single Proxmox host with **8 GB total RAM**.

- **Controller**: TurnKey Linux Jenkins template (Jenkins pre-installed)
- **Worker**: plain Debian 12 template (Java + Jenkins agent only, no bundled services)

Memory is split to leave headroom for the Proxmox host itself: 2048 MB (controller) + 2560 MB (worker) = 4608 MB assigned, leaving ~3.5 GB for the host, kernel, and storage overhead.

---

## 1. Controller Container (TurnKey Jenkins)

Click **Create CT**:

### General
| Field | Value |
|---|---|
| CT ID | 101 |
| Hostname | jenkins-controller |
| Unprivileged container | Checked |
| Nesting (Features) | Checked, only if the controller itself builds Docker images |
| Password | set a root password |
| Start at boot | Checked |

### Template
| Field | Value |
|---|---|
| Storage | local |
| Template | TurnKey Linux - Jenkins |

### Disks
| Field | Value |
|---|---|
| Storage | local-lvm |
| Disk size | 20 GB |

### CPU
| Field | Value |
|---|---|
| Cores | 1 |

### Memory
| Field | Value |
|---|---|
| Memory | 2048 MB |
| Swap | 512 MB |

### Network
| Field | Value |
|---|---|
| Bridge | vmbr0 |
| IPv4 | Static |
| Firewall | Unchecked, unless managing rules via Proxmox firewall |

### DNS
| Field | Value |
|---|---|
| Use host settings | Checked |

**Notes:**
- First boot runs TurnKey's Confconsole, not a manual OS setup — set the root password and confirm networking there.
- The appliance also bundles Webmin, TKLBAM, and Fail2ban. These add some baseline RAM usage; factor that in if you tighten the memory budget further.
- The controller should only schedule jobs and serve the UI once a worker exists — avoid running builds directly on it.

---

## 2. Worker Container (Debian 12)

Click **Create CT**:

### General
| Field | Value |
|---|---|
| CT ID | 102 |
| Hostname | jenkins-worker-01 |
| Unprivileged container | Checked |
| Nesting (Features) | Checked, plus Keyctl, if this worker runs Docker-based build steps |
| Password | set a root password |
| Start at boot | Checked |

### Template
| Field | Value |
|---|---|
| Storage | local |
| Template | Debian 12 standard template |

### Disks
| Field | Value |
|---|---|
| Storage | local-lvm |
| Disk size | 20 GB |

### CPU
| Field | Value |
|---|---|
| Cores | 1 |

### Memory
| Field | Value |
|---|---|
| Memory | 2560 MB |
| Swap | 512 MB |

### Network
| Field | Value |
|---|---|
| Bridge | vmbr0 |
| IPv4 | Static |
| Firewall | Unchecked, unless managing rules via Proxmox firewall |

### DNS
| Field | Value |
|---|---|
| Use host settings | Checked |

**Notes:**
- Using a plain Debian template here (instead of a second TurnKey Jenkins appliance) avoids running a duplicate, unused Jenkins/Webmin instance — this container only needs Java and the Jenkins agent process.
- If builds start OOM-killing on this budget, the reliable fix is more host RAM rather than shrinking further.

---

## 3. Installing the Jenkins Agent on the Worker

This sets the worker up as an **agent** connecting to the existing TurnKey controller — not a second full Jenkins install.

> **Note:** the worker container turned out to be running Debian 13 (Trixie), not Debian 12 (Bookworm) as originally templated — confirm with `cat /etc/os-release`. The controller (TurnKey) runs Java 17. Trixie no longer ships `openjdk-17-jdk` in its default repos, so these instructions use `openjdk-21-jdk` on the worker instead of matching 17 exactly. Jenkins remoting is generally fine with the agent on a newer JDK than the controller; if a specific build tool strictly requires Java 17 on the worker, install Temurin 17 from Adoptium instead.

### Step 1: Update the system
**Run on: worker**
```bash
apt update && apt upgrade -y
```

### Step 2: Install the JDK and Git
**Run on: worker**
```bash
apt install -y openjdk-21-jdk git
```
Git has to be installed on the worker's OS directly — Jenkins' SCM checkout runs as a phase before any build steps execute, so it can't be installed "just in time" from within a job.

### Step 3: Create a dedicated jenkins user
**Run on: worker**
```bash
useradd -m -s /bin/bash jenkins
mkdir -p /home/jenkins/agent
chown -R jenkins:jenkins /home/jenkins/agent
```

### Step 4: Set up SSH key authentication

Recommended launch method is **"Launch agents via SSH"**, since it needs no manual agent-jar management — the controller handles that. This method comes from the **SSH Build Agents** plugin, which isn't installed by default on the TurnKey Jenkins appliance — the node config page won't show "Launch agents via SSH" as an option until it's added.

**Run on: controller** — generate a keypair (or reuse an existing one):
```bash
ssh-keygen -t ed25519 -C "jenkins-controller" -f ~/.ssh/jenkins_worker_key
```

**Run on: worker** — add the controller's public key to the jenkins user:
```bash
mkdir -p /home/jenkins/.ssh
chmod 700 /home/jenkins/.ssh
echo "<controller's public key>" >> /home/jenkins/.ssh/authorized_keys
chmod 600 /home/jenkins/.ssh/authorized_keys
chown -R jenkins:jenkins /home/jenkins/.ssh
```

**Run on: controller** (via the web UI) — update existing plugins before installing a new one, especially after a Jenkins core upgrade (Section 4) since older plugins can be incompatible with the new version:

1. **Manage Jenkins > Plugins > Updates** tab
2. Click **Select All**, then **Download now and install after restart** (or **Install without restart** if none require it)
3. Once complete, restart Jenkins to apply:
   ```bash
   systemctl restart jenkins
   ```
4. Recheck the Updates tab — repeat until it shows no pending updates

**Run on: controller** (via the web UI) — install the plugin that provides the SSH launch method:

1. **Manage Jenkins > Plugins > Available plugins**
2. Search "SSH Build Agents", check it, click **Install**
3. Restart Jenkins if prompted (Jenkins will offer a "Restart Jenkins when installation is complete" checkbox)

**Run on: controller** (via the web UI) — add the private key as a Jenkins credential (this is separate from the node config, and must exist before you configure the node):

1. **Manage Jenkins > Credentials > System > Global credentials (unrestricted) > Add Credentials**
2. Kind: **SSH Username with private key**
3. Scope: Global
4. ID: e.g. `worker-ssh-key` (optional but helpful for reuse)
5. Username: `jenkins`
6. Private Key: select **Enter directly**, paste the contents of `~/.ssh/jenkins_worker_key` (the private key generated above)
7. Passphrase: leave blank unless you set one
8. Save

### Step 5: Register the node in Jenkins
**Run on: controller** (via the web UI)

1. **Manage Jenkins > Nodes > New Node**
2. Name: `worker-01`, type: **Permanent Agent**
3. Remote root directory: `/home/jenkins/agent`
4. Labels: e.g. `linux worker`
5. Launch method: **Launch agents via SSH** (only appears after the plugin from Step 4 is installed)
6. Host: worker container's IP
7. Credentials: select the `jenkins` / `worker-ssh-key` credential added in Step 4
8. Host Key Verification Strategy: **Non verifying** (or manually trust the fingerprint if you prefer stricter verification)
9. Save, then check the node's log to confirm it connects

If you'd rather skip installing the plugin, the node config's built-in **"Launch agent by connecting it to the controller"** option (JNLP/inbound) works without any extra plugin — see the alternative below.

### Alternative: JNLP (inbound) agent

If you'd rather have the worker initiate the connection (useful behind NAT/firewalls where the controller can't reach the worker directly):

**Run on: worker**
```bash
# Download the agent jar from the controller
curl -sO http://<controller-ip>:8080/jnlpJars/agent.jar

# Run it (get the exact -jnlpUrl and -secret from the node's page on the controller)
java -jar agent.jar -jnlpUrl http://<controller-ip>:8080/computer/worker-01/jenkins-agent.jnlp -secret <secret> -workDir /home/jenkins/agent
```

To keep it running persistently, wrap this in a systemd service:

**Run on: worker**
```ini
# /etc/systemd/system/jenkins-agent.service
[Unit]
Description=Jenkins Agent
After=network.target

[Service]
User=jenkins
WorkingDirectory=/home/jenkins/agent
ExecStart=/usr/bin/java -jar /home/jenkins/agent.jar -jnlpUrl http://<controller-ip>:8080/computer/worker-01/jenkins-agent.jnlp -secret <secret> -workDir /home/jenkins/agent
Restart=always

[Install]
WantedBy=multi-user.target
```
```bash
systemctl daemon-reload
systemctl enable --now jenkins-agent
```

### Step 6: Verify
**Run on: controller** — back in **Manage Jenkins > Nodes**, the worker should show as online. Run a test job pinned to its label to confirm builds execute there.

---

## 4. Troubleshooting: Controller Issues

### `apt update` fails with `NO_PUBKEY` on the Jenkins repo

Jenkins periodically rotates its Debian repo signing key. If `apt update` on the controller shows something like:
```
W: GPG error: https://pkg.jenkins.io/debian binary/ Release: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY <key-id>
E: The repository 'https://pkg.jenkins.io/debian binary/ Release' is not signed.
```
the existing `/etc/apt/sources.list.d/jenkins.list` is still referencing an old key. Fix it by re-pointing to the current key and repo:

**Run on: controller**
```bash
# back up the existing repo file first in case it has custom entries
cp /etc/apt/sources.list.d/jenkins.list /etc/apt/sources.list.d/jenkins.list.bak

curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key | tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null

echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" | tee /etc/apt/sources.list.d/jenkins.list > /dev/null

apt update
apt upgrade -y
```

Notes:
- Check https://www.jenkins.io/download/ or the Jenkins blog for the current key filename (`jenkins.io-<year>.key`) if this one no longer matches — the key rotates roughly annually.
- After upgrading, restart the Jenkins service if it doesn't pick up the new version automatically:
  ```bash
  systemctl restart jenkins
  ```
- A Jenkins version bump can also bump its required Java version. Recheck afterward:
  ```bash
  java -version
  ```
  and re-verify the worker's JDK (Section 3, Step 2) is still compatible.

### Jenkins fails to start after upgrade: Java version too old

If `systemctl status jenkins` shows `exit-code` failures and `journalctl -xeu jenkins.service` shows something like:
```
Running with Java 17 from /usr/lib/jvm/java-17-openjdk-amd64, which is older than the minimum required version (Java 21).
Supported Java versions are: [21, 25]
```
the apt upgrade pulled in a Jenkins release that now requires Java 21+. Debian 12 (Bookworm)'s main repo tops out at `openjdk-17-jdk` — same limitation the worker hit on Trixie — so install Java 21 via Eclipse Temurin (Adoptium):

**Run on: controller**
```bash
apt install -y wget apt-transport-https gpg
wget -O - https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor | tee /etc/apt/keyrings/adoptium.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(awk -F= '/^VERSION_CODENAME/{print$2}' /etc/os-release) main" | tee /etc/apt/sources.list.d/adoptium.list

apt update
apt install -y temurin-21-jdk
```

Then switch the system default `java` to it (Jenkins invokes whatever `java` resolves to on PATH):
```bash
update-alternatives --config java
```
Select the Temurin 21 entry, then reload systemd (needed after the JVM switch — restarting without this can still fail with the old "start request repeated too quickly" loop) before restarting:
```bash
systemctl daemon-reload
systemctl restart jenkins
systemctl status jenkins
```

If it still starts on 17 afterward, check `/etc/default/jenkins` for a hardcoded `JAVA_HOME` or `JENKINS_JAVA_CMD` line and point it at the Temurin binary directly (typically `/usr/lib/jvm/temurin-21-jdk-amd64/bin/java`).

Once the controller is on Java 21, the worker's `openjdk-21-jdk` (Section 3, Step 2) still matches — no change needed there.

### "It appears that your reverse proxy set up is broken" warning

If you're accessing Jenkins directly by IP:port (no reverse proxy), this warning is usually Jenkins' `ReverseProxySetupMonitor` false-tripping because the configured **Jenkins URL** doesn't match the address you're actually browsing to.

**Run on: controller** (via the web UI):
1. **Manage Jenkins > System** > **Jenkins Location > Jenkins URL**
2. Set it to exactly how you access it, with trailing slash, e.g. `http://10.0.0.105:8080/`
3. Save, then hard-refresh the browser (or try incognito) to confirm the warning clears

If the Jenkins URL is already correct and the warning persists, check for a browser extension, VPN, or transparent network proxy injecting `X-Forwarded-*` headers on the request even though there's no real proxy in place.

> **Warning:** this warning tends to go away cleanly once Jenkins is actually put behind a real DNS name + Nginx reverse proxy (with `proxy_set_header Host/X-Forwarded-*` set correctly) instead of being hit directly by IP:port — the direct-IP setup is what triggers the false positive in the first place. If you already have DNS and Nginx available, this is a reasonable permanent fix later; a self-signed or real cert isn't required to resolve the warning itself, only proper proxy headers and a matching Jenkins URL. Treat direct IP:port access as a temporary setup — plan to front it with Nginx once you're done with initial configuration.

#### Same warning, but after Nginx + TLS is already set up: missing `X-Forwarded-Proto`

If the banner persists even after Section 5.5 (DNS, cert, and Nginx all in place, Jenkins URL set to `https://...`), diagnose it precisely instead of guessing:

**Run on: controller** — check the Jenkins log for the exact comparison it makes:
```bash
journalctl -u jenkins -n 200 --no-pager | grep -i "vs\."
```
This prints lines like `http://jenkins.lab/manage vs. https://jenkins.lab/manage/` — the first value is what Jenkins *thinks* its URL is based on the incoming request; the second is what the browser was actually on. A scheme mismatch (`http` vs `https`) like this means Jenkins isn't seeing `X-Forwarded-Proto`.

Confirm it directly via **Manage Jenkins > Script Console**:
```groovy
def req = org.kohsuke.stapler.Stapler.getCurrentRequest2()
println("X-Forwarded-Proto header: " + req.getHeader("X-Forwarded-Proto"))
println("req.getScheme(): " + req.getScheme())
println("getRootUrlFromRequest(): " + jenkins.model.Jenkins.get().getRootUrlFromRequest())
```
If `X-Forwarded-Proto header` prints `null`, the header isn't reaching Jenkins — check the live Nginx config for the exact site:
```bash
cat /etc/nginx/sites-enabled/jenkins.lab
```
and confirm `proxy_set_header X-Forwarded-Proto $scheme;` is actually present in the `listen 443 ssl` block's `location /` (see the callout in Section 5.5 — this line is easy to lose during manual edits). Add it back if missing, then:
```bash
nginx -t
systemctl reload nginx
```
Re-run the Script Console check — it should now show `https` and a `getRootUrlFromRequest()` matching your real URL, and the banner clears on the next `/manage` load.

---

## 5. Next Steps After Linking Controller and Worker

Now that the worker connects successfully, here's what to lock down before relying on this setup for real work.

### 5.1 Move all builds off the controller

Right now the controller can still run builds itself. On an 8GB host, all actual build work should happen on the worker — the controller should only schedule and serve the UI.

**Run on: controller** (via the web UI):
1. **Manage Jenkins > Nodes**
2. Click the built-in node (usually labeled **Built-In Node** or **master**)
3. **Configure**
4. Set **Number of executors** to `0`
5. Save

With this set to 0, no job can land on the controller even accidentally — everything routes to `worker-01` (or any future worker).

### 5.2 Harden Jenkins security

TurnKey's default Jenkins security config is often permissive out of the box, and you're currently on plain HTTP with no proxy in front, so treat this as higher priority than usual.

**Run on: controller** (via the web UI):
1. **Manage Jenkins > Security**
2. Under **CSRF Protection**: modern Jenkins enables this by default and no longer exposes a plain on/off checkbox — if you see a "Crumb Issuer" already selected here, it's already active and there's nothing to change
3. Under **Authorization**: if it's set to **"Logged-in users can do anything,"** click the **Advanced...** link next to that option — that's where **Allow anonymous read access** actually lives (it's collapsed by default, which is why it wasn't visible). Uncheck it unless you want unauthenticated users to view job status. If you're on a different authorization strategy (Role-based, Matrix-based, etc.), anonymous access is instead controlled by whatever permissions are explicitly granted to the special "anonymous" user/row in that strategy's table
4. If you'd rather move to more granular control now, consider tightening it further:
   - **Manage Jenkins > Plugins > Available plugins**, search "Role-based Authorization Strategy," install, restart if prompted
   - **Manage Jenkins > Security > Authorization**, select **Role-Based Strategy**
   - **Manage Jenkins > Manage and Assign Roles > Manage Roles**: define roles (e.g. `admin`, `developer`) with specific permissions per role
   - **Manage and Assign Roles > Assign Roles**: assign your user(s) to the appropriate role
5. Until Jenkins is behind HTTPS (Section 5.5), avoid entering admin credentials over untrusted networks — plain HTTP means credentials travel in the clear

### 5.3 Configure build and log retention

With 20 GB disks on both containers, unbounded build history and artifacts will eventually fill the disk.

**Run on: controller** (via the web UI), per job:
1. Open a job > **Configure**
2. Check **Discard old builds**
3. Set **Days to keep builds** (e.g. `30`) and/or **Max # of builds to keep** (e.g. `20`)
4. Save

For Pipeline jobs, set this in the `Jenkinsfile` instead:
```groovy
options {
    buildDiscarder(logRotator(numToKeepStr: '20'))
}
```

Periodically check actual disk usage on both containers:
```bash
du -sh /var/lib/jenkins/jobs/*
df -h
```

### 5.4 Back up JENKINS_HOME

`JENKINS_HOME` (typically `/var/lib/jenkins`) holds job configs, build history, plugins, and credentials — losing it means rebuilding from scratch.

**Run on: controller**:
1. Check whether TurnKey's built-in TKLBAM backup is actually scheduled — log into Confconsole (`https://<controller-ip>:12321`) and check the backup status; TKLBAM is bundled but not necessarily configured to run automatically
2. For a quick manual backup in the meantime:
   ```bash
   systemctl stop jenkins
   tar czf /root/jenkins-home-backup-$(date +%F).tar.gz -C /var/lib/jenkins .
   systemctl start jenkins
   ```
   (Stopping Jenkins first avoids capturing an inconsistent mid-write state; fine for occasional manual backups, but rely on TKLBAM or a proper scheduled tool for ongoing protection.)

**On the Proxmox host** — schedule container-level snapshots as a second layer:
1. **Datacenter > Backup > Add**
2. Select both CT 101 (controller) and CT 102 (worker)
3. Set a nightly (or weekly) schedule, targeting your backup storage

Test a restore occasionally — a backup you haven't restored from isn't confirmed to work.

### 5.5 Put Jenkins behind your Nginx + DNS setup

This clears the reverse-proxy warning permanently and gets you off plain-IP HTTP. DNS (Pihole) and the TLS cert are already done — this wires Nginx up to use them.

**Run on: your Nginx host** — add a reverse proxy site config that redirects HTTP to HTTPS and terminates TLS with your generated cert:
```nginx
server {
    listen 80;
    server_name jenkins.yourdomain.lan;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name jenkins.yourdomain.lan;

    ssl_certificate     /etc/nginx/ssl/jenkins.crt;
    ssl_certificate_key /etc/nginx/ssl/jenkins.key;

    location / {
        proxy_pass http://10.0.0.105:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Port 443;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 90;
    }
}
```
Adjust `ssl_certificate` / `ssl_certificate_key` to wherever you actually placed the cert and key files, and confirm the DNS record in Pihole (`jenkins.yourdomain.lan`) resolves to the Nginx host's IP, not the controller's IP directly.

> **Critical:** `proxy_set_header X-Forwarded-Proto $scheme;` must be present in the `location /` block. Without it, Jenkins can't tell it's being accessed over HTTPS and computes its own root URL as `http://...` instead of `https://...`, which reliably triggers the "reverse proxy set up is broken" banner even when everything else (cert, DNS, Jenkins URL setting) is correct. If you ever hand-edit this file (e.g. to fix something else), double-check this line is still there afterward — it's easy to drop by accident.

```bash
nginx -t
systemctl reload nginx
```

**Run on: controller** (via the web UI) — update the URL Jenkins thinks it's at, to match:
1. **Manage Jenkins > System > Jenkins Location**
2. Set **Jenkins URL** to `https://jenkins.yourdomain.lan/`
3. Save

Confirm the reverse-proxy warning clears and Jenkins still loads correctly at the new address.

#### Trusting the certificate on client machines

If the cert wasn't issued by a public CA (Let's Encrypt, etc.) — i.e. it's self-signed or signed by your own internal/root CA — browsers and tools on any machine that hasn't been told to trust that CA will show certificate warnings or fail TLS verification outright. This is expected and separate from whether Nginx itself is configured correctly; distribute and trust the CA (or the leaf cert itself, if there's no separate CA) on each client that will access Jenkins:

- **Windows**: double-click the `.crt`/`.pem` file > **Install Certificate** > **Local Machine** > place it in **Trusted Root Certification Authorities**. For multiple machines, push it via Group Policy instead of doing this by hand each time.
- **macOS**: open the cert in **Keychain Access**, drag it into the **System** keychain, then double-click it and set **Trust > When using this certificate** to **Always Trust**.
- **Linux**: copy the CA cert to `/usr/local/share/ca-certificates/jenkins-ca.crt` (must end in `.crt`) and run:
  ```bash
  sudo update-ca-certificates
  ```
- **Firefox**: uses its own store, separate from the OS — `about:preferences#privacy` > **Certificates > View Certificates > Authorities > Import**.
- **Chrome/Edge**: use the OS trust store on Windows/macOS, so the OS-level steps above cover them; on Linux, Chrome uses the NSS store, which may need `certutil` from `libnss3-tools` instead of `update-ca-certificates`.

Only the *CA* certificate needs distributing this way (not the private key). If you generated this with a tool like `mkcert`, its root CA lives wherever `mkcert -CAROOT` points and is what needs importing above — not the per-site leaf cert. Once trusted, the warning disappears without touching Nginx or Jenkins again; it only needs to be done once per client device.

### 5.6 Verify a real build end-to-end

A node showing "connected" isn't the same as confirming a build actually executes there.

**Run on: controller** (via the web UI):
1. **New Item > Freestyle project**, name it `smoke-test`
2. Check **Restrict where this project can be run**, enter the worker's label (e.g. `linux worker`)
3. Add a build step, **Execute shell**:
   ```bash
   hostname && uname -a && java -version
   ```
4. Save, click **Build Now**
5. Open the console output — the hostname printed should be `jenkins-worker-01`, confirming the build ran on the worker, not the controller

If the build never starts, check **Manage Jenkins > Nodes** to confirm `worker-01` shows as Idle/connected rather than offline.

---

## 6. Ansible (surface level)

Ansible is a configuration-management/automation tool: you describe desired state in YAML "playbooks," and it applies that state to target machines over plain SSH — no agent needed on the targets. It pairs naturally with Jenkins: Jenkins builds things, Ansible can deploy or configure things as a later step in the same pipeline.

**Run on: worker**
```bash
apt update
apt install -y ansible
ansible --version
```

Minimal example — an inventory file and a playbook:
```ini
# inventory.ini
[web]
10.0.0.50
```
```yaml
# site.yml
- hosts: web
  tasks:
    - name: ensure nginx is installed
      apt:
        name: nginx
        state: present
```
Run it manually to confirm it works:
```bash
ansible-playbook -i inventory.ini site.yml
```

To call it from a Jenkins job, Jenkins needs the inventory and playbook files in its workspace first — they don't just exist on the worker by default. The standard way: keep them in a Git repo, and have the job check that repo out before running Ansible, same as it would for application source code.

Pipeline example:
```groovy
pipeline {
    agent { label 'linux worker' }
    stages {
        stage('Checkout') {
            steps {
                git url: 'https://github.com/you/infra-repo.git'
            }
        }
        stage('Deploy') {
            steps {
                sh 'ansible-playbook -i inventory.ini site.yml'
            }
        }
    }
}
```
The checkout step pulls the repo into the job's workspace (e.g. `/home/jenkins/agent/workspace/job-name/`), and the shell step runs from that same directory, so the relative paths to `inventory.ini` and `site.yml` resolve correctly.

For a Freestyle job instead of a Pipeline, add the repo under **Source Code Management > Git**, then add an **Execute shell** build step with the same `ansible-playbook -i inventory.ini site.yml` command — the checkout happens automatically before build steps run.

No special Jenkins plugin is required for any of this — an official Ansible plugin exists if you'd rather have playbook runs appear as a structured build step instead of raw shell, but it's optional. Keeping the files in Git (rather than static copies on the worker) also gets you version history, which matters once you're not just experimenting.

Note: Ansible needs SSH key access to whatever hosts it's managing, same pattern as the controller-to-worker SSH setup in Section 3 — generate/distribute a keypair for whatever machines you point it at.

This is intentionally a starting point — inventories, roles, vault for secrets, and dynamic inventory are all worth exploring later once you're actually using this for something.

---

## 7. GitHub Credentials (for private repo checkout)

Jenkins needs credentials to clone private repos (like the infra repo referenced in Section 6). Two approaches: a fine-grained Personal Access Token over HTTPS (simpler), or an SSH deploy key scoped to one repo (more restrictive). PAT is covered in full below; SSH is a quick alternative at the end.

### 7.1 Generate a fine-grained Personal Access Token

**Run on: GitHub** — **Settings > Developer settings > Personal access tokens > Fine-grained tokens > Generate new token**, filling in:

1. **Token name**: something identifiable, e.g. `jenkins-repo-access`
2. **Description**: optional, e.g. "Used by Jenkins to checkout repos"
3. **Resource owner**: your GitHub account (or the org, if the repo lives under one)
4. **Expiration**: pick a reasonable window (e.g. 90 days) — fine-grained tokens require an expiration, so set a reminder to rotate it before it lapses, since Jenkins jobs will start failing auth silently once it expires
5. **Repository access**: select **Only select repositories**, then choose the specific repo(s) Jenkins needs — narrower than "All repositories"
6. **Permissions > Repository permissions**:
   - **Contents**: **Read-only** (allows `git clone`/`git fetch`; use **Read and write** only if Jenkins also needs to push)
   - GitHub auto-adds **Metadata: Read-only** alongside it — required, leave it
   - Leave everything else at **No access** unless a specific job needs it
7. Click **Generate token**, then **copy it immediately** — GitHub only shows it once

### 7.2 Add the credential to Jenkins

**Run on: controller** (via the web UI): **Manage Jenkins > Credentials > System > Global credentials (unrestricted) > Add Credentials**
- Kind: **Username with password**
- Username: your GitHub username
- Password: paste the token from Step 7.1
- ID: e.g. `github-pat`
- Save

Reference it in a Pipeline:
```groovy
git credentialsId: 'github-pat', url: 'https://github.com/you/repo.git'
```
Or in a Freestyle job: **Source Code Management > Git**, set the Repository URL to the HTTPS clone URL, then select the credential from the dropdown that appears.

### 7.3 Test it

Two ways to confirm the token actually works — test the token directly first, then confirm Jenkins can use it.

**Run on: controller or worker** — quick CLI test, without involving Jenkins at all:
```bash
git ls-remote https://<username>:<token>@github.com/you/repo.git
```
A list of branch refs means the token and repo access are correct. An auth error here means the problem is the token/permissions, not Jenkins — fix it before troubleshooting further in the UI.

**Run on: controller** (via the web UI) — confirm Jenkins itself can use the stored credential:
1. **New Item > Freestyle project**, name it `github-checkout-test`
2. Under **Source Code Management**, select **Git**, enter the repo's HTTPS URL, and pick the `github-pat` credential from the dropdown
3. Save, click **Build Now**
4. Check the console output — a successful `Cloning repository...` with no auth errors confirms the credential is wired up correctly end-to-end

If the Freestyle test fails but the raw `git ls-remote` succeeded, the issue is in how the credential is attached to the job (wrong credential selected, wrong repo URL) rather than the token itself.

If the build instead fails with `Cannot run program "git" ... No such type of file or directory`, git itself isn't installed on the worker (Section 3, Step 2 covers this). Install it directly on the worker's OS via SSH — a build step can't fix this, since Jenkins clones the repo in a phase that runs before any build steps execute:
```bash
apt install -y git
```

### Alternative: SSH deploy key

For access scoped to a single repo instead of an account-wide token:

**Run on: controller**:
```bash
ssh-keygen -t ed25519 -C "jenkins-github" -f ~/.ssh/github_deploy_key
```
**Run on: GitHub** — repo **Settings > Deploy keys > Add deploy key**, paste the public key (check "Allow write access" only if Jenkins needs to push).

**Run on: controller** (via the web UI) — add the private key the same way as the worker SSH setup (Section 3, Step 4): Kind **SSH Username with private key**, Username `git` (GitHub's convention for all SSH access), paste the private key, ID e.g. `github-deploy-key`.

Reference it with the SSH clone URL instead:
```groovy
git credentialsId: 'github-deploy-key', url: 'git@github.com:you/repo.git'
```
Test the same way as Section 7.3, substituting `ssh -T git@github.com` for the `git ls-remote` step to confirm the key is accepted before testing through Jenkins.
