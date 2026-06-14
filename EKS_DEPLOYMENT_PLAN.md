# Conduit → AWS EKS Deployment Plan

## What You Have

- **Backend**: Django REST Framework, Python 3.10, port 8000 (has Dockerfile)
- **Frontend**: React + Redux, port 80 after build (needs Dockerfile)
- **Database**: PostgreSQL

---

## Big-Project Stack

| Layer | Tool | Why big projects use it |
|---|---|---|
| Infra as Code | **Terraform** | Reproducible, version-controlled AWS resources |
| Container Registry | **AWS ECR** | Native AWS, IAM-integrated |
| K8s Cluster | **AWS EKS** | Managed control plane, IRSA, Fargate option |
| Database | **AWS RDS PostgreSQL** | Managed, automated backups, Multi-AZ |
| Ingress | **AWS ALB Ingress Controller** | Native AWS ALB + TLS via ACM |
| TLS Cert | **AWS ACM** | Free, auto-renewing SSL |
| Secrets | **AWS Secrets Manager + External Secrets Operator** | No secrets in git, auto-rotation |
| CI/CD | **GitHub Actions** | Build → push ECR → deploy on merge |
| K8s Packaging | **Helm** | Templated manifests, environment overrides |
| Auto-scaling | **HPA (Horizontal Pod Autoscaler)** | Scale pods on CPU/memory |
| Monitoring | **CloudWatch Container Insights** | Logs + metrics in AWS native |

---

## Phase 1 — Prerequisites (Day 1)

```
AWS account with admin access
AWS CLI configured  (aws configure)
kubectl installed
eksctl installed
Helm 3 installed
Terraform installed
GitHub repo with the project
```

> **AWS cost estimate**: ~$150–250/month for a dev cluster (EKS + 2 nodes + RDS t3.micro)

---

## Phase 2 — Fix Code for Production (Day 1)

### 2a. Backend `settings.py` — read from env vars

Replace all hardcoded values:

```python
import os

SECRET_KEY = os.environ['DJANGO_SECRET_KEY']
DEBUG = os.getenv('DEBUG', 'False') == 'True'
ALLOWED_HOSTS = os.environ.get('ALLOWED_HOSTS', '').split(',')

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME':     os.environ['DB_NAME'],
        'USER':     os.environ['DB_USER'],
        'PASSWORD': os.environ['DB_PASSWORD'],
        'HOST':     os.environ['DB_HOST'],
        'PORT':     os.environ.get('DB_PORT', '5432'),
    }
}
```

### 2b. Fix Backend Dockerfile — use Gunicorn, not dev server

```dockerfile
FROM python:3.10-slim-buster
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt gunicorn
COPY . .
RUN python manage.py collectstatic --noinput
EXPOSE 8000
CMD ["gunicorn", "config.wsgi:application", "--bind", "0.0.0.0:8000", "--workers", "2"]
```

### 2c. Create Frontend Dockerfile (does not exist yet)

```dockerfile
# Build stage
FROM node:18-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
ARG REACT_APP_BACKEND_URL
ENV REACT_APP_BACKEND_URL=$REACT_APP_BACKEND_URL
RUN npm run build

# Serve stage
FROM nginx:alpine
COPY --from=build /app/build /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
```

### 2d. Frontend `nginx.conf` — handle React Router

```nginx
server {
    listen 80;
    location / {
        root /usr/share/nginx/html;
        try_files $uri /index.html;
    }
}
```

---

## Phase 3 — Terraform: Infrastructure as Code (Day 2)

### Directory layout

```
infra/
├── main.tf          # VPC, EKS, RDS, ECR, IAM
├── variables.tf
├── outputs.tf
└── terraform.tfvars
```

### What Terraform creates

1. **VPC** — 3 public + 3 private subnets across 3 AZs
2. **EKS Cluster** — 2 nodes, `t3.medium`, private node group
3. **RDS PostgreSQL** — `t3.micro`, in private subnet, automated backups
4. **ECR repositories** — `conduit/backend`, `conduit/frontend`
5. **IAM roles** — IRSA for pods, ECR push role for GitHub Actions

### Apply

```bash
cd infra
terraform init
terraform plan
terraform apply   # takes ~15 minutes
```

### Update kubeconfig after cluster is ready

```bash
aws eks update-kubeconfig --region <region> --name conduit
```

---

## Phase 4 — Secrets Management (Day 2)

### Store secrets in AWS Secrets Manager

```bash
aws secretsmanager create-secret --name conduit/prod \
  --secret-string '{
    "DJANGO_SECRET_KEY": "your-random-secret-key",
    "DB_PASSWORD": "your-db-password",
    "DB_USER": "conduit",
    "DB_NAME": "conduit",
    "DB_HOST": "<rds-endpoint-from-terraform-output>"
  }'
```

### Install External Secrets Operator in EKS

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace
```

### ExternalSecret manifest (syncs AWS SM → k8s Secret automatically)

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: conduit-backend-secret
  namespace: conduit
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secretsmanager
    kind: ClusterSecretStore
  target:
    name: conduit-backend-secret
  dataFrom:
    - extract:
        key: conduit/prod
```

---

## Phase 5 — Helm Charts (Day 3)

### Directory layout

```
helm/
├── backend/
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── hpa.yaml
│       └── externalsecret.yaml
└── frontend/
    ├── Chart.yaml
    ├── values.yaml
    └── templates/
        ├── deployment.yaml
        ├── service.yaml
        └── ingress.yaml
```

