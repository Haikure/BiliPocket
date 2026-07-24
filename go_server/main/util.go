package main

import (
	"bytes"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ==================== 工具函数 ====================

// mixinKeyConcat 直接基于两个字符串视图按 MIXIN_KEY_ENC_TAB 挑选最多 32 字节，
// 既避免了 `imgKey + subKey` 这次 64 字节左右的拼接分配，也用栈上 [32]byte
// 替代了 strings.Builder。结果与 "原拼接后取 i 字节、最后截到 32" 完全等价。
func mixinKeyConcat(a, b string) string {
	var buf [32]byte
	n := 0
	total := len(a) + len(b)
	for _, idx := range MIXIN_KEY_ENC_TAB {
		if idx >= total {
			continue
		}
		var ch byte
		if idx < len(a) {
			ch = a[idx]
		} else {
			ch = b[idx-len(a)]
		}
		buf[n] = ch
		n++
		if n == 32 {
			break
		}
	}
	return string(buf[:n])
}

// md5HashBytes 用 md5.Sum 直接拿到 [16]byte，再 hex.Encode 到栈上 [32]byte，
// 最后只产生一次 string 分配；旧版 hex.EncodeToString(h.Sum(nil)) 会多一次
// []byte 分配，并且 md5.New() 是堆对象。
func md5HashBytes(b []byte) string {
	sum := md5.Sum(b)
	var dst [32]byte
	hex.Encode(dst[:], sum[:])
	return string(dst[:])
}

// keysPool 复用 sortedKeysInto 用到的 []string，避免每次签名/查询都 alloc。
var keysPool = sync.Pool{
	New: func() any {
		s := make([]string, 0, 16)
		return &s
	},
}

// queryBufPool 复用查询构造与签名拼接用到的 bytes.Buffer。
// 这里不用 strings.Builder：Builder.Reset 会丢掉底层 buffer，无法真正复用，
// bytes.Buffer.Reset 只把长度归零，能重复利用底层数组。
var queryBufPool = sync.Pool{
	New: func() any { return new(bytes.Buffer) },
}

func acquireQueryBuf() *bytes.Buffer {
	return queryBufPool.Get().(*bytes.Buffer)
}

func releaseQueryBuf(b *bytes.Buffer) {
	if b.Cap() > 16<<10 {
		// 防止偶发的大 payload 让池长期持有大内存
		return
	}
	b.Reset()
	queryBufPool.Put(b)
}

func releaseKeys(p *[]string) {
	if cap(*p) > 64 {
		// 容量过大不放回池，避免拖累其它请求
		return
	}
	*p = (*p)[:0]
	keysPool.Put(p)
}

// sortedKeysInto 把 params 的 key 排序后写入 *p 指向的切片，必要时扩容。
// 调用方必须把 p 释放回 keysPool（用 releaseKeys）。
func sortedKeysInto(p *[]string, params map[string]string) []string {
	s := *p
	if cap(s) < len(params) {
		s = make([]string, 0, len(params))
	} else {
		s = s[:0]
	}
	for k := range params {
		s = append(s, k)
	}
	sort.Strings(s)
	*p = s
	return s
}

// writeSortedQuery 按已排序好的 keys，把 url.QueryEscape 后的 k=v&... 写入 buf。
func writeSortedQuery(buf *bytes.Buffer, params map[string]string, keys []string) {
	for i, k := range keys {
		if i > 0 {
			buf.WriteByte('&')
		}
		buf.WriteString(url.QueryEscape(k))
		buf.WriteByte('=')
		buf.WriteString(url.QueryEscape(params[k]))
	}
}

func buildSortedQuery(params map[string]string) string {
	if len(params) == 0 {
		return ""
	}
	pk := keysPool.Get().(*[]string)
	keys := sortedKeysInto(pk, params)
	buf := acquireQueryBuf()
	writeSortedQuery(buf, params, keys)
	out := buf.String()
	releaseQueryBuf(buf)
	releaseKeys(pk)
	return out
}

func encWbi(params map[string]string, imgKey, subKey string) map[string]string {
	mixinKey := mixinKeyConcat(imgKey, subKey)
	params["wts"] = strconv.FormatInt(time.Now().Unix(), 10)

	pk := keysPool.Get().(*[]string)
	keys := sortedKeysInto(pk, params)

	filtered := make(map[string]string, len(params)+1)
	buf := acquireQueryBuf()
	for i, k := range keys {
		v := wbiValueReplacer.Replace(params[k])
		filtered[k] = v
		if i > 0 {
			buf.WriteByte('&')
		}
		buf.WriteString(url.QueryEscape(k))
		buf.WriteByte('=')
		buf.WriteString(url.QueryEscape(v))
	}
	// 直接把 mixinKey 追加到 buffer，避免 builder.String() + mixinKey
	// 这次额外的 string 分配（query 串可能上百字节）。
	buf.WriteString(mixinKey)
	wbiSign := md5HashBytes(buf.Bytes())

	releaseQueryBuf(buf)
	releaseKeys(pk)

	filtered["w_rid"] = wbiSign

	if debugEnabled && len(mixinKey) >= 8 && len(wbiSign) >= 8 {
		logDebug("WBI 签名计算 mixinKey=%s... w_rid=%s...", mixinKey[:8], wbiSign[:8])
	}

	return filtered
}

func signAppParams(params map[string]string, appKey, appSec string) map[string]string {
	params["appkey"] = appKey
	if params["ts"] == "" {
		params["ts"] = strconv.FormatInt(time.Now().Unix(), 10)
	}

	pk := keysPool.Get().(*[]string)
	keys := sortedKeysInto(pk, params)
	buf := acquireQueryBuf()
	writeSortedQuery(buf, params, keys)
	// 同 encWbi：直接在原 buffer 上拼接 appSec，避免再分配一个 string。
	buf.WriteString(appSec)
	sign := md5HashBytes(buf.Bytes())

	releaseQueryBuf(buf)
	releaseKeys(pk)

	params["sign"] = sign
	return params
}

func appSign(params map[string]string) map[string]string {
	return signAppParams(params, APPKEY, APPSEC)
}

func piliPlusAppSign(params map[string]string) map[string]string {
	return signAppParams(params, piliPlusAppKey, piliPlusAppSec)
}

func maskSensitive(value string) string {
	if value == "" {
		return ""
	}
	if len(value) <= 8 {
		return value
	}
	return value[:4] + "..." + value[len(value)-4:]
}

func extractResponseCodeFromHead(head []byte) int {
	if len(head) == 0 {
		return -1
	}

	pattern := []byte(`"code"`)
	idx := bytes.Index(head, pattern)
	if idx < 0 {
		return -1
	}

	rest := head[idx+len(pattern):]
	colon := bytes.IndexByte(rest, ':')
	if colon < 0 {
		return -1
	}
	rest = bytes.TrimSpace(rest[colon+1:])
	if len(rest) == 0 {
		return -1
	}

	pos := 0
	sign := 1
	if rest[0] == '-' {
		sign = -1
		pos = 1
	}
	if pos >= len(rest) || rest[pos] < '0' || rest[pos] > '9' {
		return -1
	}
	// 内联整数解析，避免 strconv.Atoi 接受 string 时产生的 []byte→string 拷贝。
	val := 0
	for pos < len(rest) && rest[pos] >= '0' && rest[pos] <= '9' {
		// 业务 code 都在 ±10^6 量级，1<<30 已足够防御异常输入造成的溢出
		if val > 1<<30 {
			return -1
		}
		val = val*10 + int(rest[pos]-'0')
		pos++
	}
	return val * sign
}

func isJSONContentType(contentType string) bool {
	contentType = strings.ToLower(strings.TrimSpace(contentType))
	if contentType == "" {
		return false
	}
	return strings.Contains(contentType, "application/json") || strings.Contains(contentType, "+json")
}

func limitLogBody(body []byte) string {
	const maxLen = 300
	s := string(body)
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen] + "..."
}

func logUpstreamBusinessError(apiURL string, body []byte) {
	code := extractResponseCodeFromHead(body)
	if code == -1 || code == 0 {
		return
	}

	msg := ""
	if debugEnabled || code != 0 {
		var resp struct {
			Message string `json:"message"`
			Msg     string `json:"msg"`
		}
		if err := json.Unmarshal(body, &resp); err == nil {
			msg = resp.Message
			if msg == "" {
				msg = resp.Msg
			}
		}
	}

	logWarn("上游业务错误 url=%s code=%d message=%s body=%s", apiURL, code, msg, limitLogBody(body))
}

func extractKeyFromURL(rawURL string) string {
	if rawURL == "" {
		return ""
	}
	parts := strings.Split(rawURL, "/")
	filename := parts[len(parts)-1]
	dotParts := strings.Split(filename, ".")
	return dotParts[0]
}
