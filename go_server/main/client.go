package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/time/rate"
)

func (c *BilibiliClient) loadSnapshot() *clientSnapshot {
	s := c.snapshot.Load()
	if s == nil {
		return &emptyClientSnapshot
	}
	return s
}

// rebuildSnapshotLocked 必须在持有 c.mu 写锁时调用：根据当前字段构造新的快照
// 并通过 atomic.Pointer 原子发布，使读路径立即看到最新值。
func (c *BilibiliClient) rebuildSnapshotLocked() {
	s := &clientSnapshot{
		sessdata:        c.sessdata,
		buvid3:          c.buvid3,
		biliJct:         c.biliJct,
		dedeUserID:      c.dedeUserID,
		dedeUserIDCkMd5: c.dedeUserIDCkMd5,
		refreshToken:    c.refreshToken,
		biliTicket:      c.biliTicket,
		imgKey:          c.imgKey,
		subKey:          c.subKey,
	}
	s.cookie = buildCookieString(s)
	c.snapshot.Store(s)
}

func (c *BilibiliClient) rebuildSnapshot() {
	c.mu.Lock()
	c.rebuildSnapshotLocked()
	c.mu.Unlock()
}

// buildCookieString 根据快照字段拼出 Cookie 头值。各字段为空时跳过。
// 这一步在写路径完成，读路径直接读结果，省掉每次请求的 6 段拼接 + Join。
func buildCookieString(s *clientSnapshot) string {
	// 估算容量，避免 strings.Builder 内部多次扩容
	estimate := 0
	add := func(name, value string) {
		if value == "" {
			return
		}
		if estimate > 0 {
			estimate += 2 // "; "
		}
		estimate += len(name) + 1 + len(value)
	}
	add("SESSDATA", s.sessdata)
	add("buvid3", s.buvid3)
	add("bili_jct", s.biliJct)
	add("DedeUserID", s.dedeUserID)
	add("DedeUserID__ckMd5", s.dedeUserIDCkMd5)
	add("bili_ticket", s.biliTicket)
	if estimate == 0 {
		return ""
	}

	var sb strings.Builder
	sb.Grow(estimate)
	first := true
	appendC := func(name, value string) {
		if value == "" {
			return
		}
		if !first {
			sb.WriteString("; ")
		} else {
			first = false
		}
		sb.WriteString(name)
		sb.WriteByte('=')
		sb.WriteString(value)
	}
	appendC("SESSDATA", s.sessdata)
	appendC("buvid3", s.buvid3)
	appendC("bili_jct", s.biliJct)
	appendC("DedeUserID", s.dedeUserID)
	appendC("DedeUserID__ckMd5", s.dedeUserIDCkMd5)
	appendC("bili_ticket", s.biliTicket)
	return sb.String()
}

// loadCookieStore 把磁盘持久化的 CookieStore 写入 client，并立即发布快照。
// 仅在 main() 启动时由单线程调用一次。
func (c *BilibiliClient) loadCookieStore(cs CookieStore) {
	c.mu.Lock()
	c.sessdata = cs.Sessdata
	c.buvid3 = cs.Buvid3
	c.biliJct = cs.BiliJct
	c.dedeUserID = cs.DedeUserID
	c.dedeUserIDCkMd5 = cs.DedeUserIDCkMd5
	c.refreshToken = cs.RefreshToken
	c.rebuildSnapshotLocked()
	c.mu.Unlock()
}

func (c *BilibiliClient) getWbiKeys() (string, string) {
	s := c.loadSnapshot()
	return s.imgKey, s.subKey
}

func (c *BilibiliClient) setWbiKeys(imgKey, subKey string) {
	c.mu.Lock()
	c.imgKey = imgKey
	c.subKey = subKey
	c.rebuildSnapshotLocked()
	c.mu.Unlock()
}

func (c *BilibiliClient) getBiliTicket() string {
	return c.loadSnapshot().biliTicket
}

func (c *BilibiliClient) setBiliTicket(ticket string) {
	c.mu.Lock()
	c.biliTicket = ticket
	c.rebuildSnapshotLocked()
	c.mu.Unlock()
}

