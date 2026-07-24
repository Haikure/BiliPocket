package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

func handleLoginInfo(w http.ResponseWriter, r *http.Request) {
	client := getClient()
	result, err := client.GetLoginInfo(r.Context())
	if err != nil {
		logError("处理 /login/info 请求失败: %s", err.Error())
		writeError(w, 500, err.Error())
		return
	}

	// 仅在明确认证失效时清理状态并通知客户端
	var resp map[string]interface{}
	if err := json.Unmarshal(result, &resp); err == nil {
		if c, ok := resp["code"].(float64); ok {
			code := int(c)
			if code == -101 || code == -401 {
				logWarn("登录已过期，清理服务器端登录状态")
				client.ClearAuth()
				writeJSON(w, 200, map[string]interface{}{
					"code":    -101,
					"message": "登录已过期",
					"data":    nil,
				})
				return
			}
		}
	}

	writeJSON(w, 200, wrapResult(result))
}

// /login/import: 导入短信登录（bili-login /pull）拿到的 cookies
// 请求体 JSON： {"SESSDATA":"...", "bili_jct":"...", "buvid3":"...", "refresh_token":"...", "DedeUserID":"...", "DedeUserID__ckMd5":"..."}
func handleLoginImport(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]interface{}{
			"code":    405,
			"message": "method not allowed",
			"data":    nil,
		})
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		writeError(w, 400, "读取请求体失败")
		return
	}
	var payload map[string]string
	if err := json.Unmarshal(body, &payload); err != nil {
		writeError(w, 400, "JSON 解析失败")
		return
	}

	sessdata := payload["SESSDATA"]
	biliJct := payload["bili_jct"]
	buvid3 := payload["buvid3"]
	refreshToken := payload["refresh_token"]
	dedeUserID := payload["DedeUserID"]
	dedeCkMd5 := payload["DedeUserID__ckMd5"]

	if sessdata == "" {
		writeError(w, 400, "SESSDATA 不能为空")
		return
	}

	// 写入全局 Cookie（服务器端统一维护登录态）
	globalClient.UpdateAuth(sessdata, buvid3, biliJct, refreshToken, dedeUserID, dedeCkMd5)
	if buvid3 == "" {
		globalClient.ensureBuvid3()
	}

	writeJSON(w, 200, map[string]interface{}{
		"code":    0,
		"message": "ok",
		"data": map[string]interface{}{
			"sessdata": sessdata != "",
			"buvid3":   buvid3 != "",
			"bili_jct": biliJct != "",
		},
	})
}

func handleLogout(w http.ResponseWriter, r *http.Request) {
	client := getClient()

	// 按文档退出登录（web端）：POST https://passport.bilibili.com/login/exit/v2
	// 必须包含 Cookie: DedeUserID bili_jct SESSDATA，并在表单中带 biliCSRF=bili_jct
	sessdata, _, biliJct, _, dedeUserID, _ := client.getAuth()
	if sessdata == "" || biliJct == "" || dedeUserID == "" {
		// 条件不足：仍然清理本地，避免前端卡住
		logWarn("退出登录所需 cookie 不完整，直接清理本地状态 sessdata=%t bili_jct=%t DedeUserID=%t", sessdata != "", biliJct != "", dedeUserID != "")
		client.ClearAuth()
		writeJSON(w, 200, map[string]interface{}{
			"code":    0,
			"message": "logout(local)",
			"data":    nil,
		})
		return
	}

	form := url.Values{}
	form.Set("biliCSRF", biliJct)

	req, err := http.NewRequest("POST", "https://passport.bilibili.com/login/exit/v2", strings.NewReader(form.Encode()))
	if err != nil {
		logWarn("创建退出登录请求失败: %s", err.Error())
		client.ClearAuth()
		writeJSON(w, 200, map[string]interface{}{"code": 0, "message": "logout(local)", "data": nil})
		return
	}
	// headers
	client.setHeaders(req)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	// 强制带必要 cookie（避免 buildCookie 缺字段时失败）
	req.Header.Set("Cookie", "DedeUserID="+dedeUserID+"; bili_jct="+biliJct+"; SESSDATA="+sessdata)

	hc := &http.Client{Timeout: 10 * time.Second}
	resp, err := hc.Do(req)
	if err != nil {
		logWarn("退出登录请求失败: %s", err.Error())
		client.ClearAuth()
		writeJSON(w, 200, map[string]interface{}{"code": 0, "message": "logout(local)", "data": nil})
		return
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)

	// 若返回 HTML（cookie 失效时），也视为已退出
	trim := bytes.TrimSpace(body)
	if len(trim) > 0 && trim[0] == '<' {
		logInfo("退出登录返回HTML，视为登录已失效")
		client.ClearAuth()
		writeJSON(w, 200, map[string]interface{}{"code": 0, "message": "logout(expired)", "data": nil})
		return
	}

	var out map[string]interface{}
	if json.Unmarshal(body, &out) != nil {
		logWarn("退出登录返回非JSON，直接清理本地")
		client.ClearAuth()
		writeJSON(w, 200, map[string]interface{}{"code": 0, "message": "logout(local)", "data": nil})
		return
	}

	// code==0 && status==true 认为成功
	codeF, _ := out["code"].(float64)
	status, _ := out["status"].(bool)
	if int(codeF) == 0 && status {
		logInfo("退出登录成功(远端)")
	} else {
		logWarn("退出登录远端返回异常: %s", string(body))
	}

	client.ClearAuth()
	writeJSON(w, 200, map[string]interface{}{
		"code":    0,
		"message": "logout",
		"data":    nil,
	})
}


