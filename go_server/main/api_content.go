package main

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ==================== API 方法 ====================

func (c *BilibiliClient) GetPopularVideos(ctx context.Context, pn, ps int) (json.RawMessage, error) {
	logInfo("获取热门视频 pn=%d ps=%d", pn, ps)
	return c.wbiRequest(ctx, "https://api.bilibili.com/x/web-interface/popular", map[string]string{
		"pn": strconv.Itoa(pn),
		"ps": strconv.Itoa(ps),
	}, "GET")
}

func (c *BilibiliClient) GetRanking(ctx context.Context, rid int, typ string) (json.RawMessage, error) {
	logInfo("获取排行榜 rid=%d type=%s", rid, typ)
	return c.wbiRequest(ctx, "https://api.bilibili.com/x/web-interface/ranking/v2", map[string]string{
		"rid":  strconv.Itoa(rid),
		"type": typ,
	}, "GET")
}

func (c *BilibiliClient) GetDynamicFeed(ctx context.Context, typ, offset string, hostMid int64) (json.RawMessage, error) {
	typ = strings.TrimSpace(typ)
	if typ == "" {
		typ = "all"
	}
	params := map[string]string{
		"type":         typ,
		"platform":     "web",
		"features":     dynamicFeatures,
		"web_location": "333.1365",
	}
	if offset = strings.TrimSpace(offset); offset != "" {
		params["offset"] = offset
	}
	if hostMid > 0 {
		params["host_mid"] = strconv.FormatInt(hostMid, 10)
	}
	logInfo("获取动态列表 type=%s offset=%s host_mid=%d", typ, offset, hostMid)
	endpoint := "https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/all"
	if hostMid > 0 {
		endpoint = "https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/space"
	}
	return c.request(ctx, endpoint, params, "GET")
}

func (c *BilibiliClient) SearchVideos(ctx context.Context, keyword string, page, pageSize int) (json.RawMessage, error) {
	logInfo("搜索视频 keyword=\"%s\" page=%d", keyword, page)
	return c.wbiRequest(ctx, "https://api.bilibili.com/x/web-interface/wbi/search/type", map[string]string{
		"search_type": "video",
		"keyword":     keyword,
		"page":        strconv.Itoa(page),
		"page_size":   strconv.Itoa(pageSize),
	}, "GET")
}

func (c *BilibiliClient) GetVideoInfo(ctx context.Context, aid int, bvid string) (json.RawMessage, error) {
	logInfo("获取视频信息 aid=%d bvid=%s", aid, bvid)
	params := map[string]string{}
	if aid > 0 {
		params["aid"] = strconv.Itoa(aid)
	}
	if bvid != "" {
		params["bvid"] = bvid
	}
	// PiliPlus 使用普通 view；wbi/view 在高 UID 用户上可能返回 2147483647。
	return c.request(ctx, "https://api.bilibili.com/x/web-interface/view", params, "GET")
}

func (c *BilibiliClient) GetVideoRelation(ctx context.Context, aid int, bvid string) (json.RawMessage, error) {
	logInfo("获取视频关系状态 aid=%d bvid=%s", aid, bvid)
	params := map[string]string{}
	if aid > 0 {
		params["aid"] = strconv.Itoa(aid)
	}
	if bvid != "" {
		params["bvid"] = bvid
	}
	return c.request(ctx, "https://api.bilibili.com/x/web-interface/archive/relation", params, "GET")
}

func (c *BilibiliClient) GetVideoRelated(ctx context.Context, aid int, bvid string) (json.RawMessage, error) {
	logInfo("获取视频相关推荐 aid=%d bvid=%s", aid, bvid)
	params := map[string]string{}
	if aid > 0 {
		params["aid"] = strconv.Itoa(aid)
	}
	if bvid != "" {
		params["bvid"] = bvid
	}
	raw, err := c.request(ctx, "https://api.bilibili.com/x/web-interface/archive/related", params, "GET")
	if err != nil {
		return nil, err
	}

	var resp map[string]interface{}
	if err := json.Unmarshal(raw, &resp); err == nil {
		if arr, ok := resp["data"].([]interface{}); ok {
			resp["data"] = map[string]interface{}{"list": arr}
			if merged, mErr := json.Marshal(resp); mErr == nil {
				return merged, nil
			}
		}
	}
	return raw, nil
}

func (c *BilibiliClient) GetVideoComments(ctx context.Context, oid, typ, sortVal, ps, pn int) (json.RawMessage, error) {
	logInfo("获取评论 oid=%d type=%d sort=%d", oid, typ, sortVal)
	return c.request(ctx, "https://api.bilibili.com/x/v2/reply", map[string]string{
		"type": strconv.Itoa(typ),
		"oid":  strconv.Itoa(oid),
		"sort": strconv.Itoa(sortVal),
		"ps":   strconv.Itoa(ps),
		"pn":   strconv.Itoa(pn),
	}, "GET")
}