func (c *BilibiliClient) UpdateAuth(sessdata, buvid3, biliJct, refreshToken, dedeUserID, dedeUserIDCkMd5 string) {
	c.mu.Lock()

	changed := false
	if sessdata != "" && sessdata != c.sessdata {
		c.sessdata = sessdata
		changed = true
	}
	if buvid3 != "" && buvid3 != c.buvid3 {
		c.buvid3 = buvid3
		changed = true
	}
	if biliJct != "" && biliJct != c.biliJct {
		c.biliJct = biliJct
		changed = true
	}
	if dedeUserID != "" && dedeUserID != c.dedeUserID {
		c.dedeUserID = dedeUserID
		changed = true
	}
	if dedeUserIDCkMd5 != "" && dedeUserIDCkMd5 != c.dedeUserIDCkMd5 {
		c.dedeUserIDCkMd5 = dedeUserIDCkMd5
		changed = true
	}
	if refreshToken != "" && refreshToken != c.refreshToken {
		c.refreshToken = refreshToken
		changed = true
	}

	// 在锁内先快照，磁盘 IO 放到锁外，避免 saveCookies 期间阻塞所有读路径
	var snapshot CookieStore
	if changed {
		c.rebuildSnapshotLocked()
		snapshot = CookieStore{
			Sessdata:        c.sessdata,
			Buvid3:          c.buvid3,
			BiliJct:         c.biliJct,
			DedeUserID:      c.dedeUserID,
			DedeUserIDCkMd5: c.dedeUserIDCkMd5,
			RefreshToken:    c.refreshToken,
		}
	}
	c.mu.Unlock()

	if !changed {
		return
	}
	if err := saveCookies(snapshot); err != nil {
		logWarn("Cookie 持久化失败: %s", err.Error())
	} else {
		logInfo("已更新并持久化全局 Cookie")
	}
}

// 清理登录状态（仅在明确认证失效时调用）
func (c *BilibiliClient) ClearAuth() {
	c.mu.Lock()
	c.sessdata = ""
	c.buvid3 = ""
	c.biliJct = ""
	c.dedeUserID = ""
	c.dedeUserIDCkMd5 = ""
	c.refreshToken = ""
	c.rebuildSnapshotLocked()
	c.mu.Unlock()

	if err := saveCookies(CookieStore{}); err != nil {
		logWarn("清理 Cookie 持久化失败: %s", err.Error())
	} else {
		logInfo("已清理登录状态并持久化")
	}
}

// ==================== Bilibili API 客户端 ====================

// clientSnapshot 是 BilibiliClient 在某一时刻的只读快照，包含每次请求都需要读
// 的认证字段、WBI keys、bili_ticket，以及预先拼接好的 Cookie 字符串。
// 写路径在持有 BilibiliClient.mu 的情况下重建快照后通过 atomic.Pointer 原子替换；
// 读路径完全无锁，避免 setHeaders/buildCookie/getWbiKeys 在每次上游请求都做
// RWMutex.RLock 与字符串 Join。
type clientSnapshot struct {
	sessdata        string
	buvid3          string
	biliJct         string
	dedeUserID      string
	dedeUserIDCkMd5 string
	refreshToken    string
	biliTicket      string
	imgKey          string
	subKey          string
	cookie          string // 预先拼好的 Cookie 头值，供 setHeaders 直接使用
}

// emptyClientSnapshot 在 atomic.Pointer 还未首次发布时充当 zero-value 视图，
// 让 loadSnapshot 始终返回非 nil 指针，省掉每次读路径的 nil 检查分支。
var emptyClientSnapshot clientSnapshot

type BilibiliClient struct {
	mu              sync.RWMutex
	readLimiter     *rate.Limiter
	writeLimiter    *rate.Limiter
	sessdata        string
	buvid3          string
	biliJct         string
	dedeUserID      string
	dedeUserIDCkMd5 string
	refreshToken    string
	biliTicket      string
	imgKey          string
	subKey          string
	httpClient      *http.Client
	snapshot        atomic.Pointer[clientSnapshot]
}

// waitBeforeUpstream 对上游请求做分桶令牌桶限速：
//   - GET 读取类请求：稳态 ~33 rps（每 30ms 一个令牌），burst 5，
//     让同一页面的聚合读请求在空闲后能并发放出，而不是被串成 30ms 阶梯。
//   - 非 GET 写请求：稳态 ~5 rps（每 200ms 一个令牌），burst 2，降低触发风控概率。
//
// 令牌桶长期平均速率与旧漏桶一致，仅新增突发额度；ctx 取消时立即返回。
func (c *BilibiliClient) waitBeforeUpstream(ctx context.Context, method string) error {
	lim := c.readLimiter
	if method != http.MethodGet {
		lim = c.writeLimiter
	}
	return lim.Wait(ctx)
}

