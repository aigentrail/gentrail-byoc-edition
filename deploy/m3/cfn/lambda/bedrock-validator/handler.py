"""CFN CustomResource: advisory check that a Bedrock model is enabled in this
region. Always sends SUCCESS (with a WARNING reason if not), so a model-access
gap never blocks substrate provisioning. Idempotent (re-runs on update).

Kept in sync with the inline ZipFile in m3-byoc-substrate.yaml; that inline copy
is what actually runs, this file is for future cfn-package builds."""

import json
import urllib.request

import boto3


def _respond(event, context, status, reason):
    body = {
        "Status": status,
        "Reason": reason,
        "PhysicalResourceId": event.get("PhysicalResourceId") or context.log_stream_name,
        "StackId": event["StackId"],
        "RequestId": event["RequestId"],
        "LogicalResourceId": event["LogicalResourceId"],
        "Data": {},
    }
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        event["ResponseURL"],
        data=data,
        method="PUT",
        headers={"Content-Type": "", "Content-Length": str(len(data))},
    )
    urllib.request.urlopen(req).read()


def handler(event, context):
    # Always SUCCESS on Delete — nothing to clean up.
    if event["RequestType"] == "Delete":
        _respond(event, context, "SUCCESS", "delete-noop")
        return

    model_id = event["ResourceProperties"]["BedrockModelId"]
    region = event["ResourceProperties"]["Region"]
    # A region prefix (us./eu./apac.) marks a cross-region inference profile,
    # which lives in a different API than foundation models.
    is_profile = model_id.split(".", 1)[0] in ("us", "eu", "apac")

    try:
        client = boto3.client("bedrock", region_name=region)
        if is_profile:
            summaries = client.list_inference_profiles()["inferenceProfileSummaries"]
            available_ids = {p["inferenceProfileId"] for p in summaries}
        else:
            models = client.list_foundation_models()["modelSummaries"]
            available_ids = {m["modelId"] for m in models}
    except Exception as exc:
        _respond(event, context, "SUCCESS",
                 f"WARNING: could not verify Bedrock access in {region} ({exc}); "
                 f"enable model access before using the policy engine.")
        return

    if model_id not in available_ids:
        kind = "inference profile" if is_profile else "model"
        _respond(event, context, "SUCCESS",
                 f"WARNING: Bedrock {kind} {model_id!r} not available in {region}; "
                 f"enable model access before using the policy engine. "
                 f"Available: {sorted(available_ids)[:5]}...")
        return

    _respond(event, context, "SUCCESS",
             f"model {model_id} available in {region}")