func (c *BilibiliClient) GetVideoCommentsMain(ctx context.Context, oid, typ, mode, ps int, paginationStr string) (json.RawMessage, error) {
	logInfo("获取评论主列表 oid=%d type=%d mode=%d", oid, typ, mode)
	params := map[string]string{
		"type": strconv.Itoa(typ),
		"oid":  strconv.Itoa(oid),
		"mode": strconv.Itoa(mode),
		"ps":   strconv.Itoa(ps),
	}
	if paginationStr == "" {
		paginationStr = "{\"offset\":\"\"}"
	}
	params["pagination_str"] = paginationStr
	return c.request(ctx, "https://api.bilibili.com/x/v2/reply/main", params, "GET")
}

func (c *BilibiliClient) GetCommentReplies(ctx context.Context, oid, root, typ, ps, pn int) (json.RawMessage, error) {
	logInfo("获取子评论 oid=%d root=%d type=%d", oid, root, typ)
	params := map[string]string{
		"type": strconv.Itoa(typ),
		"oid":  strconv.Itoa(oid),
		"root": strconv.Itoa(root),
		"sort": "1",
		"ps":   strconv.Itoa(ps),
		"pn":   strconv.Itoa(pn),
	}
	if _, biliJct, err := c.requireLogin(); err == nil && biliJct != "" {
		params["csrf"] = biliJct
	}
	return c.request(ctx, "https://api.bilibili.com/x/v2/reply/reply", params, "GET")
}

func (c *BilibiliClient) ToggleCommentLike(ctx context.Context, oid, rpid, typ, action int) (json.RawMessage, error) {
	_, biliJct, err := c.requireLogin()
	if err != nil {
		return nil, err
	}
	if action != 0 && action != 1 {
		action = 1
	}
	return c.webPost(ctx, "https://api.bilibili.com/x/v2/reply/action", map[string]string{
		"oid":    strconv.Itoa(oid),
		"type":   strconv.Itoa(typ),
		"rpid":   strconv.Itoa(rpid),
		"action": strconv.Itoa(action),
		"csrf":   biliJct,
	})
}

func normalizeUserCardInfo(cardResp map[string]interface{}) (map[string]interface{}, bool) {
	data, _ := cardResp["data"].(map[string]interface{})
	if data == nil {
		return nil, false
	}
	card, _ := data["card"].(map[string]interface{})
	if card == nil {
		return nil, false
	}

	result := map[string]interface{}{}
	copyKey := func(dst, src string) {
		if v, ok := card[src]; ok {
			result[dst] = v
		}
	}
	copyKey("mid", "mid")
	copyKey("name", "name")
	copyKey("face", "face")
	copyKey("sign", "sign")
	copyKey("level_info", "level_info")
	copyKey("pendant", "pendant")
	copyKey("nameplate", "nameplate")
	copyKey("vip", "vip")
	copyKey("Official", "Official")
	copyKey("official_verify", "official_verify")
	if v, ok := card["Official"]; ok {
		result["official"] = v
	}
	if v, ok := data["follower"]; ok {
		result["follower"] = v
	}
	if v, ok := data["following"]; ok {
		result["is_following"] = v
	}
	if v, ok := data["archive_count"]; ok {
		result["archive_count"] = v
	}
	if v, ok := data["like_num"]; ok {
		result["like_num"] = v
	}
	return result, true
}

func normalizeUserSpaceAppInfo(spaceResp map[string]interface{}) (map[string]interface{}, bool) {
	data, _ := spaceResp["data"].(map[string]interface{})
	if data == nil {
		return nil, false
	}
	card, _ := data["card"].(map[string]interface{})
	if card == nil {
		return nil, false
	}

	result := map[string]interface{}{}
	copyKey := func(dst, src string) {
		if v, ok := card[src]; ok {
			result[dst] = v
		}
	}
	copyKey("mid", "mid")
	copyKey("name", "name")
	copyKey("face", "face")
	copyKey("sign", "sign")
	copyKey("level_info", "level_info")
	copyKey("pendant", "pendant")
	copyKey("vip", "vip")
	copyKey("official_verify", "official_verify")
	if v, ok := card["fans"]; ok {
		result["follower"] = v
	}
	if v, ok := card["attention"]; ok {
		result["following"] = v
	}
	if v, ok := card["nameplate"]; ok {
		result["nameplate"] = v
	}
	if v, ok := card["relation"]; ok {
		result["relation"] = v
	}
	if relation, ok := data["relation"].(float64); ok {
		result["relation_attribute"] = int(relation)
		result["is_following"] = relation == 2 || relation == 6 || relation == 128 || relation == 129 || relation == 130
	}
	return result, true
}

func (c *BilibiliClient) getUserSpaceAppFallback(ctx context.Context, mid int64) (map[string]interface{}, error) {
	raw, err := c.appRequest(ctx, "https://app.bilibili.com/x/v2/space", map[string]string{
		"build":      "8430300",
		"version":    "8.43.0",
		"c_locale":   "zh_CN",
		"channel":    "master",
		"mobi_app":   "android",
		"platform":   "android",
		"s_locale":   "zh_CN",
		"statistics": appStatistics,
		"vmid":       strconv.FormatInt(mid, 10),
	})
	if err != nil {
		return nil, err
	}

	var resp map[string]interface{}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return nil, err
	}
	if code, ok := resp["code"].(float64); ok && int(code) != 0 {
		return nil, fmt.Errorf("APP空间接口返回 code=%d message=%v", int(code), resp["message"])
	}
	data, ok := normalizeUserSpaceAppInfo(resp)
	if !ok {
		return nil, fmt.Errorf("APP空间接口响应缺少用户卡片")
	}
	return data, nil
}

