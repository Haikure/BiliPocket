package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ==================== HTTP 辅助函数 ====================

func writeJSON(w http.ResponseWriter, statusCode int, data interface{}) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(statusCode)
	encoder := json.NewEncoder(w)
	encoder.SetEscapeHTML(false)
	encoder.Encode(data)
}

func writeError(w http.ResponseWriter, statusCode int, message string) {
	writeJSON(w, statusCode, map[string]interface{}{
		"code":    -1,
		"message": message,
		"data":    nil,
	})
}

func wrapResult(raw json.RawMessage) map[string]interface{} {
	var result map[string]interface{}
	if err := json.Unmarshal(raw, &result); err != nil {
		// 尝试截取首尾 JSON 对象，避免上游返回多余前后缀导致解析失败
		start := bytes.IndexByte(raw, '{')
		end := bytes.LastIndexByte(raw, '}')
		if start >= 0 && end > start {
			trimmed := raw[start : end+1]
			if json.Unmarshal(trimmed, &result) == nil {
				raw = trimmed
			} else {
				logWarn("wrapResult JSON 解析失败: %s, raw=%s", err.Error(), string(raw))
				return map[string]interface{}{
					"code":    -1,
					"message": "上游返回非 JSON",
					"data":    nil,
				}
			}
		} else {
			logWarn("wrapResult JSON 解析失败: %s, raw=%s", err.Error(), string(raw))
			return map[string]interface{}{
				"code":    -1,
				"message": "解析响应失败",
				"data":    nil,
			}
		}
	}

	code := 0
	if c, ok := result["code"].(float64); ok {
		code = int(c)
	}
	message := ""
	if m, ok := result["message"].(string); ok {
		message = m
	}
	var data interface{}
	if d, ok := result["data"]; ok {
		data = d
	}

	return map[string]interface{}{
		"code":    code,
		"message": message,
		"data":    data,
	}
}

func joinIntParams(values []int) string {
	parts := make([]string, 0, len(values))
	for _, v := range values {
		if v > 0 {
			parts = append(parts, strconv.Itoa(v))
		}
	}
	return strings.Join(parts, ",")
}

func intParam(val string, min int, defaultVal int, hasMin bool) (int, error) {
	if val == "" {
		return defaultVal, nil
	}
	n, err := strconv.Atoi(val)
	if err != nil {
		return 0, fmt.Errorf("参数必须为整数，收到: %s", val)
	}
	if hasMin && n < min {
		return 0, fmt.Errorf("参数不得小于 %d，收到: %d", min, n)
	}
	return n, nil
}

func getIntQuery(w http.ResponseWriter, q url.Values, name string, min, def int, hasMin bool) (int, bool) {
	n, err := intParam(q.Get(name), min, def, hasMin)
	if err != nil {
		writeError(w, 400, err.Error())
		return 0, false
	}
	return n, true
}

func requireIntQuery(w http.ResponseWriter, q url.Values, name string) (int, bool) {
	v, ok := getIntQuery(w, q, name, 1, 0, true)
	if !ok {
		return 0, false
	}
	if v == 0 {
		logWarn("%s 缺失", name)
		writeError(w, 400, name+" 为必填参数")
		return 0, false
	}
	return v, true
}

func requireInt64Query(w http.ResponseWriter, q url.Values, name string) (int64, bool) {
	raw := strings.TrimSpace(q.Get(name))
	if raw == "" {
		logWarn("%s 缺失", name)
		writeError(w, 400, name+" 为必填参数")
		return 0, false
	}
	v, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		writeError(w, 400, fmt.Sprintf("参数必须为整数，收到: %s", raw))
		return 0, false
	}
	if v < 1 {
		writeError(w, 400, fmt.Sprintf("参数不得小于 1，收到: %d", v))
		return 0, false
	}
	return v, true
}

func getInt64Query(q url.Values, names ...string) int64 {
	for _, name := range names {
		if val := q.Get(name); val != "" {
			if v, err := strconv.ParseInt(val, 10, 64); err == nil {
				return v
			}
		}
	}
	return 0
}

