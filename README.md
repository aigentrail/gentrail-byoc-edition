# Gentrail BYOC

> [!WARNING]
> Work in progress. Interfaces and image tags may change without notice while
> we continuously harden the system. Expect rough edges.

Run the full Gentrail stack in your own AWS account; your trace data never leaves
it. There is no login, so the network is your access boundary. One binary installs,
connects, reports on, and removes it; there is nothing to clone.

## 1. Get a license

Get a free evaluation license (10 agents, 60 days) at https://gentrail.ai/#license.
You paste it into the dashboard after install; there is nothing to set up first.

## 2. Install the CLI

```bash
curl -LsSf https://gentrail.ai/install.sh | sh
```

This downloads the `gentrail` binary for your platform from this repo's latest
release, verifies its SHA256, and puts it in `~/.local/bin`. On Windows, download
`gentrail-windows-amd64.exe` (or `-arm64`) from the latest release, rename it to
`gentrail.exe`, and put it on your `PATH`; every command below works the same from
PowerShell.

The CLI uses your AWS credentials the way the `aws` CLI does (`aws sts
get-caller-identity` must work). `gentrail connect` also needs `aws` and `kubectl`
on your PATH, plus the AWS Session Manager plugin for the evaluation tier.

## 3. Pick a tier

- **Evaluation** (start here): one EC2 node running k3s with every store
  in-cluster. About 5 to 8 minutes, roughly $70/mo while it runs. Single-AZ,
  node-local storage, no managed backups: a trial box, not a system of record.
- **Production**: EKS + RDS, KMS CMK encryption, and S3 Object-Lock evidence.
  About 30 minutes, roughly $400/mo. Highly available and the compliance system
  of record.

Both keep all data in your account. Start on Evaluation; move to Production when
you need HA and the compliance posture.

## 4. Install

```bash
gentrail install --tier evaluation     # or --tier production
```

Evaluation deploys one CloudFormation stack; the node installs k3s and the chart
itself. Production stages the trace archiver, stands up the EKS and RDS substrate,
and a short-lived bootstrap node inside the VPC installs the load balancer
controller and the chart, then stops itself. Either way your machine only runs
the CLI, and each step is shown as it happens.

Production puts the dashboard and the OTLP ingest endpoint behind two load
balancers the stack itself owns, private inside the VPC by default; `gentrail
status` prints their URLs. Pass `--dashboard-exposure internet-facing` or
`--otel-exposure internet-facing` together with `--cert-arn` (an ACM certificate)
to publish either one with TLS, and `--allowed-cidr` to narrow who can reach them.

Production needs broad admin-level AWS rights: the stack provisions a VPC, EKS,
RDS, DynamoDB, Lambda, S3, KMS, Secrets Manager, CloudWatch Logs, and named IAM
roles. Attach the scoped `iac/cfn/deploy-policy.json` from this repo to your
deploy principal, or use `arn:aws:iam::aws:policy/AdministratorAccess` for the
simplest path. Evaluation needs only the EC2, IAM, and SSM subset.

Flags: `--stack` (default `gentrail`), `--region`, `--profile`. Re-running Production
is a no-op unless the stack inputs change. Re-running Evaluation is a no-op unless
you change a node property; upgrading the appliance means replacing the node,
which wipes its node-local data.

## 5. Open the dashboard

```bash
gentrail connect                       # leave it running; Ctrl-C to disconnect
```

This detects your tier and forwards the dashboard and the OTLP ingest endpoint to
localhost with nothing publicly exposed (Evaluation over an SSM tunnel to the box,
Production through the EKS API). Open http://localhost:8001. There is no login;
every page redirects to the license input until you paste your license, then every
service activates within about two minutes.

On Production the principal running `connect` needs access to the EKS cluster. The
principal that ran `install` has it automatically; grant others an EKS access entry
on the cluster.

`gentrail status` reports the install's health at any time.

## 6. Send a trace

Generate an API key in the dashboard (Integrations, then API keys), install the
SDK, and run an agent pointed at the OTLP endpoint `gentrail connect` printed. See
the SDK quickstart at https://github.com/aigentrail/sdk.

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
gentrail teardown                      # add --stack <name> if you changed it at install
```

Confirms once, then detects the tier. Evaluation deletes the single stack (its EC2
and VPC). Production clears the database's deletion protection and deletes the
substrate: EKS, RDS, the VPC, and the stack's own load balancers. Nothing the
install creates lives outside its stack, so a console delete works the same way.
Your data stores are kept on purpose: the DynamoDB tables, the evidence,
trace-archive, and log buckets, the KMS key, and the gentrail-cfn-<account>-<region>
bucket the CLI stages templates in survive a teardown so it can never destroy
customer data. Delete them yourself when you are sure; until then a reinstall
under the same stack name collides with the retained table names.

## What ships in this repo

The Helm chart the install runs, the CloudFormation templates it deploys, the
scoped IAM policy, and the CLI binaries on the releases page. The service source
does not ship; the chart pulls public images.

## Hardening

The install is single-tenant with no login, so the network is your boundary.
Restrict dashboard and ingest access to your VPN or corporate CIDR, confirm
CloudTrail is on, and forward logs to your SIEM.
