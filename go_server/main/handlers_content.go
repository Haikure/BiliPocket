package main

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
)

// ==================== 路由处理函数 ====================

func handleRoot(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		logWarn("404 未找到路由: %s %s", r.Method, r.URL.Path)
		writeJSON(w, 404, map[string]interface{}{
			"code":    -404,
			"message": "接口不存在",
			"data":    nil,
		})
		return
	}
	writeJSON(w, 200, map[string]interface{}{
		"code":    0,
		"message": "Bilibili API Server 运行中",
		"data": map[string]interface{}{
			"version":   "1.0.0",
			"endpoints": rootEndpoints,
		},
	})
}

func handlePopular(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	pn, ps, ok := getPageParams(w, q, 20)
	if !ok {
		return
	}
	handleAPI(w, "/popular", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.GetPopularVideos(r.Context(), pn, ps)
	})
}

func handleRanking(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	rid, ok := getIntQuery(w, q, "rid", 0, 0, true)
	if !ok {
		return
	}
	typ := q.Get("type")
	if typ == "" {
		typ = "all"
	}
	handleAPI(w, "/ranking", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.GetRanking(r.Context(), rid, typ)
	})
}

func handleDynamicFeed(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	// host_mid 为可选：未传时取 0；与 /user/* 一致按 int64 解析，避免大 UID 截断。
	hostMid := getInt64Query(q, "host_mid")
	if raw := strings.TrimSpace(q.Get("host_mid")); raw != "" && hostMid == 0 {
		if _, err := strconv.ParseInt(raw, 10, 64); err != nil {
			writeError(w, 400, "参数必须为整数，收到: "+raw)
			return
		}
		// 解析成功但结果为 0：合法的零值，按未指定处理。
	}
	typ := q.Get("type")
	if typ == "" {
		typ = "all"
	}
	offset := q.Get("offset")
	handleAPI(w, "/dynamic/feed", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.GetDynamicFeed(r.Context(), typ, offset, hostMid)
	})
}

func handleSearch(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	keyword := q.Get("keyword")
	if keyword == "" {
		logWarn("搜索关键词为空")
		writeError(w, 400, "keyword 不能为空")
		return
	}
	page, ok := getIntQuery(w, q, "page", 1, 1, true)
	if !ok {
		return
	}
	pageSize, ok := getIntQuery(w, q, "page_size", 1, 20, true)
	if !ok {
		return
	}
	handleAPI(w, "/search", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.SearchVideos(r.Context(), keyword, page, pageSize)
	})
}

func handleVideoInfo(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	aid, ok := getIntQuery(w, q, "aid", 1, 0, true)
	if !ok {
		return
	}
	bvid := q.Get("bvid")
	if aid == 0 && bvid == "" {
		logWarn("aid 和 bvid 都未提供")
		writeError(w, 400, "aid 或 bvid 至少提供一个")
		return
	}
	handleAPI(w, "/video/info", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.GetVideoInfo(r.Context(), aid, bvid)
	})
}

func handleVideoRelated(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	aid, ok := getIntQuery(w, q, "aid", 1, 0, true)
	if !ok {
		return
	}
	bvid := q.Get("bvid")
	if aid == 0 && bvid == "" {
		logWarn("aid 和 bvid 都未提供")
		writeError(w, 400, "aid 或 bvid 至少提供一个")
		return
	}
	handleAPI(w, "/video/related", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.GetVideoRelated(r.Context(), aid, bvid)
	})
}

func handleVideoRelation(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	aid, ok := getIntQuery(w, q, "aid", 1, 0, true)
	if !ok {
		return
	}
	bvid := q.Get("bvid")
	if aid == 0 && bvid == "" {
		logWarn("aid 和 bvid 都未提供")
		writeError(w, 400, "aid 或 bvid 至少提供一个")
		return
	}
	handleAPI(w, "/video/relation", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.GetVideoRelation(r.Context(), aid, bvid)
	})
}

