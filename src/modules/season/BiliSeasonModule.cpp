#include "modules/season/BiliSeasonModule.h"

#include "BiliAsyncUtils.hpp"
#include "BiliController.h"
#include "BiliJsonUtils.h"
#include "BiliListFetch.hpp"
#include "BiliModels.h"
#include "BiliNetwork.h"

#include <QJsonArray>
#include <QMap>
#include <QPointer>

namespace {

QVector<VideoItem> parseSeasonArchiveItems(const QJsonArray &archives, qint64 ownerMid,
                                          const QString &ownerName) {
  QVector<VideoItem> items;
  items.reserve(archives.size());

  for (const QJsonValue &value : archives) {
    if (!value.isObject()) continue;
    QJsonObject obj = value.toObject();
    VideoItem item = VideoListModel::parseVideoItem(obj);
    if (item.aid <= 0) {
      item.aid = obj.value("aid").toVariant().toLongLong();
    }
    if (item.pubdate <= 0) {
      item.pubdate = obj.value("pubdate").toVariant().toLongLong();
    }
    if (item.pubdate <= 0) {
      item.pubdate = obj.value("ctime").toVariant().toLongLong();
    }
    if (item.duration == 0) {
      item.duration = obj.value("duration").toInt();
    }
    QJsonObject statObj = obj.value("stat").toObject();
    if (item.views == 0) {
      item.views = statObj.value("view").toVariant().toLongLong();
    }
    if (item.ownerName.isEmpty()) {
      item.ownerName = ownerName;
    }
    if (item.ownerMid == 0) {
      item.ownerMid = ownerMid;
    }
    items.append(item);
  }

  return items;
}

int seasonArchiveTotal(const QJsonObject &data, bool *ok) {
  QJsonObject pageObj = data.value("page").toObject();
  QJsonObject metaObj = data.value("meta").toObject();
  int total = BiliJson::intValue(pageObj.value("total"), ok);
  if (ok && !*ok) total = BiliJson::intValue(pageObj.value("count"), ok);
  if (ok && !*ok) total = BiliJson::intValue(data.value("count"), ok);
  if (ok && !*ok) total = BiliJson::intValue(metaObj.value("total"), ok);
  return total;
}

bool seasonArchiveHasMore(const QJsonObject &data, int page, int pageSize, int total,
                          int itemCount) {
  QJsonObject pageObj = data.value("page").toObject();
  int pn = pageObj.value("page_num").toInt(page);
  int ps = pageObj.value("page_size").toInt(pageSize);
  if (total > 0 && ps > 0) {
    return pn * ps < total;
  }
  return itemCount >= pageSize;
}

QString videoRequestKey(const VideoItem &video) {
  return !video.bvid.isEmpty() ? video.bvid : QString::number(video.aid);
}

struct ParsedSeasonVideos {
  qint64 mid = 0;
  qint64 seasonId = 0;
  int page = 1;
  bool oldestFirst = false;
  QVector<VideoItem> items;
  bool totalKnown = false;
  int total = 0;
  bool hasMore = false;
};

QVector<VideoItem> parseRelatedVideosPayload(const QJsonObject &data,
                                             const QString &currentBvid) {
  QVector<VideoItem> items;
  QJsonArray list = data.value("list").toArray();
  items.reserve(list.size());
  for (const QJsonValue &value : list) {
    if (!value.isObject())
      continue;
    VideoItem item = VideoListModel::parseVideoItem(value.toObject());
    if (item.bvid.isEmpty() || item.bvid == currentBvid)
      continue;
    items.append(item);
  }
  return items;
}

ParsedSeasonVideos parseSeasonVideosPayload(const QJsonObject &data,
                                            qint64 mid, qint64 seasonId,
                                            int page, int pageSize,
                                            bool oldestFirst,
                                            const QString &ownerName) {
  ParsedSeasonVideos result;
  result.mid = mid;
  result.seasonId = seasonId;
  result.page = page;
  result.oldestFirst = oldestFirst;
  QJsonArray archives = data.value("archives").toArray();
  if (archives.isEmpty()) archives = data.value("item").toArray();
  if (archives.isEmpty()) archives = data.value("list").toArray();
  if (archives.isEmpty()) {
    QJsonObject listObj = data.value("list").toObject();
    archives = listObj.value("archives").toArray();
    if (archives.isEmpty()) archives = listObj.value("item").toArray();
    if (archives.isEmpty()) archives = listObj.value("vlist").toArray();
  }
  result.items = parseSeasonArchiveItems(archives, mid, ownerName);

  result.total = seasonArchiveTotal(data, &result.totalKnown);
  result.hasMore =
      seasonArchiveHasMore(data, page, pageSize, result.total, result.items.size());
  return result;
}

}  // namespace

