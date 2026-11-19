# Tuner Box on GKE

This manifest is a single-GPU baseline for the current Tuner Box backend. The
server keeps SQLite, voice profiles, generated audio, model cache, and its
serial generation queue inside the pod's data volume. `replicas: 1` and the
`Recreate` strategy are intentional: adding replicas now would create separate
databases and profile stores while sending work to independent in-memory queues.

The server already uses asynchronous FastAPI handlers and `asyncio.to_thread`
for blocking audio/model work. The manifest caps native CPU thread pools at four
threads. TTS inference remains serialized per pod to prevent GPU contention.
Use one replica per GPU for inference parallelism; do not run multiple Uvicorn
workers inside one GPU pod, because each worker can load its own model copy.

## Build and publish

Replace the placeholders with your project, region, and Artifact Registry
repository. These commands are intentionally not run from this checkout:

```bash
gcloud auth configure-docker REGION-docker.pkg.dev
docker build -t REGION-docker.pkg.dev/PROJECT_ID/REPOSITORY/tuner-box:TAG .
docker push REGION-docker.pkg.dev/PROJECT_ID/REPOSITORY/tuner-box:TAG
```

Use a fixed release tag or image digest in `deployment.yaml`; do not deploy
`latest` for a model-serving workload. The first selected model download is
written to `/app/data/models`, so the 100Gi claim also acts as the model cache.

## GPU node pool and deploy

Create or select a GKE Standard GPU node pool with the accelerator type that
matches the `nodeSelector`. Enable GKE's managed NVIDIA driver installation and
node-pool autoscaling according to your cluster policy. Then authenticate to the
cluster and apply the manifest:

```bash
gcloud container clusters get-credentials CLUSTER_NAME \
  --location CLUSTER_LOCATION --project PROJECT_ID
kubectl apply -k deploy/gke
kubectl -n tuner-box set image deployment/tuner-box \
  tuner-box=REGION-docker.pkg.dev/PROJECT_ID/REPOSITORY/tuner-box:TAG
kubectl -n tuner-box rollout status deployment/tuner-box --timeout=15m
kubectl -n tuner-box port-forward service/tuner-box 17493:80
curl http://127.0.0.1:17493/health
```

Keep the service as `ClusterIP` until an authenticated gateway is in place. The
backend does not provide general API-key authentication, and voice profiles are
sensitive biometric data. Exposing port 17493 directly through a public
`LoadBalancer` would put the API on the internet without an identity boundary.

## Scaling safely

The current queue is process-local and serial by design. Scaling means adding
GPU-backed pods, not increasing Uvicorn workers or putting more TTS calls into a
single process. Before setting `replicas > 1`, move the following state behind
shared services:

- SQLite metadata to PostgreSQL or another transactional database.
- Profiles and generated audio to a shared object store such as GCS, with signed
  URLs and explicit retention/deletion controls.
- The in-memory generation queue to a durable broker (for example Pub/Sub or a
  task service), with idempotency keys and retry/dead-letter handling.
- Model caches to an image layer or per-node cache; do not require every pod to
  redownload weights on every rollout.

After that split, route a request to one inference worker and autoscale on queue
depth or generation latency. CPU HPA alone is a poor signal for a GPU-bound,
serial queue. A custom or external metric can drive HPA, while the GKE GPU node
pool autoscaler supplies nodes. The `OMP_NUM_THREADS` and `MKL_NUM_THREADS`
values are starting points; benchmark the selected engine and GPU before changing
them.

## Local smoke run

The same image can be run locally on a machine with Docker:

```bash
docker compose up --build
curl http://127.0.0.1:17600/health
```

The local compose file maps host port 17600 to the backend's native 17493 port.
Model download and a first TTS request require network access to Hugging Face;
health checks do not require an OpenAI key.

References: [GKE GPU node pools](https://cloud.google.com/kubernetes-engine/docs/how-to/gpus),
[GKE HPA](https://cloud.google.com/kubernetes-engine/docs/concepts/horizontalpodautoscaler),
and [Artifact Registry Docker images](https://cloud.google.com/artifact-registry/docs/docker/pushing-and-pulling).