### Backend Deployment (key sections)

```yaml
# helm/backend/templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: conduit-backend
  namespace: conduit
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: conduit-backend
  template:
    spec:
      initContainers:
        - name: migrate
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          command: ["python", "manage.py", "migrate"]
          envFrom:
            - secretRef:
                name: conduit-backend-secret
      containers:
        - name: backend
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          ports:
            - containerPort: 8000
          envFrom:
            - secretRef:
                name: conduit-backend-secret
          readinessProbe:
            httpGet:
              path: /api/health/
              port: 8000
          resources:
            requests:
              cpu: 256m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
```

### Frontend Deployment (key sections)

```yaml
# helm/frontend/templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: conduit-frontend
  namespace: conduit
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: conduit-frontend
  template:
    spec:
      containers:
        - name: frontend
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi
```

### ALB Ingress

```yaml
# helm/frontend/templates/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: conduit-ingress
  namespace: conduit
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/certificate-arn: <acm-cert-arn>
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
spec:
  rules:
    - host: api.yourdomain.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: conduit-backend
                port:
                  number: 8000
    - host: app.yourdomain.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: conduit-frontend
                port:
                  number: 80
```

### HPA

```yaml
# helm/backend/templates/hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: conduit-backend-hpa
  namespace: conduit
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: conduit-backend
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

---

## Phase 6 — CI/CD: GitHub Actions (Day 3)

### `.github/workflows/deploy.yml`

```yaml
name: Build and Deploy

on:
  push:
    branches: [main]

env:
  AWS_REGION: ap-southeast-1
  ECR_REGISTRY: <account-id>.dkr.ecr.ap-southeast-1.amazonaws.com

permissions:
  id-token: write   # GitHub OIDC — no long-lived AWS keys needed
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::<account-id>:role/github-actions-conduit
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to ECR
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build and push backend
        run: |
          IMAGE=$ECR_REGISTRY/conduit/backend:${{ github.sha }}
          docker build -t $IMAGE ./backend/realWorld-DjangoRestFramework
          docker push $IMAGE

      - name: Build and push frontend
        run: |
          IMAGE=$ECR_REGISTRY/conduit/frontend:${{ github.sha }}
          docker build \
            --build-arg REACT_APP_BACKEND_URL=https://api.yourdomain.com \
            -t $IMAGE ./frontend/react-redux-realworld-example-app
          docker push $IMAGE

      - name: Update kubeconfig
        run: aws eks update-kubeconfig --region $AWS_REGION --name conduit

      - name: Deploy backend via Helm
        run: |
          helm upgrade --install conduit-backend ./helm/backend \
            --namespace conduit --create-namespace \
            --set image.tag=${{ github.sha }} \
            --set image.repository=$ECR_REGISTRY/conduit/backend \
            --atomic --timeout 5m

      - name: Deploy frontend via Helm
        run: |
          helm upgrade --install conduit-frontend ./helm/frontend \
            --namespace conduit \
            --set image.tag=${{ github.sha }} \
            --set image.repository=$ECR_REGISTRY/conduit/frontend \
            --atomic --timeout 5m

      - name: Verify rollout
        run: |
          kubectl rollout status deployment/conduit-backend -n conduit
          kubectl rollout status deployment/conduit-frontend -n conduit
```

---

## Phase 7 — Monitoring (Day 4)

### Enable CloudWatch Container Insights

```bash
aws eks update-addon \
  --cluster-name conduit \
  --addon-name amazon-cloudwatch-observability \
  --region ap-southeast-1
```

This gives you:
- Container logs in CloudWatch Logs (grouped by namespace/pod)
- CPU, memory, network metrics per pod/node
- Alerts via CloudWatch Alarms → SNS → email/Slack

---

## Full Deployment Sequence

```
Day 1   Fix settings.py + Dockerfiles       → test locally with docker-compose
Day 2   terraform apply                      → VPC + EKS + RDS + ECR provisioned
Day 2   Push secrets to AWS Secrets Manager → install External Secrets Operator
Day 3   Write Helm charts                   → helm install (first manual deploy)
Day 3   GitHub Actions workflow             → automated on every push to main
Day 4   Enable CloudWatch Container Insights → monitoring live
Day 4   Point domain DNS to ALB             → TLS live via ACM
```

---

## Final Repository Structure

```
conduit/
├── backend/
│   └── realWorld-DjangoRestFramework/
│       ├── Dockerfile              ← updated (gunicorn, no dev server)
│       └── config/settings.py     ← updated (env vars, no hardcoded values)
├── frontend/
│   └── react-redux-realworld-example-app/
│       ├── Dockerfile              ← new (multi-stage: node build + nginx)
│       └── nginx.conf              ← new (React Router support)
├── helm/
│   ├── backend/                    ← Helm chart for Django
│   └── frontend/                   ← Helm chart for React + ALB Ingress
├── infra/                          ← Terraform (VPC, EKS, RDS, ECR, IAM)
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars
└── .github/
    └── workflows/
        └── deploy.yml              ← GitHub Actions CI/CD pipeline
```

---

## Things to Do Before Starting

- [ ] Register a domain (Route 53 or external, point to AWS)
- [ ] Request ACM certificate for `yourdomain.com` and `*.yourdomain.com`
- [ ] Create GitHub OIDC IAM role in AWS for Actions (no stored AWS keys)
- [ ] Generate a strong `DJANGO_SECRET_KEY` (`python -c "import secrets; print(secrets.token_urlsafe(50))"`)