BiliSeasonModule::BiliSeasonModule(BiliController *controller)
    : QObject(controller), m_controller(controller) {}

QObject *BiliSeasonModule::seasonVideoModel() { return m_controller->m_seasonVideoModel; }
QObject *BiliSeasonModule::relatedVideoModel() { return m_controller->m_relatedVideoModel; }

void BiliSeasonModule::fetchRelatedVideos() {
  BiliController *controller = m_controller;
  if (!controller) return;
  if (!controller->m_relatedVideoModel) return;
  if (!controller->m_videoDetailLoadingBvid.isEmpty()) return;
  if (controller->m_currentVideo.bvid.isEmpty() && controller->m_currentVideo.aid <= 0) return;

  const QString requestKey = videoRequestKey(controller->m_currentVideo);
  if (controller->m_relatedVideoLoadingBvid == requestKey) return;
  if (controller->m_relatedVideoBvid == requestKey) return;

  if (controller->m_relatedVideoBvid != requestKey) {
    controller->m_relatedVideoModel->clear();
    controller->m_relatedVideoModel->setHasMore(false);
    controller->m_relatedVideoModel->setErrorMessage("");
  }

  QMap<QString, QString> params;
  if (!controller->m_currentVideo.bvid.isEmpty()) {
    params["bvid"] = controller->m_currentVideo.bvid;
  } else {
    params["aid"] = QString::number(controller->m_currentVideo.aid);
  }

  controller->m_relatedVideoLoadingBvid = requestKey;
  controller->m_relatedVideoModel->setLoading(true);

  const QString currentBvid = controller->m_currentVideo.bvid;
  BiliListFetch::fetchParsed(
      controller, BiliListFetch::Via::Network, "/video/related", params,
      // 丢弃过期响应前先复位 loading
      [requestKey](BiliController *self) {
        if (!self->m_relatedVideoModel) return false;
        const QString currentKey = videoRequestKey(self->m_currentVideo);
        if (currentKey != requestKey) {
          if (self->m_relatedVideoLoadingBvid == requestKey) {
            self->m_relatedVideoLoadingBvid.clear();
            self->m_relatedVideoModel->setLoading(false);
          }
          return false;
        }
        return true;
      },
      [currentBvid](const QJsonObject &data) {
        return parseRelatedVideosPayload(data, currentBvid);
      },
      [requestKey](BiliController *self, QVector<VideoItem> items) {
        if (!self->m_relatedVideoModel) return;
        if (videoRequestKey(self->m_currentVideo) != requestKey) return;

        self->m_relatedVideoModel->clear();
        self->m_relatedVideoModel->appendItems(items);
        self->m_relatedVideoModel->setHasMore(false);
        self->m_relatedVideoModel->setLoading(false);
        self->m_relatedVideoBvid = requestKey;
        self->m_relatedVideoLoadingBvid.clear();
      },
      [requestKey](BiliController *self, int, const QString &) {
        if (!self->m_relatedVideoModel) return;
        if (self->m_relatedVideoLoadingBvid != requestKey) return;
        self->m_relatedVideoModel->setLoading(false);
        self->m_relatedVideoLoadingBvid.clear();
      });
}

