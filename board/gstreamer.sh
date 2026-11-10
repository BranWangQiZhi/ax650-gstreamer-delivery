# GStreamer 1.22.12 运行环境（third-party/gstreamer 交叉编译产物）
# 部署路径: /etc/profile.d/gstreamer.sh
# 注意: 必须 source 本文件, whip_push 才能找到 glibc 兼容层与插件目录
export PATH=/usr/local/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
export LD_PRELOAD=/usr/local/lib/libglibc230_compat.so
export GST_PLUGIN_SYSTEM_PATH=/usr/local/lib/gstreamer-1.0
export GST_PLUGIN_SCANNER=/usr/local/libexec/gstreamer-1.0/gst-plugin-scanner
export GST_REGISTRY=/usr/local/var/gst-registry.bin
