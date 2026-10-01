# Planner 1 (primer master)

Comandos para el **primer planner**, que crea el cluster. Ejecútalos en orden y en este nodo, salvo que se indique otra cosa.
Qué hace cada paso: [README principal](../README.md).

## Antes de empezar

```bash
git clone <url-del-repositorio> k8s-ha-almalinux
cd k8s-ha-almalinux/planner-1
```

## Paso 0. Valores de tu entorno

Cambia los valores de ejemplo por los tuyos y pega los dos bloques en la terminal. Vuelve a pegarlos cada vez que abras una sesión nueva.

```bash
# --- Red y nodos: iguales en TODOS los nodos ---
VIP=192.168.1.100                          # IP libre para la API (fuera del rango DHCP)
MASTER1_NAME=k8s-planner1; MASTER1_IP=192.168.1.11
MASTER2_NAME=k8s-planner2; MASTER2_IP=192.168.1.12
MASTER3_NAME=k8s-planner3; MASTER3_IP=192.168.1.13
WORKER1_NAME=k8s-worker1;  WORKER1_IP=192.168.1.21
WORKER2_NAME=k8s-worker2;  WORKER2_IP=192.168.1.22
API_PORT=8443
POD_CIDR=10.244.0.0/16                     # no debe solaparse con tus redes
SVC_CIDR=10.96.0.0/12

# --- Versiones: iguales en TODOS los nodos ---
K8S_MINOR=v1.34
K8S_VERSION=1.34.12
CONTAINERD_VERSION=2.3.5
```

```bash
# --- Este nodo ---
NODE_NAME=${MASTER1_NAME}
NODE_IP=${MASTER1_IP}
IFACE=ens18                  # interfaz de red: ip -br a
VIP_PREFIX=24                # máscara de la red de los planners
KA_STATE=MASTER
KA_PRIORITY=101
KA_ROUTER_ID=51              # igual en los 3 planners
KA_PASS=CambiaMe             # máx. 8 caracteres, igual en los 3 planners
CALICO_VERSION=v3.30.0
```

## Paso 1. Preparación del sistema

### 1.1 Clave GPG y actualización

```bash
sudo rpm --import https://repo.almalinux.org/almalinux/RPM-GPG-KEY-AlmaLinux-9
sudo dnf clean all
sudo dnf update -y
sudo dnf install -y dnf-plugins-core iproute-tc curl vim
```

Si se actualizó el kernel: `sudo reboot` y vuelve a pegar el bloque del **Paso 0**.

### 1.2 Hostname y /etc/hosts

```bash
sudo hostnamectl set-hostname ${NODE_NAME}

cat <<EOF | sudo tee -a /etc/hosts
${VIP} k8s-api
${MASTER1_IP} ${MASTER1_NAME}
${MASTER2_IP} ${MASTER2_NAME}
${MASTER3_IP} ${MASTER3_NAME}
${WORKER1_IP} ${WORKER1_NAME}
${WORKER2_IP} ${WORKER2_NAME}
EOF

hostname
cat /etc/hosts
```

### 1.3 Swap

```bash
sudo swapoff -a
sudo sed -i '/^[^#].* swap / s/^/#/' /etc/fstab
swapon --show        # no debe mostrar nada
```

### 1.4 SELinux

```bash
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
getenforce           # Permissive
```

### 1.5 Módulos del kernel y sysctl

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
```

### 1.6 NetworkManager

```bash
cat <<EOF | sudo tee /etc/NetworkManager/conf.d/calico.conf
[keyfile]
unmanaged-devices=interface-name:cali*;interface-name:tunl*;interface-name:vxlan.calico;interface-name:vxlan-v6.calico;interface-name:wireguard.cali;interface-name:wg-v6.cali
EOF
sudo systemctl restart NetworkManager
```

### 1.7 containerd

```bash
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo rpm --import https://download.docker.com/linux/centos/gpg
sudo dnf install -y containerd.io-${CONTAINERD_VERSION}

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl enable --now containerd

grep SystemdCgroup /etc/containerd/config.toml     # SystemdCgroup = true
```

### 1.8 kubeadm, kubelet y kubectl

```bash
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

sudo rpm --import https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/repodata/repomd.xml.key
sudo dnf install -y kubelet-${K8S_VERSION} kubeadm-${K8S_VERSION} kubectl-${K8S_VERSION} \
  cri-tools --disableexcludes=kubernetes
sudo systemctl enable --now kubelet

cat <<EOF | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
EOF

kubeadm version -o short
```

## Paso 2. Firewall

```bash
sudo systemctl enable --now firewalld
sudo firewall-cmd --permanent --add-port={6443,${API_PORT},2379-2380,10250,10256,10257,10259,179}/tcp
sudo firewall-cmd --permanent --add-port=30000-32767/tcp
sudo firewall-cmd --permanent --add-rich-rule='rule protocol value="vrrp" accept'
sudo firewall-cmd --permanent --add-rich-rule='rule protocol value="4" accept'
sudo firewall-cmd --permanent --zone=trusted --add-source=${POD_CIDR}
sudo firewall-cmd --permanent --zone=trusted --add-source=${SVC_CIDR}
sudo firewall-cmd --reload

sudo firewall-cmd --list-ports
sudo firewall-cmd --zone=trusted --list-sources
```

## Paso 3. HAProxy

```bash
sudo dnf install -y haproxy
sudo setsebool -P haproxy_connect_any 1

cat <<EOF | sudo tee /etc/haproxy/haproxy.cfg
global
    log /dev/log local0
    maxconn 4000
    daemon

defaults
    mode tcp
    log global
    option tcplog
    timeout connect 10s
    timeout client  1m
    timeout server  1m

frontend k8s-api
    bind *:${API_PORT}
    default_backend k8s-masters