func NewBilibiliClient(sessdata, buvid3 string) *BilibiliClient {
	// 自定义 Transport：限制空闲连接、对每个 host 的并发，避免连接堆积/泄漏
	transport := &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: (&net.Dialer{
			Timeout:   8 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          100,
		MaxIdleConnsPerHost:   16,
		MaxConnsPerHost:       64,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
		ResponseHeaderTimeout: 10 * time.Second,
	}
	c := &BilibiliClient{
		sessdata:     sessdata,
		buvid3:       buvid3,
		readLimiter:  rate.NewLimiter(rate.Every(30*time.Millisecond), 5),
		writeLimiter: rate.NewLimiter(rate.Every(200*time.Millisecond), 2),
		httpClient: &http.Client{
			Timeout:   15 * time.Second,
			Transport: transport,
		},
	}
	// 发布初始快照，确保所有读路径在第一次请求前就能拿到非空 snapshot。
	c.rebuildSnapshot()
	return c
}

func (c *BilibiliClient) Init() {
	logInfo("初始化 Bilibili 客户端...")
	c.setBiliTicket(getBiliTicket())
	c.updateWbiKeys()
	c.ensureBuvid3()
	c.refreshCookies()
	logSuccess("客户端初始化完成")
}

// buildCookie 直接读取已经预拼接好的快照 cookie 串，
// 避免每次请求都做 RLock + 6 段拼接 + strings.Join。
func (c *BilibiliClient) buildCookie() string {
	return c.loadSnapshot().cookie
}

func (c *BilibiliClient) requireLogin() (string, string, error) {
	sessdata, _, biliJct, _, _, _ := c.getAuth()
	if sessdata == "" || biliJct == "" {
		return "", "", fmt.Errorf("登录信息不完整")
	}
	return sessdata, biliJct, nil
}

func (c *BilibiliClient) requireRiskAuth() (string, string, string, error) {
	sessdata, buvid3, biliJct, _, _, _ := c.getAuth()
	if sessdata == "" || biliJct == "" {
		return "", "", "", fmt.Errorf("登录信息不完整")
	}
	if buvid3 == "" {
		return "", "", "", fmt.Errorf("缺少 buvid3，按文档该字段异常会触发风控")
	}
	return sessdata, buvid3, biliJct, nil
}

func (c *BilibiliClient) setHeaders(req *http.Request) {
	h := req.Header
	h.Set("User-Agent", defaultUserAgent)
	h.Set("Referer", defaultReferer)
	if cookie := c.loadSnapshot().cookie; cookie != "" {
		h.Set("Cookie", cookie)
	}
}

func (c *BilibiliClient) updateWbiKeys() {
	logInfo("正在更新 WBI Keys...")

	req, err := http.NewRequest("GET", "https://api.bilibili.com/x/web-interface/nav", nil)
	if err != nil {
		logError("WBI Keys 请求创建失败: %s", err.Error())
		c.setDefaultWbiKeys()
		return
	}
	c.setHeaders(req)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		logError("WBI Keys 更新异常: %s", err.Error())
		c.setDefaultWbiKeys()
		return
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	var result map[string]interface{}
	if err := json.Unmarshal(body, &result); err != nil {
		logError("WBI Keys 解析失败: %s", err.Error())
		c.setDefaultWbiKeys()
		return
	}

	code, _ := result["code"].(float64)
	if int(code) != 0 {
		msg, _ := result["message"].(string)
		logWarn("WBI Keys 获取失败，使用默认值. 错误: %s", msg)
		c.setDefaultWbiKeys()
		return
	}

	data, _ := result["data"].(map[string]interface{})
	wbiImg, _ := data["wbi_img"].(map[string]interface{})
	imgURL, _ := wbiImg["img_url"].(string)
	subURL, _ := wbiImg["sub_url"].(string)

	imgKey := extractKeyFromURL(imgURL)
	subKey := extractKeyFromURL(subURL)
	c.setWbiKeys(imgKey, subKey)

	imgKeyDisplay := imgKey
	if len(imgKeyDisplay) > 8 {
		imgKeyDisplay = imgKeyDisplay[:8] + "..."
	}
	subKeyDisplay := subKey
	if len(subKeyDisplay) > 8 {
		subKeyDisplay = subKeyDisplay[:8] + "..."
	}
	logSuccess("WBI Keys 更新成功: imgKey=%s subKey=%s", imgKeyDisplay, subKeyDisplay)
}

func (c *BilibiliClient) setDefaultWbiKeys() {
	c.setWbiKeys("7cd084941338484aae1ad9425b84077c", "4932caff0ff746eab6f01bf08b70ac45")
}

func (c *BilibiliClient) ensureBuvid3() {
	_, buvid3, _, _, _, _ := c.getAuth()
	if buvid3 != "" {
		return
	}

	logInfo("buvid3 缺失，尝试获取...")
	req, err := http.NewRequest("GET", "https://www.bilibili.com/", nil)
	if err != nil {
		logWarn("buvid3 请求创建失败: %s", err.Error())
		return
	}
	c.setHeaders(req)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		logWarn("buvid3 请求失败: %s", err.Error())
		return
	}
	defer resp.Body.Close()

	newBuvid3 := ""
	for _, ck := range resp.Cookies() {
		if ck.Name == "buvid3" {
			newBuvid3 = ck.Value
			break
		}
	}
	if newBuvid3 != "" {
		c.UpdateAuth("", newBuvid3, "", "", "", "")
		logInfo("buvid3 获取成功")
	} else {
		logWarn("buvid3 获取失败，响应未包含该字段")
	}
}

