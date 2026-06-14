# Gentrail M3 BYOC — install runbook

Total wall-clock: ~90 minutes. ~15 minutes of your attention.

## Before you begin: get your free license

The Gentrail BYOC stack is free to evaluate: up to 10 agents for 60 days. The
container images are public; a signed license is what unlocks the stack.

1. Get a free license at https://gentrail.ai/license. Fill in the short form and
   your free BYOC evaluation license is shown on the page and emailed to you.
2. Save the license JWT to a file. It becomes a Kubernetes Secret in Step 6.

The license is a 10-agent, 60-day evaluation. To extend or upgrade to Unlimited,
email support@gentrail.ai (see Section 12).

## 0. Prerequisites

- An AWS account with **CloudFormation, EKS, KMS, IAM, RDS, S3** rights.
- The AWS CLI (v2.17+), `kubectl`, `helm` (v3.13+), and `jq` on your shell PATH.
- This deploy repo (Helm chart, CFN templates, scripts) checked out locally.
- Your free license JWT from the step above.
- `python3` and `pip` if you want to run the SDK quickstart in Step 10a.
- Optionally, a Route 53 hosted zone you control for the dashboard hostname. If you don't share Route 53 with us, you'll create the DNS record manually in Step 9.

## 1. Generate an ExternalId

```bash
EXTERNAL_ID="$(uuidgen)x$(uuidgen)"
echo "$EXTERNAL_ID"   # save somewhere — you'll email it to us in step 3
```

## 1b. Stage the CFN template + archiver Lambda (~1 min)

The substrate template is >51 KB, over CloudFormation's inline limit, so it
deploys from a staging S3 bucket. The trace-archiver Lambda zip (vendor ships
it alongside the chart and images) stages into the same bucket:

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=us-west-2
STAGING="gentrail-cfn-staging-${ACCOUNT}-${REGION}"
aws s3api create-bucket --bucket "$STAGING" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"
aws s3api put-public-access-block --bucket "$STAGING" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3 cp archiver.zip "s3://$STAGING/lambda/archiver.zip"
```

## 2. Launch the substrate stack (~25 min)

The substrate template is the single CFN you deploy — it provisions
everything: VPC, EKS, RDS, S3, KMS, DDB, IRSA roles, ACM cert, the
Bedrock-model validator Lambda, the trace-archiver Lambda (expired traces
archive to S3 with GLACIER tiering, same retention as Gentrail cloud), AND the
cross-account scanner role the vendor will assume into your account. The
Gentrail services themselves (authproxy, evaluator, dashboard, policy-engine,
NATS) install as pods via the Helm chart in Step 7.

```bash
aws cloudformation deploy \
    --template-file deploy/m3/cfn/m3-byoc-substrate.yaml \
    --stack-name gentrail-substrate \
    --s3-bucket "$STAGING" --s3-prefix substrate \
    --parameter-overrides \
        Hostname=gentrail.acme.com \
        OtelHostname=otel.acme.com \
        HostedZoneId=Z0123456789ABCDEFGHIJ \
        ExternalId="${EXTERNAL_ID}" \
        BedrockModelId="anthropic.claude-3-5-sonnet-20241022-v2:0" \
        ArchiverCodeS3Bucket="$STAGING" \
        ArchiverCodeS3Key=lambda/archiver.zip \
    --capabilities CAPABILITY_NAMED_IAM
```

If `HostedZoneId` is omitted, you'll create the DNS records manually in Step 8.

**Bedrock-model availability.** Model access is a manual, per-account
per-region console opt-in that neither CloudFormation nor IAM can grant. The
validator is therefore advisory: if the chosen model isn't enabled it records
a WARNING on the `BedrockModelValidation` resource and the stack still
completes. The policy engine is the only Bedrock consumer; enable model
access before turning it on. List what's available:
`aws bedrock list-foundation-models --region us-west-2 --query 'modelSummaries[?starts_with(modelId,\`anthropic.\`)].modelId'`.

**For sandbox / test installs**, also pass:
- `RdsDeletionProtection=false` — production default is true, but if the
  deploy fails CFN rollback can't delete a protected RDS, wedging the stack.
- `RdsInstanceClass=db.t3.micro RdsAllocatedStorageGb=20 EnableRdsPerformanceInsights=false RdsBackupRetentionDays=0`
  if the account is free-tier-restricted.

(`deploy/m3/cfn/cfn-deploy.sh` automates steps 1b-7 with those sandbox
parameters; `cfn-teardown.sh` is its inverse. See `deploy/m3/cfn/README.md`.)

## 3. Configure kubectl (~30s)

```bash
REGION=us-west-2
aws eks update-kubeconfig --name gentrail --region "$REGION"
kubectl get nodes
```

Expect 2 nodes `Ready`.

## 3a. Email vendor the cross-account scanner role + ExternalId (~30s)

Copy these two values and send them to `support@gentrail.ai`:

```bash
aws cloudformation describe-stacks --stack-name gentrail-substrate \
    --query 'Stacks[0].Outputs[?OutputKey==`GentrailReadOnlyRoleArn`].OutputValue' --output text
