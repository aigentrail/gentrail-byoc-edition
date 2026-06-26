# Gentrail BYOC

> [!WARNING]
> Work in progress. Scripts, image tags, and interfaces may change without
> notice while we continuously harden the system. Expect rough edges.

Run the full Gentrail stack in your own AWS account; your trace data never leaves
it. There is no login, so the network is your access boundary. One command picks
a tier, then you paste your license in the dashboard.

## 1. Get a license

Get a free evaluation license (10 agents, 60 days) at https://gentrail.ai/#license.
You paste it into the dashboard after install; there is nothing to set up first.

## 2. Quickstart: evaluation with the CLI

For the evaluation tier the `gentrail` CLI is the one-command path: it embeds the
CloudFormation template (no repo clone) and shows each step as it stands up a bare
k3s box over SSM. `connect` needs the AWS Session Manager plugin and `kubectl`, as
the script does.

```bash
curl -LsSf https://gentrail.ai/install.sh | sh   # install the gentrail CLI
gentrail install --tier evaluation               # stand up the box (~5 min)
gentrail connect                                 # tunnel the dashboard to localhost:8001
```

Paste your license in the dashboard, then send a trace (step 7). `gentrail status`
reports health and `gentrail teardown` removes the box. Production (EKS + RDS) uses
the cloned-repo scripts below; the CLI covers evaluation only.

## 3. Pick a tier

`./install.sh` asks which tier to stand up (or pass `--tier=eval` / `--tier=prod`
to skip the prompt):

- **Evaluation** (recommended to start): one EC2 node running k3s with every
  store in-cluster. About 5 to 8 minutes, roughly $70/mo while it runs. Single-AZ,
  node-local storage, no managed backups: a trial box, not a system of record.
- **Production**: EKS + Multi-AZ RDS, KMS CMK encryption, and S3 Object-Lock
  evidence. About 30 minutes, roughly $400/mo. Highly available and the
  compliance system of record.

Both keep all data in your account. Start on Evaluation; move to Production when
you need HA and the compliance posture.

## 4. Prerequisites

```bash
git clone https://github.com/aigentrail/gentrail-byoc-edition.git
cd gentrail-byoc-edition
```

- **Evaluation**: the `aws` CLI authenticated to your account
  (`aws sts get-caller-identity` works), plus the AWS Session Manager plugin so
  `./connect.sh` can reach the box. The node self-installs; nothing else is
  needed locally.
- **Production**: `aws` (v2.17+), `kubectl`, `helm` (v3.13+), and `jq` on your
  PATH, and broad admin-level AWS rights: the stack provisions a VPC, EKS, RDS,
  DynamoDB, Lambda, S3, KMS, ACM, Secrets Manager, CloudWatch Logs, and named IAM
  roles (so the deploy needs CAPABILITY_NAMED_IAM).

For those rights, attach the scoped `deploy/m3/cfn/deploy-policy.json` from this repo
to your deploy principal (it grants only the services the installer provisions and
keeps `iam:*` because the stack creates named roles), or use
`arn:aws:iam::aws:policy/AdministratorAccess` for the simplest path. Evaluation needs
only the EC2, IAM, and SSM subset.

## 5. Install

```bash
./install.sh                 # then pick a tier
```

Evaluation deploys one CloudFormation stack; the node installs k3s and the chart
itself, so your machine only needs the `aws` CLI. Production stages the template,
stands up the EKS and RDS substrate, installs the AWS Load Balancer Controller and
a default StorageClass, then installs the chart. The controller step pulls its
manifests from `raw.githubusercontent.com` and `aws.github.io`, so the install host
needs egress there. Production is idempotent: re-run to upgrade in place. Re-running Evaluation is a no-op unless you change a node
property; upgrading the appliance means replacing the node (a newer instance type
or AMI), which wipes its node-local data.

Optional env vars: `REGION` (default us-west-2), `STACK` (default gentrail),
`INSTANCE_TYPE` (Evaluation node size), `LICENSE_JWT` (Evaluation only: pre-seed a
license; on Production paste it in the dashboard). On Production, `PUBLIC_OTEL_HOST`
makes OTLP ingest internet-facing while the dashboard stays internal, and
`PUBLIC_HOST` also exposes the dashboard.

## 6. Open the dashboard

```bash
./connect.sh                 # leave it running; Ctrl-C to disconnect
```

This auto-detects your tier and tunnels the dashboard and the OTLP ingest endpoint
to localhost with nothing publicly exposed (Evaluation over SSM, Production through
the EKS API). Open http://localhost:8001. There is no login; every page redirects
to the license input until you paste your license, then every service activates
within about two minutes.

## 7. Send a trace

Generate an API key in the dashboard (Integrations, then API keys), install the
SDK, and run an agent pointed at the OTLP endpoint `./connect.sh` printed. See the
SDK quickstart at https://github.com/aigentrail/sdk.

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
./teardown.sh                 # add STACK=<name> if you changed it at install
```

Confirms once, then auto-detects the tier. Evaluation deletes the single stack
(its EC2 and VPC). Production removes the chart, the substrate (EKS + RDS + VPC),
and the non-locked S3 buckets, and schedules the KMS key for deletion. The WORM
evidence bucket (Object-Lock, default 7-year retention) is not removed while its
objects are within their retention window; delete it manually with
bypass-governance-retention. The KMS step is irreversible once its window elapses
and makes all SSE-KMS-encrypted backups unreadable.

## Hardening

The install is single-tenant with no login, so the network is your boundary.
Restrict dashboard and ingest access to your VPN or corporate CIDR, confirm
CloudTrail is on, and forward logs to your SIEM.
