# Worker 1 y worker 2

Comandos para los **workers**. Son los mismos para los dos; solo cambia `NODE_NAME`.
Qué hace cada paso: [README principal](../README.md).

Requisito: los 3 planners están unidos y en `Ready`.

## Antes de empezar

```bash
git clone <url-del-repositorio> k8s-ha-almalinux
cd k8s-ha-almalinux/worker-1-y-2
```

## Paso 0. Valores de tu entorno

Usa los mismos valores que en los planners y pega los dos bloques en la terminal. Vuelve a pegarlos cada vez que abras una sesión nueva.

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
NODE_NAME=${WORKER1_NAME}    # ${WORKER2_NAME} en el worker 2
```

Si el servidor tuvo antes otro cluster, límpialo primero:

```bash
sudo ../scripts/limpiar-nodo.sh
sudo reboot
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
sudo firewall-cmd --list-services              # debe incluir ssh
sudo firewall-cmd --permanent --add-port={10250,10256,179}/tcp
sudo firewall-cmd --permanent --add-port=30000-32767/tcp
sudo firewall-cmd --permanent --add-rich-rule='rule protocol value="4" accept'
sudo firewall-cmd --permanent --zone=trusted --add-source=${POD_CIDR}
sudo firewall-cmd --permanent --zone=trusted --add-source=${SVC_CIDR}
sudo firewall-cmd --reload

sudo firewall-cmd --list-ports
curl -k https://${VIP}:${API_PORT}/version       # JSON con la versión de Kubernetes
```

## Paso 3. Unirse al cluster

En el **planner 1**, ejecuta su [Paso 10](../planner-1/README.md#paso-10-generar-el-join-para-los-workers) y copia la línea que genera. Después, en este nodo:

```bash
sudo kubeadm join ...        # pega aquí la línea generada en el planner 1
```

## Paso 4. Verificación

```bash
sudo ../scripts/check-k8s.sh worker ${VIP}
```

Después, en el **planner 1**: [Paso 11](../planner-1/README.md#paso-11-etiquetar-los-workers) (etiquetas), [Paso 12](../planner-1/README.md#paso-12-taint-de-los-planners) (taint) y [Paso 13](../planner-1/README.md#paso-13-prueba-de-red-entre-pods) (prueba de red).