echo "ExternalId: $EXTERNAL_ID"
```

The vendor uses these to assume into your account from their scanner
suite. The role is read-only (`ReadOnlyAccess` + `SecurityAudit`,
nothing more); access is gated by your ExternalId.

## 4. Install AWS Load Balancer Controller (~2 min)

```bash
deploy/m3/scripts/install-alb-controller.sh gentrail-substrate
```

## 4b. Create a CSI StorageClass (~30s)

EKS 1.32 has no in-tree EBS provisioner, so the chart's PersistentVolumeClaims
need a CSI-backed StorageClass (the substrate installs the EBS CSI addon, but
not a class):

```bash
kubectl apply -f - <<'SC'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-csi
  annotations: { storageclass.kubernetes.io/is-default-class: "true" }
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters: { type: gp3 }
SC
```

Pass `--set storage.class=gp3-csi` in Step 7 (or rely on the default-class
annotation above).

## 5. Generate Helm values (~10s)

```bash
deploy/m3/scripts/cfn-to-values.sh gentrail-substrate > values.yaml
```

## 6. Create the license secret (~30s)

The chart mounts a `gentrail-license` Secret, so create it now. If you already
have your license file, install it here. Otherwise create it empty and paste the
license in the dashboard after install (Step 9): with no license present the
dashboard boots straight to a license-input page.

```bash
kubectl create namespace gentrail || true

# With your license file:
kubectl -n gentrail create secret generic gentrail-license --from-file=jwt=<your-license-file>

# ...or empty, to paste it in the dashboard later:
kubectl -n gentrail create secret generic gentrail-license --from-literal=jwt=
```

## 7. Install the Helm chart (~2 min)

```bash
helm install gentrail deploy/m3/helm/gentrail \
    --namespace gentrail --create-namespace \
    -f values.yaml
kubectl -n gentrail rollout status deployment/dashboard --timeout=180s
```

## 8. Wait for the ALBs and create the Route 53 alias records (~3 min)

The chart creates two Ingresses, each with its own ALB: `dashboard` (the web
UI, at `Hostname`) and `authproxy` (OTLP ingestion, at `OtelHostname`). Create
an alias record for each:

```bash
HOSTED_ZONE_ID=Z0123456789ABCDEFGHIJ

