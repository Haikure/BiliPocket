package main

import (
	"embed"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed web/*
var webFS embed.FS

const (
	UA  = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
	CID = 86
)

var (
	client *http.Client

	// 最近一次成功登录的账号数据（通过 /pull 拉取）
	lastAccountMu sync.RWMutex
	lastAccount   *AccountData
)

type AccountData struct {
	TS           int64             `json:"ts"`
	Tel          string            `json:"tel"`
	RefreshToken string            `json:"refresh_token"`
	Cookies      map[string]string `json:"cookies"`
}

type CaptchaResp struct {
	Code int `json:"code"`
	Data struct {
		Token   string `json:"token"`
		Geetest struct {
			Challenge string `json:"challenge"`
			GT        string `json:"gt"`
		} `json:"geetest"`
	} `json:"data"`
}

type SMSResp struct {
	Code int `json:"code"`
	Data struct {
		CaptchaKey string `json:"captcha_key"`
	} `json:"data"`
}

func main() {
	host := "0.0.0.0"

	jar, _ := cookiejar.New(nil)
	client = &http.Client{
		Jar:     jar,
		Timeout: 15 * time.Second,
	}

	// 静态文件
	sub, _ := fs.Sub(webFS, "web")
	http.Handle("/", http.FileServer(http.FS(sub)))

	http.HandleFunc("/api/captcha", handleCaptcha)
	http.HandleFunc("/api/sms/send", handleSMSSend)
	http.HandleFunc("/api/login/sms", handleSMSLogin)
	http.HandleFunc("/pull", handlePull)

	addr := host + ":8666"
	log.Printf("服务启动，监听于：http://%s/verify.html", addr)
	log.Fatal(http.ListenAndServe(addr, nil))
}

func handleCaptcha(w http.ResponseWriter, r *http.Request) {
	captcha, err := fetchCaptcha()
	if (err != nil) || captcha.Code != 0 {
		http.Error(w, "captcha 获取失败", 500)
		return
	}
	resp := map[string]string{
		"gt":        captcha.Data.Geetest.GT,
		"challenge": captcha.Data.Geetest.Challenge,
		"token":     captcha.Data.Token,
	}
	writeJSON(w, resp)
}

func handleSMSSend(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Tel       string `json:"tel"`
		Token     string `json:"token"`
		Challenge string `json:"challenge"`
		Validate  string `json:"validate"`
		SecCode   string `json:"seccode"`
	}

	body, _ := io.ReadAll(r.Body)
	_ = json.Unmarshal(body, &req)

	// tel 必须是数字
	if _, err := strconv.ParseInt(req.Tel, 10, 64); err != nil {
		http.Error(w, "tel 必须是数字", 400)
		return
	}

	form := url.Values{}
	form.Set("tel", req.Tel)
	form.Set("cid", fmt.Sprintf("%d", CID))
	form.Set("source", "main_web")
	form.Set("token", req.Token)
	form.Set("challenge", req.Challenge)
	form.Set("validate", req.Validate)
	form.Set("seccode", req.SecCode)

	respBytes, err := doPostForm("https://passport.bilibili.com/x/passport-login/web/sms/send", form)
	if err != nil {
		http.Error(w, "短信发送失败", 500)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(respBytes)
}

func handleSMSLogin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Tel        string `json:"tel"`
		Code       string `json:"code"`
		CaptchaKey string `json:"captcha_key"`
	}

	body, _ := io.ReadAll(r.Body)
	_ = json.Unmarshal(body, &req)

	if _, err := strconv.ParseInt(req.Tel, 10, 64); err != nil {
		http.Error(w, "tel 必须是数字", 400)
		return
	}

	// 继续使用 web 端短信登录接口
	form := url.Values{}
	form.Set("cid", fmt.Sprintf("%d", CID))
	form.Set("tel", req.Tel)
	form.Set("code", req.Code)
	form.Set("source", "main_web")
	form.Set("captcha_key", req.CaptchaKey)

	resp, err := doPost("https://passport.bilibili.com/x/passport-login/web/login/sms", form)
	if err != nil {
		http.Error(w, "登录失败", 500)
		return
	}
	defer resp.Body.Close()

	// 先读出响应体：既要回传给前端，也要用于判断是否登录成功
	respBytes, _ := io.ReadAll(resp.Body)

	// 访问主页，补齐可能延迟下发的站点 Cookie（如 buvid3）
	_, _ = doGet("https://www.bilibili.com")

	// 人类可读方式输出最终 Cookie
	printReadableCookies(resp)

	// 登录成功后缓存账号数据，供 /pull 拉取
	if isLoginOK(respBytes) {
		acc := &AccountData{
			TS:           time.Now().Unix(),
			Tel:          req.Tel,
			RefreshToken: extractRefreshToken(respBytes),
			Cookies:      collectCookiesForPull(),
		}
		lastAccountMu.Lock()
		lastAccount = acc
		lastAccountMu.Unlock()
	}

	w.Header().Set("Content-Type", "application/json")
	w.Write(respBytes)
}

func printReadableCookies(loginResp *http.Response) {
	fmt.Println("\n================ 登录后 Cookie 摘要 ================")

	// A. 登录响应头中的 Set-Cookie（原始）
	fmt.Println("\n[1/2] 登录响应头 Set-Cookie（原始）")
	setCookies := loginResp.Header["Set-Cookie"]
	if len(setCookies) == 0 {
		fmt.Println("  (无)")
	} else {
		for i, c := range setCookies {
			fmt.Printf("  %02d. %s\n", i+1, c)
		}
	}

	// B. CookieJar 中的当前最终 Cookie（按域名分组）
	fmt.Println("\n[2/2] CookieJar 当前最终 Cookie（按域名）")
	targets := []string{
		"https://passport.bilibili.com",
		"https://www.bilibili.com",
		"https://api.bilibili.com",
	}

	for _, t := range targets {
		u, _ := url.Parse(t)
		ck := client.Jar.Cookies(u)
		fmt.Printf("\n- 域名: %s\n", u.Host)
		if len(ck) == 0 {
			fmt.Println("  (无)")
			continue
		}
		for i, c := range ck {
			fmt.Printf("  %02d) %-20s = %s\n", i+1, c.Name, c.Value)
		}
	}

	fmt.Println("====================================================\n")
}

func handlePull(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusMethodNotAllowed)
		_ = json.NewEncoder(w).Encode(map[string]any{"code": 405, "message": "method not allowed"})
		return
	}

	lastAccountMu.RLock()
	acc := lastAccount
	lastAccountMu.RUnlock()

	if acc == nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNotFound)
		_ = json.NewEncoder(w).Encode(map[string]any{"code": 404, "message": "no account"})
		return
	}

	writeJSON(w, acc)
}

func isLoginOK(respBytes []byte) bool {
	// B 站接口一般返回 {"code":0,...} 表示成功
	var tmp struct {
		Code int `json:"code"`
	}
	if err := json.Unmarshal(respBytes, &tmp); err != nil {
		return false
	}
	return tmp.Code == 0
}

func extractRefreshToken(respBytes []byte) string {
	// 部分登录接口会返回 data.refresh_token，需要持久化保存（对应 localStorage 的 ac_time_value）
	var tmp struct {
		Code int `json:"code"`
		Data struct {
			RefreshToken string `json:"refresh_token"`
		} `json:"data"`
	}
	if err := json.Unmarshal(respBytes, &tmp); err != nil {
		return ""
	}
	if tmp.Code != 0 {
		return ""
	}
	return tmp.Data.RefreshToken
}

func collectCookiesForPull() map[string]string {
	// /pull 期望给出一组“可直接拿去用”的关键 Cookie。
	// Cookie 可能分散在不同子域名下，这里做一次合并。
	targets := []string{
		"https://www.bilibili.com",
		"https://passport.bilibili.com",
		"https://api.bilibili.com",
	}

	out := make(map[string]string)
	for _, t := range targets {
		u, _ := url.Parse(t)
		for _, c := range client.Jar.Cookies(u) {
			// 后写覆盖先写：一般 www 域更“最终”，因此放在 targets 第一个
			if _, ok := out[c.Name]; !ok {
				out[c.Name] = c.Value
			}
		}
	}

	// 确保常用字段存在（如果 jar 里没有就保持缺省）
	// 典型需要：SESSDATA, bili_jct, buvid3, DedeUserID, DedeUserID__ckMd5
	return out
}

func fetchCaptcha() (*CaptchaResp, error) {
	req, _ := http.NewRequest("GET",
		"https://passport.bilibili.com/x/passport-login/captcha?source=main_web", nil)
	req.Header.Set("User-Agent", UA)

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result CaptchaResp
	err = json.NewDecoder(resp.Body).Decode(&result)
	return &result, err
}

func doPostForm(urlStr string, form url.Values) ([]byte, error) {
	resp, err := doPost(urlStr, form)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	return io.ReadAll(resp.Body)
}

func doPost(urlStr string, form url.Values) (*http.Response, error) {
	req, _ := http.NewRequest("POST", urlStr, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("User-Agent", UA)
	return client.Do(req)
}

func doGet(urlStr string) ([]byte, error) {
	req, _ := http.NewRequest("GET", urlStr, nil)
	req.Header.Set("User-Agent", UA)
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	return io.ReadAll(resp.Body)
}

func writeJSON(w http.ResponseWriter, data any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(data)
}