func (c *BilibiliClient) getUserCardInfoFallback(ctx context.Context, mid int64) (map[string]interface{}, error) {
	raw, err := c.request(ctx, "https://api.bilibili.com/x/web-interface/card", map[string]string{
		"mid":   strconv.FormatInt(mid, 10),
		"photo": "false",
	}, "GET")
	if err != nil {
		return nil, err
	}

	var resp map[string]interface{}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return nil, err
	}
	if code, ok := resp["code"].(float64); ok && int(code) != 0 {
		return nil, fmt.Errorf("card接口返回 code=%d message=%v", int(code), resp["message"])
	}
	data, ok := normalizeUserCardInfo(resp)
	if !ok {
		return nil, fmt.Errorf("card接口响应缺少用户卡片")
	}
	return data, nil
}

func (c *BilibiliClient) getUserInfoFallback(ctx context.Context, mid int64) (map[string]interface{}, string, error) {
	if data, err := c.getUserSpaceAppFallback(ctx, mid); err == nil {
		return data, "APP空间", nil
	} else {
		logWarn("用户信息APP空间兜底失败 mid=%d err=%s", mid, err.Error())
	}
	if data, err := c.getUserCardInfoFallback(ctx, mid); err == nil {
		return data, "card", nil
	} else {
		return nil, "", err
	}
}

func userInfoNeedsFallback(resp map[string]interface{}) bool {
	if code, ok := resp["code"].(float64); ok && int(code) != 0 {
		return true
	}
	data, _ := resp["data"].(map[string]interface{})
	if data == nil {
		return true
	}
	name, _ := data["name"].(string)
	uname, _ := data["uname"].(string)
	face, _ := data["face"].(string)
	return strings.TrimSpace(name) == "" && strings.TrimSpace(uname) == "" && strings.TrimSpace(face) == ""
}

func userInfoResponseFromData(data map[string]interface{}) map[string]interface{} {
	return map[string]interface{}{
		"code":    0,
		"message": "0",
		"data":    data,
	}
}

func (c *BilibiliClient) GetUserInfo(ctx context.Context, mid int64) (json.RawMessage, error) {
	logInfo("获取用户信息 mid=%d", mid)

	var baseResp map[string]interface{}
	if baseResp == nil {
		baseRaw, err := c.wbiRequest(ctx, "https://api.bilibili.com/x/space/wbi/acc/info", map[string]string{
			"mid":              strconv.FormatInt(mid, 10),
			"token":            "",
			"platform":         "web",
			"web_location":     "1550101",
			"dm_img_list":      "[]",
			"dm_img_str":       "",
			"dm_cover_img_str": "",
			"dm_img_inter":     `{"ds":[],"wh":[0,0,0],"of":[0,0,0]}`,
		}, "GET")
		if err != nil {
			if fallbackData, source, fallbackErr := c.getUserInfoFallback(ctx, mid); fallbackErr == nil {
				logWarn("用户信息主接口请求失败，使用%s兜底 mid=%d err=%s", source, mid, err.Error())
				baseResp = userInfoResponseFromData(fallbackData)
			} else {
				return nil, err
			}
		} else if err := json.Unmarshal(baseRaw, &baseResp); err != nil {
			return nil, err
		}
	}

	if userInfoNeedsFallback(baseResp) {
		if fallbackData, source, fallbackErr := c.getUserInfoFallback(ctx, mid); fallbackErr == nil {
			logWarn("用户信息主接口失败或为空，使用%s兜底 mid=%d", source, mid)
			baseResp = userInfoResponseFromData(fallbackData)
		} else if code, ok := baseResp["code"].(float64); ok && int(code) != 0 {
			logWarn("用户信息兜底失败 mid=%d err=%s", mid, fallbackErr.Error())
			baseRaw, _ := json.Marshal(baseResp)
			return baseRaw, nil
		}
	}

	dataObj, _ := baseResp["data"].(map[string]interface{})
	if dataObj == nil {
		dataObj = map[string]interface{}{}
		baseResp["data"] = dataObj
	}

	// 补充粉丝/关注统计
	relRaw, err := c.request(ctx, "https://api.bilibili.com/x/relation/stat", map[string]string{
		"vmid": strconv.FormatInt(mid, 10),
	}, "GET")
	if err == nil {
		var relResp map[string]interface{}
		if json.Unmarshal(relRaw, &relResp) == nil {
			if relCode, ok := relResp["code"].(float64); ok && int(relCode) == 0 {
				if relData, ok := relResp["data"].(map[string]interface{}); ok {
					if follower, ok := relData["follower"]; ok {
						dataObj["follower"] = follower
					}
					if following, ok := relData["following"]; ok {
						dataObj["following"] = following
					}
				}
			}
		}
	}

	// 补充当前登录用户与该 UP 的关注关系。查询自己的信息时不需要打该接口，
	// 否则登录后初始化会额外增加一次上游请求，更容易触发风控。
	sessdata, _, _, _, dedeUserID, _ := c.getAuth()
	if sessdata != "" && dedeUserID != strconv.FormatInt(mid, 10) {
		relationRaw, err := c.GetUserRelation(ctx, mid)
		if err == nil {
			var relationResp map[string]interface{}
			if json.Unmarshal(relationRaw, &relationResp) == nil {
				if relationCode, ok := relationResp["code"].(float64); ok && int(relationCode) == 0 {
					if relationData, ok := relationResp["data"].(map[string]interface{}); ok {
						attribute := 0
						if v, ok := relationData["attribute"].(float64); ok {
							attribute = int(v)
						}
						isFollowing := attribute == 2 || attribute == 6 || attribute == 128 || attribute == 129 || attribute == 130
						dataObj["relation_attribute"] = attribute
						dataObj["is_following"] = isFollowing
					}
				}
			}
		}
	}

	merged, err := json.Marshal(baseResp)
	if err != nil {
		return nil, err
	}
	return merged, nil
}