func getPageParams(w http.ResponseWriter, q url.Values, defaultPS int) (pn, ps int, ok bool) {
	pn, ok = getIntQuery(w, q, "pn", 1, 1, true)
	if !ok {
		return 0, 0, false
	}
	ps, ok = getIntQuery(w, q, "ps", 1, defaultPS, true)
	if !ok {
		return 0, 0, false
	}
	return pn, ps, true
}

func normalizeSubtitleColorPreset(value string) string {
	switch value {
	case "white", "yellow", "cyan", "black":
		return value
	default:
		return "white"
	}
}

func subtitleStyleParamsFromRequest(w http.ResponseWriter, q url.Values) (fontSize int, marginV int, spacing float64, weight int, colorPreset string, outlineEnabled bool, outlineWidth int, backgroundEnabled bool, backgroundOpacity float64, ok bool) {
	fontSize, err := intParam(q.Get("font_size"), 6, 10, true)
	if err != nil {
		writeError(w, 400, err.Error())
		return 0, 0, 0, 0, "", false, 0, false, 0, false
	}
	marginV, err = intParam(q.Get("margin_v"), 0, 2, false)
	if err != nil {
		writeError(w, 400, err.Error())
		return 0, 0, 0, 0, "", false, 0, false, 0, false
	}
	spacing, err = floatParam(q.Get("spacing"), 2.0)
	if err != nil {
		writeError(w, 400, err.Error())
		return 0, 0, 0, 0, "", false, 0, false, 0, false
	}
	weight, err = intParam(q.Get("weight"), 100, 700, true)
	if err != nil {
		writeError(w, 400, err.Error())
		return 0, 0, 0, 0, "", false, 0, false, 0, false
	}
	if weight > 900 {
		weight = 900
	}
	colorPreset = normalizeSubtitleColorPreset(q.Get("color_preset"))
	outlineFlag, err := intParam(q.Get("outline_enabled"), 0, 0, true)
	if err != nil {
		writeError(w, 400, err.Error())
		return 0, 0, 0, 0, "", false, 0, false, 0, false
	}
	outlineEnabled = outlineFlag != 0
	outlineWidth, err = intParam(q.Get("outline_width"), 1, 1, true)
	if err != nil {
		writeError(w, 400, err.Error())
		return 0, 0, 0, 0, "", false, 0, false, 0, false
	}
	if outlineWidth > 6 {
		outlineWidth = 6
	}
	backgroundFlag, err := intParam(q.Get("background_enabled"), 0, 0, true)
	if err != nil {
		writeError(w, 400, err.Error())
		return 0, 0, 0, 0, "", false, 0, false, 0, false
	}
	backgroundEnabled = backgroundFlag != 0
	backgroundOpacity, err = floatParam(q.Get("background_opacity"), 0.5)
	if err != nil {
		writeError(w, 400, err.Error())
		return 0, 0, 0, 0, "", false, 0, false, 0, false
	}
	if backgroundOpacity < 0 {
		backgroundOpacity = 0
	}
	if backgroundOpacity > 1 {
		backgroundOpacity = 1
	}
	return fontSize, marginV, spacing, weight, colorPreset, outlineEnabled, outlineWidth, backgroundEnabled, backgroundOpacity, true
}

func writeJSONBytes(w http.ResponseWriter, statusCode int, data []byte) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(statusCode)
	_, _ = w.Write(data)
}

func handleAPI(w http.ResponseWriter, action string, call func(*BilibiliClient) (json.RawMessage, error)) {
	result, err := call(getClient())
	if err != nil {
		logError("处理 %s 请求失败: %s", action, err.Error())
		writeError(w, 500, err.Error())
		return
	}

	trimmed := bytes.TrimSpace(result)
	if len(trimmed) > 0 && trimmed[0] == '{' && trimmed[len(trimmed)-1] == '}' && json.Valid(trimmed) {
		writeJSONBytes(w, 200, trimmed)
		return
	}

	writeJSON(w, 200, wrapResult(result))
}

// ==================== 全局客户端 ====================

var globalClient *BilibiliClient

