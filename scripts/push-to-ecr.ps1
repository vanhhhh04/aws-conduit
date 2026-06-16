$ECR_REGISTRY = "972766771187.dkr.ecr.ap-southeast-1.amazonaws.com"
$REGION = "ap-southeast-1"
$EC2_IP = "54.255.167.12"

Write-Host "Step 1: Authenticating Docker to ECR..." -ForegroundColor Cyan
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_REGISTRY
if (-not $?) { Write-Host "ECR login failed" -ForegroundColor Red; exit 1 }

Write-Host "`nStep 2: Building backend..." -ForegroundColor Cyan
docker build -t conduit/backend ./backend/realWorld-DjangoRestFramework
if (-not $?) { Write-Host "Backend build failed" -ForegroundColor Red; exit 1 }

docker tag conduit/backend "$ECR_REGISTRY/conduit/backend:latest"
docker push "$ECR_REGISTRY/conduit/backend:latest"
if (-not $?) { Write-Host "Backend push failed" -ForegroundColor Red; exit 1 }

Write-Host "`nStep 3: Building frontend..." -ForegroundColor Cyan
docker build -t conduit/frontend --build-arg REACT_APP_BACKEND_URL="http://$EC2_IP/api" ./frontend/react-redux-realworld-example-app
if (-not $?) { Write-Host "Frontend build failed" -ForegroundColor Red; exit 1 }

docker tag conduit/frontend "$ECR_REGISTRY/conduit/frontend:latest"
docker push "$ECR_REGISTRY/conduit/frontend:latest"
if (-not $?) { Write-Host "Frontend push failed" -ForegroundColor Red; exit 1 }

Write-Host "`nDone! Both images pushed to ECR." -ForegroundColor Green
