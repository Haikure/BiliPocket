package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"
)

func (c *BilibiliClient) GetRecentHistory(ctx context.Context, max, viewAt int64, ps int) (json.RawMessage, error) {
	logInfo("获取最近观看 max=%d view_at=%d ps=%d", max, viewAt, ps)
	params := map[string]string{}
	if max > 0 {
		params["max"] = strconv.FormatInt(max, 10)
	}
	if viewAt > 0 {
		params["view_at"] = strconv.FormatInt(viewAt, 10)
	}
	if ps > 0 {
		params["ps"] = strconv.Itoa(ps)
	}
	params["business"] = "archive"
	return c.request(ctx, "https://api.bilibili.com/x/web-interface/history/cursor", params, "GET")
}

func (c *BilibiliClient) SearchHistory(ctx context.Context, keyword string, pn int) (json.RawMessage, error) {
	keyword = strings.TrimSpace(keyword)
	if pn <= 0 {
		pn = 1
	}
	logInfo("搜索历史 keyword=%s pn=%d", keyword, pn)
	return c.request(ctx, "https://api.bilibili.com/x/web-interface/history/search", map[string]string{
		"pn":       strconv.Itoa(pn),
		"keyword":  keyword,
		"business": "all",
	}, "GET")
}

func (c *BilibiliClient) DeleteHistory(ctx context.Context, kid string) (json.RawMessage, error) {
	_, biliJct, err := c.requireLogin()
	if err != nil {
		return nil, err
	}
	kid = strings.TrimSpace(kid)
	if kid == "" {
		return nil, fmt.Errorf("kid 为空")
	}
	logInfo("删除历史 kid=%s", kid)
	return c.webPost(ctx, "https://api.bilibili.com/x/v2/history/delete", map[string]string{
		"kid":   kid,
		"jsonp": "jsonp",
		"csrf":  biliJct,
	})
}

func (c *BilibiliClient) GetWatchLaterList(ctx context.Context, pn, ps int) (json.RawMessage, error) {
	if pn <= 0 {
		pn = 1
	}
	if ps <= 0 {
		ps = 20
	}
	if ps > 50 {
		ps = 50
	}
	logInfo("获取稍后再看 pn=%d ps=%d", pn, ps)
	params := map[string]string{
		"pn": strconv.Itoa(pn),
		"ps": strconv.Itoa(ps),
	}
	return c.request(ctx, "https://api.bilibili.com/x/v2/history/toview", params, "GET")
}

func (c *BilibiliClient) AddToWatchLater(ctx context.Context, aid int, bvid string) (json.RawMessage, error) {
	_, biliJct, err := c.requireLogin()
	if err != nil {
		return nil, err
	}
	params := map[string]string{
		"csrf": biliJct,
	}
	if bvid != "" {
		params["bvid"] = bvid
	} else if aid > 0 {
		params["aid"] = strconv.Itoa(aid)
	} else {
		return nil, fmt.Errorf("aid 或 bvid 缺失")
	}
	return c.webPost(ctx, "https://api.bilibili.com/x/v2/history/toview/add", params)
}

func (c *BilibiliClient) RemoveFromWatchLater(ctx context.Context, aid int) (json.RawMessage, error) {
	_, biliJct, err := c.requireLogin()
	if err != nil {
		return nil, err
	}
	if aid <= 0 {
		return nil, fmt.Errorf("aid 缺失")
	}
	params := map[string]string{
		"csrf": biliJct,
		"aid":  strconv.Itoa(aid),
	}
	return c.webPost(ctx, "https://api.bilibili.com/x/v2/history/toview/del", params)
}

func (c *BilibiliClient) GetFavoriteFolders(ctx context.Context, mid int64) (json.RawMessage, error) {
	logInfo("获取收藏夹列表 mid=%d", mid)
	return c.request(ctx, "https://api.bilibili.com/x/v3/fav/folder/created/list-all", map[string]string{
		"up_mid": strconv.FormatInt(mid, 10),
	}, "GET")
}

func (c *BilibiliClient) GetFavoriteFoldersForResource(ctx context.Context, mid int64, aid int) (json.RawMessage, error) {
	logInfo("获取视频所在收藏夹 mid=%d aid=%d", mid, aid)
	return c.request(ctx, "https://api.bilibili.com/x/v3/fav/folder/created/list-all", map[string]string{
		"up_mid": strconv.FormatInt(mid, 10),
		"type":   "2",
		"rid":    strconv.Itoa(aid),
	}, "GET")
}

func (c *BilibiliClient) GetFavoriteResources(ctx context.Context, mediaId, pn, ps int) (json.RawMessage, error) {
	logInfo("获取收藏夹内容 media_id=%d pn=%d ps=%d", mediaId, pn, ps)
	return c.request(ctx, "https://api.bilibili.com/x/v3/fav/resource/list", map[string]string{
		"media_id": strconv.Itoa(mediaId),
		"pn":       strconv.Itoa(pn),
		"ps":       strconv.Itoa(ps),
		"order":    "mtime",
		"type":     "0",
	}, "GET")
}