func handleRecentHistory(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	// max / view_at 是游标，可能超过 int32 范围，按 int64 解析。
	maxVal := getInt64Query(q, "max")
	viewAt := getInt64Query(q, "view_at")
	if raw := strings.TrimSpace(q.Get("max")); raw != "" && maxVal == 0 {
		if _, err := strconv.ParseInt(raw, 10, 64); err != nil {
			writeError(w, 400, fmt.Sprintf("参数必须为整数，收到: %s", raw))
			return
		}
	}
	if raw := strings.TrimSpace(q.Get("view_at")); raw != "" && viewAt == 0 {
		if _, err := strconv.ParseInt(raw, 10, 64); err != nil {
			writeError(w, 400, fmt.Sprintf("参数必须为整数，收到: %s", raw))
			return
		}
	}
	ps, ok := getIntQuery(w, q, "ps", 1, 0, true)
	if !ok {
		return
	}
	handleAPI(w, "/history/recent", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.GetRecentHistory(r.Context(), maxVal, viewAt, ps)
	})
}

func handleHistorySearch(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	keyword := strings.TrimSpace(q.Get("keyword"))
	if keyword == "" {
		writeError(w, 400, "keyword 为必填参数")
		return
	}
	pn, ok := getIntQuery(w, q, "pn", 1, 1, true)
	if !ok {
		return
	}
	handleAPI(w, "/history/search", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.SearchHistory(r.Context(), keyword, pn)
	})
}

func handleHistoryDelete(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	kid := strings.TrimSpace(q.Get("kid"))
	if kid == "" {
		writeError(w, 400, "kid 为必填参数")
		return
	}
	handleAPI(w, "/history/delete", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.DeleteHistory(r.Context(), kid)
	})
}

func handleToviewList(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	pn, ps, ok := getPageParams(w, q, 20)
	if !ok {
		return
	}
	handleAPI(w, "/toview/list", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.GetWatchLaterList(r.Context(), pn, ps)
	})
}

func handleToviewAdd(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	aid, bvid, ok := requireAidOrBvid(w, q)
	if !ok {
		return
	}
	handleAPI(w, "/toview/add", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.AddToWatchLater(r.Context(), aid, bvid)
	})
}

func handleToviewDel(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	aid, ok := getIntQuery(w, q, "aid", 1, 0, true)
	if !ok {
		return
	}
	if aid == 0 {
		writeError(w, 400, "aid 为必填参数")
		return
	}
	handleAPI(w, "/toview/del", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.RemoveFromWatchLater(r.Context(), aid)
	})
}