func (c *BilibiliClient) GetUserRelation(ctx context.Context, mid int64) (json.RawMessage, error) {
	logInfo("获取用户关系 mid=%d", mid)
	return c.request(ctx, "https://api.bilibili.com/x/relation", map[string]string{
		"fid": strconv.FormatInt(mid, 10),
	}, "GET")
}

func (c *BilibiliClient) ToggleUserFollow(ctx context.Context, mid int64, follow bool) (json.RawMessage, error) {
	_, biliJct, err := c.requireLogin()
	if err != nil {
		return nil, err
	}

	act := "2"
	if follow {
		act = "1"
	}

	logInfo("切换关注状态 mid=%d follow=%t", mid, follow)
	return c.webPost(ctx, "https://api.bilibili.com/x/relation/modify", map[string]string{
		"fid":        strconv.FormatInt(mid, 10),
		"act":        act,
		"re_src":     "11",
		"csrf":       biliJct,
		"csrf_token": biliJct,
	})
}

// GetUserVideosApp 使用 APP 游标接口获取投稿。
// 注意：该接口实际使用 aid 作为游标参数（不是时间戳）。
// cursorAid=0 表示首次；cursorAid>0 表示从“上一页最后一个视频的 aid”继续向后翻页。
func (c *BilibiliClient) GetUserVideosApp(ctx context.Context, mid int64, cursorAid int64, ps int, includeCursor bool, sortOrder string) (json.RawMessage, error) {
	if ps <= 0 {
		ps = 20
	}
	if ps > 30 {
		ps = 30
	}
	logInfo("获取用户投稿(APP) mid=%d aid=%d ps=%d", mid, cursorAid, ps)

	params := map[string]string{
		"vmid": strconv.FormatInt(mid, 10),
		// 该接口是游标分页：用 aid 翻页更稳定，pn 固定为 1
		"pn":       "1",
		"ps":       strconv.Itoa(ps),
		"order":    "pubdate",
		"build":    "8430300",
		"version":  "8.43.0",
		"c_locale": "zh_CN",
		"s_locale": "zh_CN",
		"channel":  "master",
		"platform": "android",
		"mobi_app": "android",
		"device":   "android",
		"ts":       strconv.FormatInt(time.Now().Unix(), 10),
	}
	if cursorAid > 0 {
		params["aid"] = strconv.FormatInt(cursorAid, 10)
	}
	if includeCursor {
		params["include_cursor"] = "true"
	}
	if sortOrder != "" {
		params["sort"] = sortOrder
	}
	params = appSign(params)
	raw, err := c.request(ctx, "https://app.biliapi.com/x/v2/space/archive/cursor", params, "GET")
	if err != nil {
		return nil, err
	}

	// 修正偶发返回列表顺序异常（旧稿件在前）的问题
	var resp map[string]interface{}
	if err := json.Unmarshal(raw, &resp); err == nil {
		if code, ok := resp["code"].(float64); ok && int(code) == 0 {
			data, _ := resp["data"].(map[string]interface{})
			if data != nil {
				if data["last_watched_locator"] != nil {
					return raw, nil
				}
				list, listKey := data["item"], "item"
				if list == nil {
					list = data["archives"]
					listKey = "archives"
				}
				if arr, ok := list.([]interface{}); ok && len(arr) > 1 {
					sort.SliceStable(arr, func(i, j int) bool {
						getTime := func(v interface{}) int64 {
							obj, _ := v.(map[string]interface{})
							if obj == nil {
								return 0
							}
							if t, ok := obj["pubdate"].(float64); ok {
								return int64(t)
							}
							if t, ok := obj["ctime"].(float64); ok {
								return int64(t)
							}
							if t, ok := obj["created"].(float64); ok {
								return int64(t)
							}
							if arc, ok := obj["archive"].(map[string]interface{}); ok {
								if t, ok := arc["pubdate"].(float64); ok {
									return int64(t)
								}
								if t, ok := arc["ctime"].(float64); ok {
									return int64(t)
								}
								if t, ok := arc["created"].(float64); ok {
									return int64(t)
								}
							}
							return 0
						}
						return getTime(arr[i]) > getTime(arr[j])
					})
					data[listKey] = arr
					resp["data"] = data
					if merged, mErr := json.Marshal(resp); mErr == nil {
						return merged, nil
					}
				}
			}
		}
	}

	return raw, nil
}

