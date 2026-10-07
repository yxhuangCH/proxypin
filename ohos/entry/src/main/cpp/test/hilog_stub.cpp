// 本地测试用 hilog 桩：剥掉 %{public}/%{private} 前缀后按普通 printf 输出，便于看隧道日志
#include <cstdarg>
#include <cstdio>
#include <string>

#include "hilog/log.h"

int OH_LOG_Print(LogType type, LogLevel level, unsigned int domain, const char *tag, const char *fmt, ...) {
    (void)type;
    (void)domain;
    std::string cleaned;
    for (const char *p = fmt; *p != '\0';) {
        if (p[0] == '%' && p[1] == '{') {
            const char *end = p + 2;
            while (*end != '\0' && *end != '}') {
                end++;
            }
            if (*end == '}') {
                cleaned.push_back('%');  // 保留转换符，仅去掉 {public}/{private} 前缀
                p = end + 1;
                continue;
            }
        }
        cleaned.push_back(*p++);
    }
    const char *level_name = level >= LOG_ERROR ? "E" : (level >= LOG_WARN ? "W" : "I");
    fprintf(stderr, "%s/%s: ", level_name, tag);
    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, cleaned.c_str(), args);
    va_end(args);
    fprintf(stderr, "\n");
    return 0;
}
