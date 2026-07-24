package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/skip2/go-qrcode"
)

// ==================== Cookie 持久化 ====================

type CookieStore struct {
	Sessdata        string `json:"sessdata"`
	Buvid3          string `json:"buvid3"`
	BiliJct         string `json:"bili_jct"`
	DedeUserID      string `json:"dedeuserid"`
	DedeUserIDCkMd5 string `json:"dedeuserid_ckmd5"`
	RefreshToken    string `json:"refresh_token"`
}

const cookieFile = "cookies.json"

func loadCookies() (CookieStore, error) {
	var cs CookieStore
	b, err := os.ReadFile(cookieFile)
	if err != nil {
		return cs, err
	}
	if err := json.Unmarshal(b, &cs); err != nil {
		return cs, err
	}
	return cs, nil
}

func saveCookies(cs CookieStore) error {
	b, err := json.MarshalIndent(cs, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(cookieFile, b, 0600)
}

// getAuth 直接从无锁快照读取，避免每次上游请求都做 RWMutex.RLock。
// 写路径仍持有 c.mu 并通过 rebuildSnapshotLocked 原子发布最新视图。
func (c *BilibiliClient) getAuth() (string, string, string, string, string, string) {
	s := c.loadSnapshot()
	return s.sessdata, s.buvid3, s.biliJct, s.refreshToken, s.dedeUserID, s.dedeUserIDCkMd5
}

func hmacSha256(key, message string) string {
	mac := hmac.New(sha256.New, []byte(key))
	mac.Write([]byte(message))
	return hex.EncodeToString(mac.Sum(nil))
}

func getBiliTicket() string {
	logInfo("正在获取 bili_ticket...")
	ts := strconv.FormatInt(time.Now().Unix(), 10)
	hexsign := hmacSha256("XgwSnGZ1p", "ts"+ts)

	params := url.Values{}
	params.Set("key_id", "ec02")
	params.Set("hexsign", hexsign)
	params.Set("context[ts]", ts)
	params.Set("csrf", "")

	apiURL := "https://api.bilibili.com/bapis/bilibili.api.ticket.v1.Ticket/GenWebTicket?" + params.Encode()

	client := &http.Client{Timeout: 5 * time.Second}
	req, err := http.NewRequest("POST", apiURL, nil)
	if err != nil {
		logError("bili_ticket 请求创建失败: %s", err.Error())
		return ""
	}
	req.Header.Set("User-Agent", defaultUserAgent)
	resp, err := client.Do(req)
	if err != nil {
		logError("bili_ticket 获取异常: %s", err.Error())
		return ""
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	var result map[string]interface{}
	if err := json.Unmarshal(body, &result); err != nil {
		logError("bili_ticket 解析失败: %s", err.Error())
		return ""
	}

	code, _ := result["code"].(float64)
	if int(code) == 0 {
		data, _ := result["data"].(map[string]interface{})
		if data == nil {
			data = map[string]interface{}{}
		}
		ticket, _ := data["ticket"].(string)
		if len(ticket) > 20 {
			logSuccess("bili_ticket 获取成功: %s...", ticket[:20])
		} else {
			logSuccess("bili_ticket 获取成功: %s", ticket)
		}
		return ticket
	}

	msg, _ := result["message"].(string)
	logWarn("bili_ticket 获取失败: %s", msg)
	return ""
}

func buildCorrespondPath(ts int64) (string, error) {
	message := []byte("refresh_" + strconv.FormatInt(ts, 10))
	modulusHex := "y4HdjgJHBlbaBN04VERG4qNBIFHP6a3GozCl75AihQloSWCXC5HDNgyinEnhaQ_4-gaMud_GF50elYXLlCToR9se9Z8z433U3KjM-3Yx7ptKkmQNAMggQwAVKgq3zYAoidNEWuxpkY_mAitTSRLnsJW-NCTa0bqBFF6Wm1MxgfE"
	modulusBytes, err := base64.RawURLEncoding.DecodeString(modulusHex)
	if err != nil {
		return "", err
	}
	modulus := new(big.Int).SetBytes(modulusBytes)
	pub := &rsa.PublicKey{N: modulus, E: 65537}

	ciphertext, err := rsa.EncryptOAEP(sha256.New(), rand.Reader, pub, message, nil)
	if err != nil {
		return "", err
	}
	return strings.ToLower(hex.EncodeToString(ciphertext)), nil
}

func getRefreshCSRF(c *BilibiliClient, sessdata, biliJct string, tsMilli int64) string {
	// 文档：使用毫秒时间戳生成 CorrespondPath
	correspondPath, err := buildCorrespondPath(tsMilli)
	if err != nil {
		logWarn("生成 correspondPath 失败: %s", err.Error())
		return ""
	}
	urlStr := "https://www.bilibili.com/correspond/1/" + correspondPath
	req, err := http.NewRequest("GET", urlStr, nil)
	if err != nil {
		logWarn("请求 refresh_csrf 失败: %s", err.Error())
		return ""
	}
	c.setHeaders(req)
	// 对应文档示例：只要求 SESSDATA 也可，但这里带上 bili_jct
	req.Header.Set("Cookie", "SESSDATA="+sessdata+"; bili_jct="+biliJct)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		logWarn("refresh_csrf 请求失败: %s", err.Error())
		return ""
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	text := string(body)

	// 文档：refresh_csrf 位于 <div id="1-name">REFRESH_CSRF</div>
	re := regexp.MustCompile(`<div\s+id="1-name"\s*>([^<]+)</div>`)
	if m := re.FindStringSubmatch(text); len(m) > 1 {
		return strings.TrimSpace(m[1])
	}

	// 兼容：若页面结构变化，保留原有两种兜底匹配
	re1 := regexp.MustCompile(`refresh_csrf"\s*:\s*"([^"]+)"`)
	re2 := regexp.MustCompile(`name="refresh_csrf"\s+value="([^"]+)"`)
	if m := re1.FindStringSubmatch(text); len(m) > 1 {
		return m[1]
	}
	if m := re2.FindStringSubmatch(text); len(m) > 1 {
		return m[1]
	}
	return ""
}

func (c *BilibiliClient) refreshCookies() {
	sessdata, buvid3, biliJct, refreshToken, dedeUserID, dedeCkMd5 := c.getAuth()
	logInfo("Cookie 刷新检查: sessdata=%t bili_jct=%t refresh_token=%t", sessdata != "", biliJct != "", refreshToken != "")
	if sessdata == "" || biliJct == "" || refreshToken == "" {
		logInfo("Cookie 刷新条件不足: sessdata=%t bili_jct=%t refresh_token=%t", sessdata != "", biliJct != "", refreshToken != "")
		return
	}

	// 1) 检查是否需要刷新
	infoURL := "https://passport.bilibili.com/x/passport-login/web/cookie/info?csrf=" + url.QueryEscape(biliJct)
	req, err := http.NewRequest("GET", infoURL, nil)
	if err != nil {
		logWarn("Cookie info 请求创建失败: %s", err.Error())
		return
	}
	c.setHeaders(req)
	req.Header.Set("Cookie", "SESSDATA="+sessdata+"; bili_jct="+biliJct)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		logWarn("Cookie info 请求失败: %s", err.Error())
		return
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	var infoResult map[string]interface{}
	if err := json.Unmarshal(body, &infoResult); err != nil {
		logWarn("Cookie info 解析失败: %s", err.Error())
		return
	}
	if code, ok := infoResult["code"].(float64); ok && int(code) != 0 {
		logWarn("Cookie info 返回异常: code=%d body=%s", int(code), string(body))
		return
	}
	data, _ := infoResult["data"].(map[string]interface{})
	refreshNeeded, _ := data["refresh"].(bool)
	if !refreshNeeded {
		logInfo("Cookie 无需刷新")
		return
	}

	// 文档：timestamp 为毫秒时间戳
	tsMilli := int64(0)
	if ts, ok := data["timestamp"].(float64); ok {
		tsMilli = int64(ts)
	}
	if tsMilli <= 0 {
		logWarn("cookie/info 未返回有效 timestamp(ms)，跳过刷新")
		return
	}

	// 2) 获取 refresh_csrf
	refreshCSRF := getRefreshCSRF(c, sessdata, biliJct, tsMilli)
	if refreshCSRF == "" {
		logWarn("refresh_csrf 获取失败，跳过本次刷新")
		return
	}

	// 3) 刷新 Cookie（必须保存旧 refresh_token，用于 confirm/refresh）
	oldRefreshToken := refreshToken

	params := url.Values{}
	params.Set("csrf", biliJct)
	params.Set("refresh_csrf", refreshCSRF)
	params.Set("refresh_token", refreshToken)
	params.Set("source", "main_web")

	refreshReq, err := http.NewRequest("POST", "https://passport.bilibili.com/x/passport-login/web/cookie/refresh", strings.NewReader(params.Encode()))
	if err != nil {
		logWarn("Cookie refresh 请求创建失败: %s", err.Error())
		return
	}
	c.setHeaders(refreshReq)
	refreshReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	refreshReq.Header.Set("Cookie", "SESSDATA="+sessdata+"; bili_jct="+biliJct)

	refreshResp, err := c.httpClient.Do(refreshReq)
	if err != nil {
		logWarn("Cookie refresh 请求失败: %s", err.Error())
		return
	}
	defer refreshResp.Body.Close()

	refreshBody, _ := io.ReadAll(refreshResp.Body)
	var refreshResult map[string]interface{}
	if err := json.Unmarshal(refreshBody, &refreshResult); err != nil {
		logWarn("Cookie refresh 解析失败: %s", err.Error())
		return
	}
	if code, ok := refreshResult["code"].(float64); ok && int(code) != 0 {
		codeInt := int(code)
		if codeInt == 86095 {
			logInfo("Cookie 当前无需刷新或刷新条件不满足: code=%d", codeInt)
			return
		}
		logWarn("Cookie refresh 返回异常: code=%d body=%s", codeInt, string(refreshBody))
		return
	}

	newSessdata := ""
	newBiliJct := ""
	newDedeUserID := ""
	newDedeCkMd5 := ""
	for _, ck := range refreshResp.Cookies() {
		switch ck.Name {
		case "SESSDATA":
			newSessdata = ck.Value
		case "bili_jct":
			newBiliJct = ck.Value
		case "DedeUserID":
			newDedeUserID = ck.Value
		case "DedeUserID__ckMd5":
			newDedeCkMd5 = ck.Value
		}
	}
	if d, ok := refreshResult["data"].(map[string]interface{}); ok {
		if rt, ok := d["refresh_token"].(string); ok && rt != "" {
			refreshToken = rt
		}
	}

	if newSessdata != "" {
		sessdata = newSessdata
	}
	if newBiliJct != "" {
		biliJct = newBiliJct
	}
	if newDedeUserID != "" {
		dedeUserID = newDedeUserID
	}
	if newDedeCkMd5 != "" {
		dedeCkMd5 = newDedeCkMd5
	}
	c.UpdateAuth(sessdata, buvid3, biliJct, refreshToken, dedeUserID, dedeCkMd5)
	logInfo("Cookie refresh 成功，已更新本地 Cookie")

	// 4) confirm/refresh：使旧 refresh_token 失效
	confirmParams := url.Values{}
	confirmParams.Set("csrf", biliJct)
	confirmParams.Set("refresh_token", oldRefreshToken)
	confirmReq, err := http.NewRequest("POST", "https://passport.bilibili.com/x/passport-login/web/confirm/refresh", strings.NewReader(confirmParams.Encode()))
	if err != nil {
		logWarn("confirm/refresh 请求创建失败: %s", err.Error())
		return
	}
	c.setHeaders(confirmReq)
	confirmReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	confirmReq.Header.Set("Cookie", "SESSDATA="+sessdata+"; bili_jct="+biliJct)

	confirmResp, err := c.httpClient.Do(confirmReq)
	if err != nil {
		logWarn("confirm/refresh 请求失败: %s", err.Error())
		return
	}
	defer confirmResp.Body.Close()
	confirmBody, _ := io.ReadAll(confirmResp.Body)
	var confirmResult map[string]interface{}
	if json.Unmarshal(confirmBody, &confirmResult) != nil {
		logWarn("confirm/refresh 响应非JSON: %s", string(confirmBody))
		return
	}
	if code, ok := confirmResult["code"].(float64); ok && int(code) == 0 {
		logInfo("confirm/refresh 成功，旧 refresh_token 已失效")
	} else {
		logWarn("confirm/refresh 返回异常: %s", string(confirmBody))
	}

	// 5) SSO 跨域登录：暂不实现，只记录说明
	// 文档中浏览器会通过 iframe/crossDomain 做站点同步；当前服务端不强制执行。
}

func handleQrcodeGenerate(w http.ResponseWriter, r *http.Request) {
	logInfo("生成登录二维码")

	httpClient := &http.Client{Timeout: 10 * time.Second}
	req, err := http.NewRequest("GET", "https://passport.bilibili.com/x/passport-login/web/qrcode/generate", nil)
	if err != nil {
		logError("处理 /qrcode/generate 请求失败: %s", err.Error())
		writeError(w, 500, err.Error())
		return
	}

	resp, err := httpClient.Do(req)
	if err != nil {
		logError("处理 /qrcode/generate 请求失败: %s", err.Error())
		writeError(w, 500, err.Error())
		return
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	var result map[string]interface{}
	if err := json.Unmarshal(body, &result); err != nil {
		logError("解析二维码响应失败: %s", err.Error())
		writeError(w, 500, err.Error())
		return
	}

	data, _ := result["data"].(map[string]interface{})
	if data == nil {
		data = map[string]interface{}{}
	}
	qrURL, _ := data["url"].(string)

	qrcodeBase64 := ""
	if qrURL != "" {
		png, err := qrcode.Encode(qrURL, qrcode.Medium, 150)
		if err == nil {
			qrcodeBase64 = "data:image/png;base64," + base64.StdEncoding.EncodeToString(png)
			logInfo("二维码生成成功")
		} else {
			logWarn("二维码图片生成失败: %s", err.Error())
		}
	}

	data["qrcode"] = qrcodeBase64

	code := 0
	if c, ok := result["code"].(float64); ok {
		code = int(c)
	}
	message := ""
	if m, ok := result["message"].(string); ok {
		message = m
	}

	writeJSON(w, 200, map[string]interface{}{
		"code":    code,
		"message": message,
		"data":    data,
	})
}

func handleQrcodePoll(w http.ResponseWriter, r *http.Request) {
	qrcodeKey := r.URL.Query().Get("qrcode_key")
	if qrcodeKey == "" {
		logWarn("qrcode_key 缺失")
		writeError(w, 400, "qrcode_key 为必填参数")
		return
	}

	keyDisplay := qrcodeKey
	if len(keyDisplay) > 10 {
		keyDisplay = keyDisplay[:10] + "..."
	}
	logInfo("轮询二维码状态 key=%s", keyDisplay)

	httpClient := &http.Client{Timeout: 10 * time.Second}
	params := url.Values{}
	params.Set("qrcode_key", qrcodeKey)
	apiURL := "https://passport.bilibili.com/x/passport-login/web/qrcode/poll?" + params.Encode()

	req, err := http.NewRequest("GET", apiURL, nil)
	if err != nil {
		logError("处理 /qrcode/poll 请求失败: %s", err.Error())
		writeError(w, 500, err.Error())
		return
	}
	req.Header.Set("User-Agent", defaultUserAgent)

	resp, err := httpClient.Do(req)
	if err != nil {
		logError("处理 /qrcode/poll 请求失败: %s", err.Error())
		writeError(w, 500, err.Error())
		return
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	var result map[string]interface{}
	if err := json.Unmarshal(body, &result); err != nil {
		logError("解析轮询响应失败: %s", err.Error())
		writeError(w, 500, err.Error())
		return
	}

	data, _ := result["data"].(map[string]interface{})

	code := 0
	if c, ok := result["code"].(float64); ok {
		code = int(c)
	}

	if code == 0 {
		if dataURL, ok := data["url"].(string); ok && dataURL != "" {
			var sessdata, biliJct, buvid3, dedeUserID, dedeCkMd5 string
			for _, cookie := range resp.Cookies() {
				switch cookie.Name {
				case "SESSDATA":
					sessdata = cookie.Value
					data["SESSDATA"] = sessdata
				case "bili_jct":
					biliJct = cookie.Value
					data["bili_jct"] = biliJct
				case "buvid3":
					buvid3 = cookie.Value
					data["buvid3"] = buvid3
				case "DedeUserID":
					dedeUserID = cookie.Value
					data["DedeUserID"] = dedeUserID
				case "DedeUserID__ckMd5":
					dedeCkMd5 = cookie.Value
					data["DedeUserID__ckMd5"] = dedeCkMd5
				}
			}
			if sessdata != "" {
				logInfo("成功获取 SESSDATA")
			}

			refreshToken := ""
			if rt, ok := data["refresh_token"].(string); ok {
				refreshToken = rt
			}
			if refreshToken != "" {
				data["refresh_token"] = refreshToken
			}

			globalClient.UpdateAuth(sessdata, buvid3, biliJct, refreshToken, dedeUserID, dedeCkMd5)
			if buvid3 == "" {
				globalClient.ensureBuvid3()
			}
		}
	}

	message := ""
	if m, ok := result["message"].(string); ok {
		message = m
	}

	writeJSON(w, 200, map[string]interface{}{
		"code":    code,
		"message": message,
		"data":    data,
	})
}