void BiliSeasonModule::fetchUpSeasonVideos(int page, int pageSize) {
  BiliController *controller = m_controller;
  if (!controller) return;
  if (controller->m_upUserMid <= 0 || controller->m_upSelectedSeasonId <= 0) return;
  if (!controller->m_upVideoModel) return;
  if (controller->m_upVideoModel->loading()) return;

  page = qBound(1, page, 9999);
  pageSize = qBound(1, pageSize, 100);

  controller->m_upVideoModel->setLoading(true);
  controller->m_upVideoModel->setErrorMessage("");

  const qint64 mid = controller->m_upUserMid;
  const qint64 seasonId = controller->m_upSelectedSeasonId;

  QMap<QString, QString> params;
  params["mid"] = QString::number(mid);
  params["season_id"] = QString::number(seasonId);
  params["sort_reverse"] = "false";
  params["pn"] = QString::number(page);
  params["ps"] = QString::number(pageSize);

  const QString ownerName = controller->m_upUserName;
  BiliListFetch::fetchParsed(
      controller, BiliListFetch::Via::ApiWithLoading, "/user/season/videos",
      params,
      [mid, seasonId](BiliController *self) {
        if (!self->m_upVideoModel) return false;
        if (self->m_upUserMid != mid || self->m_upSelectedSeasonId != seasonId)
          return false;
        return true;
      },
      [mid, seasonId, page, pageSize, ownerName](const QJsonObject &data) {
        return parseSeasonVideosPayload(data, mid, seasonId, page, pageSize,
                                        false, ownerName);
      },
      [](BiliController *self, ParsedSeasonVideos result) {
        if (!self->m_upVideoModel) return;
        if (self->m_upUserMid != result.mid ||
            self->m_upSelectedSeasonId != result.seasonId) {
          return;
        }

        self->m_upSeasonVideoPage = result.page;
        self->m_upVideoModel->appendItems(result.items);
        if (result.totalKnown) self->setUpVideoTotal(result.total);
        self->m_upSeasonVideoHasMore = result.hasMore;
        self->m_upVideoModel->setHasMore(result.hasMore);
        self->m_upVideoModel->setLoading(false);

        if (result.items.isEmpty() && result.page == 1) {
          self->m_upVideoModel->setErrorMessage("该合集暂无视频");
        }
      },
      [mid, seasonId](BiliController *self, int, const QString &msg) {
        if (!self->m_upVideoModel) return;
        if (self->m_upUserMid != mid || self->m_upSelectedSeasonId != seasonId) return;
        self->m_upVideoModel->setLoading(false);
        self->m_upVideoModel->setErrorMessage(msg);
        emit self->toastMessage(QString("加载合集失败：%1").arg(msg));
      });
}

void BiliSeasonModule::fetchUpSeriesVideos(int page, int pageSize) {
  BiliController *controller = m_controller;
  if (!controller) return;
  if (controller->m_upUserMid <= 0 || controller->m_upSelectedSeasonId <= 0) return;
  if (!controller->m_upVideoModel) return;
  if (controller->m_upVideoModel->loading()) return;

  page = qBound(1, page, 9999);
  pageSize = qBound(1, pageSize, 100);

  controller->m_upVideoModel->setLoading(true);
  controller->m_upVideoModel->setErrorMessage("");

  const qint64 mid = controller->m_upUserMid;
  const qint64 seriesId = controller->m_upSelectedSeasonId;

  QMap<QString, QString> params;
  params["mid"] = QString::number(mid);
  params["series_id"] = QString::number(seriesId);
  params["sort"] = "desc";
  params["pn"] = QString::number(page);
  params["ps"] = QString::number(pageSize);

  const QString ownerName = controller->m_upUserName;
  BiliListFetch::fetchParsed(
      controller, BiliListFetch::Via::ApiWithLoading, "/user/series/videos",
      params,
      [mid, seriesId](BiliController *self) {
        if (!self->m_upVideoModel) return false;
        if (self->m_upUserMid != mid || self->m_upSelectedSeasonId != seriesId ||
            !self->m_upSelectedIsSeries) return false;
        return true;
      },
      [mid, seriesId, page, pageSize, ownerName](const QJsonObject &data) {
        return parseSeasonVideosPayload(data, mid, seriesId, page, pageSize,
                                        false, ownerName);
      },
      [](BiliController *self, ParsedSeasonVideos result) {
        if (!self->m_upVideoModel) return;
        if (self->m_upUserMid != result.mid ||
            self->m_upSelectedSeasonId != result.seasonId ||
            !self->m_upSelectedIsSeries) {
          return;
        }

        self->m_upSeasonVideoPage = result.page;
        self->m_upVideoModel->appendItems(result.items);
        if (result.totalKnown) self->setUpVideoTotal(result.total);
        self->m_upSeasonVideoHasMore = result.hasMore;
        self->m_upVideoModel->setHasMore(result.hasMore);
        self->m_upVideoModel->setLoading(false);

        if (result.items.isEmpty() && result.page == 1) {
          self->m_upVideoModel->setErrorMessage("该系列暂无视频");
        }
      },
      [mid, seriesId](BiliController *self, int, const QString &msg) {
        if (!self->m_upVideoModel) return;
        if (self->m_upUserMid != mid || self->m_upSelectedSeasonId != seriesId ||
            !self->m_upSelectedIsSeries) return;
        self->m_upVideoModel->setLoading(false);
        self->m_upVideoModel->setErrorMessage(msg);
        emit self->toastMessage(QString("加载系列失败：%1").arg(msg));
      });
}

