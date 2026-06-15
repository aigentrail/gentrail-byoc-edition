# Gentrail BYOC

> [!WARNING]
> Work in progress. Scripts, image tags, and interfaces may change without
> notice, and this is not yet production ready. Expect rough edges.

Run the full Gentrail stack in your own AWS account. Internal by default: private
ALBs, no public domain, and no login, so the cluster network is your access
boundary. One script, then paste your license in the dashboard.

## 1. Get a license

Get a free evaluation license (10 agents, 60 days) at https://gentrail.ai/license.
You paste it into the dashboard after install; there is nothing to set up first.

## 2. Prerequisites

- An AWS account with CloudFormation, EKS, KMS, IAM, RDS, and S3 rights, with the
  CLI authenticated (`aws sts get-caller-identity` works).
- `aws` (v2.17+), `kubectl`, `helm` (v3.13+), and `jq` on your PATH.

## 3. Install

```bash
git clone https://github.com/aigentrail/gentrail-byoc-edition.git
cd gentrail-byoc-edition
./install.sh
```

This takes about 30 minutes. It stages the CloudFormation template, stands up the
EKS and RDS substrate, installs the AWS Load Balancer Controller and a default
StorageClass, then installs the chart. It is idempotent, so re-run it to upgrade
in place.

Optional env vars: `REGION` (default us-west-2), `STACK` (default gentrail),
`IMAGE_TAG` (override the pinned version), and `PUBLIC_HOST` with
`PUBLIC_OTEL_HOST` for a public, internet-facing install instead of the internal
default.

## 4. Open the dashboard

There is no login. Reach the internal ALB over your VPC or VPN, or port-forward
it:

```bash
kubectl -n gentrail port-forward deploy/dashboard 8001:8001   # http://localhost:8001
```

Every page redirects to the license input until you paste your license. Once you
do, it is written to the mounted secret and every service activates within about
two minutes.

## 5. Send a trace

Generate an API key in the dashboard (Integrations, then API keys), install the
SDK, and run an agent pointed at your install. See the SDK quickstart at
https://github.com/aigentrail/sdk.

## License

The license is an Ed25519-signed JWT. Paste it or a renewal on the dashboard's
License page; it verifies locally and hot-reloads every service with no restarts.
You get a renewal banner within 30 days of expiry. At expiry the install goes
read-only: reads keep working, writes are refused, and nothing is deleted, until
you install a new license.

Free tier covers full observability and the dashboard for 60 days with up to 10
agents. Past 10 agents, new agents' traces are dropped at ingest (the request
still succeeds) and a banner reports the suppressed count.

## Uninstall

```bash
deploy/m3/scripts/uninstall.sh gentrail
```

Follow the prompts. The final step schedules the KMS key for deletion, which is
irreversible and makes all SSE-KMS-encrypted backups permanently unreadable.

## Hardening

The install is single-tenant with no login, so the network is your boundary.
Restrict dashboard and ingest access to your VPN or corporate CIDR, confirm
CloudTrail is on, and forward logs to your SIEM.
