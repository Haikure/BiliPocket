package main

// ==================== 配置常量 ====================

const (
	APPKEY = "1d8b6e7d45233436"
	APPSEC = "560c52ccd288fed045859ed18bffd973"
)

var MIXIN_KEY_ENC_TAB = []int{
	46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
	33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
	61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
	36, 20, 34, 44, 52,
}

const (
	defaultUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
	defaultReferer   = "https://www.bilibili.com/"
	appUserAgent     = "Mozilla/5.0 BiliDroid/8.43.0 (bbcallen@gmail.com) os/android model/android mobi_app/android build/8430300 channel/master innerVer/8430300 osVer/15 network/2"
	appStatistics    = `{"appId":1,"platform":3,"version":"8.43.0","abtest":""}`
	dynamicFeatures  = "itemOpusStyle,listOnlyfans,opusBigCover,onlyfansVote,decorationCard,onlyfansAssetsV2,forwardListHidden,ugcDelete"
	piliPlusAppKey   = "dfca71928277209b"
	piliPlusAppSec   = "b5475a8825547a4fc26c7d518eaaa02e"
)

var rootEndpoints = []string{
	"/popular - 热门视频",
	"/ranking - 排行榜",
	"/dynamic/feed - 动态列表",
	"/search - 搜索视频",
	"/video/info - 视频详情",
	"/video/related - 视频相关推荐",
	"/video/relation - 视频关系状态",
	"/video/playurl - 播放地址",
	"/video/player/info - 播放器信息",
	"/video/danmaku - 弹幕",
	"/video/danmaku/config - 弹幕配置",
	"/video/comments - 评论",
	"/video/comments/replies - 子评论",
	"/video/subtitle/list - CC字幕列表",
	"/video/subtitle/ass - 生成ASS字幕",
	"/video/subtitle/ass/file - 直接下载ASS字幕",
	"/user/info - 用户信息",
	"/user/follow/toggle - 关注/取消关注UP主",
	"/user/videos - 用户投稿",
	"/user/search - UP主投稿搜索",
	"/user/seasons - UP主合集列表",
	"/user/season/videos - UP主合集内视频",
	"/user/series/videos - UP主系列内视频",
	"/login/info - 登录信息",
	"/login/import - 导入登录Cookie",
	"/logout - 退出登录",
	"/hot/search - 热搜",
	"/recommend - 首页推荐",
	"/history/recent - 最近观看",
	"/history/search - 搜索历史",
	"/history/delete - 删除历史",
	"/toview/list - 稍后再看列表",
	"/toview/add - 添加稍后再看",
	"/toview/del - 取消稍后再看",
	"/player/heartbeat - 回调心跳",
	"/fav/folder/list - 收藏夹列表",
	"/fav/resource/list - 收藏夹内容",
	"/fav/status - 收藏状态",
	"/fav/toggle - 收藏切换",
	"/coin/status - 投币状态",
	"/coin/add - 投币",
	"/like/status - 点赞状态",
	"/like/toggle - 点赞/取消点赞",
	"/qrcode/generate - 生成登录二维码",
	"/qrcode/poll - 轮询二维码状态",
}

var startupEndpoints = []string{
	"GET  /popular                - 热门视频",
	"GET  /ranking                - 排行榜",
	"GET  /dynamic/feed           - 动态列表",
	"GET  /search                 - 搜索视频",
	"GET  /video/info             - 视频详情",
	"GET  /video/related          - 视频相关推荐",
	"GET  /video/relation         - 视频关系状态",
	"GET  /video/playurl          - 播放地址",
	"GET  /video/player/info      - 播放器信息",
	"GET  /video/danmaku          - 弹幕数据",
	"GET  /video/danmaku/config   - 弹幕配置",
	"GET  /video/comments         - 评论列表",
	"GET  /video/comments/replies - 子评论",
	"GET  /video/subtitle/list    - CC字幕列表",
	"GET  /video/subtitle/ass     - 生成ASS字幕",
	"GET  /video/subtitle/ass/file - 直接下载ASS字幕",
	"GET  /user/info              - 用户信息",
	"GET  /user/follow/toggle     - 关注/取消关注UP主",
	"GET  /user/videos            - 用户投稿",
	"GET  /user/search            - UP主投稿搜索",
	"GET  /user/seasons           - UP主合集列表",
	"GET  /user/season/videos     - UP主合集内视频",
	"GET  /user/series/videos     - UP主系列内视频",
	"GET  /login/info             - 登录信息",
	"POST /login/import           - 导入登录Cookie",
	"GET  /logout                 - 退出登录",
	"GET  /hot/search             - 热搜榜",
	"GET  /recommend              - 首页推荐",
	"GET  /history/recent         - 最近观看",
	"GET  /history/search         - 搜索历史",
	"GET  /history/delete         - 删除历史",
	"GET  /toview/list            - 稍后再看列表",
	"GET  /toview/add             - 添加稍后再看",
	"GET  /toview/del             - 取消稍后再看",
	"GET  /player/heartbeat       - 回调心跳",
	"GET  /fav/folder/list        - 收藏夹列表",
	"GET  /fav/resource/list      - 收藏夹内容",
	"GET  /fav/status             - 收藏状态",
	"GET  /fav/toggle             - 收藏切换",
	"GET  /coin/status            - 投币状态",
	"GET  /coin/add               - 投币",
	"GET  /like/status            - 点赞状态",
	"GET  /like/toggle            - 点赞/取消点赞",
	"GET  /qrcode/generate        - 生成登录二维码",
	"GET  /qrcode/poll            - 轮询二维码状态",
}