func handlePlayerHeartbeat(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	aid, err := intParam(q.Get("aid"), 1, 0, true)
	if err != nil {
		writeError(w, 400, err.Error())
		return
	}
	cid, err := intParam(q.Get("cid"), 1, 0, true)
	if err != nil {
		writeError(w, 400, err.Error())
		return
	}
	playedTime, err := intParam(q.Get("played_time"), -1, 0, true)
	if err != nil {
		writeError(w, 400, err.Error())
		return
	}
	videoDuration := 0
	if raw := q.Get("video_duration"); raw != "" {
		videoDuration, err = intParam(raw, 1, 0, true)
		if err != nil {
			writeError(w, 400, err.Error())
			return
		}
	}
	bvid := q.Get("bvid")
	if bvid == "" {
		writeError(w, 400, "bvid 为必填参数")
		return
	}

	extra := map[string]string{
		"type":      q.Get("type"),
		"sub_type":  q.Get("sub_type"),
		"epid":      q.Get("epid"),
		"sid":       q.Get("sid"),
		"play_type": q.Get("play_type"),
	}

	client := getClient()
	result, err := client.ReportHeartbeat(r.Context(), aid, cid, bvid, playedTime, videoDuration, extra)
	if err != nil {
		logError("处理 /player/heartbeat 请求失败: %s", err.Error())
		writeError(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, wrapResult(result))
}

func handleFavFolderList(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	mid, ok := requireInt64Query(w, q, "mid")
	if !ok {
		return
	}
	handleAPI(w, "/fav/folder/list", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.GetFavoriteFolders(r.Context(), mid)
	})
}

func handleFavResourceList(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	mediaId, ok := requireIntQuery(w, q, "media_id")
	if !ok {
		return
	}
	pn, ps, ok := getPageParams(w, q, 20)
	if !ok {
		return
	}
	handleAPI(w, "/fav/resource/list", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.GetFavoriteResources(r.Context(), mediaId, pn, ps)
	})
}

type favoriteFolderListResponse struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    *struct {
		List []struct {
			ID       int `json:"id"`
			Fid      int `json:"fid"`
			FavState int `json:"fav_state"`
		} `json:"list"`
	} `json:"data"`
}