func (c *BilibiliClient) GetUserVideos(ctx context.Context, mid int64, pn, ps int, max, targetAid int64, includeCursor bool, sortOrder string) (json.RawMessage, error) {
	logInfo("获取用户投稿 mid=%d pn=%d ps=%d max=%d targetAid=%d includeCursor=%t sort=%s", mid, pn, ps, max, targetAid, includeCursor, sortOrder)

	// 经验：网页端 x/space/wbi/arc/search 更容易触发 -412 / 风控页，
	// 且 pn 翻页在 UP 有新稿件插入时更容易出现重复/缺失。
	// 因此这里默认使用 APP 游标接口 x/v2/space/archive/cursor。
	//
	// 前端分页策略：
	// - 首次请求 max=0
	// - 加载更多时传入上一次返回的 cursor.next/max 作为 max
	//
	// 兼容 pn>1（但未给 max）的情况：通过多次游标前进到目标页。
	if pn < 1 {
		pn = 1
	}
	if targetAid > 0 {
		return c.GetUserVideosApp(ctx, mid, targetAid, ps, includeCursor, sortOrder)
	}

	cursor := max
	var raw json.RawMessage
	var err error

	// 如果没有提供 cursor，但要求 pn>1，则先把 cursor 向后推进 (pn-1) 页
	// 该接口的 cursor 实际为 aid：即“上一页最后一个视频的 aid”（通常在 item[].param 字段）。
	if cursor <= 0 && pn > 1 {
		for i := 1; i < pn; i++ {
			raw, err = c.GetUserVideosApp(ctx, mid, cursor, ps, false, "")
			if err != nil {
				return nil, err
			}
			var resp map[string]interface{}
			if json.Unmarshal(raw, &resp) != nil {
				break
			}
			code, _ := resp["code"].(float64)
			if int(code) != 0 {
				// 业务错误直接返回，让上层 wrapResult 透出 message
				return raw, nil
			}
			data, _ := resp["data"].(map[string]interface{})
			if data == nil {
				break
			}
			// 优先从 data.cursor 读取（若存在）
			if cursorObj, ok := data["cursor"].(map[string]interface{}); ok && cursorObj != nil {
				if nextF, ok := cursorObj["next"].(float64); ok && int64(nextF) > 0 {
					cursor = int64(nextF)
				} else if maxF, ok := cursorObj["max"].(float64); ok && int64(maxF) > 0 {
					cursor = int64(maxF)
				}
			}

			// 兜底：从 item 最后一条的 param(=aid) 提取下一页游标
			if cursor <= 0 {
				if arr, ok := data["item"].([]interface{}); ok && len(arr) > 0 {
					if last, ok := arr[len(arr)-1].(map[string]interface{}); ok {
						if p, ok := last["param"].(string); ok {
							if v, e := strconv.ParseInt(p, 10, 64); e == nil {
								cursor = v
							}
						}
					}
				}
			}

			if cursor <= 0 {
				break
			}
		}
	}

	// 取目标页
	raw, err = c.GetUserVideosApp(ctx, mid, cursor, ps, false, "")
	if err != nil {
		return nil, err
	}
	return raw, nil
}

func (c *BilibiliClient) GetUserSearchVideos(ctx context.Context, mid int64, keyword string, pn, ps int) (json.RawMessage, error) {
	keyword = strings.TrimSpace(keyword)
	if ps <= 0 {
		ps = 20
	}
	if ps > 30 {
		ps = 30
	}
	if pn < 1 {
		pn = 1
	}

	logInfo("搜索 UP 投稿 mid=%d keyword=\"%s\" pn=%d ps=%d", mid, keyword, pn, ps)
	return c.wbiRequest(ctx, "https://api.bilibili.com/x/space/wbi/arc/search", map[string]string{
		"mid":           strconv.FormatInt(mid, 10),
		"keyword":       keyword,
		"pn":            strconv.Itoa(pn),
		"ps":            strconv.Itoa(ps),
		"order":         "pubdate",
		"platform":      "web",
		"web_location":  "333.1387",
		"order_avoided": "true",
	}, "GET")
}

func metaInt64(obj map[string]interface{}, key string) int64 {
	v, ok := obj[key]
	if !ok || v == nil {
		return 0
	}
	switch x := v.(type) {
	case float64:
		return int64(x)
	case string:
		n, _ := strconv.ParseInt(x, 10, 64)
		return n
	case int:
		return int64(x)
	case int64:
		return x
	default:
		return 0
	}
}

func filterListByMetaMid(list interface{}, mid int64, key string) interface{} {
	items, ok := list.([]interface{})
	if !ok || mid <= 0 {
		return list
	}
	filtered := make([]interface{}, 0, len(items))
	for _, item := range items {
		obj, _ := item.(map[string]interface{})
		meta, _ := obj["meta"].(map[string]interface{})
		metaMid := metaInt64(meta, "mid")
		if metaMid > 0 && metaMid != mid {
			logWarn("过滤归属不匹配的%s条目 request_mid=%d meta_mid=%d", key, mid, metaMid)
			continue
		}
		filtered = append(filtered, item)
	}
	return filtered
}