void BiliSeasonModule::fetchMoreUpSeasonVideos() {
  BiliController *controller = m_controller;
  if (!controller) return;
  if (!controller->m_upSeasonVideoHasMore) return;
  if (!controller->m_upVideoModel || controller->m_upVideoModel->loading()) return;
  if (controller->m_upSelectedIsSeries) {
    fetchUpSeriesVideos(controller->m_upSeasonVideoPage + 1, 30);
  } else {
    fetchUpSeasonVideos(controller->m_upSeasonVideoPage + 1, 30);
  }
}

void BiliSeasonModule::fetchSeasonVideos(qint64 mid, qint64 seasonId, int page,
                                         int pageSize, bool oldestFirst) {
  BiliController *controller = m_controller;
  if (!controller) return;
  if (mid <= 0 || seasonId <= 0) return;
  if (!controller->m_seasonVideoModel) return;
  if (controller->m_seasonVideoModel->loading()) return;

  page = qBound(1, page, 9999);
  pageSize = qBound(1, pageSize, 100);

  bool reset = page == 1 || m_seasonVideoMid != mid ||
               m_seasonVideoSeasonId != seasonId ||
               m_seasonVideoOldestFirst != oldestFirst;
  m_seasonVideoMid = mid;
  m_seasonVideoSeasonId = seasonId;
  m_seasonVideoOldestFirst = oldestFirst;

  if (reset) {
    controller->m_seasonVideoModel->clear();
    controller->m_seasonVideoModel->setHasMore(true);
    m_seasonVideoHasMore = true;
    controller->setSeasonVideoTotal(0);
  }

  controller->m_seasonVideoModel->setLoading(true);
  controller->m_seasonVideoModel->setErrorMessage("");

  QMap<QString, QString> params;
  params["mid"] = QString::number(mid);
  params["season_id"] = QString::number(seasonId);
  params["sort_reverse"] = oldestFirst ? "true" : "false";
  params["pn"] = QString::number(page);
  params["ps"] = QString::number(pageSize);

  QString ownerName = controller->m_currentVideo.ownerName;
  BiliListFetch::fetchParsed(
      controller, BiliListFetch::Via::ApiWithLoading, "/user/season/videos",
      params,
      [this, mid, seasonId, oldestFirst](BiliController *self) {
        if (!self->m_seasonVideoModel) return false;
        if (m_seasonVideoMid != mid || m_seasonVideoSeasonId != seasonId ||
            m_seasonVideoOldestFirst != oldestFirst) return false;
        return true;
      },
      [mid, seasonId, page, pageSize, oldestFirst, ownerName](const QJsonObject &data) {
        return parseSeasonVideosPayload(data, mid, seasonId, page, pageSize,
                                        oldestFirst, ownerName);
      },
      [this](BiliController *self, ParsedSeasonVideos result) {
        if (!self->m_seasonVideoModel) return;
        if (m_seasonVideoMid != result.mid ||
            m_seasonVideoSeasonId != result.seasonId ||
            m_seasonVideoOldestFirst != result.oldestFirst) {
          return;
        }

        m_seasonVideoPage = result.page;
        self->m_seasonVideoModel->appendItems(result.items);
        if (result.totalKnown) self->setSeasonVideoTotal(result.total);
        m_seasonVideoHasMore = result.hasMore;
        self->m_seasonVideoModel->setHasMore(result.hasMore);
        self->m_seasonVideoModel->setLoading(false);

        if (result.items.isEmpty() && result.page == 1) {
          self->m_seasonVideoModel->setErrorMessage("该合集暂无视频");
        }
      },
      [this, mid, seasonId, oldestFirst](BiliController *self, int,
                                         const QString &msg) {
        if (!self->m_seasonVideoModel) return;
        if (m_seasonVideoMid != mid || m_seasonVideoSeasonId != seasonId ||
            m_seasonVideoOldestFirst != oldestFirst) return;
        self->m_seasonVideoModel->setLoading(false);
        self->m_seasonVideoModel->setErrorMessage(msg);
        emit self->toastMessage(QString("加载合集失败：%1").arg(msg));
      });
}

void BiliSeasonModule::fetchMoreSeasonVideos() {
  BiliController *controller = m_controller;
  if (!controller) return;
  if (!m_seasonVideoHasMore) return;
  if (!controller->m_seasonVideoModel || controller->m_seasonVideoModel->loading()) return;
  fetchSeasonVideos(m_seasonVideoMid, m_seasonVideoSeasonId,
                    m_seasonVideoPage + 1, 30, m_seasonVideoOldestFirst);
}