backend k8s-masters
    balance roundrobin
    option tcp-check
    server ${MASTER1_NAME} ${MASTER1_IP}:6443 check fall 3 rise 2
    server ${MASTER2_NAME} ${MASTER2_IP}:6443 check fall 3 rise 2
    server ${MASTER3_NAME} ${MASTER3_IP}:6443 check fall 3 rise 2
EOF

sudo haproxy -c -f /etc/haproxy/haproxy.cfg      # Configuration file is valid
sudo systemctl enable --now haproxy
sudo ss -tlnp | grep ${API_PORT}
```

## Paso 4. Keepalived

```bash
sudo dnf install -y keepalived

cat <<EOF | sudo tee /etc/keepalived/keepalived.conf
global_defs {
    enable_script_security
    script_user root
}

vrrp_script chk_haproxy {
    script "/usr/sbin/pidof haproxy"
    interval 2
    weight 2
}

vrrp_instance VI_1 {
    state ${KA_STATE}
    interface ${IFACE}
    virtual_router_id ${KA_ROUTER_ID}
    priority ${KA_PRIORITY}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass ${KA_PASS}
    }
    virtual_ipaddress {
        ${VIP}/${VIP_PREFIX}
    }
    track_script {
        chk_haproxy
    }
}
EOF

sudo systemctl enable --now keepalived
sudo journalctl -u keepalived -n 10 --no-pager
ip -br a show ${IFACE}
```

## Paso 5. Crear el cluster

```bash
sudo kubeadm config images pull

sudo kubeadm init \
  --control-plane-endpoint "${VIP}:${API_PORT}" \
  --upload-certs \
  --pod-network-cidr=${POD_CIDR} \
  --service-cidr=${SVC_CIDR} \
  --apiserver-advertise-address=${NODE_IP} | tee ~/kubeadm-init.log

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

curl -k https://${VIP}:${API_PORT}/version
kubectl get nodes
```

## Paso 6. Calico

```bash
curl -fLO https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml

sed -i -e 's|# - name: CALICO_IPV4POOL_CIDR|- name: CALICO_IPV4POOL_CIDR|' \
       -e "s|#   value: \"192.168.0.0/16\"|  value: \"${POD_CIDR}\"|" calico.yaml
grep -A1 CALICO_IPV4POOL_CIDR calico.yaml       # sin '#' y con tu POD_CIDR

kubectl apply -f calico.yaml
kubectl get pods -n kube-system -w              # Ctrl+C cuando todo esté 1/1 Running
kubectl get nodes                               # Ready
```

## Paso 7. Verificación

```bash
sudo ../scripts/check-k8s.sh master ${VIP}
```

---

# Comandos que ejecutarás aquí más adelante

## Paso 8. Generar el join para el planner 2 y el planner 3

Ejecútalo cuando el planner nuevo haya terminado su Paso 4. Genera uno nuevo para cada planner.

```bash
NEW_MASTER_IP=${MASTER2_IP}      # ${MASTER3_IP} para el planner 3

CERT_KEY=$(sudo kubeadm init phase upload-certs --upload-certs | tail -1)
JOIN_CMD=$(kubeadm token create --print-join-command)
echo "sudo ${JOIN_CMD} --control-plane --certificate-key ${CERT_KEY} --apiserver-advertise-address=${NEW_MASTER_IP}"
```

Copia la línea que empieza por `sudo kubeadm join` y ejecútala en el planner nuevo.

## Paso 9. Verificar etcd (con los 3 planners unidos)

```bash
kubectl -n kube-system exec etcd-${MASTER1_NAME} -- etcdctl \
  --endpoints=https://${MASTER1_IP}:2379,https://${MASTER2_IP}:2379,https://${MASTER3_IP}:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status -w table
```

## Paso 10. Generar el join para los workers

Ejecútalo cuando el worker haya terminado su Paso 2.

```bash
kubeadm token create --print-join-command
```

Ejecuta esa línea en el worker con `sudo` delante.

## Paso 11. Etiquetar los workers

```bash
kubectl label node ${WORKER1_NAME} node-role.kubernetes.io/worker=
kubectl label node ${WORKER2_NAME} node-role.kubernetes.io/worker=
kubectl get nodes -o wide
```

## Paso 12. Taint de los planners

```bash
kubectl taint nodes ${MASTER1_NAME} ${MASTER2_NAME} ${MASTER3_NAME} \
  node-role.kubernetes.io/control-plane=:NoSchedule --overwrite
kubectl describe nodes | grep -E "^Name:|^Taints:"
```

Solo si todavía no tienes workers y los planners deben ejecutar aplicaciones:

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

## Paso 13. Prueba de red entre pods

```bash
kubectl run test-w1 --image=busybox:1.36 --restart=Never \
  --overrides="{\"spec\":{\"nodeName\":\"${WORKER1_NAME}\"}}" -- sleep 3600
kubectl run test-m1 --image=busybox:1.36 --restart=Never \
  --overrides="{\"spec\":{\"nodeName\":\"${MASTER1_NAME}\"}}" -- sleep 3600
kubectl wait --for=condition=Ready pod/test-w1 pod/test-m1 --timeout=120s

W1_IP=$(kubectl get pod test-w1 -o jsonpath='{.status.podIP}')
M1_IP=$(kubectl get pod test-m1 -o jsonpath='{.status.podIP}')
kubectl exec test-w1 -- ping -c 3 ${M1_IP}
kubectl exec test-m1 -- ping -c 3 ${W1_IP}
kubectl exec test-w1 -- nslookup kubernetes.default.svc.cluster.local

kubectl delete pod test-w1 test-m1
```

## Paso 14. Verificación final

```bash
kubectl get nodes -o wide
kubectl get pods -A
sudo kubeadm certs check-expiration
```