func filterSeasonsSeriesByMid(raw json.RawMessage, mid int64) json.RawMessage {
	var resp map[string]interface{}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return raw
	}
	if code, ok := resp["code"].(float64); ok && int(code) != 0 {
		return raw
	}
	data, _ := resp["data"].(map[string]interface{})
	itemsLists, _ := data["items_lists"].(map[string]interface{})
	if itemsLists == nil {
		return raw
	}

	requestMid := mid
	itemsLists["seasons_list"] = filterListByMetaMid(itemsLists["seasons_list"], requestMid, "seasons_list")
	itemsLists["series_list"] = filterListByMetaMid(itemsLists["series_list"], requestMid, "series_list")

	merged, err := json.Marshal(resp)
	if err != nil {
		return raw
	}
	return merged
}

func seasonMetaMismatchError(message string, requestMid int64, requestSeasonID int, metaMid int64, metaSeasonID int64) json.RawMessage {
	body, _ := json.Marshal(map[string]interface{}{
		"code":    -1,
		"message": message,
		"data": map[string]interface{}{
			"request_mid":       requestMid,
			"request_season_id": requestSeasonID,
			"meta_mid":          metaMid,
			"meta_season_id":    metaSeasonID,
		},
	})
	return body
}

func validateSeasonArchivesMeta(raw json.RawMessage, mid int64, seasonID int) json.RawMessage {
	var resp map[string]interface{}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return raw
	}
	if code, ok := resp["code"].(float64); ok && int(code) != 0 {
		return raw
	}
	data, _ := resp["data"].(map[string]interface{})
	meta, _ := data["meta"].(map[string]interface{})
	if meta == nil {
		return raw
	}
	metaMid := metaInt64(meta, "mid")
	metaSeasonID := metaInt64(meta, "season_id")
	if metaMid > 0 && metaMid != mid {
		logWarn("合集归属 mid 不匹配 request_mid=%d meta_mid=%d season_id=%d", mid, metaMid, seasonID)
		return seasonMetaMismatchError("合集归属不匹配", mid, seasonID, metaMid, metaSeasonID)
	}
	if metaSeasonID > 0 && metaSeasonID != int64(seasonID) {
		logWarn("合集 season_id 不匹配 request_season=%d meta_season=%d mid=%d", seasonID, metaSeasonID, mid)
		return seasonMetaMismatchError("合集ID不匹配", mid, seasonID, metaMid, metaSeasonID)
	}
	return raw
}

// 获取 UP 主的合集与系列列表（合集 = seasons，系列 = series）
// 文档接口：/x/polymer/web-space/seasons_series_list，返回 data.items_lists.{seasons_list, series_list, page}。
func (c *BilibiliClient) GetUserSeasonsSeries(ctx context.Context, mid int64, pn, ps int) (json.RawMessage, error) {
	logInfo("获取 UP 合集/系列列表 mid=%d pn=%d ps=%d", mid, pn, ps)
	raw, err := c.wbiRequest(ctx, "https://api.bilibili.com/x/polymer/web-space/seasons_series_list", map[string]string{
		"mid":          strconv.FormatInt(mid, 10),
		"page_num":     strconv.Itoa(pn),
		"page_size":    strconv.Itoa(ps),
		"web_location": "333.999",
	}, "GET")
	if err != nil {
		return nil, err
	}
	return filterSeasonsSeriesByMid(raw, mid), nil
}

// 获取 UP 主合集内的视频列表
func (c *BilibiliClient) GetUserSeasonVideos(ctx context.Context, mid int64, seasonID, pn, ps int, sortReverse bool) (json.RawMessage, error) {
	logInfo("获取 UP 合集视频 mid=%d season=%d pn=%d ps=%d", mid, seasonID, pn, ps)
	sr := "false"
	if sortReverse {
		sr = "true"
	}
	raw, err := c.wbiRequest(ctx, "https://api.bilibili.com/x/polymer/web-space/seasons_archives_list", map[string]string{
		"mid":          strconv.FormatInt(mid, 10),
		"season_id":    strconv.Itoa(seasonID),
		"sort_reverse": sr,
		"page_num":     strconv.Itoa(pn),
		"page_size":    strconv.Itoa(ps),
		"web_location": "333.999",
	}, "GET")
	if err != nil {
		return nil, err
	}
	return validateSeasonArchivesMeta(raw, mid, seasonID), nil
}

// 获取 UP 主系列内的视频列表。
func (c *BilibiliClient) GetUserSeriesVideos(ctx context.Context, mid int64, seriesID, pn, ps int, sortOrder string) (json.RawMessage, error) {
	if ps <= 0 {
		ps = 30
	}
	if ps > 100 {
		ps = 100
	}
	if pn < 1 {
		pn = 1
	}
	if sortOrder == "" {
		sortOrder = "desc"
	}
	logInfo("获取 UP 系列视频 mid=%d series=%d pn=%d ps=%d sort=%s", mid, seriesID, pn, ps, sortOrder)
	params := map[string]string{
		"vmid":      strconv.FormatInt(mid, 10),
		"series_id": strconv.Itoa(seriesID),
		"pn":        strconv.Itoa(pn),
		"ps":        strconv.Itoa(ps),
		"sort":      sortOrder,
		"build":     "8430300",
		"version":   "8.43.0",
		"c_locale":  "zh_CN",
		"s_locale":  "zh_CN",
		"channel":   "master",
		"platform":  "android",
		"mobi_app":  "android",
		"device":    "android",
		"ts":        strconv.FormatInt(time.Now().Unix(), 10),
	}
	params = appSign(params)
	return c.request(ctx, "https://app.biliapi.com/x/v2/space/series", params, "GET")
}