func (c *BilibiliClient) doRequest(ctx context.Context, apiURL string, params map[string]string, method string) (json.RawMessage, error) {
	startTime := time.Now()
	query := buildSortedQuery(params)
	fullURL := apiURL
	var bodyReader io.Reader

	switch method {
	case http.MethodGet:
		if query != "" {
			fullURL += "?" + query
		}
	case http.MethodPost:
		bodyReader = strings.NewReader(query)
	default:
		return nil, fmt.Errorf("不支持的请求方法: %s", method)
	}

	req, err := http.NewRequestWithContext(ctx, method, fullURL, bodyReader)
	if err != nil {
		return nil, err
	}
	c.setHeaders(req)
	if method == http.MethodPost {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}

	if err := c.waitBeforeUpstream(ctx, method); err != nil {
		return nil, err
	}
	resp, err := c.httpClient.Do(req)
	duration := time.Since(startTime)
	if err != nil {
		logError("API 请求失败 (%dms): %s", duration.Milliseconds(), err.Error())
		return nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	logDebug("API 响应 %s %s (%dms)", method, apiURL, duration.Milliseconds())
	logUpstreamBusinessError(apiURL, body)
	return json.RawMessage(body), nil
}

func (c *BilibiliClient) wbiRequest(ctx context.Context, apiURL string, params map[string]string, method string) (json.RawMessage, error) {
	imgKey, subKey := c.getWbiKeys()
	logDebug("WBI 请求 %s %s", method, apiURL)
	// encWbi 会向 params 中写入 wts 并返回新的 filtered map，
	// 调用方传入的 map 都是当次请求新建的临时 map，无需 copyMap 复制保护。
	return c.doRequest(ctx, apiURL, encWbi(params, imgKey, subKey), method)
}

func (c *BilibiliClient) request(ctx context.Context, apiURL string, params map[string]string, method string) (json.RawMessage, error) {
	logDebug("普通请求 %s %s", method, apiURL)
	return c.doRequest(ctx, apiURL, params, method)
}

func (c *BilibiliClient) appRequest(ctx context.Context, apiURL string, params map[string]string) (json.RawMessage, error) {
	logDebug("APP请求 GET %s", apiURL)
	params = piliPlusAppSign(params)
	query := buildSortedQuery(params)
	fullURL := apiURL
	if query != "" {
		fullURL += "?" + query
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fullURL, nil)
	if err != nil {
		return nil, err
	}
	c.setHeaders(req)
	req.Header.Del("Cookie")
	req.Header.Set("User-Agent", appUserAgent)
	req.Header.Set("bili-http-engine", "cronet")
	req.Header.Set("env", "prod")
	req.Header.Set("app-key", "android64")
	req.Header.Set("x-bili-aurora-zone", "sh001")
	_, _, _, _, dedeUserID, _ := c.getAuth()
	if dedeUserID != "" {
		req.Header.Set("x-bili-mid", dedeUserID)
	}

	if err := c.waitBeforeUpstream(ctx, http.MethodGet); err != nil {
		return nil, err
	}
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	logUpstreamBusinessError(apiURL, body)
	return json.RawMessage(body), nil
}

func (c *BilibiliClient) rawRequest(ctx context.Context, apiURL string, params map[string]string) ([]byte, error) {
	query := buildSortedQuery(params)
	fullURL := apiURL
	if query != "" {
		if strings.Contains(fullURL, "?") {
			fullURL = fullURL + "&" + query
		} else {
			fullURL = fullURL + "?" + query
		}
	}

	req, err := http.NewRequestWithContext(ctx, "GET", fullURL, nil)
	if err != nil {
		return nil, err
	}
	c.setHeaders(req)

	if err := c.waitBeforeUpstream(ctx, http.MethodGet); err != nil {
		return nil, err
	}
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	return io.ReadAll(resp.Body)
}

func (c *BilibiliClient) rawGetURL(ctx context.Context, fullURL string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", fullURL, nil)
	if err != nil {
		return nil, err
	}
	c.setHeaders(req)

	if err := c.waitBeforeUpstream(ctx, http.MethodGet); err != nil {
		return nil, err
	}
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	return io.ReadAll(resp.Body)
}

func (c *BilibiliClient) webPost(ctx context.Context, apiURL string, params map[string]string) (json.RawMessage, error) {
	query := buildSortedQuery(params)

	var lastErr error
	for attempt := 1; attempt <= 2; attempt++ {
		req, err := http.NewRequestWithContext(ctx, "POST", apiURL, strings.NewReader(query))
		if err != nil {
			return nil, err
		}
		// setHeaders 已经写入 User-Agent / Referer / Cookie，
		// 这里只补 Origin、Content-Type、X-Requested-With 三项 webPost 专属头。
		c.setHeaders(req)
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
		req.Header.Set("Origin", "https://www.bilibili.com")
		req.Header.Set("X-Requested-With", "XMLHttpRequest")

		if err := c.waitBeforeUpstream(ctx, http.MethodPost); err != nil {
			return nil, err
		}
		resp, err := c.httpClient.Do(req)
		if err != nil {
			lastErr = err
			logWarn("webPost 请求失败 attempt=%d url=%s err=%s", attempt, apiURL, err.Error())
			if attempt < 2 {
				select {
				case <-time.After(300 * time.Millisecond):
				case <-ctx.Done():
					return nil, ctx.Err()
				}
				continue
			}
			return nil, err
		}

		body, readErr := io.ReadAll(resp.Body)
		resp.Body.Close()
		if readErr != nil {
			lastErr = readErr
			logWarn("webPost 读取响应失败 attempt=%d url=%s err=%s", attempt, apiURL, readErr.Error())
			if attempt < 2 {
				select {
				case <-time.After(300 * time.Millisecond):
				case <-ctx.Done():
					return nil, ctx.Err()
				}
				continue
			}
			return nil, readErr
		}

		if resp.StatusCode == http.StatusForbidden {
			sessdata, buvid3, biliJct, refreshToken, _, _ := c.getAuth()
			logWarn("webPost 命中403 attempt=%d url=%s sessdata=%t buvid3=%t bili_jct=%t refresh_token=%t body=%s",
				attempt,
				apiURL,
				sessdata != "",
				buvid3 != "",
				biliJct != "",
				refreshToken != "",
				string(body))
			lastErr = fmt.Errorf("HTTP 403 Forbidden")
			if attempt < 2 {
				select {
				case <-time.After(300 * time.Millisecond):
				case <-ctx.Done():
					return nil, ctx.Err()
				}
				continue
			}
			return nil, lastErr
		}

		if resp.StatusCode >= 400 {
			logWarn("webPost 非成功状态 attempt=%d url=%s status=%d body=%s", attempt, apiURL, resp.StatusCode, string(body))
			lastErr = fmt.Errorf("HTTP %d", resp.StatusCode)
			if attempt < 2 {
				select {
				case <-time.After(300 * time.Millisecond):
				case <-ctx.Done():
					return nil, ctx.Err()
				}
				continue
			}
			return nil, lastErr
		}

		logUpstreamBusinessError(apiURL, body)
		if debugEnabled && extractResponseCodeFromHead(body) == -1 {
			logDebug("webPost 非JSON响应 body=%s", string(body))
		}

		return body, nil
	}

	if lastErr != nil {
		return nil, lastErr
	}
	return nil, fmt.Errorf("webPost unknown error")
}
