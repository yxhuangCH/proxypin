# 鸿蒙 VPN 隧道 napi 模块（路线 A PoC）
# 实施文档：harmony/docs/09-应用白名单与VPN路线实施.md
cmake_minimum_required(VERSION 3.5.0)
project(proxypin_vpntunnel)

add_library(vpntunnel SHARED napi_init.cpp)

target_link_libraries(vpntunnel PUBLIC libace_napi.z.so libhilog_ndk.z.so)
