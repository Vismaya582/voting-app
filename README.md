# Voting App on AWS EKS

## Overview

Deployment of the [Docker Example Voting App](https://github.com/dockersamples/example-voting-app) on AWS EKS using a GitOps approach — GitHub Actions for CI and ArgoCD for CD — with Helm charts, AWS Load Balancer Controller, and Prometheus/Grafana monitoring.

---

## Architecture

### Application Services

| Service | Language | Role |
|---|---|---|
| vote | Python / Flask | Voting UI — writes to Redis |
| redis | Redis | In-memory queue |
| worker | .NET | Reads from Redis, writes to Postgres |
| db | Postgres | Persistent vote storage |
| result | Node.js / Socket.io | Results UI — reads from Postgres |

### Data Flow
```
Browser → Vote app → Redis → Worker → Postgres → Result app → Browser
```

---

## Repositories

### `Vismaya582/voting-app`
- Application source code (`vote/`, `result/`, `worker/`)
- Terraform for EKS infrastructure
- GitHub Actions CI pipeline

### `Vismaya582/voting-k8s`
- Helm chart for all 5 services
- ArgoCD Application manifest

---

## Infrastructure (Terraform)

**Region:** `ap-south-1`

**VPC:**
- CIDR: `10.0.0.0/16`
- 2 public subnets (`ap-south-1a`, `ap-south-1b`) — for ALB
- 2 private subnets (`ap-south-1a`, `ap-south-1b`) — for EKS nodes
- Internet Gateway for public subnets
- NAT Gateway for private subnet outbound traffic

**EKS Cluster:**
- Node type: `m7i-flex.large`
- Desired nodes: 2, Min: 1, Max: 3
- Nodes placed in private subnets

**IAM Roles:**

| Role | Purpose | Policies |
|---|---|---|
| `eks-cluster-role` | EKS control plane manages AWS resources | `AmazonEKSClusterPolicy` |
| `eks-node-group-role` | EC2 nodes join cluster, pull images | `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly` |
| `voting-app-github-actions-role` | GitHub Actions pushes to ECR via OIDC | `AmazonEC2ContainerRegistryPowerUser` |
| `AmazonEKSLoadBalancerControllerRole` | ALB controller pod manages AWS load balancers via IRSA | `AWSLoadBalancerControllerIAMPolicy` |

**State Backend:**
- S3 bucket: `voting-app-terraform-state`
- DynamoDB table: `voting-app-lock-table`

---

## CI/CD Pipeline

### CI — GitHub Actions
Triggers on push to `main` branch of `voting-app` repo:
1. Checkout code
2. Assume AWS IAM role via OIDC (no stored credentials)
3. Login to ECR
4. Build and push `voting-vote`, `voting-result`, `voting-worker` images to ECR with commit SHA as tag
5. Update image tags in `voting-k8s/charts/voting-app/values.yaml`

### CD — ArgoCD
- Watches `voting-k8s` repo continuously
- Detects new commit (image tag update)
- Re-renders Helm chart with new values
- Applies changes to EKS cluster (rolling update)
- `selfHeal: true` — reverts any manual cluster changes back to Git state

### GitOps Pattern
```
Code push → GitHub Actions (CI) → ECR + values.yaml update
                                        ↓
                               ArgoCD detects commit
                                        ↓
                               Syncs to EKS cluster
```

---

## Helm Chart Structure

```
voting-k8s/
├── charts/
│   └── voting-app/
│       ├── Chart.yaml
│       ├── values.yaml          ← image tags updated by CI
│       └── templates/
│           ├── vote-deployment.yaml
│           ├── vote-service.yaml
│           ├── result-deployment.yaml
│           ├── result-service.yaml
│           ├── worker-deployment.yaml
│           ├── redis-deployment.yaml
│           ├── redis-service.yaml
│           ├── db-deployment.yaml
│           ├── db-service.yaml
│           └── ingress.yaml
└── argocd/
    └── application.yaml
```

**Services:**
- `vote` and `result` — `ClusterIP`, exposed via ALB Ingress
- `redis` and `db` — `ClusterIP`, internal only
- `worker` — no service (outbound only)

---

## Networking

### AWS Load Balancer Controller
- Installed via Helm in `kube-system` namespace
- Uses IRSA (IAM Roles for Service Accounts) via EKS OIDC provider
- Creates ALBs for ingress resources automatically
- Target type: `ip` — routes directly to pod IPs

### Ingress
Two separate ALB ingresses in the `vote` namespace:
- `vote-ingress` → vote service (port 8080) → pod port 80
- `result-ingress` → result service (port 8081) → pod port 80

---

## OIDC Authentication

### GitHub Actions → AWS (Account level)
```
GitHub Actions → OIDC token → AWS verifies against token.actions.githubusercontent.com → assumes IAM role → ECR push
```

### ALB Controller Pod → AWS (IRSA — cluster level)
```
ALB controller pod → Kubernetes service account → EKS OIDC provider → assumes IAM role → creates ALBs
```

---

## Monitoring

**Stack:** `kube-prometheus-stack` installed via Helm in `monitoring` namespace

**Components:**
- Prometheus — scrapes metrics from all pods every 15s via `/metrics` endpoint
- Grafana — pre-built dashboards for cluster, node, and pod metrics
- Alertmanager — alert routing
- node-exporter — node level metrics
- kube-state-metrics — Kubernetes object metrics

**Access Grafana:**
```bash
kubectl --namespace monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# open http://localhost:3000
```

---

## Quick Reinstall Guide

After `terraform apply` on a fresh cluster:

```bash
# 1. Update kubeconfig
aws eks update-kubeconfig --region ap-south-1 --name voter-app-eks-cluster

# 2. Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 3. Deploy app via ArgoCD
kubectl create namespace vote
kubectl apply -f ~/voting-k8s/argocd/application.yaml

# 4. Associate OIDC provider
eksctl utils associate-iam-oidc-provider --region=ap-south-1 --cluster=voter-app-eks-cluster --approve

# 5. Create ALB controller service account
eksctl create iamserviceaccount \
  --cluster=voter-app-eks-cluster \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve --region ap-south-1

# 6. Install ALB controller
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=voter-app-eks-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=ap-south-1 \
  --set vpcId=$(aws eks describe-cluster --name voter-app-eks-cluster --region ap-south-1 --query "cluster.resourcesVpcConfig.vpcId" --output text)

# 7. Install monitoring
kubectl create namespace monitoring
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring

# 8. Trigger CI — push any change to voting-app repo
```

---

## Cleanup

```bash
# Delete K8s resources first
kubectl delete ingress --all -n vote
kubectl delete namespace vote
kubectl delete namespace argocd
kubectl delete namespace monitoring

# Destroy infrastructure
cd ~/project-2/terraform
terraform destroy

# Delete ECR images
aws ecr batch-delete-image --repository-name voting-vote --region ap-south-1 --image-ids imageTag=<tag>
aws ecr batch-delete-image --repository-name voting-result --region ap-south-1 --image-ids imageTag=<tag>
aws ecr batch-delete-image --repository-name voting-worker --region ap-south-1 --image-ids imageTag=<tag>
```