func handleVideoPlayurl(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	aid, ok := getIntQuery(w, q, "aid", 1, 0, true)
	if !ok {
		return
	}
	cid, ok := getIntQuery(w, q, "cid", 1, 0, true)
	if !ok {
		return
	}
	if aid == 0 || cid == 0 {
		logWarn("aid 或 cid 缺失")
		writeError(w, 400, "aid 和 cid 为必填参数")
		return
	}
	qn, ok := getIntQuery(w, q, "qn", 0, 64, true)
	if !ok {
		return
	}
	fnval, ok := getIntQuery(w, q, "fnval", 0, 1, false)
	if !ok {
		return
	}
	platform := q.Get("platform")
	client := getClient()
	result, err := client.GetPlayUrl(r.Context(), aid, cid, qn, fnval, platform)
	if err != nil {
		logError("处理 /video/playurl 请求失败: %s", err.Error())
		writeError(w, 500, err.Error())
		return
	}

	// 过滤不可观看的清晰度（以 accept_quality 为主，结合 support_formats 限制）
	var resp map[string]interface{}
	if err := json.Unmarshal(result, &resp); err == nil {
		if code, ok := resp["code"].(float64); ok && int(code) == 0 {
			if data, ok := resp["data"].(map[string]interface{}); ok {
				allowed := make(map[int]bool)

				// 先以 accept_quality 为主
				if aq, ok := data["accept_quality"].([]interface{}); ok {
					for _, v := range aq {
						qf, _ := v.(float64)
						if int(qf) > 0 {
							allowed[int(qf)] = true
						}
					}
				}

				// 再用 support_formats 的限制条件剔除不可观看清晰度
				if sf, ok := data["support_formats"].([]interface{}); ok {
					filtered := make([]interface{}, 0)
					for _, v := range sf {
						obj, _ := v.(map[string]interface{})
						q, _ := obj["quality"].(float64)
						canWatch, _ := obj["can_watch_qn_reason"].(float64)
						limit, _ := obj["limit_watch_reason"].(float64)
						if int(q) <= 0 {
							continue
						}
						if int(canWatch) != 0 || int(limit) != 0 {
							delete(allowed, int(q))
							continue
						}
						filtered = append(filtered, obj)
					}
					data["support_formats"] = filtered
				}

				// 重建 accept_quality（保持原顺序）
				if aq, ok := data["accept_quality"].([]interface{}); ok {
					newAq := make([]interface{}, 0)
					for _, v := range aq {
						qf, _ := v.(float64)
						if allowed[int(qf)] {
							newAq = append(newAq, v)
						}
					}
					if len(newAq) > 0 {
						data["accept_quality"] = newAq
					}
				}
			}
		}
	}

	if len(resp) > 0 {
		writeJSON(w, 200, resp)
		return
	}
	writeJSON(w, 200, wrapResult(result))
}

func handleVideoDanmaku(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	cid, ok := getIntQuery(w, q, "cid", 1, 0, true)
	if !ok {
		return
	}
	if cid == 0 {
		logWarn("cid 缺失")
		writeError(w, 400, "cid 为必填参数")
		return
	}
	segment, ok := getIntQuery(w, q, "segment", 1, 1, true)
	if !ok {
		return
	}
	client := getClient()
	data, err := client.GetDanmaku(r.Context(), cid, segment)
	if err != nil {
		logError("处理 /video/danmaku 请求失败: %s", err.Error())
		writeError(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, map[string]interface{}{
		"code":    0,
		"message": "success",
		"data": map[string]interface{}{
			"cid":     cid,
			"segment": segment,
			"size":    len(data),
			"note":    "弹幕数据为 Protobuf 二进制格式，需使用专用解析器",
		},
	})
}


func handleVideoDanmakuConfig(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	oid, ok := getIntQuery(w, q, "oid", 1, 0, true)
	if !ok {
		return
	}
	if oid == 0 {
		logWarn("oid 缺失")
		writeError(w, 400, "oid 为必填参数")
		return
	}
	pid, ok := getIntQuery(w, q, "pid", 1, 0, true)
	if !ok {
		return
	}
	handleAPI(w, "/video/danmaku/config", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.GetDanmakuConfig(r.Context(), oid, pid)
	})
}

func handleVideoCommentsReplies(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	oid, ok := requireIntQuery(w, q, "oid")
	if !ok {
		return
	}
	root, ok := requireIntQuery(w, q, "root")
	if !ok {
		return
	}
	typ, ok := getIntQuery(w, q, "type", 0, 1, true)
	if !ok {
		return
	}
	pn, ps, ok := getPageParams(w, q, 20)
	if !ok {
		return
	}
	handleAPI(w, "/video/comments/replies", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.GetCommentReplies(r.Context(), oid, root, typ, ps, pn)
	})
}

func handleCommentLikeToggle(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	oid, ok := requireIntQuery(w, q, "oid")
	if !ok {
		return
	}
	rpid, ok := requireIntQuery(w, q, "rpid")
	if !ok {
		return
	}
	typ, ok := getIntQuery(w, q, "type", 0, 1, true)
	if !ok {
		return
	}
	action, ok := getIntQuery(w, q, "action", 0, 1, true)
	if !ok {
		return
	}
	handleAPI(w, "/comment/like/toggle", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.ToggleCommentLike(r.Context(), oid, rpid, typ, action)
	})
}

