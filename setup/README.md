# Setting up HLF project infrastructure
This repository is meant to be deployed on a chosen Linux host (e.g. `moura` from the BIGLab @ INESC-ID).
After initial setup, the GitLab CI will automatically deploy Hyperledger Fabric (HLF) to the host on the first commit, along with your chaincode and application.
Subsequent commits pushed to the repository will also trigger the GitLab CI pipeline and cause it to 1) confirm that the HLF deployment still exists and 2) rebuild and redeploy your chaincode and application.

For simplicity, the chosen Linux host is also used as a GitLab Runner, i.e., the CI pipeline will run on that host.

To this end, we create a kubernetes cluster with `kind` on the chosen host, create two namespaces `hlf` and `gitlab-ci`, for the HLF deployment and the GitLab runner respectively, and configure the required service accounts and permissions granting the CI pipeline access to the HLF deployment.
Furthermore we take a few bootstrap steps required for the kubernetes cluster and the HLF deployment to work correctly.

In this document we present the requirements of this setup, how to prepare it, and a few tips for monitoring it.

## Requirements
- GitLab repository with project, following the structure of this repository.
- Linux host to use as a GitLab runner and to host your Hyperledger Fabric entities (CAs, peers, etc.), your chaincode and respective application. Ensure it:
  * has Docker, `kind`, `helm`, and `kubectl` installed (bonus: install `k9s` to monitor the cluster with a TUI);
  * you have access to this machine, and your user is either `root` or in the `docker` group.