for PAIR in "dashboard:Hostname" "authproxy:OtelHostname"; do
    INGRESS="${PAIR%%:*}"; OUTPUT="${PAIR##*:}"
    ALB_DNS=$(kubectl -n gentrail get ingress "$INGRESS" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    NAME=$(aws cloudformation describe-stacks --stack-name gentrail-substrate \
        --query "Stacks[0].Outputs[?OutputKey=='${OUTPUT}'].OutputValue" --output text)
    ALB_HOSTED_ZONE_ID=$(aws elbv2 describe-load-balancers \
        --query "LoadBalancers[?DNSName=='${ALB_DNS}'].CanonicalHostedZoneId" --output text)
    aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch "{
        \"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"${NAME}\",\"Type\":\"A\",
        \"AliasTarget\":{\"HostedZoneId\":\"${ALB_HOSTED_ZONE_ID}\",\"DNSName\":\"${ALB_DNS}\",\"EvaluateTargetHealth\":false}}}]}"
done
```

If you opted out of Route 53 delegation, create the equivalent A/CNAME records
in your DNS provider pointing each hostname at its ALB DNS.

Point your agent SDK's `OTEL_EXPORTER_OTLP_ENDPOINT` env var at
`https://<OtelHostname>` (the SDK appends `/v1/traces`). Step 10 walks through
sending your first trace. To watch evaluation as traces arrive:
`kubectl -n gentrail logs deploy/evaluator -f`.

## 9. Open the dashboard

Visit `https://gentrail.acme.com`. A BYOC install is single-tenant with no
login: the cluster network is your access boundary. If you created the license
secret empty in Step 6, every page redirects to the license input - paste the
license you got in "Before you begin" and it takes effect across all services
within about two minutes. If you installed the license in Step 6, you land
straight on the dashboard.

## 10. Send your first trace (SDK quickstart, ~5 min)

This proves the ingest path end to end: generate a key, run a tiny agent, watch
it appear.

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
       model_id="anthropic.claude-3-5-sonnet-20241022-v2:0",
       prompt="What is the capital of France?",
       response_text="Paris.",
       input_tokens=8,
       output_tokens=2,
       total_tokens=10,
   )
   tracer.force_flush()  # flush before the process exits
   print("sent one invocation")
   ```

   Then run it:

   ```bash
   export AIGENTRAIL_API_KEY=<the-key-from-step-1>
   export OTEL_EXPORTER_OTLP_ENDPOINT=https://<OtelHostname>
   python3 first_agent.py
   ```

4. **See it land.** Watch ingestion and evaluation:

   ```bash
   kubectl -n gentrail logs deploy/authproxy -f   # accepts the trace
   kubectl -n gentrail logs deploy/evaluator -f   # evaluates it
   ```

   Then open the dashboard. `hello-agent` shows up under Agents within a few
   seconds, with the invocation and model call under its trace viewer. That is
   one of your 10 free-tier agents (see Section 12).

If the agent doesn't appear: confirm the API key is active, that
`OTEL_EXPORTER_OTLP_ENDPOINT` resolves to your authproxy ALB, and (for a private
CA or self-signed cert) set `OTEL_EXPORTER_OTLP_CERTIFICATE=/path/to/ca.pem`.

## 11. License lifecycle

Your license is a single Ed25519-signed JWT delivered by email from the Gentrail vendor. Behavior:

- **Pre-expiry:** services start cleanly and log `license: valid for customer=… expires_in=N days`.
- **Within 30 days of expiry:** the dashboard shows a renewal banner and every restart logs `WARN license: expires in N days for customer=… tier=…`. The exact `N` lets your log aggregator escalate however you want (e.g. page on `N <= 7`).
- **After expiry (30-day grace):** everything keeps working at full function. The dashboard banner counts down the grace window. **Your traces, evaluations, violations, and dashboard reads keep working.**
- **After grace:** the install degrades to free-tier limits: compliance/audit routes show the upgrade wall and new agents beyond the free cap stop being captured. Existing agents keep flowing and nothing is deleted, so a late renewal restores full function with no gap.
- **Renewal:** email `support@gentrail.ai` ahead of expiry. The vendor mints a new JWT and emails it. An org admin can paste it on the dashboard's License page (`/?view=license`): it verifies locally, patches the license Secret through a single-secret RBAC grant, and takes effect everywhere within about two minutes. Updating the Kubernetes Secret by hand works identically:

```bash
kubectl -n gentrail create secret generic gentrail-license \
    --from-file=jwt=<new-jwt-file> \
    --dry-run=client -o yaml | kubectl apply -f -
```

Every service reads the JWT from that one Secret as a mounted file and
re-verifies it on change, so the new license takes effect on all pods within
about two minutes (kubelet secret sync plus the services' poll) with no
restarts. Each service logs `license: reloaded for customer=…` when it picks
the new license up. A malformed replacement is rejected and logged while the
previous license stays active.

**Hard-stop conditions** (service exits 1 at startup):
- Missing `LICENSE_JWT` env var
- Unparseable JWT
- Bad signature (forgery or wrong vendor public key)
- `nbf` in future (operationally indistinguishable from forgery or clock-tampered host — check NTP if you see this unexpectedly)

There is no online revocation. Licenses simply expire on their stated `exp`.

---

## 12. BYOC free tier

The BYOC free tier is a capped, time-boxed evaluation license. It gives you full observability (trace ingestion, agent visibility, policy/violation detection) and the dashboard for 60 days with up to 10 registered agents. The compliance and audit suite (reports, evidence exports, continuous audit controls) is **Unlimited tier only**.

### Getting a free license

Get one at https://gentrail.ai/license: a short form returns a free BYOC
evaluation license (10 agents, 60 days), shown on the page and emailed to you.
No sales call, no waiting. The license is what unlocks the public images you
install in this runbook.

### Agent cap (10 agents)

Once 10 agents have been registered, traces for **new** agents are dropped at the ingest front door: the lambda-authproxy skips persisting an unrecognised agent's traces beyond the cap and logs a one-line suppression notice. (The ingest request itself still returns success; there is no per-request error code, so the SDK is not interrupted.) Agents already captured continue flowing at full depth with no interruption. A persistent banner in the dashboard warns the operator that the install is at the agent cap.

### 60-day expiry → read-only

At the license `exp` the install transitions to **read-only**:

- Dashboard reads (trace replay, violation list, policy configuration) continue to work.
- Ingestion returns **402 Payment Required** for new writes.
- The evaluator skips scheduling new evaluation runs.
- The dashboard blocks any mutating request (policy saves, user management, etc.).

**No data is deleted.** All captured traces, evaluations, and violations are preserved.

Pre-expiry warnings fire in service logs and a dashboard countdown banner at **30 / 14 / 7 / 1 days** remaining.

Expiry enforcement is evaluated per request against the license `exp`, so the read-only gate engages at the expiry instant on running pods; no restart is involved.

### Upgrading free → Unlimited (in-place)

The upgrade is non-destructive. All captured data is preserved and the install rehydrates to full functionality on restart; no re-ingestion or re-seeding required.

All four services watch the same `gentrail-license` Secret as a mounted file, so the upgrade is one secret update with no restarts and no downtime:

```bash
kubectl -n gentrail create secret generic gentrail-license \
    --from-file=jwt=<name>-unlimited.jwt \
    --dry-run=client -o yaml | kubectl apply -f -