func (c *BilibiliClient) GetFavoriteStatus(ctx context.Context, aid int) (json.RawMessage, error) {
	logInfo("获取收藏状态 aid=%d", aid)
	return c.request(ctx, "https://api.bilibili.com/x/v2/fav/video/favoured", map[string]string{
		"aid": strconv.Itoa(aid),
	}, "GET")
}

func (c *BilibiliClient) GetCoinStatus(ctx context.Context, aid int, bvid string) (json.RawMessage, error) {
	logInfo("获取投币状态 aid=%d bvid=%s", aid, bvid)
	params := map[string]string{}
	if bvid != "" {
		params["bvid"] = bvid
	} else if aid > 0 {
		params["aid"] = strconv.Itoa(aid)
	}
	return c.request(ctx, "https://api.bilibili.com/x/web-interface/archive/coins", params, "GET")
}

func (c *BilibiliClient) AddCoin(ctx context.Context, aid int, multiply int, selectLike bool, bvid string) (json.RawMessage, error) {
	_, buvid3, biliJct, err := c.requireRiskAuth()
	if err != nil {
		return nil, err
	}
	logInfo("投币请求认证信息: buvid3=%s", maskSensitive(buvid3))
	if multiply < 1 {
		multiply = 1
	}
	if multiply > 2 {
		multiply = 2
	}
	like := "0"
	if selectLike {
		like = "1"
	}
	params := map[string]string{
		"multiply":    strconv.Itoa(multiply),
		"select_like": like,
		"csrf":        biliJct,
	}
	if bvid != "" {
		params["bvid"] = bvid
	} else if aid > 0 {
		params["aid"] = strconv.Itoa(aid)
	}

	apiURL := "https://api.bilibili.com/x/web-interface/coin/add"
	return c.webPost(ctx, apiURL, params)
}

func (c *BilibiliClient) GetLikeStatus(ctx context.Context, aid int, bvid string) (json.RawMessage, error) {
	logInfo("获取点赞状态 aid=%d bvid=%s", aid, bvid)
	params := map[string]string{}
	if bvid != "" {
		params["bvid"] = bvid
	} else if aid > 0 {
		params["aid"] = strconv.Itoa(aid)
	}
	return c.request(ctx, "https://api.bilibili.com/x/web-interface/archive/has/like", params, "GET")
}

func (c *BilibiliClient) ToggleLike(ctx context.Context, aid int, like int, bvid string) (json.RawMessage, error) {
	_, buvid3, biliJct, err := c.requireRiskAuth()
	if err != nil {
		return nil, err
	}
	logInfo("点赞请求认证信息: buvid3=%s", maskSensitive(buvid3))
	if like != 1 && like != 2 {
		like = 1
	}
	params := map[string]string{
		"like": strconv.Itoa(like),
		"csrf": biliJct,
	}
	if bvid != "" {
		params["bvid"] = bvid
	} else if aid > 0 {
		params["aid"] = strconv.Itoa(aid)
	}

	apiURL := "https://api.bilibili.com/x/web-interface/archive/like"
	return c.webPost(ctx, apiURL, params)
}

func (c *BilibiliClient) ToggleFavorite(ctx context.Context, aid int, add bool, mediaIds []int) (json.RawMessage, error) {
	_, biliJct, err := c.requireLogin()
	if err != nil {
		return nil, err
	}
	mediaIDParam := joinIntParams(mediaIds)
	if mediaIDParam == "" {
		return nil, fmt.Errorf("收藏夹ID无效")
	}

	addMedia := ""
	delMedia := ""
	if add {
		addMedia = mediaIDParam
	} else {
		delMedia = mediaIDParam
	}

	return c.webPost(ctx, "https://api.bilibili.com/x/v3/fav/resource/deal", map[string]string{
		"rid":           strconv.Itoa(aid),
		"type":          "2",
		"add_media_ids": addMedia,
		"del_media_ids": delMedia,
		"csrf":          biliJct,
	})
}

func (c *BilibiliClient) ReportHeartbeat(ctx context.Context, aid, cid int, bvid string, playedTime int, videoDuration int, extra map[string]string) (json.RawMessage, error) {
	_, biliJct, err := c.requireLogin()
	if err != nil {
		return nil, err
	}
	playType := extra["play_type"]
	if playType == "" {
		playType = "0"
		if playedTime == -1 {
			playType = "4"
		}
	}
	videoType := extra["type"]
	if videoType == "" {
		videoType = "3"
	}
	params := map[string]string{
		"aid":              strconv.Itoa(aid),
		"cid":              strconv.Itoa(cid),
		"bvid":             bvid,
		"played_time":      strconv.Itoa(playedTime),
		"real_played_time": strconv.Itoa(playedTime),
		"start_ts":         strconv.FormatInt(time.Now().Unix(), 10),
		"type":             videoType,
		"dt":               "2",
		"play_type":        playType,
		"csrf":             biliJct,
	}
	if videoDuration > 0 {
		params["video_duration"] = strconv.Itoa(videoDuration)
	}
	for _, key := range []string{"sub_type", "epid", "sid"} {
		if value := strings.TrimSpace(extra[key]); value != "" {
			params[key] = value
		}
	}
	return c.request(ctx, "https://api.bilibili.com/x/click-interface/web/heartbeat", params, "POST")
}