// 统一使用服务器端持久化的登录态，不接受客户端传入 Cookie
func getClient() *BilibiliClient {
	return globalClient
}

// ==================== 日志中间件 ====================

// loggingResponseWriter 仅缓存响应体的前 N 字节，用于从业务层 JSON 中
// 提取 code 字段写入访问日志，避免把整个响应（可能数 MB）保留在内存中。
type loggingResponseWriter struct {
	http.ResponseWriter
	statusCode  int
	bodyHead    []byte
	headBudget  int
	wroteHeader bool
}

func (lrw *loggingResponseWriter) Write(b []byte) (int, error) {
	if !lrw.wroteHeader {
		lrw.wroteHeader = true
	}
	if lrw.headBudget > 0 {
		n := lrw.headBudget
		if n > len(b) {
			n = len(b)
		}
		lrw.bodyHead = append(lrw.bodyHead, b[:n]...)
		lrw.headBudget -= n
	}
	return lrw.ResponseWriter.Write(b)
}

func (lrw *loggingResponseWriter) WriteHeader(code int) {
	if lrw.wroteHeader {
		return
	}
	lrw.wroteHeader = true
	lrw.statusCode = code
	lrw.ResponseWriter.WriteHeader(code)
}

// Flush 透传给底层 ResponseWriter（如果支持），便于 SSE / 流式响应
func (lrw *loggingResponseWriter) Flush() {
	if f, ok := lrw.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// Unwrap 让 http.ResponseController 能穿透中间件链，
// 例如合并接口需要按请求清除服务级 WriteTimeout。
func (lrw *loggingResponseWriter) Unwrap() http.ResponseWriter {
	return lrw.ResponseWriter
}

const loggingHeadBudget = 512

// loggingRWPool 复用 loggingResponseWriter，避免每个请求都做一次 heap 分配。
// bodyHead 预分配到 loggingHeadBudget 上限，下次请求 reset 到长度 0，cap 不变。
var loggingRWPool = sync.Pool{
	New: func() any {
		return &loggingResponseWriter{
			bodyHead: make([]byte, 0, loggingHeadBudget),
		}
	},
}

func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		startTime := time.Now()

		if accessLogEnabled {
			params := make(map[string]string)
			for k, v := range r.URL.Query() {
				if len(v) > 0 {
					params[k] = v[0]
				}
			}
			logRequest(r.Method, r.URL.Path, params)
		}

		lrw := loggingRWPool.Get().(*loggingResponseWriter)
		lrw.ResponseWriter = w
		lrw.statusCode = 200
		lrw.bodyHead = lrw.bodyHead[:0]
		lrw.headBudget = loggingHeadBudget
		lrw.wroteHeader = false

		next.ServeHTTP(lrw, r)

		duration := time.Since(startTime)

		code := extractResponseCodeFromHead(lrw.bodyHead)
		statusCode := lrw.statusCode
		contentType := lrw.Header().Get("Content-Type")
		if code == -1 && statusCode >= 200 && statusCode < 300 &&
			!isJSONContentType(contentType) {
			code = 0
		}

		// 释放前清空对外引用，避免 sync.Pool 持续持有 ResponseWriter / 上层资源。
		lrw.ResponseWriter = nil
		loggingRWPool.Put(lrw)

		logResponse(r.URL.Path, code, duration)
	})
}

// recoverMiddleware 在 handler panic 时返回 500 而不是让连接被强制断开，
// 同时避免单个请求 panic 拖垮整个进程的 goroutine 监控信息。
func recoverMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				// 客户端连接关闭引发的 ErrAbortHandler 直接重新抛出，让 net/http 自行处理
				if rec == http.ErrAbortHandler {
					panic(rec)
				}
				stack := debug.Stack()
				logError("处理请求时 panic: %s %s err=%v\n%s", r.Method, r.URL.Path, rec, string(stack))

				// 若已写过 header 则只能放弃 —— 双重保险防止再次 panic
				defer func() { _ = recover() }()
				writeError(w, http.StatusInternalServerError, "internal server error")
			}
		}()
		next.ServeHTTP(w, r)
	})
}