```

**Within about two minutes:** the 10-agent cap lifts, the compliance/audit navigation unlocks in the dashboard, and any read-only or cap banners clear. Each service logs `license: reloaded` as it picks the new license up.

---

## Hardening checklist (first 24 hours)

1. **Narrow `AllowedIngressCidr`** to your corporate CIDR via stack update.
2. **Restrict dashboard access** to your VPN or corporate CIDR. A BYOC install has no login (it is single-tenant), so the network is the access boundary - do not expose the dashboard ALB to the public internet.
3. **Confirm CloudTrail is on** (logs every Gentrail-substrate API call).
4. **Forward CloudWatch logs to your SIEM** using your existing pipeline.

## Uninstall (crypto-shred deletion)

```bash
deploy/m3/scripts/uninstall.sh gentrail-substrate
```

Follow the prompts. Phase 5 (KMS-key deletion) is the irreversible step that makes all SSE-KMS-encrypted backups permanently unreadable.

## Recovering from a failed install

By design, S3 buckets, DynamoDB tables, KMS keys, and RDS snapshots
have `DeletionPolicy: Retain` or `Snapshot` — so a failed CFN create
leaves them behind. The next `aws cloudformation deploy` attempt then
fails early validation because those resources already exist. To
recover:

```bash
# 1) Delete the failed stack
aws cloudformation delete-stack --stack-name gentrail-substrate
aws cloudformation wait stack-delete-complete --stack-name gentrail-substrate

# 2) If RDS deletion-protection is on AND the stack stuck in ROLLBACK_FAILED,
#    disable protection and delete RDS manually first, then retry the stack delete.
aws rds modify-db-instance --db-instance-identifier gentrail-rds \
    --no-deletion-protection --apply-immediately
aws rds delete-db-instance --db-instance-identifier gentrail-rds --skip-final-snapshot
aws rds wait db-instance-deleted --db-instance-identifier gentrail-rds

# 3) Empty the retained DDB tables
for t in gentrail-traces gentrail-violations gentrail-agent-stats gentrail-policy-rules gentrail-api-keys; do
    aws dynamodb describe-table --table-name "$t" >/dev/null 2>&1 && \
        aws dynamodb delete-table --table-name "$t"
done

# 4) Empty the retained S3 buckets. Evidence bucket has Object Lock —
#    list-object-versions + delete-object --bypass-governance-retention.
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=us-west-2
for B in "gentrail-alb-logs-${ACCOUNT}-${REGION}" \
         "gentrail-evidence-${ACCOUNT}-${REGION}" \
         "gentrail-vpc-flow-logs-${ACCOUNT}-${REGION}"; do
    aws s3 ls "s3://$B" >/dev/null 2>&1 || continue
    aws s3api list-object-versions --bucket "$B" --output json | \
        jq -c '.Versions[]?, .DeleteMarkers[]? | {Key, VersionId}' | \
        while read -r o; do
            K=$(echo "$o" | jq -r .Key); V=$(echo "$o" | jq -r .VersionId)
            aws s3api delete-object --bucket "$B" --key "$K" --version-id "$V" --bypass-governance-retention
        done
    aws s3api delete-bucket --bucket "$B"
done

# 5) Retry the deploy
```

## IRSA expansion checklist (vendor engineers only)

When a service binary needs a new AWS API permission:

1. Add the action+resource to the matching `IrsaRole` in `deploy/m3/cfn/m3-byoc-substrate.yaml`.
2. Deploy the stack update.
3. Restart the affected Pods: `kubectl -n gentrail rollout restart deployment/<name>`.

Never relax the IRSA boundary in the Helm chart — keep the boundary at the IAM policy level.