func (c *BilibiliClient) GetLoginInfo(ctx context.Context) (json.RawMessage, error) {
	logInfo("获取登录信息")
	return c.request(ctx, "https://api.bilibili.com/x/web-interface/nav", map[string]string{}, "GET")
}

func (c *BilibiliClient) GetPlayerV2(ctx context.Context, aid, cid int, bvid string) (json.RawMessage, error) {
	params := map[string]string{
		"aid": strconv.Itoa(aid),
		"cid": strconv.Itoa(cid),
	}
	if bvid != "" {
		params["bvid"] = bvid
	}
	return c.wbiRequest(ctx, "https://api.bilibili.com/x/player/wbi/v2", params, "GET")
}

func (c *BilibiliClient) GetPlayUrl(ctx context.Context, aid, cid, qn, fnval int, platform string) (json.RawMessage, error) {
	if qn <= 0 {
		qn = 32
	}
	if fnval <= 0 {
		fnval = 4048
	}
	if platform == "" {
		platform = "pc"
	}

	allowedQn := map[int]bool{
		16:  true,
		32:  true,
		64:  true,
		80:  true,
		112: true,
		116: true,
		120: true,
		125: true,
	}
	if !allowedQn[qn] {
		logWarn("不支持的清晰度 qn=%d，回退到 32", qn)
		qn = 32
	}

	logInfo("获取播放地址 aid=%d cid=%d qn=%d fnval=%d platform=%s", aid, cid, qn, fnval, platform)
	return c.wbiRequest(ctx, "https://api.bilibili.com/x/player/wbi/playurl", map[string]string{
		"avid":             strconv.Itoa(aid),
		"cid":              strconv.Itoa(cid),
		"qn":               strconv.Itoa(qn),
		"type":             "",
		"otype":            "json",
		"fourk":            "1",
		"fnver":            "0",
		"fnval":            strconv.Itoa(fnval),
		"platform":         platform,
		"gaia_source":      "pre-load",
		"isGaiaAvoided":    "true",
		"web_location":     "1315873",
		"try_look":         "1",
		"dm_img_list":      "[]",
		"dm_img_str":       "",
		"dm_cover_img_str": "",
		"dm_img_inter":     "{}",
		"cur_language":     "",
	}, "GET")
}

func (c *BilibiliClient) GetDanmaku(ctx context.Context, cid, segment int) ([]byte, error) {
	logInfo("获取弹幕 cid=%d segment=%d", cid, segment)
	return c.rawRequest(ctx, "https://api.bilibili.com/x/v2/dm/web/seg.so", map[string]string{
		"type":          "1",
		"oid":           strconv.Itoa(cid),
		"segment_index": strconv.Itoa(segment),
	})
}

func (c *BilibiliClient) GetDanmakuConfig(ctx context.Context, oid int, pid int) (json.RawMessage, error) {
	logInfo("获取弹幕配置 oid=%d pid=%d", oid, pid)
	params := map[string]string{
		"type": "1",
		"oid":  strconv.Itoa(oid),
	}
	if pid > 0 {
		params["pid"] = strconv.Itoa(pid)
	}
	return c.request(ctx, "https://api.bilibili.com/x/v2/dm/web/view", params, "GET")
}

func (c *BilibiliClient) GetHotSearch(ctx context.Context, limit int) (json.RawMessage, error) {
	logInfo("获取热搜 limit=%d", limit)
	return c.request(ctx, "https://api.bilibili.com/x/web-interface/search/square", map[string]string{
		"limit": strconv.Itoa(limit),
	}, "GET")
}

func (c *BilibiliClient) GetRecommend(ctx context.Context, freshType int) (json.RawMessage, error) {
	logInfo("获取推荐 feed fresh_type=%d", freshType)
	raw, err := c.wbiRequest(ctx, "https://api.bilibili.com/x/web-interface/wbi/index/top/feed/rcmd", map[string]string{
		"fresh_type": strconv.Itoa(freshType),
	}, "GET")
	if err != nil {
		return nil, err
	}
	return c.enrichRecommendPartCounts(ctx, raw), nil
}

