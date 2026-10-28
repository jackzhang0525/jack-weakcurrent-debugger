# JACK 弱电调试宝

Windows 免安装、浏览器界面的弱电现场调试工具。

## V1 功能
- 读取网卡 IP、掩码、网关、DNS、MAC
- Ping 内网设备
- `/24` 局域网扫描与常见弱电端口探测
- ARP/MAC、主机名反查
- HTTP 登录页特征与常见品牌识别
- ONVIF WS-Discovery
- 海康/大华/通用 RTSP 地址生成
- CSV 导出

## 运行
1. 下载项目 ZIP 并解压。
2. 双击 `启动弱电调试宝.bat`。
3. 浏览器打开 `http://127.0.0.1:8765/`。
4. 关闭 PowerShell 窗口停止服务。

无需安装 Python、Node.js、Java 或数据库。仅用于有权限管理的内网设备。品牌识别为启发式判断，不能保证识别所有 OEM 设备。

## 规划中的功能
完整 ONVIF Profiles/Media URI、设备类型识别、IP 冲突与空闲地址检查、VLAN/跨网段排障、项目台账、拓扑记录、更多厂商特征。
