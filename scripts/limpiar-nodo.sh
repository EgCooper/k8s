if [ "$(id -u)" -ne 0 ]; then
  echo "Ejecuta el script con sudo."
  exit 1
fi

echo "Nodo: $(hostname)"
echo "Contenedores que se van a borrar: $(ctr -n k8s.io containers list -q 2>/dev/null | wc -l)"
read -r -p "Esto borra Kubernetes y todos sus datos en este nodo. Escribe BORRAR para continuar: " CONFIRM
[ "$CONFIRM" = "BORRAR" ] || { echo "Cancelado."; exit 1; }

set -x
kubeadm reset -f 2>/dev/null

for s in kubelet docker docker.socket containerd haproxy keepalived; do
  systemctl stop "$s" 2>/dev/null
  systemctl disable "$s" 2>/dev/null
done

dnf remove -y kubelet kubeadm kubectl cri-tools kubernetes-cni containerd.io haproxy keepalived \
  docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras podman-docker

rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd
rm -rf /etc/cni /opt/cni /var/lib/cni /var/lib/calico /run/flannel
rm -rf /etc/containerd /var/lib/containerd /run/containerd
rm -rf /var/lib/docker /etc/docker /etc/haproxy /etc/keepalived
rm -rf /root/.kube /etc/crictl.yaml
[ -n "$SUDO_USER" ] && rm -rf "$(getent passwd "$SUDO_USER" | cut -d: -f6)/.kube"

rm -f /etc/yum.repos.d/kubernetes.repo /etc/yum.repos.d/docker-ce.repo /etc/yum.repos.d/download.docker.com*
rm -f /etc/modules-load.d/k8s.conf /etc/sysctl.d/k8s.conf /etc/NetworkManager/conf.d/calico.conf
dnf clean all

for i in cni0 flannel.1 docker0 tunl0 vxlan.calico; do ip link delete "$i" 2>/dev/null; done
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
set +x

echo
echo "Limpieza terminada. Reinicia el nodo: sudo reboot"
echo "Después revisa /etc/hosts y las reglas de firewall de la instalación anterior."
