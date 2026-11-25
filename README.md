# SmartTunes DevOps — Three Dog

DevOps toolchain and server pipeline for **SmartTunes**, a PHP karaoke web app
(SWE40006 Software Deployment and Evolution team project).

## Repository layout

| Path | Contents |
|---|---|
| `app/` | SmartTunes PHP application (copied from `DebugKnight-SmartTunes/legacy`) |
| `db/` | `schema_seed.sql` — MySQL schema + ~1,000 seed rows per table |
| `tests/` | Automated tests (Phase 3) |
| `docker/` | Dockerfile and PHP config (Phase 3) |
| `deploy/` | Compose file, Nginx templates, canary/rollback scripts (Phase 3–4) |
| `monitoring/` | Prometheus config, Grafana dashboards (Phase 2) |
| `Jenkinsfile` | Pipeline definition (Phase 1+) |

Secrets are never committed. `.env` files and certificates are git-ignored.

## Decisions log (Phase 0)

| # | Decision | Notes |
|---|---|---|
| 1 | Deploy the PHP app (`legacy/`) | Runs on PHP 8 + Apache with `mod_rewrite`; needs `mysqli`, `curl`, `fileinfo`, `openssl`. Config via env vars (override `app/config/.env`). The React/Express folders in the source repo are unfinished scaffolds. |
| 2 | Data services | Aiven for MySQL (TLS) and Supabase Storage (public bucket `karaoke-recordings`), both already supported by the app. |
| 3 | Infrastructure | All on AWS, one VPC, four EC2 instances (Ubuntu 24.04): `jenkins` (t3.medium), `test` (t3.small), `prod` (t3.small, Elastic IP), `monitoring` (t3.micro). Funded by credits. |
| 4 | Monitoring access | Prometheus on the `monitoring` EC2 scrapes `prod` over the private VPC network; prod's security group allows only the monitoring security group on 9100/8080. No VPN. |
| 5 | Images | Docker Hub repo `smarttunes` (public). Tag = short Git SHA; deploy by digest. `latest` is not used for deploys. |
| 6 | Secrets | Docker Hub token in AWS Secrets Manager (`dockerhub`), exposed to Jenkins via the AWS Secrets Manager Credentials Provider plugin and the jenkins EC2's IAM role. |
| 7 | Sessions under Canary | Default PHP file sessions are per-container; to be handled before the Canary phase. |
| — | Deferred | Separate test DB (`smarttunes_test`) and test bucket (`karaoke-recordings-test`). |
