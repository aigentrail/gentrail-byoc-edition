# Gentrail BYOC — install

Run the whole stack in your own AWS account. Internal by default: private ALBs,
no public domain, no login (the install is single-tenant, so the cluster network
is the access boundary). One script, then paste your license in the dashboard.

## 1. Get your free license

Get one at https://gentrail.ai/license: a short form returns a free BYOC
evaluation license (10 agents, 60 days), shown on the page and emailed to you.
You paste it into the dashboard after install - nothing to create up front.

## 2. Prerequisites

- An AWS account with **CloudFormation, EKS, KMS, IAM, RDS, S3** rights, with the
  CLI authenticated to it (`aws sts get-caller-identity` works).
- `aws` (v2.17+), `kubectl`, `helm` (v3.13+), and `jq` on your PATH.

## 3. Install

```bash
git clone https://github.com/aigentrail/gentrail-byoc-edition.git
cd gentrail-byoc-edition
./install.sh                  # ~30 min: substrate (EKS + RDS) + the chart
```

Optional env vars:

| var | default | purpose |
|-----|---------|---------|
| `REGION` | `us-west-2` | AWS region |
| `STACK` | `gentrail` | stack / cluster name |
| `GHCR_USER` + `GHCR_TOKEN` | — | a `read:packages` token, only if the images are private |
| `PUBLIC_HOST` (+ `PUBLIC_OTEL_HOST`) | — | do a public, internet-facing install instead of internal |
| `IMAGE_TAG` | the chart's pin | override the image version |

`install.sh` stages the template, stands up the substrate, installs the AWS Load
Balancer Controller + a default StorageClass, and installs the chart (which
auto-provisions an empty license secret). It is idempotent — re-run it to upgrade
in place.

## 4. Open the dashboard and add your license

There is no login. The ALBs are internal, so reach the dashboard over your VPC /
VPN, or port-forward it:

```bash
kubectl -n gentrail port-forward deploy/dashboard 8001:8001   # http://localhost:8001
```

With no license yet, every page redirects to the license input. Paste your
license; it is written to the provisioned secret and every service activates
within about two minutes.

## 5. Send your first trace (SDK quickstart, ~5 min)

Generate a key, run a tiny agent, watch it appear.

1. **Generate an API key.** In the dashboard open Integrations, then API keys,
   and generate a key. Copy it.

2. **Install the SDK** into your agent's Python environment:

   ```bash
   pip install aigentrail
   ```

3. **Point the SDK at your install and run a sample agent.** Save this as
   `first_agent.py`:

   ```python
   from aigentrail import get_governance_tracer

   tracer = get_governance_tracer()  # reads AIGENTRAIL_API_KEY + endpoint from env
   if tracer is None:
       raise SystemExit("AIGENTRAIL_API_KEY not set, or opentelemetry not installed")

   tracer.record_llm_call(
       agent_id="hello-agent",
       agent_name="Hello Agent",
       model_id="anthropic.claude-sonnet-4-5-20250929-v1:0",
       prompt="What is the capital of France?",
       response_text="Paris.",
       input_tokens=8,
       output_tokens=2,
       total_tokens=10,
   )
   tracer.force_flush()  # flush before the process exits
   print("sent one invocation")
   ```

   Point it at the ingest endpoint and run it (port-forward is easiest for a
   quick check; in production use the internal ALB DNS):

   ```bash
   kubectl -n gentrail port-forward deploy/authproxy 4318:4318 &
   export AIGENTRAIL_API_KEY=<the-key-from-step-1>
   export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
   python3 first_agent.py
   ```

4. **See it land.** `hello-agent` shows up under Agents within a few seconds,
   with the invocation and model call in its trace viewer. Watch the pipeline:
   `kubectl -n gentrail logs deploy/evaluator -f`. That's one of your 10
   free-tier agents.

If the agent doesn't appear: confirm the API key is active and that
`OTEL_EXPORTER_OTLP_ENDPOINT` reaches the authproxy.

## License lifecycle

The license is an Ed25519-signed JWT. An org admin pastes it (or a renewal) on
the dashboard's License page; it verifies locally, patches the one mounted
secret, and every service hot-reloads within about two minutes — no restarts.

- **Pre-expiry:** services log `license: valid … expires_in=N days`.
- **Within 30 days:** a renewal banner + `WARN license: expires in N days` so your
  log aggregator can escalate.
- **At expiry:** the install goes **read-only** — reads keep working, new writes
  are refused, nothing is deleted. Install a new license to resume.

A present-but-invalid license (unparseable / bad signature / `nbf` in the future)
fails a service at startup; a *missing* one is fine — the install runs unlicensed
and waits for you to paste one. There is no online revocation.

## Free tier (10 agents, 60 days)

Full observability (trace ingestion, agent inventory, trace viewer, policy /
violation detection) and the dashboard, for 60 days with up to 10 agents.

- **Agent cap:** past 10 distinct agents, new agents' traces are dropped at the
  ingest front door (the request still succeeds, so the SDK isn't interrupted)
  and a dashboard banner reports the suppressed count. The first 10 keep flowing.
- **60-day expiry → read-only:** at the license `exp` the install goes read-only
  (reads work, ingestion returns 402, no data deleted), with countdown banners at
  30 / 14 / 7 / 1 days. Installing a new license clears it, non-destructively.

## Uninstall

```bash
deploy/m3/scripts/uninstall.sh gentrail
```

Follow the prompts. KMS-key deletion is the irreversible step that makes all
SSE-KMS-encrypted backups permanently unreadable.

## Recovering from a failed install

Retained resources (S3, DynamoDB, KMS, RDS snapshots) survive a failed `create`,
so a retry fails early on "already exists". To recover: delete the stack
(`aws cloudformation delete-stack`), then remove the retained RDS instance,
DynamoDB tables, and S3 buckets for the stack, and re-run `install.sh`.

## Hardening checklist (first 24 hours)

1. **Restrict dashboard + ingest access** to your VPN / corporate CIDR — the
   install is single-tenant with no login, so the network is the access boundary.
2. **Confirm CloudTrail is on** and **forward CloudWatch logs to your SIEM**.