func loginMidFromNav(raw json.RawMessage) (int64, error) {
	var resp struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
		Data    struct {
			Mid     int64 `json:"mid"`
			IsLogin bool  `json:"isLogin"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return 0, fmt.Errorf("登录信息解析失败")
	}
	if resp.Code != 0 {
		msg := resp.Message
		if msg == "" {
			msg = "登录信息请求失败"
		}
		return 0, fmt.Errorf("%s", msg)
	}
	if resp.Data.Mid <= 0 || !resp.Data.IsLogin {
		return 0, fmt.Errorf("未登录")
	}
	return resp.Data.Mid, nil
}

func favoriteFolderMediaIDs(raw json.RawMessage, favoredOnly bool) ([]int, error) {
	var resp favoriteFolderListResponse
	if err := json.Unmarshal(raw, &resp); err != nil {
		return nil, fmt.Errorf("收藏夹解析失败")
	}
	if resp.Code != 0 {
		msg := resp.Message
		if msg == "" {
			msg = "收藏夹列表请求失败"
		}
		return nil, fmt.Errorf("%s", msg)
	}
	if resp.Data == nil || len(resp.Data.List) == 0 {
		return nil, nil
	}

	mediaIDs := make([]int, 0, len(resp.Data.List))
	for _, folder := range resp.Data.List {
		if favoredOnly && folder.FavState != 1 {
			continue
		}
		mediaID := folder.ID
		if mediaID <= 0 {
			mediaID = folder.Fid
		}
		if mediaID > 0 {
			mediaIDs = append(mediaIDs, mediaID)
		}
	}
	return mediaIDs, nil
}

func requireAidOrBvid(w http.ResponseWriter, q url.Values) (int, string, bool) {
	aid, err := intParam(q.Get("aid"), 1, 0, true)
	if err != nil {
		writeError(w, 400, err.Error())
		return 0, "", false
	}
	bvid := q.Get("bvid")
	if aid == 0 && bvid == "" {
		logWarn("aid 和 bvid 均缺失")
		writeError(w, 400, "aid 或 bvid 至少提供一个")
		return 0, "", false
	}
	return aid, bvid, true
}

func handleFavStatus(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	aid, ok := requireIntQuery(w, q, "aid")
	if !ok {
		return
	}
	handleAPI(w, "/fav/status", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.GetFavoriteStatus(r.Context(), aid)
	})
}

func handleCoinStatus(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	aid, bvid, ok := requireAidOrBvid(w, q)
	if !ok {
		return
	}
	handleAPI(w, "/coin/status", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.GetCoinStatus(r.Context(), aid, bvid)
	})
}

func handleCoinAdd(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	aid, bvid, ok := requireAidOrBvid(w, q)
	if !ok {
		return
	}
	multiply, ok := getIntQuery(w, q, "multiply", 1, 1, true)
	if !ok {
		return
	}
	if multiply > 2 {
		multiply = 2
	}
	selectLike := q.Get("select_like") == "1"
	handleAPI(w, "/coin/add", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.AddCoin(r.Context(), aid, multiply, selectLike, bvid)
	})
}

func handleLikeStatus(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	aid, bvid, ok := requireAidOrBvid(w, q)
	if !ok {
		return
	}
	client := getClient()
	result, err := client.GetLikeStatus(r.Context(), aid, bvid)
	if err != nil {
		logError("处理 /like/status 请求失败: %s", err.Error())
		writeError(w, 500, err.Error())
		return
	}

	// 将 data 的数值包装为对象，保证客户端解析
	var resp map[string]interface{}
	if err := json.Unmarshal(result, &resp); err == nil {
		if code, ok := resp["code"].(float64); ok && int(code) == 0 {
			liked := 0
			if v, ok := resp["data"].(float64); ok {
				liked = int(v)
			}
			writeJSON(w, 200, map[string]interface{}{
				"code":    0,
				"message": "success",
				"data": map[string]interface{}{
					"liked": liked,
				},
			})
			return
		}
	}
	writeJSON(w, 200, wrapResult(result))
}

func handleLikeToggle(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	aid, bvid, ok := requireAidOrBvid(w, q)
	if !ok {
		return
	}
	likeVal, ok := getIntQuery(w, q, "like", 1, 1, true)
	if !ok {
		return
	}
	handleAPI(w, "/like/toggle", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.ToggleLike(r.Context(), aid, likeVal, bvid)
	})
}

func handleFavToggle(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	aid, err := intParam(q.Get("aid"), 1, 0, true)
	if err != nil {
		writeError(w, 400, err.Error())
		return
	}
	if aid == 0 {
		logWarn("aid 缺失")
		writeError(w, 400, "aid 为必填参数")
		return
	}
	action := q.Get("action")
	add := action != "0"

	mediaId, err := intParam(q.Get("media_id"), 1, 0, true)
	if err != nil {
		mediaId = 0
	}

	client := getClient()
	mediaIds := []int{}
	if mediaId > 0 {
		mediaIds = []int{mediaId}
	}

	if len(mediaIds) == 0 {
		loginRaw, err := client.GetLoginInfo(r.Context())
		if err != nil {
			logError("获取登录信息失败: %s", err.Error())
			writeError(w, 500, err.Error())
			return
		}
		mid, err := loginMidFromNav(loginRaw)
		if err != nil {
			status := 500
			if err.Error() == "未登录" {
				status = 401
			}
			writeError(w, status, err.Error())
			return
		}

		var foldersRaw json.RawMessage
		if add {
			foldersRaw, err = client.GetFavoriteFolders(r.Context(), mid)
		} else {
			foldersRaw, err = client.GetFavoriteFoldersForResource(r.Context(), mid, aid)
		}
		if err != nil {
			logError("获取收藏夹失败: %s", err.Error())
			writeError(w, 500, err.Error())
			return
		}

		ids, err := favoriteFolderMediaIDs(foldersRaw, !add)
		if err != nil {
			writeError(w, 500, err.Error())
			return
		}
		if len(ids) == 0 {
			if add {
				writeError(w, 500, "未找到收藏夹")
			} else {
				writeError(w, 500, "未找到视频所在收藏夹")
			}
			return
		}
		if add {
			mediaIds = []int{ids[0]}
		} else {
			mediaIds = ids
		}
	}

	if len(mediaIds) == 0 {
		if add {
			writeError(w, 500, "未找到收藏夹")
		} else {
			writeError(w, 500, "未找到视频所在收藏夹")
		}
		return
	}

	result, err := client.ToggleFavorite(r.Context(), aid, add, mediaIds)
	if err != nil {
		logError("处理 /fav/toggle 请求失败: %s", err.Error())
		writeError(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, wrapResult(result))
}

func handleUserFollowToggle(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	mid, ok := requireInt64Query(w, q, "mid")
	if !ok {
		return
	}

	action := q.Get("action")
	follow := action != "0"

	result, err := getClient().ToggleUserFollow(r.Context(), mid, follow)
	if err != nil {
		logError("处理 /user/follow/toggle 请求失败: %s", err.Error())
		writeError(w, 500, err.Error())
		return
	}

	var resp map[string]interface{}
	if err := json.Unmarshal(result, &resp); err == nil {
		if code, ok := resp["code"].(float64); ok && int(code) == 0 {
			writeJSON(w, 200, map[string]interface{}{
				"code":    0,
				"message": "success",
				"data": map[string]interface{}{
					"following": follow,
				},
			})
			return
		}
	}

	writeJSON(w, 200, wrapResult(result))
}
