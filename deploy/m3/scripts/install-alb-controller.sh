#!/usr/bin/env bash
# Install the AWS Load Balancer Controller into an EKS cluster.
#
# Reads CFN stack outputs to discover the cluster + region + IRSA role.
# Pins ALB Controller v2.8.2; bump explicitly when validating a new release.
#
# Usage:
#   ./install-alb-controller.sh <substrate-stack-name>
set -euo pipefail

STACK_NAME="${1:?usage: $0 <substrate-stack-name>}"
ALB_CONTROLLER_VERSION="${ALB_CONTROLLER_VERSION:-v2.8.2}"
ALB_CHART_VERSION="${ALB_CHART_VERSION:-1.8.2}"  # eks-charts version matching v2.8.2

REGION="${AWS_REGION:-$(aws configure get region)}"

echo "==> reading CFN outputs from ${STACK_NAME}"
get_output () {
    aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
CLUSTER_NAME=$(get_output ClusterName)
ROLE_ARN=$(get_output AlbControllerIrsaRoleArn)
VPC_ID=$(get_output VpcId)

if [ -z "$CLUSTER_NAME" ] || [ -z "$ROLE_ARN" ]; then
    echo "missing required outputs from ${STACK_NAME}" >&2
    exit 1
fi

echo "==> downloading ALB controller IAM policy ${ALB_CONTROLLER_VERSION}"
POLICY_JSON=$(curl -fsSL \
    "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${ALB_CONTROLLER_VERSION}/docs/install/iam_policy.json")
ROLE_NAME=$(basename "$ROLE_ARN")
aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name AwsLoadBalancerControllerPolicy \
    --policy-document "$POLICY_JSON"

echo "==> kubeconfig"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

echo "==> kube-system service-account for ALB controller"
kubectl apply -f - <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aws-load-balancer-controller
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: ${ROLE_ARN}
YAML

echo "==> installing ALB controller chart ${ALB_CHART_VERSION}"
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --namespace kube-system \
    --version "$ALB_CHART_VERSION" \
    --set clusterName="$CLUSTER_NAME" \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set vpcId="$VPC_ID" \
    --set region="$REGION" \
    --wait

echo "==> verifying deployment"
kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=120s
kubectl -n kube-system get deployment/aws-load-balancer-controller \
    -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

echo "==> done"
