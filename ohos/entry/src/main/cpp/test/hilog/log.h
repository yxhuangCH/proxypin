#ifndef STUB_HILOG_LOG_H
#define STUB_HILOG_LOG_H
typedef enum { LOG_DEBUG = 3, LOG_INFO = 4, LOG_WARN = 5, LOG_ERROR = 6, LOG_FATAL = 7 } LogLevel;
typedef enum { LOG_APP = 0 } LogType;
int OH_LOG_Print(LogType type, LogLevel level, unsigned int domain, const char *tag, const char *fmt, ...);
#endif
