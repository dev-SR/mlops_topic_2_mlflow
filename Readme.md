# MLflow For Experiment Tracking


## Mlflow Setup with postgres, minio (kubeflow)



### ⚙️ SInstall Kubeflow Pipelines (Standalone)


```bash
# https://www.kubeflow.org/docs/components/pipelines/operator-guides/installation/

export PIPELINE_VERSION=2.15.0
kubectl apply -k "github.com/kubeflow/pipelines/manifests/kustomize/cluster-scoped-resources?ref=$PIPELINE_VERSION"
kubectl wait --for condition=established --timeout=60s crd/applications.app.k8s.io
kubectl apply -k "github.com/kubeflow/pipelines/manifests/kustomize/env/dev?ref=$PIPELINE_VERSION" 
```
Once the pods are running, you can access the KFP UI by port-forwarding:

```bash
kubectl port-forward -n kubeflow svc/ml-pipeline-ui 8080:80
```
Then open your browser to `http://localhost:8080`.

### Step : Install MinIO

Kubeflow uses MinIO as its default object storage. You can leverage this same instance for MLflow, or install a separate one. The simplest approach is to use the one that comes with Kubeflow.

To use the existing MinIO instance, you need its service address and credentials. You can find them with:

```bash
# Get the service address (it will be something like minio-service.kubeflow.svc.cluster.local)
kubectl get svc -n kubeflow | grep minio
# > minio-service                     ClusterIP   10.101.75.222    <none>        9000/TCP
# So url will be http://minio-service.kubeflow.svc.cluster.local:9000
# Get the credentials (these are stored in a Kubernetes secret)
kubectl get secret -n kubeflow mlpipeline-minio-artifact -o jsonpath="{.data.accesskey}" | base64 --decode
# > minio
kubectl get secret -n kubeflow mlpipeline-minio-artifact -o jsonpath="{.data.secretkey}" | base64 --decode
# > minio123
```

For the purpose of this guide, let's assume the service is minio-service.kubeflow.svc.cluster.local:9000, and the credentials are minio/minio123. (You should verify this in your actual cluster).


### Step 5: Deploy MLflow

Now, deploy the MLflow Tracking Server, configuring it to use MinIO for artifact storage and a PostgreSQL database for metadata.

1. Deploy PostgreSQL:

```bash
kubectl create deployment postgres --image=postgres:13 -n kubeflow
kubectl expose deployment postgres --port=5432 --target-port=5432 -n kubeflow
kubectl set env deployment/postgres POSTGRES_USER=mlflow POSTGRES_PASSWORD=mlflow_password POSTGRES_DB=mlflow -n kubeflow
```

Test:

```bash
kubectl port-forward -n kubeflow svc/postgres 5432:5432
```

Connect from Your Local Client
Now you can use a local PostgreSQL client with the following modified connection details:

- Host: localhost
- Port: 5432
- Database: `mlflow`
- User: `mlflow`
- Password: `mlflow_password`

2. Create a Secret for MinIO Credentials:

```bash
kubectl create secret generic mlflow-minio-secret \
  --from-literal=AWS_ACCESS_KEY_ID='minio' \
  --from-literal=AWS_SECRET_ACCESS_KEY='minio123' \
  -n kubeflow
```

3. Deploy MLflow using Docker file:


```Dockerfile
FROM python:3.9-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies for psycopg2
RUN apt-get update && apt-get install -y \
    build-essential \
    libpq-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install Python packages
RUN pip install --no-cache-dir \
    mlflow \
    boto3 \
    psycopg2-binary

WORKDIR /app

# Create a startup script
RUN echo '#!/bin/bash\n\
set -e\n\
mlflow server \
  --backend-store-uri "${BACKEND_STORE_URI}" \
  --default-artifact-root "${DEFAULT_ARTIFACT_ROOT}" \
  --host 0.0.0.0 \
  --port 5000 \
  ${EXTRA_MLFLOW_ARGS}' > /app/start.sh && chmod +x /app/start.sh

EXPOSE 5000

ENTRYPOINT ["/app/start.sh"]
```

Build and (Push)

```bash
docker build -t mlflow-custom:latest .
```

4. Apply the kubernates deployment:

```yml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mlflow
  namespace: kubeflow
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mlflow
  template:
    metadata:
      labels:
        app: mlflow
    spec:
      containers:
        - name: mlflow
          image: mlflow-custom:latest
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 5000
          env:
            - name: AWS_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: mlflow-minio-secret
                  key: AWS_ACCESS_KEY_ID
            - name: AWS_SECRET_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: mlflow-minio-secret
                  key: AWS_SECRET_ACCESS_KEY
            - name: MLFLOW_S3_ENDPOINT_URL
              value: 'http://minio-service.kubeflow.svc.cluster.local:9000'
            - name: BACKEND_STORE_URI
              value: 'postgresql://mlflow:mlflow_password@postgres.kubeflow.svc.cluster.local:5432/mlflow'
            - name: DEFAULT_ARTIFACT_ROOT
              value: 's3://mlflow'
          resources:
            requests:
              memory: '512Mi'
              cpu: '250m'
            limits:
              memory: '2Gi' # Increased from 512Mi
              cpu: '1000m'
          # Add readiness and liveness probes to prevent traffic to unhealthy pod
          readinessProbe:
            httpGet:
              path: /health
              port: 5000
            initialDelaySeconds: 10
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              port: 5000
            initialDelaySeconds: 30
            periodSeconds: 20
---
apiVersion: v1
kind: Service
metadata:
  name: mlflow
  namespace: kubeflow
spec:
  selector:
    app: mlflow
  ports:
    - protocol: TCP
      port: 5000
      targetPort: 5000
```

```bash
kubectl apply -f mlflow-deployment.yaml
```

1. Access MLflow UI:

```bash
kubectl port-forward -n kubeflow svc/mlflow 5000:5000
```

Visit `http://localhost:5000` to see the MLflow UI.