func (c *BilibiliClient) enrichRecommendPartCounts(ctx context.Context, raw json.RawMessage) json.RawMessage {
	var resp map[string]interface{}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return raw
	}
	if code := jsonInt64Value(resp, "code"); code != 0 {
		return raw
	}

	data, _ := resp["data"].(map[string]interface{})
	if data == nil {
		return raw
	}

	items := recommendItemObjects(data)
	if len(items) == 0 {
		return raw
	}

	const (
		enrichLimit       = 12
		enrichConcurrency = 4
	)

	sem := make(chan struct{}, enrichConcurrency)
	var wg sync.WaitGroup
	started := 0

	for _, item := range items {
		if ctx.Err() != nil || started >= enrichLimit {
			break
		}

		if count := recommendPartCountFromItem(item); count > 0 {
			setRecommendPartCount(item, count)
			continue
		}

		aid, bvid, ok := recommendVideoIdentity(item)
		if !ok {
			continue
		}

		started++
		wg.Add(1)
		go func(item map[string]interface{}, aid int, bvid string) {
			defer wg.Done()

			select {
			case sem <- struct{}{}:
				defer func() { <-sem }()
			case <-ctx.Done():
				return
			}

			detail, err := c.GetVideoInfo(ctx, aid, bvid)
			if err != nil {
				logDebug("推荐分P补齐失败 aid=%d bvid=%s err=%s", aid, bvid, err.Error())
				return
			}
			if count := videoInfoPartCount(detail); count > 0 {
				setRecommendPartCount(item, count)
			}
		}(item, aid, bvid)
	}

	wg.Wait()

	merged, err := json.Marshal(resp)
	if err != nil {
		return raw
	}
	return merged
}

func recommendItemObjects(data map[string]interface{}) []map[string]interface{} {
	items := make([]map[string]interface{}, 0, 16)
	for _, key := range []string{"item", "items", "list", "result"} {
		arr, ok := data[key].([]interface{})
		if !ok {
			continue
		}
		for _, value := range arr {
			if obj, ok := value.(map[string]interface{}); ok && obj != nil {
				items = append(items, obj)
			}
		}
	}
	return items
}

func recommendVideoIdentity(item map[string]interface{}) (int, string, bool) {
	bvid := jsonStringValue(item, "bvid", "bvid_str")
	gotoType := jsonStringValue(item, "goto", "card_goto")
	aid := int(jsonInt64Value(item, "aid"))

	if aid <= 0 && (gotoType == "" || gotoType == "av" || gotoType == "video") {
		aid = int(jsonInt64Value(item, "id"))
	}
	if aid <= 0 {
		param := strings.TrimSpace(jsonStringValue(item, "param"))
		if param != "" {
			if parsed, err := strconv.ParseInt(param, 10, 64); err == nil {
				aid = int(parsed)
			}
		}
	}

	if bvid == "" && aid <= 0 {
		return 0, "", false
	}
	if bvid == "" && gotoType != "" && gotoType != "av" && gotoType != "video" {
		return 0, "", false
	}
	return aid, bvid, true
}

func recommendPartCountFromItem(item map[string]interface{}) int {
	if count := partCountFromObject(item); count > 0 {
		return count
	}
	for _, key := range []string{"archive", "arc", "video"} {
		nested, _ := item[key].(map[string]interface{})
		if nested == nil {
			continue
		}
		if count := partCountFromObject(nested); count > 0 {
			return count
		}
	}
	return 0
}

func videoInfoPartCount(raw json.RawMessage) int {
	var resp map[string]interface{}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return 0
	}
	if code := jsonInt64Value(resp, "code"); code != 0 {
		return 0
	}
	data, _ := resp["data"].(map[string]interface{})
	if data == nil {
		return 0
	}
	return partCountFromObject(data)
}

func partCountFromObject(obj map[string]interface{}) int {
	if obj == nil {
		return 0
	}
	for _, key := range []string{"videos", "page_count", "pages_count", "part_count", "parts"} {
		if count := jsonInt64Value(obj, key); count > 0 {
			return int(count)
		}
	}
	if pages, ok := obj["pages"].([]interface{}); ok && len(pages) > 0 {
		return len(pages)
	}
	if count := numericInt64(obj["pages"]); count > 0 {
		return int(count)
	}
	return 0
}

func setRecommendPartCount(item map[string]interface{}, count int) {
	if item == nil || count <= 0 {
		return
	}
	item["videos"] = count
	item["part_count"] = count
	item["page_count"] = count
}

func jsonStringValue(obj map[string]interface{}, keys ...string) string {
	for _, key := range keys {
		switch value := obj[key].(type) {
		case string:
			if trimmed := strings.TrimSpace(value); trimmed != "" {
				return trimmed
			}
		case json.Number:
			if s := strings.TrimSpace(value.String()); s != "" {
				return s
			}
		case float64:
			if value > 0 {
				return strconv.FormatInt(int64(value), 10)
			}
		case int:
			if value > 0 {
				return strconv.Itoa(value)
			}
		case int64:
			if value > 0 {
				return strconv.FormatInt(value, 10)
			}
		}
	}
	return ""
}

func jsonInt64Value(obj map[string]interface{}, keys ...string) int64 {
	for _, key := range keys {
		if value := numericInt64(obj[key]); value != 0 {
			return value
		}
	}
	return 0
}

func numericInt64(value interface{}) int64 {
	switch v := value.(type) {
	case float64:
		return int64(v)
	case float32:
		return int64(v)
	case int:
		return int64(v)
	case int64:
		return v
	case int32:
		return int64(v)
	case json.Number:
		if n, err := v.Int64(); err == nil {
			return n
		}
		if f, err := strconv.ParseFloat(v.String(), 64); err == nil {
			return int64(f)
		}
	case string:
		s := strings.TrimSpace(v)
		if s == "" {
			return 0
		}
		if n, err := strconv.ParseInt(s, 10, 64); err == nil {
			return n
		}
		if f, err := strconv.ParseFloat(s, 64); err == nil {
			return int64(f)
		}
	}
	return 0
}