func handleVideoComments(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	oid, ok := requireIntQuery(w, q, "oid")
	if !ok {
		return
	}
	typ, ok := getIntQuery(w, q, "type", 0, 1, true)
	if !ok {
		return
	}
	sortVal, ok := getIntQuery(w, q, "sort", 0, 0, true)
	if !ok {
		return
	}
	pn, ps, ok := getPageParams(w, q, 20)
	if !ok {
		return
	}
	offset := strings.TrimSpace(q.Get("offset"))
	paginationStr := strings.TrimSpace(q.Get("pagination_str"))
	if paginationStr == "" && offset != "" {
		if raw, err := json.Marshal(map[string]string{"offset": offset}); err == nil {
			paginationStr = string(raw)
		}
	}
	mode, ok := getIntQuery(w, q, "mode", 0, sortVal+2, true)
	if !ok {
		return
	}
	handleAPI(w, "/video/comments", func(c *BilibiliClient) (json.RawMessage, error) {
		sessdata, _, _, _, _, _ := c.getAuth()
		if sessdata == "" || paginationStr != "" {
			return c.GetVideoCommentsMain(r.Context(), oid, typ, mode, ps, paginationStr)
		}
		return c.GetVideoComments(r.Context(), oid, typ, sortVal, ps, pn)
	})
}

func handleUserVideos(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	mid, ok := requireInt64Query(w, q, "mid")
	if !ok {
		return
	}
	pn, ps, ok := getPageParams(w, q, 20)
	if !ok {
		return
	}
	maxVal := getInt64Query(q, "max", "cursor")
	targetAid := getInt64Query(q, "aid")
	includeCursor := strings.EqualFold(q.Get("include_cursor"), "true") || q.Get("include_cursor") == "1"
	sortOrder := q.Get("sort")

	handleAPI(w, "/user/videos", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.GetUserVideos(r.Context(), mid, pn, ps, maxVal, targetAid, includeCursor, sortOrder)
	})
}

func handleUserSearch(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	mid, ok := requireInt64Query(w, q, "mid")
	if !ok {
		return
	}
	keyword := strings.TrimSpace(q.Get("keyword"))
	if keyword == "" {
		logWarn("UP 投稿搜索关键词为空")
		writeError(w, 400, "keyword 不能为空")
		return
	}
	pn, ps, ok := getPageParams(w, q, 20)
	if !ok {
		return
	}

	handleAPI(w, "/user/search", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.GetUserSearchVideos(r.Context(), mid, keyword, pn, ps)
	})
}

func handleUserSeasons(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	mid, ok := requireInt64Query(w, q, "mid")
	if !ok {
		return
	}
	pn, ps, ok := getPageParams(w, q, 20)
	if !ok {
		return
	}
	handleAPI(w, "/user/seasons", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.GetUserSeasonsSeries(r.Context(), mid, pn, ps)
	})
}

func handleUserSeasonVideos(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	mid, ok := requireInt64Query(w, q, "mid")
	if !ok {
		return
	}
	seasonID, ok := requireIntQuery(w, q, "season_id")
	if !ok {
		return
	}
	pn, ps, ok := getPageParams(w, q, 30)
	if !ok {
		return
	}
	sortReverse := strings.EqualFold(q.Get("sort_reverse"), "true")
	handleAPI(w, "/user/season/videos", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.GetUserSeasonVideos(r.Context(), mid, seasonID, pn, ps, sortReverse)
	})
}

func handleUserSeriesVideos(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	mid, ok := requireInt64Query(w, q, "mid")
	if !ok {
		return
	}
	seriesID, ok := requireIntQuery(w, q, "series_id")
	if !ok {
		return
	}
	pn, ps, ok := getPageParams(w, q, 30)
	if !ok {
		return
	}
	sortOrder := q.Get("sort")
	handleAPI(w, "/user/series/videos", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.GetUserSeriesVideos(r.Context(), mid, seriesID, pn, ps, sortOrder)
	})
}

func handleUserInfo(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	mid, ok := requireInt64Query(w, q, "mid")
	if !ok {
		return
	}
	handleAPI(w, "/user/info", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.GetUserInfo(r.Context(), mid)
	})
}


func handleHotSearch(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	limit, ok := getIntQuery(w, q, "limit", 1, 10, true)
	if !ok {
		return
	}
	handleAPI(w, "/hot/search", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.GetHotSearch(r.Context(), limit)
	})
}

func handleRecommend(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	freshType, ok := getIntQuery(w, q, "fresh_type", 0, 3, true)
	if !ok {
		return
	}
	handleAPI(w, "/recommend", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.GetRecommend(r.Context(), freshType)
	})
}


func handleVideoPlayerInfo(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	aid, ok := requireIntQuery(w, q, "aid")
	if !ok {
		return
	}
	cid, ok := requireIntQuery(w, q, "cid")
	if !ok {
		return
	}
	bvid := q.Get("bvid")
	handleAPI(w, "/video/player/info", func(c *BilibiliClient) (json.RawMessage, error) {
		return c.GetPlayerV2(r.Context(), aid, cid, bvid)
	})
}
