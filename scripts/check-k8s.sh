VIP=192.168.100.220
ok(){ echo -e "  [\e[32m OK  \e[0m] $1"; }
ko(){ echo -e "  [\e[31mFALTA\e[0m] $1"; }
chk(){ if eval "$2" &>/dev/null; then ok "$1"; else ko "$1"; fi; }
KC="kubectl --kubeconfig /etc/kubernetes/admin.conf"

echo "===== Checklist $(hostname) ====="
chk "1.1 Clave GPG AlmaLinux"        'rpm -q gpg-pubkey --qf "%{SUMMARY}\n" | grep -qi alma'
chk "1.2 /etc/hosts con la VIP"      "grep -q $VIP /etc/hosts"
chk "1.3 Swap desactivada"           'test -z "$(swapon --show)"'
chk "1.4 SELinux permisivo"          'grep -q "^SELINUX=permissive" /etc/selinux/config'
chk "1.5 Modulos kernel"             'lsmod | grep -q br_netfilter && lsmod | grep -q overlay'
chk "1.5 sysctl ip_forward"          'test "$(sysctl -n net.ipv4.ip_forward)" = 1'
chk "1.6 NetworkManager Calico"      'test -f /etc/NetworkManager/conf.d/calico.conf'
chk "1.7 containerd activo"          'systemctl is-active -q containerd'
chk "1.7 SystemdCgroup = true"       'grep -q "SystemdCgroup = true" /etc/containerd/config.toml'
chk "1.8 kubeadm instalado"          'command -v kubeadm'
chk "1.8 kubelet habilitado"         'systemctl is-enabled -q kubelet'
chk "1.9 Firewall puerto 6443"       'firewall-cmd --list-ports | grep -q 6443'
chk "1.9 Firewall puerto 8443"       'firewall-cmd --list-ports | grep -q 8443'
chk "1.9 Firewall VRRP"              'firewall-cmd --list-rich-rules | grep -q vrrp'
chk "2.1 HAProxy activo"             'systemctl is-active -q haproxy'
chk "2.2 Keepalived activo"          'systemctl is-active -q keepalived'
chk "2.2 VIP en este nodo"           "ip a | grep -q $VIP"
chk "3   kubeadm init hecho"         'test -f /etc/kubernetes/admin.conf'
chk "3   API responde por la VIP"    "$KC get nodes"
chk "4   Calico desplegado"          "$KC -n kube-system get ds calico-node"
chk "4   Nodo en Ready"              "$KC get node \$(hostname) | grep -qw Ready"
chk "5   Taint quitado"              "$KC get node \$(hostname) && ! $KC describe node \$(hostname) | grep -q 'control-plane:NoSchedule'"
echo "================================="
kubeadm version -o short 2>/dev/null
