# NPanel：NixOS 原生 Web 门面（声明式服务注册表 + Nix 时间机器 + 选项检索）。
#
# 模块本体来自 npanel flake（nixosModules.default，在 flake.nix 里接线），
# 此文件只做主机级启用与参数——与 gitea.nix / syncthing.nix 同构。
# 口令用 passwordHash（PHC 哈希可入库，明文永不落地；生成：npanel-hash <口令>）。
{ ... }:

{
  services.npanel = {
    enable = true;
    # 直连访问（不经 Caddy）：8080 已被 Caddy 占用，9090 是 Cockpit，故用 8081。
    listenAddress = "0.0.0.0:8081";
    # 登录用系统用户名口令（D37，PAM），allowedGroup 缺省 wheel，无需再配口令。
  };

  # 异名 unit 必须用贡献点声明（同名才推得出来，宁漏勿错）：
  # 磁贴的健康状态取自这些 unit 的实时状态。
  npanel.tile = {
    openssh.units = [ "sshd.service" ];
    avahi.units = [ "avahi-daemon.service" ];
    samba.units = [ "samba-smbd.service" "samba-nmbd.service" ];
    tailscale.units = [ "tailscaled.service" ];
    rustdesk.units = [ "rustdesk-hbbs.service" "rustdesk-hbbr.service" ];
    cockpit.units = [ "cockpit.service" ];
  };

  networking.firewall.allowedTCPPorts = [ 8081 ];
}