## Preparing the host
In this section we create a kubernetes cluster, perform the initial setup steps of the [HLF Bevel Operator](https://github.com/hyperledger-bevel/bevel-operator-fabric), and configure GitLab CI to access the cluster and run CI jobs on it.

### Create a Kubernetes cluster
We will create a kubernetes cluster with `kind` -- a tool which spawns a whole cluster as docker containers.

1. Create a YAML file named `kind-config.yaml` with the following contents:
    ```yaml
    kind: Cluster
    name: k8s-hlf
    apiVersion: kind.x-k8s.io/v1alpha4
    nodes:
      - role: control-plane
        extraPortMappings:
        - containerPort: 30949
          hostPort: 80
        - containerPort: 30950
          hostPort: 443
    ```

    This instructs `kind` to create a cluster named `k8s-hlf` (name is only used in `kind` to select among multiple clusters), and map ports 30080 and 30443 the kubernetes cluster to ports 80 and 443 on your Linux host, allowing you to access any exposed HTTP(S) services through a browser without additional effort.
    If you wish to run multiple clusters (or an HTTP(S) server) in your Linux host, adjust `hostPort`s to avoid conflicts between clusters/services, and pick another `name`.

2. Create the kubernetes cluster with `kind` using the command: `kind create cluster --config kind-config.yaml`.

    You can confirm that the cluster was created with `docker ps` (whose output should include a container named `<cluster name>-control-plane`), and `kind get clusters` (whose output should include the cluster's name).

### Prepare Kubernetes cluster
For the CI pipeline to work, the Kubernetes cluster must be fitted with adequate networking capabilities and the [HLF Operator](https://github.com/hyperledger-bevel/bevel-operator-fabric) which simplifies construction of an HLF network on Kubernetes.

1.  Install the HLF Operator (from its repository)
    ```bash
    helm repo add kfs https://kfsoftware.github.io/hlf-helm-charts --force-update
    helm install hlf-operator --version=1.11.1 -- kfs/hlf-operator
    ```

2.  Install istio
    ```bash
    curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.23.3 sh -
    
    kubectl create namespace istio-system
    
    export ISTIO_PATH=$(echo $PWD/istio-*/bin)
    export PATH="$PATH:$ISTIO_PATH"
    
    istioctl operator init
    
    kubectl apply -f - <<EOF
    apiVersion: install.istio.io/v1alpha1
    kind: IstioOperator
    metadata:
      name: istio-gateway
      namespace: istio-system
    spec:
      addonComponents:
        grafana:
          enabled: false
        kiali:
          enabled: false
        prometheus:
          enabled: false
        tracing:
          enabled: false
      components:
        ingressGateways:
          - enabled: true
            k8s:
              hpaSpec:
                minReplicas: 1
              resources:
                limits:
                  cpu: 500m
                  memory: 512Mi
                requests:
                  cpu: 100m
                  memory: 128Mi
              service:
                ports:
                  - name: http
                    port: 80
                    targetPort: 8080
                    nodePort: 30949
                  - name: https
                    port: 443
                    targetPort: 8443
                    nodePort: 30950
                type: NodePort
            name: istio-ingressgateway
        pilot:
          enabled: true
          k8s:
            hpaSpec:
              minReplicas: 1
            resources:
              limits:
                cpu: 300m
                memory: 512Mi
              requests:
                cpu: 100m
                memory: 128Mi
      meshConfig:
        accessLogFile: /dev/stdout
        enableTracing: false
        outboundTrafficPolicy:
          mode: ALLOW_ANY
      profile: default
    EOF
    ```


3.  Configure Internal DNS
    ```bash
    kubectl apply -f - <<EOF
    kind: ConfigMap
    apiVersion: v1
    metadata:
      name: coredns
      namespace: kube-system
    data:
      Corefile: |
        .:53 {
            errors
            health {
               lameduck 5s
            }
            rewrite name regex (.*)\.localho\.st istio-ingressgateway.istio-system.svc.cluster.local
            hosts {
              fallthrough
            }
            ready
            kubernetes cluster.local in-addr.arpa ip6.arpa {
              pods insecure
              fallthrough in-addr.arpa ip6.arpa
              ttl 30
            }
            prometheus :9153
            forward . /etc/resolv.conf {
              max_concurrent 1000
            }
            cache 30
            loop
            reload
            loadbalance
        }
    EOF
    ```
    **Note:** If you wish to use a different domain from `localho.st` for your HLF network resources, you must change the configuration above (and point your domain to kubernetes' DNS).

### Create a GitLab Runner
1. Create a namespace on the kubernetes cluster for GitLab to use on its CI jobs: `kubectl create namespace gitlab-ci`.

2. Create a GitLab CI project runner.
    1.  Create a new runner in GitLab (Settings > CI/CD Settings > Runners > New project runner), with the options "Can run untagged jobs" and "Lock to current projects" enabled.
    
        While "Lock to current projects" isn't strictly necessary, it is highly recommended unless you are absolutely sure that other projects using the runner won't interfere with the kubernetes cluster associated with this runner.
    
        **Save the runner's authentication token.**


    2.  Create a file named `runner-token.yml` with the following contents (we will later replace `<YOUR TOKEN HERE>` with the runner authentication token from ):
        ```yaml
        apiVersion: v1
        kind: Secret
        metadata:
          name: gitlab-runner-secret
          namespace: gitlab-ci
        type: Opaque
        stringData:
          runner-registration-token: "" # need to leave as an empty string for compatibility reasons
          runner-token: "<YOUR TOKEN HERE>"
        ```  
        **WARNING: in a sensitive environment, place this file in a shreddable filesystem (e.g. not ZFS/Btrfs), and shred it after adding the secret to kubernetes.**
  
    3. Add the secret to kubernetes with `kubectl apply -f runner-token.yml`.

4.  Install GitLab runner in the cluster:
    ```bash
    helm repo add gitlab https://charts.gitlab.io --force-update

    helm install --namespace gitlab-ci gitlab-runner -f gitlab-runner-conf.yml gitlab/gitlab-runner
    ```

    For this to work, ensure `setup/gitlab-runner-conf.yml` is in your current directory (or change the path in the command accordingly), and modify it with the desired GitLab instance URL if not using RNL's GitLab.

5. Enable the Container Registry for your GitLab project (in Settings > General > Visibility, project features, permissions).
If you don't do this, your CI jobs will try to push your images to DockerHub and likely fail with permission errors.

6. Grant kubernetes access to your repository's container registry. You may skip this step if using a public registry (not RNL's GitLab).
    1. Create a project access token in GitLab with the `read_registry` scope. You can set any expiration date (within your needs) and leave the role as `Guest`.
        
        You can create this token in `Settings > Access tokens` from your repository.
  
    2.  Save the access token in your kubernetes cluster by running `kubectl create secret docker-registry pull-secret --docker-server=<your-registry-server> --docker-username=<your-username> --docker-password=<access-token> --docker-email=<your-email>` (note that you **must use your access token instead of your password**).

        If using [RNL's GitLab](https://gitlab.rnl.tecnico.ulisboa.pt/), the registry server is `registry.rnl.tecnico.ulisboa.pt`.
    
        **WARNING: in a sensitive environment, manually construct the secret yaml definition (see kubernetes documentation) and add it with `kubectl apply`. This method exposes the access token in your shell history and to all other running processes (through the processe's arguments).**

7.  Run `kubectl apply -f init.yml`, where `init.yml` is the file in `setup/init.yml` from this repository.

    It will create a namespace for your HLF network (named `hlf`), grant it access to your container image repository (with the `pull-secret` from the previous), and allow the GitLab runner to control everything in the `hlf` namespace.

    You may need to run this command a few times until it succeeds. Testing encountered spurious errors while updating the service account created automatically with the `hlf` namespace.

### Use it!
Try pushing a commit to the main branch. The CI pipeline should create your HLF network and deploy your application.


## Monitoring tips
In this section we present a few tricks that can help you better monitor your deployment and troubleshoot any issues in it.

### Switching between kubernetes clusters
Check out `kubectx`. Run it and it will let you switch between "contexts" (separate kubectl connection configurations). `kind` creates one context per cluster by default.

### Seeing running containers with `k9s`
`k9s` is a terminal user interface for kubernetes clusters, which is very useful to inspect the state of your cluster and applications running in it, particularly your chaincode and HLF application.
In this section we go over a few relevant commands and metrics available in `k9s`.
Refer to [their page](https://k9scli.io/) for more information.

On a host with access to your kubernetes cluster, run `k9s`. It will open your default context and show all containers on the `default` namespace.
Notice that a reference of all available commands is available in the interface itself on the top of the list of pods, next to generic cluster information.

Let us go over a few key metrics and how to see logs.

First, press `0` to see pods (groups of containers) in all kubernetes namespaces.
In this setup, your application and chaincode will run in the `hlf` namespace, so we won't see them in the default view, which only shows the `default` namespace.

Secondly, we'll turn our attention to the list of pods and notice some information presented for each.

The `READY` column shows how many containers are running (on the left of `/`) and how many containers are defined in the pod (on the right of `/`).

The `STATUS` column show a summary of the state of the pod and its containers.
In a healthy deployment you'd expect this status to be `Running` for all pods, but it is normal for it to be different (and even in an error state) for a short time after startup, e.g., due to dependencies not being ready yet, causing their dependents to (temporarily) crash.

The `RESTARTS` column shows how many times containers in the pod were restarted by kubernetes (because they failed in some way).
Similarly to the `STATUS` column, it's sometimes normal for containers to accumulate a few restarts on startup, but this number should stabilize after successful healthy deployments.

Thirdly, try using your arrow keys to navigate up and down the pods list. Press `L` when one is selected and `k9s` will show you the logs corresponding to all containers in that pod, in real-time. You can navigate back from the log view by pressing the `ESC` key.

Fourthly, you can also inspect individual containers in pods by pressing `ENTER` when selecting a pod. You'll be presented with the list of containers in that pod which can be interacted in a similar way to pods (including pressing `L` to see logs).
To navigate back to the pod list, press `L`.

### `kubectl` access from another machine over SSH to your kind cluster
Want to use `kubectl`/`helm`/`k9s` from your personal computer and have your cluster running somewhere else? It's doable!

First, go to your cluster host and run `kubectl config view --raw`. It will display a list of clusters, contexts, and users.
Copy the relevant cluster, context and user for your cluster, and merge it in your own config in `~/.kube/config` on your personal machine.
If you don't use kubernetes for anything else and have a single cluster on the host, you can also just copy the entire file to your personal machine.

Now your personal computer has the credentials and address of your kubernetes cluster, but lacks connectivity to it.

Inspect the copied configuration. The server field of the cluster object should be a URL pointed at the local machine (e.g. `https://127.0.0.1:44195`). Note the port of the cluster (in this example `44195`).
We'll use SSH port forwarding to forward port `44915` on our personal computer to port `44195` on the host with the kubernetes cluster.
Run `ssh -L 44195:127.0.0.1:44195 <your kubernetes host>` from your personal computer. While it's open, you can freely use your kubernetes tools to control your remote cluster!

