package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// ==================== 日志工具 ====================

const (
	colorReset   = "\x1b[0m"
	colorBright  = "\x1b[1m"
	colorDim     = "\x1b[2m"
	colorRed     = "\x1b[31m"
	colorGreen   = "\x1b[32m"
	colorYellow  = "\x1b[33m"
	colorBlue    = "\x1b[34m"
	colorMagenta = "\x1b[35m"
	colorCyan    = "\x1b[36m"

	asyncLogDefaultQueueSize = 1024
	asyncLogMaxQueueSize     = 65536
	asyncLogBufferSize       = 64 * 1024
	asyncLogFlushSize        = 32 * 1024
	asyncLogFlushInterval    = 200 * time.Millisecond
	asyncLogShutdownTimeout  = 2 * time.Second
)

var (
	debugEnabled     = os.Getenv("DEBUG") == "true"
	accessLogEnabled = debugEnabled || os.Getenv("ACCESS_LOG") == "true"
	asyncLogCh       = make(chan string, asyncLogQueueSize())
	asyncLogFlushCh  = make(chan chan struct{})
	asyncLogDropped  atomic.Uint64
	wbiValueReplacer = strings.NewReplacer("!", "", "'", "", "(", "", ")", "", "*", "")
)

func init() {
	go asyncLogWriter()
}

func getTimestamp() string {
	return time.Now().Format("2006-01-02 15:04:05")
}

func asyncLogQueueSize() int {
	raw := strings.TrimSpace(os.Getenv("LOG_QUEUE_SIZE"))
	if raw == "" {
		return asyncLogDefaultQueueSize
	}

	size, err := strconv.Atoi(raw)
	if err != nil || size <= 0 {
		return asyncLogDefaultQueueSize
	}
	if size > asyncLogMaxQueueSize {
		return asyncLogMaxQueueSize
	}
	return size
}

func asyncLogWriter() {
	writer := bufio.NewWriterSize(os.Stdout, asyncLogBufferSize)
	ticker := time.NewTicker(asyncLogFlushInterval)
	defer ticker.Stop()

	writeDropped := func() {
		if dropped := asyncLogDropped.Swap(0); dropped > 0 {
			_, _ = fmt.Fprintf(writer, "%s[WARN]%s %s%s%s 日志队列已满，丢弃 %d 条日志\n",
				colorYellow, colorReset, colorDim, getTimestamp(), colorReset, dropped)
		}
	}

	writeLine := func(line string) {
		writeDropped()
		_, _ = writer.WriteString(line)
		if writer.Buffered() >= asyncLogFlushSize {
			_ = writer.Flush()
		}
	}

	flush := func() {
		writeDropped()
		_ = writer.Flush()
	}

	for {
		select {
		case line := <-asyncLogCh:
			writeLine(line)
		case done := <-asyncLogFlushCh:
			for {
				select {
				case line := <-asyncLogCh:
					writeLine(line)
				default:
					flush()
					close(done)
					done = nil
				}
				if done == nil {
					break
				}
			}
		case <-ticker.C:
			flush()
		}
	}
}

func enqueueLogLine(line string) {
	select {
	case asyncLogCh <- line:
	default:
		asyncLogDropped.Add(1)
	}
}

func asyncLogFlush(timeout time.Duration) bool {
	done := make(chan struct{})
	timer := time.NewTimer(timeout)
	defer timer.Stop()

	select {
	case asyncLogFlushCh <- done:
	case <-timer.C:
		return false
	}

	select {
	case <-done:
		return true
	case <-timer.C:
		return false
	}
}

func logPlain(message string) {
	enqueueLogLine(message + "\n")
}

func logInfo(message string, args ...interface{}) {
	if !debugEnabled {
		return
	}
	msg := fmt.Sprintf(message, args...)
	enqueueLogLine(fmt.Sprintf("%s[INFO]%s %s%s%s %s\n", colorCyan, colorReset, colorDim, getTimestamp(), colorReset, msg))
}

func logSuccess(message string, args ...interface{}) {
	msg := fmt.Sprintf(message, args...)
	enqueueLogLine(fmt.Sprintf("%s[SUCCESS]%s %s%s%s %s\n", colorGreen, colorReset, colorDim, getTimestamp(), colorReset, msg))
}

func logWarn(message string, args ...interface{}) {
	msg := fmt.Sprintf(message, args...)
	enqueueLogLine(fmt.Sprintf("%s[WARN]%s %s%s%s %s\n", colorYellow, colorReset, colorDim, getTimestamp(), colorReset, msg))
}

func logError(message string, args ...interface{}) {
	msg := fmt.Sprintf(message, args...)
	enqueueLogLine(fmt.Sprintf("%s[ERROR]%s %s%s%s %s\n", colorRed, colorReset, colorDim, getTimestamp(), colorReset, msg))
}

func logDebug(message string, args ...interface{}) {
	if !debugEnabled {
		return
	}
	msg := fmt.Sprintf(message, args...)
	enqueueLogLine(fmt.Sprintf("%s[DEBUG]%s %s%s%s %s\n", colorMagenta, colorReset, colorDim, getTimestamp(), colorReset, msg))
}

func logRequest(method, path string, params map[string]string) {
	paramStr := ""
	if accessLogEnabled && len(params) > 0 {
		b, _ := json.Marshal(params)
		paramStr = string(b)
	}
	enqueueLogLine(fmt.Sprintf("%s[REQUEST]%s %s%s%s %s%s%s %s %s%s%s\n",
		colorBlue, colorReset, colorDim, getTimestamp(), colorReset,
		colorBright, method, colorReset, path, colorDim, paramStr, colorReset))
}

func logResponse(path string, code int, duration time.Duration) {
	if !accessLogEnabled && code == 0 {
		return
	}
	color := colorGreen
	if code != 0 {
		color = colorRed
	}
	enqueueLogLine(fmt.Sprintf("%s[RESPONSE]%s %s%s%s %s %scode=%d%s %s(%dms)%s\n",
		color, colorReset, colorDim, getTimestamp(), colorReset,
		path, color, code, colorReset, colorDim, duration.Milliseconds(), colorReset))
}
