$EC2_IP = "54.255.167.12"
$KEY = "$env:USERPROFILE\.ssh\conduit-demo.pem"
$ECR_REGISTRY = "972766771187.dkr.ecr.ap-southeast-1.amazonaws.com"
$REGION = "ap-southeast-1"
$SSH = "ssh -i `"$KEY`" -o StrictHostKeyChecking=no ec2-user@$EC2_IP"

Write-Host "Step 1: Copying manifests to EC2..." -ForegroundColor Cyan
scp -i "$KEY" -o StrictHostKeyChecking=no -r ./k8s ec2-user@${EC2_IP}:~/k8s

Write-Host "`nStep 2: Creating ECR pull secret on k3s..." -ForegroundColor Cyan
$ECR_PASSWORD = aws ecr get-login-password --region $REGION
Invoke-Expression "$SSH `"sudo kubectl create secret docker-registry ecr-secret --docker-server=$ECR_REGISTRY --docker-username=AWS --docker-password='$ECR_PASSWORD' --dry-run=client -o yaml | sudo kubectl apply -f -`""

Write-Host "`nStep 3: Applying manifests..." -ForegroundColor Cyan
Invoke-Expression "$SSH `"sudo kubectl apply -f ~/k8s/`""

Write-Host "`nStep 4: Waiting for pods to start (60s)..." -ForegroundColor Cyan
Start-Sleep -Seconds 60
Invoke-Expression "$SSH `"sudo kubectl get pods`""

Write-Host "`nDone! App should be available at http://$EC2_IP" -ForegroundColor Green
