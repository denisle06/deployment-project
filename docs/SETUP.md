# SmartTunes pipeline: setup runbook

Three EC2 instances in one VPC, all created from one launch template.

| Name / Role tag | Type | Disk | Security group | IAM role |
|---|---|---|---|---|
| `jenkins` | t3.medium | 30 GB | `sg-jenkins` | `jenkins-secrets-read` |
| `test` | t3.small | 20 GB | `sg-test` | none |
| `prod` | t3.small | 20 GB | `sg-prod` | none |

Security groups:

| Group | Inbound |
|---|---|
| `sg-jenkins` | 22, 8080 (Jenkins), 3000 (Grafana) from your IP |
| `sg-test` | 22 from `sg-jenkins` and your IP |
| `sg-prod` | 80 from anywhere; 22 from `sg-jenkins` and your IP; 9100 and 8080 (metrics) from `sg-jenkins` |

## 1. Launch template (once)

EC2 → Launch templates → Create launch template:

- **Name:** `smarttunes-base`
- **AMI:** Ubuntu Server 24.04 LTS (64-bit x86)
- **Instance type:** t3.small · **Key pair:** `three-dog-key`
- **Network settings:** leave subnet and security group unset (chosen per launch)
- **Storage:** 20 GiB gp3
- **Advanced details:**
  - Metadata version: **V2 only (token required)**
  - Allow tags in metadata: **Enable** (the startup script reads the `Role` tag)
  - User data: paste the whole of [`infra/user-data.sh`](../infra/user-data.sh)

## 2. Launch the three instances

Launch templates → `smarttunes-base` → Actions → **Launch instance from template**, three times. For each, override:

- **Instance type**, **storage** and **security group** from the table above
- **Advanced details → IAM instance profile:** `jenkins-secrets-read` (jenkins only)
- **Resource tags:** `Name` = jenkins / test / prod **and** `Role` = jenkins / test / prod (tag "Instances")

Installation takes about 3–5 minutes. Check it finished:
```bash
ssh -i three-dog-key.pem ubuntu@<public-ip> 'ls /var/log/smarttunes-bootstrap.done && tail -n 3 /var/log/smarttunes-bootstrap.log'
```

## 3. Prod: app secrets

```bash
ssh -i three-dog-key.pem ubuntu@<prod-public-ip>
nano /opt/smarttunes/app.env        # fill in from deploy/app.env.example (prod DB + bucket)
chmod 600 /opt/smarttunes/app.env
```

## 4. Jenkins

1. Open `http://<jenkins-public-ip>:8080`. Unlock with:
   `ssh ... ubuntu@<jenkins-public-ip> sudo cat /var/lib/jenkins/secrets/initialAdminPassword`
2. **Install suggested plugins**, create the admin user.
3. Manage Jenkins → Plugins → Available, install:
   - **AWS Secrets Manager Credentials Provider**
   - **SSH Build Agents**
4. Manage Jenkins → System → **AWS Secrets Manager Credentials Provider**: set the region if `dockerhub` does not appear under Credentials.
5. Manage Jenkins → Credentials → System → Global, add:

| ID | Kind | Value |
|---|---|---|
| `dockerhub` | (appears automatically from Secrets Manager) | |
| `github` | Username with password | `denisle06` + a fine-grained PAT with read access to this repo's contents (or store it in Secrets Manager like `dockerhub`) |
| `ec2-ssh` | SSH Username with private key | Username `ubuntu`, key = contents of `three-dog-key.pem` |
| `smarttunes-test-env` | Secret file | an `app.env` pointing at the **test** DB and **test** bucket |

6. Manage Jenkins → Nodes → **New node** `test` (Permanent agent):
   - Remote root directory `/home/ubuntu/jenkins-agent` · Labels `test` · Executors 1
   - Launch method: **via SSH** · Host: test **private** IP · Credentials `ec2-ssh`
   - Host key verification: **Manually trusted key verification strategy**
7. New Item → `smarttunes` → **Pipeline**:
   - Pipeline script from SCM → Git → `https://github.com/denisle06/deployment-project.git`, credentials `github`, branch `*/main`, script path `Jenkinsfile`
8. Edit the two `CHANGE_ME` values at the top of `Jenkinsfile` (Docker Hub repo, prod private IP), commit, then **Build Now** once. This first run also activates the 2-minute polling trigger.

## 5. Monitoring (on the jenkins EC2)

```bash
ssh -i three-dog-key.pem ubuntu@<jenkins-public-ip>
git clone https://github.com/denisle06/deployment-project.git   # PAT as password
cd deployment-project/monitoring
sed -i 's/PROD_PRIVATE_IP/<prod-private-ip>/g' prometheus.yml
docker compose up -d
```
Grafana: `http://<jenkins-public-ip>:3000` (admin/admin). Dashboards → New → Import → ID **1860** (Node Exporter Full) and **14282** (cAdvisor), data source Prometheus.

## 6. Demo commands

| What | How |
|---|---|
| Level 4 release | Change something visible in `app/`, commit, push → Jenkins picks it up within 2 min |
| Blocked release | Build with Parameters → tick `FAIL_TESTS` → Test stage fails, prod unchanged |
| Automatic rollback | Build with Parameters → tick `SIMULATE_CANARY_FAILURE` → gate fails at 10%, traffic back to stable |
| Manual rollback | `ssh ubuntu@<prod> bash /opt/smarttunes/scripts/rollback.sh` |
| Which version answered | `curl -sI http://<prod-public-ip>/login.php \| grep X-App-Version` |
| Canary evidence | `ssh ubuntu@<prod> tail -f /var/log/nginx/smarttunes.access.log` |
