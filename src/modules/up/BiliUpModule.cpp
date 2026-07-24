#include "modules/up/BiliUpModule.h"
#include "BiliAsyncUtils.hpp"
#include "BiliController.h"
#include "BiliJsonUtils.h"
#include "BiliModels.h"
#include "BiliNetwork.h"
#include "modules/history/BiliHistoryModule.h"
#include "modules/login/BiliLoginModule.h"
#include "modules/feed/BiliFeedModule.h"
#include "modules/playback/BiliPlaybackModule.h"
#include "modules/season/BiliSeasonModule.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPointer>
#include <QProcess>
#include <QRegExp>
#include <QSettings>
#include <QStandardPaths>
#include <QStringListModel>
#include <QTimer>
#include <QUrl>
#include <QUrlQuery>
#include <QtGlobal>
#include <algorithm>
#include <functional>

// 由插件文件提供的 Go 服务控制函数
extern bool bili_startApiServer();
extern void bili_stopApiServer();

namespace {

struct ParsedUpVideos {
  qint64 mid = 0;
  int page = 1;
  QVector<VideoItem> items;
  bool totalKnown = false;
  int total = 0;
  int lastWatchedRank = 0;
  qint64 nextCursor = 0;
  qint64 prevCursor = 0;
  bool hasMore = false;
  bool hasPrevious = false;
};

bool jsonBoolValue(const QJsonValue &value) {
  if (value.isBool()) return value.toBool();
  if (value.isDouble()) return value.toInt() != 0;
  if (value.isString()) {
    const QString text = value.toString().trimmed().toLower();
    return text == "1" || text == "true" || text == "yes";
  }
  return false;
}

QString upOfficialFallbackLabel(int type) {
  if (type == 1) return QStringLiteral("机构认证");
  if (type == 0) return QStringLiteral("认证 UP");
  return QString();
}

ParsedUpVideos parseUpVideosPayload(const QJsonObject &data, qint64 mid,
                                    int page, int pageSize) {
  ParsedUpVideos result;
  result.mid = mid;
  result.page = page;

  QJsonArray list;
  if (data.value("list").isObject()) {
    QJsonObject listObj = data.value("list").toObject();
    list = listObj.value("vlist").toArray();
  }
  if (list.isEmpty()) {
    list = data.value("vlist").toArray();
  }
  if (list.isEmpty()) {
    list = data.value("item").toArray();
  }

  result.items.reserve(list.size());
  for (const QJsonValue &v : list) {
    if (!v.isObject())
      continue;

    QJsonObject obj = v.toObject();
    QJsonObject archiveObj = obj.value("archive").toObject();
    VideoItem item = archiveObj.isEmpty()
                         ? VideoListModel::parseVideoItem(obj)
                         : VideoListModel::parseVideoItem(archiveObj);

    QJsonObject cursorAttr = obj.value("cursor_attr").toObject();
    if (!cursorAttr.isEmpty()) {
      item.isLastWatchedArc = cursorAttr.value("is_last_watched_arc").toVariant().toBool();
      item.lastWatchedRank = cursorAttr.value("rank").toVariant().toInt();
    }

    if (item.aid <= 0) {
      item.aid = obj.value("aid").toVariant().toLongLong();
    }
    if (item.aid <= 0) {
      item.aid = obj.value("param").toString().toLongLong();
    }

    if (item.pubdate <= 0) {
      item.pubdate = obj.value("pubdate").toVariant().toLongLong();
    }
    if (item.pubdate <= 0) {
      item.pubdate = obj.value("ctime").toVariant().toLongLong();
    }
    if (item.pubdate <= 0) {
      item.pubdate = obj.value("created").toVariant().toLongLong();
    }
    if (item.pubdate <= 0 && !archiveObj.isEmpty()) {
      item.pubdate = archiveObj.value("created").toVariant().toLongLong();
    }

    result.items.append(item);
  }

  QJsonObject pageObj = data.value("page").toObject();
  result.total = BiliJson::intValue(data.value("count"), &result.totalKnown);
  if (!result.totalKnown)
    result.total = BiliJson::intValue(pageObj.value("count"), &result.totalKnown);
  if (!result.totalKnown)
    result.total = BiliJson::intValue(pageObj.value("total"), &result.totalKnown);

  QJsonObject locatorObj = data.value("last_watched_locator").toObject();
  result.lastWatchedRank = locatorObj.value("insert_ranking").toVariant().toInt();

  result.nextCursor = data.value("next").toVariant().toLongLong();
  QJsonObject cursorObj = data.value("cursor").toObject();
  if (!cursorObj.isEmpty()) {
    if (result.nextCursor <= 0) {
      result.nextCursor = cursorObj.value("next").toVariant().toLongLong();
    }
    if (result.nextCursor <= 0) {
      result.nextCursor = cursorObj.value("max").toVariant().toLongLong();
    }
  }

  if (result.nextCursor <= 0 && !result.items.isEmpty()) {
    result.nextCursor =
        result.items.last().aid > 0 ? result.items.last().aid
                                    : result.items.last().pubdate;
  }
  if (!result.items.isEmpty()) {
    result.prevCursor = result.items.first().aid > 0 ? result.items.first().aid
                                                     : result.items.first().pubdate;
  }

  result.hasMore = !result.items.isEmpty();
  if (data.contains("has_next")) {
    result.hasMore = data.value("has_next").toBool(false);
  } else if (data.contains("hasNext")) {
    result.hasMore = data.value("hasNext").toBool(false);
  } else {
    const int count = pageObj.value("count").toInt(0);
    const int num = pageObj.value("pn").toInt(page);
    const int size = pageObj.value("ps").toInt(pageSize);
    if (count > 0 && size > 0) {
      result.hasMore = (num * size < count);
    } else {
      result.hasMore = (result.nextCursor > 0) && (result.items.size() >= pageSize);
    }
  }

  if (data.contains("has_prev")) {
    result.hasPrevious = data.value("has_prev").toBool(false);
  } else if (data.contains("hasPrev")) {
    result.hasPrevious = data.value("hasPrev").toBool(false);
  }
  result.hasPrevious = result.hasPrevious && result.prevCursor > 0;

  return result;
}

QVector<UpSeasonItem> parseUpSeasonsPayload(const QJsonObject &data) {
  QVector<UpSeasonItem> items;
  QJsonObject itemsLists = data.value("items_lists").toObject();

  auto parseList = [&items](const QJsonArray &arr, bool isSeries) {
    for (const QJsonValue &v : arr) {
      if (!v.isObject())
        continue;
      QJsonObject obj = v.toObject();
      QJsonObject meta = obj.value("meta").toObject();
      UpSeasonItem it;
      if (isSeries) {
        it.seasonId = meta.value("series_id").toVariant().toLongLong();
      } else {
        it.seasonId = meta.value("season_id").toVariant().toLongLong();
      }
      it.name = meta.value("name").toString();
      it.cover = meta.value("cover").toString();
      it.total = meta.value("total").toInt();
      it.isSeries = isSeries;
      if (it.seasonId > 0 && !it.name.isEmpty())
        items.append(it);
    }
  };

  parseList(itemsLists.value("seasons_list").toArray(), false);
  parseList(itemsLists.value("series_list").toArray(), true);
  return items;
}

} // namespace

BiliUpModule::BiliUpModule(BiliController *controller)
    : QObject(controller), m_controller(controller) {}

QObject *BiliUpModule::upVideoModel() { return m_controller->m_upVideoModel; }
QObject *BiliUpModule::upSeasonModel() { return m_controller->m_upSeasonModel; }
QObject *BiliUpModule::upSearchVideoModel() { return m_controller->m_upSearchModel; }

// ====== UP 主主页 ======

void BiliUpModule::fetchUpInfo(qint64 mid) {
  if (mid <= 0) {
    return;
  }

  if (m_controller->m_upUserMid != mid) {
    m_controller->m_upUserMid = mid;
    m_controller->m_upVideoPage = 1;
    m_controller->m_upVideoHasMore = true;
    m_controller->m_upVideoCursorNext = 0;
    m_controller->m_upVideoCursorPrev = 0;
    m_controller->m_upVideoHasPrevious = false;
    if (m_controller->m_upLastWatchedRank != 0) {
      m_controller->m_upLastWatchedRank = 0;
      emit m_controller->upLastWatchedChanged();
    }
    m_controller->setUpVideoTotal(0);
    if (m_controller->m_upVideoModel) {
      m_controller->m_upVideoModel->clear();
      m_controller->m_upVideoModel->setHasMore(true);
    }
    clearUpSearch();
    m_controller->m_upOfficialLabel.clear();
    m_controller->m_upOfficialDesc.clear();
    m_controller->m_upOfficialType = -1;
    m_controller->m_upVipLabel.clear();
    m_controller->m_upIsVip = false;
    m_controller->m_upNameplateName.clear();
    m_controller->m_upFansMedalName.clear();
    m_controller->m_upFansMedalLevel = 0;
    if (m_controller->m_upIsFollowing) {
      m_controller->m_upIsFollowing = false;
      emit m_controller->upFollowChanged();
    }
    // 重置合集筛选 / 合集列表
    if (m_controller->m_upSeasonModel) m_controller->m_upSeasonModel->clear();
    bool seasonChanged = (m_controller->m_upSelectedSeasonId != 0)
                         || !m_controller->m_upSelectedSeasonName.isEmpty()
                         || m_controller->m_upSelectedIsSeries
                         || m_controller->m_upSelectedDynamic;
    m_controller->m_upSelectedSeasonId = 0;
    m_controller->m_upSelectedSeasonName.clear();
    m_controller->m_upSelectedIsSeries = false;
    m_controller->m_upSelectedDynamic = false;
    m_controller->m_upSeasonVideoPage = 1;
    m_controller->m_upSeasonVideoHasMore = true;
    if (m_controller->m_upDynamicModel) m_controller->m_upDynamicModel->clear();
    if (seasonChanged) emit m_controller->upSelectedSeasonChanged();
  }

  QMap<QString, QString> params;
  params["mid"] = QString::number(mid);

  m_controller->apiGet(
      "/user/info", params,
      [this, mid](const QJsonObject &data) {
        if (m_controller->m_upUserMid != mid)
          return;

        const QJsonObject obj = data;

        m_controller->m_upUserName = obj.value("name").toString();
        if (m_controller->m_upUserName.isEmpty()) {
          m_controller->m_upUserName = obj.value("uname").toString();
        }
        m_controller->m_upUserFace = obj.value("face").toString();
        m_controller->m_upUserSign = obj.value("sign").toString();

        int level = obj.value("level").toInt(0);
        if (level <= 0) {
          QJsonObject levelInfo = obj.value("level_info").toObject();
          level = levelInfo.value("current_level").toInt(0);
        }
        m_controller->m_upUserLevel = level;

        QJsonObject official = obj.value("official").toObject();
        if (official.isEmpty()) {
          official = obj.value("Official").toObject();
        }
        QJsonObject officialVerify = obj.value("official_verify").toObject();
        bool officialTypeKnown = false;
        int officialType = BiliJson::intValue(official.value("type"), &officialTypeKnown);
        if (!officialTypeKnown) {
          bool verifyTypeKnown = false;
          const int verifyType = BiliJson::intValue(officialVerify.value("type"), &verifyTypeKnown);
          if (verifyTypeKnown) {
            officialType = verifyType;
            officialTypeKnown = true;
          }
        }
        bool officialRoleKnown = false;
        const int officialRole = BiliJson::intValue(official.value("role"), &officialRoleKnown);
        QString officialTitle = official.value("title").toString().trimmed();
        QString officialDesc = official.value("desc").toString().trimmed();
        if (officialDesc.isEmpty()) {
          officialDesc = officialVerify.value("desc").toString().trimmed();
        }
        QString officialLabel = officialTitle;
        const bool hasOfficial = (officialTypeKnown && officialType >= 0) ||
                                 (officialRoleKnown && officialRole > 0) ||
                                 !officialTitle.isEmpty() || !officialDesc.isEmpty();
        if (officialLabel.isEmpty() && hasOfficial) {
          officialLabel = upOfficialFallbackLabel(officialType);
          if (officialLabel.isEmpty()) officialLabel = QStringLiteral("认证 UP");
        }
        if (!hasOfficial) {
          officialType = -1;
        }
        m_controller->m_upOfficialType = officialType;
        m_controller->m_upOfficialLabel = officialLabel;
        m_controller->m_upOfficialDesc = officialDesc;

        QJsonObject vip = obj.value("vip").toObject();
        QJsonObject vipLabelObj = vip.value("label").toObject();
        if (vipLabelObj.isEmpty()) {
          vipLabelObj = obj.value("vip_label").toObject();
        }
        bool vipStatusKnown = false;
        int vipStatus = BiliJson::intValue(vip.value("status"), &vipStatusKnown);
        if (!vipStatusKnown) {
          vipStatus = BiliJson::intValue(vip.value("vipStatus"), &vipStatusKnown);
        }
        const int vipType = qMax(BiliJson::intValue(vip.value("type")),
                                 BiliJson::intValue(vip.value("vipType")));
        m_controller->m_upIsVip = vipStatusKnown ? (vipStatus == 1) : (vipType > 0);
        m_controller->m_upVipLabel = vipLabelObj.value("text").toString().trimmed();
        if (m_controller->m_upIsVip && m_controller->m_upVipLabel.isEmpty()) {
          m_controller->m_upVipLabel = QStringLiteral("大会员");
        }

        QJsonObject nameplate = obj.value("nameplate").toObject();
        m_controller->m_upNameplateName = nameplate.value("name").toString().trimmed();

        QJsonObject fansMedal = obj.value("fans_medal").toObject();
        QJsonObject medal = fansMedal.value("medal").toObject();
        const bool medalVisible = jsonBoolValue(fansMedal.value("show")) &&
                                  jsonBoolValue(fansMedal.value("wear")) &&
                                  !medal.isEmpty();
        if (medalVisible) {
          m_controller->m_upFansMedalName = medal.value("medal_name").toString().trimmed();
          m_controller->m_upFansMedalLevel = BiliJson::intValue(medal.value("level"));
        } else {
          m_controller->m_upFansMedalName.clear();
          m_controller->m_upFansMedalLevel = 0;
        }

        auto toIntSafe = [](const QJsonValue &v) -> int {
          if (v.isDouble())
            return v.toInt();
          if (v.isString())
            return v.toString().toInt();
          return 0;
        };
        m_controller->m_upUserFans = toIntSafe(obj.value("follower"));
        m_controller->m_upUserFollowing = toIntSafe(obj.value("following"));

        bool newFollowState = obj.value("is_following").toBool(false)
                              || obj.value("is_followed").toBool(false);
        bool followStateChanged = (m_controller->m_upIsFollowing != newFollowState);
        m_controller->m_upIsFollowing = newFollowState;

        emit m_controller->upUserChanged();
        if (followStateChanged) {
          emit m_controller->upFollowChanged();
        }
      },
      [this](int, const QString &msg) {
        emit m_controller->toastMessage(QString("获取UP主信息失败：%1").arg(msg));
      },
      true);
}

void BiliUpModule::fetchUpVideos(qint64 mid, int page, int pageSize) {
  if (mid <= 0) {
    return;
  }
  if (m_controller->m_upVideoModel->loading())
    return;

  page = qBound(1, page, 9999);
  pageSize = qBound(1, pageSize, 30);

  if (m_controller->m_upUserMid != mid) {
    m_controller->m_upUserMid = mid;
    m_controller->m_upVideoPage = 1;
    m_controller->m_upVideoHasMore = true;
    m_controller->m_upVideoCursorNext = 0;
    m_controller->m_upVideoCursorPrev = 0;
    m_controller->m_upVideoHasPrevious = false;
    if (m_controller->m_upLastWatchedRank != 0) {
      m_controller->m_upLastWatchedRank = 0;
      emit m_controller->upLastWatchedChanged();
    }
    m_controller->m_upVideoModel->clear();
  }

  m_controller->m_upVideoPage = page;
  if (page == 1) {
    m_controller->m_upVideoCursorNext = 0;
    m_controller->m_upVideoCursorPrev = 0;
    m_controller->m_upVideoHasPrevious = false;
    m_controller->m_upVideoModel->clear();
  }
  m_controller->m_upVideoModel->setLoading(true);
  m_controller->m_upVideoModel->setErrorMessage("");

  QMap<QString, QString> params;
  params["mid"] = QString::number(mid);
  params["ps"] = QString::number(pageSize);

  // 优先使用游标翻页：当 page>1 且已有游标时，带 max 参数请求下一段
  // 这样可避免 UP 新增稿件导致 pn 翻页出现丢失/重复。
  if (page > 1 && m_controller->m_upVideoCursorNext > 0) {
    params["pn"] = "1";
    params["max"] = QString::number(m_controller->m_upVideoCursorNext);
  } else {
    params["pn"] = QString::number(page);
  }

  QPointer<BiliController> self(m_controller);
  const qint64 requestMid = mid;
  const int requestPage = page;
  const int requestPageSize = pageSize;
  m_controller->apiGet(
      "/user/videos", params,
      [self, requestMid, requestPage, requestPageSize](const QJsonObject &data) {
        if (!self)
          return;
        biliRunInWorker(
            self,
            [data, requestMid, requestPage, requestPageSize]() {
              return parseUpVideosPayload(data, requestMid, requestPage,
                                          requestPageSize);
            },
            [self](ParsedUpVideos result) {
              if (!self || !self->m_upVideoModel)
                return;
              if (self->m_upUserMid != result.mid ||
                  self->m_upVideoPage != result.page ||
                  self->m_upSelectedSeasonId > 0) {
                return;
              }

              self->m_upVideoModel->appendItems(result.items);
              if (result.page == 1 && self->m_upLastWatchedRank != result.lastWatchedRank) {
                self->m_upLastWatchedRank = result.lastWatchedRank;
                emit self->upLastWatchedChanged();
              }
              if (result.totalKnown)
                self->setUpVideoTotal(result.total);
              if (result.nextCursor > 0)
                self->m_upVideoCursorNext = result.nextCursor;
              self->m_upVideoCursorPrev = result.prevCursor;
              self->m_upVideoHasPrevious = result.hasPrevious;

              self->m_upVideoHasMore = result.hasMore;
              self->m_upVideoModel->setHasMore(result.hasMore);
              self->m_upVideoModel->setLoading(false);

              if (result.items.isEmpty() && result.page == 1) {
                self->m_upVideoModel->setErrorMessage("暂无投稿");
              }
            });
      },
      [this](int, const QString &msg) {
        m_controller->m_upVideoModel->setLoading(false);
        m_controller->m_upVideoModel->setErrorMessage(msg);
        emit m_controller->toastMessage(QString("加载投稿失败：%1").arg(msg));
      },
      true);
}

void BiliUpModule::fetchUpVideosAroundAid(qint64 mid, qint64 aid, int pageSize) {
  if (mid <= 0 || aid <= 0 || !m_controller->m_upVideoModel) {
    return;
  }
  if (m_controller->m_upVideoModel->loading())
    return;
  if (m_controller->m_upSelectedSeasonId > 0 || m_controller->m_upSelectedDynamic)
    return;

  pageSize = qBound(1, pageSize, 30);
  m_controller->m_upUserMid = mid;
  m_controller->m_upVideoPage = 1;
  m_controller->m_upVideoHasMore = true;
  m_controller->m_upVideoCursorNext = 0;
  m_controller->m_upVideoCursorPrev = 0;
  m_controller->m_upVideoHasPrevious = false;
  m_controller->m_upVideoModel->clear();
  m_controller->m_upVideoModel->setLoading(true);
  m_controller->m_upVideoModel->setErrorMessage("");

  QMap<QString, QString> params;
  params["mid"] = QString::number(mid);
  params["ps"] = QString::number(pageSize);
  params["pn"] = "1";
  params["aid"] = QString::number(aid);
  params["include_cursor"] = "true";

  QPointer<BiliController> self(m_controller);
  const qint64 requestMid = mid;
  const qint64 requestAid = aid;
  const int requestPageSize = pageSize;
  m_controller->apiGet(
      "/user/videos", params,
      [self, requestMid, requestAid, requestPageSize](const QJsonObject &data) {
        if (!self)
          return;
        biliRunInWorker(
            self,
            [data, requestMid, requestPageSize]() {
              return parseUpVideosPayload(data, requestMid, 1, requestPageSize);
            },
            [self, requestAid](ParsedUpVideos result) {
              if (!self || !self->m_upVideoModel)
                return;
              if (self->m_upUserMid != result.mid ||
                  self->m_upSelectedSeasonId > 0) {
                return;
              }

              self->m_upVideoModel->appendItems(result.items);
              if (self->m_upLastWatchedRank != result.lastWatchedRank) {
                self->m_upLastWatchedRank = result.lastWatchedRank;
                emit self->upLastWatchedChanged();
              }
              if (result.totalKnown)
                self->setUpVideoTotal(result.total);
              if (result.nextCursor > 0)
                self->m_upVideoCursorNext = result.nextCursor;
              self->m_upVideoCursorPrev = result.prevCursor;
              // 定位到很靠后的视频时，APP 游标接口常把定位 aid 放在返回列表首项。
              // 此时 first aid == requestAid 仍然可以作为“向前取”的游标，不能据此关掉前置加载。
              self->m_upVideoHasPrevious = result.prevCursor > 0 &&
                                           (result.hasPrevious || result.prevCursor == requestAid);

              self->m_upVideoHasMore = result.hasMore;
              self->m_upVideoModel->setHasMore(result.hasMore);
              self->m_upVideoModel->setLoading(false);

              if (result.items.isEmpty()) {
                self->m_upVideoModel->setErrorMessage("暂无投稿");
              }
            });
      },
      [this](int, const QString &msg) {
        m_controller->m_upVideoModel->setLoading(false);
        m_controller->m_upVideoModel->setErrorMessage(msg);
        emit m_controller->toastMessage(QString("定位投稿失败：%1").arg(msg));
      },
      true);
}

bool BiliUpModule::canFetchPreviousUpVideos() const {
  return m_controller && m_controller->m_upSelectedSeasonId == 0 &&
         !m_controller->m_upSelectedDynamic &&
         m_controller->m_upVideoHasPrevious &&
         m_controller->m_upVideoCursorPrev > 0 &&
         m_controller->m_upVideoModel &&
         !m_controller->m_upVideoModel->loading();
}

void BiliUpModule::fetchPreviousUpVideos() {
  if (!canFetchPreviousUpVideos())
    return;

  m_controller->m_upVideoModel->setLoading(true);
  m_controller->m_upVideoModel->setErrorMessage("");

  QMap<QString, QString> params;
  params["mid"] = QString::number(m_controller->m_upUserMid);
  params["ps"] = "20";
  params["pn"] = "1";
  params["aid"] = QString::number(m_controller->m_upVideoCursorPrev);
  // 参考 PiliPlus：include_cursor 只用于首次按 aid 定位；
  // 向前补页只传 firstAid + sort=asc，否则会再次返回定位窗口，拿不到前置页。
  params["sort"] = "asc";

  QPointer<BiliController> self(m_controller);
  const qint64 requestMid = m_controller->m_upUserMid;
  const qint64 requestCursor = m_controller->m_upVideoCursorPrev;
  m_controller->apiGet(
      "/user/videos", params,
      [self, requestMid, requestCursor](const QJsonObject &data) {
        if (!self)
          return;
        biliRunInWorker(
            self,
            [data, requestMid]() {
              return parseUpVideosPayload(data, requestMid, 1, 20);
            },
            [self, requestCursor](ParsedUpVideos result) {
              if (!self || !self->m_upVideoModel)
                return;
              if (self->m_upUserMid != result.mid || self->m_upSelectedSeasonId > 0) {
                self->m_upVideoModel->setLoading(false);
                return;
              }

              QVector<VideoItem> freshItems;
              freshItems.reserve(result.items.size());
              for (const VideoItem &item : result.items) {
                if (item.aid > 0 && self->m_upVideoModel->indexOfAid(item.aid) >= 0)
                  continue;
                bool duplicated = false;
                for (const VideoItem &fresh : freshItems) {
                  if (item.aid > 0 && fresh.aid == item.aid) {
                    duplicated = true;
                    break;
                  }
                }
                if (!duplicated) freshItems.append(item);
              }

              self->m_upVideoModel->prependItems(freshItems);
              self->m_upVideoCursorPrev = result.prevCursor;
              self->m_upVideoHasPrevious = (result.hasPrevious || !freshItems.isEmpty()) &&
                                           result.prevCursor > 0 &&
                                           result.prevCursor != requestCursor;
              self->m_upVideoModel->setLoading(false);
            });
      },
      [self](int, const QString &msg) {
        if (!self || !self->m_upVideoModel) return;
        self->m_upVideoModel->setLoading(false);
        self->m_upVideoModel->setErrorMessage(msg);
        emit self->toastMessage(QString("加载更早定位内容失败：%1").arg(msg));
      },
      true);
}

void BiliUpModule::searchUpVideos(qint64 mid, const QString &keyword, int page, int pageSize) {
  if (mid <= 0 || !m_controller || !m_controller->m_upSearchModel) {
    return;
  }

  QString trimmed = keyword.trimmed();
  if (trimmed.isEmpty()) {
    emit m_controller->toastMessage("请输入搜索关键词");
    return;
  }
  if (m_controller->m_upSearchModel->loading()) {
    return;
  }
  if (trimmed.length() > 100) {
    trimmed = trimmed.left(100);
  }

  page = qBound(1, page, 100);
  pageSize = qBound(1, pageSize, 30);

  const bool reset = page == 1 || m_upSearchMid != mid || m_upSearchKeyword != trimmed;
  m_upSearchMid = mid;
  m_upSearchKeyword = trimmed;
  m_upSearchPage = page;
  m_upSearchPageSize = pageSize;

  if (reset) {
    m_controller->m_upSearchModel->clear();
  }
  m_controller->m_upSearchModel->setKeyword(m_upSearchKeyword);
  m_controller->m_upSearchModel->setLoading(true);
  m_controller->m_upSearchModel->setErrorMessage("");
  m_controller->setIsLoading(true);

  QMap<QString, QString> params;
  params["mid"] = QString::number(mid);
  params["keyword"] = m_upSearchKeyword;
  params["pn"] = QString::number(page);
  params["ps"] = QString::number(pageSize);

  QPointer<BiliController> self(m_controller);
  SearchResultModel *searchModel = m_controller->m_upSearchModel;
  const qint64 requestMid = mid;
  const QString requestKeyword = m_upSearchKeyword;
  const int requestPage = page;
  const int requestPageSize = pageSize;

  m_controller->apiGet(
      "/user/search", params,
      [this, self, searchModel, requestMid, requestKeyword, requestPage,
       requestPageSize](const QJsonObject &data) {
        if (!self || !searchModel) {
          return;
        }
        biliRunInWorker(
            self,
            [data, requestMid, requestPage, requestPageSize]() {
              return parseUpVideosPayload(data, requestMid, requestPage,
                                          requestPageSize);
            },
            [this, self, searchModel, requestKeyword,
             requestPageSize](ParsedUpVideos result) {
              if (!self || !searchModel) {
                return;
              }
              if (m_upSearchMid != result.mid || m_upSearchKeyword != requestKeyword ||
                  m_upSearchPage != result.page) {
                searchModel->setLoading(false);
                self->setIsLoading(false);
                return;
              }

              searchModel->appendItems(result.items);
              bool hasMore = result.hasMore;
              if (result.totalKnown && requestPageSize > 0) {
                hasMore = result.page * requestPageSize < result.total;
              }
              searchModel->setHasMore(hasMore);
              searchModel->setLoading(false);
              self->setIsLoading(false);

              if (result.items.isEmpty() && result.page == 1) {
                searchModel->setErrorMessage(
                    QString("未找到“%1”相关视频").arg(requestKeyword));
              }
            });
      },
      [self, searchModel](int, const QString &msg) {
        if (!self || !searchModel) return;
        searchModel->setLoading(false);
        searchModel->setErrorMessage(msg);
        self->setIsLoading(false);
        emit self->toastMessage(QString("UP 投稿搜索失败：%1").arg(msg));
      },
      true);
}

void BiliUpModule::searchMoreUpVideos() {
  if (!m_controller || !m_controller->m_upSearchModel) return;
  if (!m_controller->m_upSearchModel->hasMore() ||
      m_controller->m_upSearchModel->loading() || m_upSearchKeyword.isEmpty()) {
    return;
  }
  searchUpVideos(m_upSearchMid, m_upSearchKeyword, m_upSearchPage + 1,
                 m_upSearchPageSize);
}

void BiliUpModule::clearUpSearch() {
  m_upSearchMid = 0;
  m_upSearchKeyword.clear();
  m_upSearchPage = 1;
  m_upSearchPageSize = 20;
  if (m_controller && m_controller->m_upSearchModel) {
    m_controller->m_upSearchModel->clear();
    m_controller->m_upSearchModel->setHasMore(true);
    m_controller->m_upSearchModel->setLoading(false);
    m_controller->m_upSearchModel->setErrorMessage("");
  }
}

void BiliUpModule::fetchMoreUpVideos() {
  if (m_controller->m_upSelectedDynamic) {
    m_controller->m_feedModule->fetchMoreUpDynamics();
    return;
  }
  // 若当前选中的是合集/系列，则委托到合集翻页
  if (m_controller->m_upSelectedSeasonId > 0) {
    m_controller->m_seasonModule->fetchMoreUpSeasonVideos();
    return;
  }
  if (!m_controller->m_upVideoHasMore || m_controller->m_upVideoModel->loading())
    return;
  m_controller->m_upVideoPage++;
  fetchUpVideos(m_controller->m_upUserMid, m_controller->m_upVideoPage);
}

void BiliUpModule::fetchUpSeasons(qint64 mid) {
  if (mid <= 0 || !m_controller->m_upSeasonModel) return;
  if (m_controller->m_upSeasonModel->loading()) return;

  // 切换 UP 主时由 fetchUpInfo 负责清空 model；这里只在 mid 一致时拉取
  if (m_controller->m_upUserMid != mid) {
    m_controller->m_upUserMid = mid;
  }

  m_controller->m_upSeasonModel->setLoading(true);

  QMap<QString, QString> params;
  params["mid"] = QString::number(mid);
  params["pn"] = "1";
  params["ps"] = "20";

  QPointer<BiliController> self(m_controller);
  m_controller->apiGet(
      "/user/seasons", params,
      [self, mid](const QJsonObject &data) {
        if (!self || self->m_upUserMid != mid) return;
        if (!self->m_upSeasonModel) return;
        biliRunInWorker(
            self, [data]() { return parseUpSeasonsPayload(data); },
            [self, mid](QVector<UpSeasonItem> items) {
              if (!self || self->m_upUserMid != mid || !self->m_upSeasonModel)
                return;
              self->m_upSeasonModel->setItems(items);
              self->m_upSeasonModel->setLoading(false);
            });
      },
      [self](int, const QString &msg) {
        if (!self || !self->m_upSeasonModel) return;
        self->m_upSeasonModel->setLoading(false);
        // 静默：合集列表失败不弹 toast，避免主页打扰
        Q_UNUSED(msg);
      },
      false);
}

void BiliUpModule::selectUpSeason(qint64 seasonId, const QString &name, bool isSeries, int total) {
  if (m_controller->m_upUserMid <= 0) return;
  if (!m_controller->m_upSelectedDynamic &&
      m_controller->m_upSelectedSeasonId == seasonId &&
      m_controller->m_upSelectedIsSeries == isSeries) {
    // 已选中，无需切换
    return;
  }
  m_controller->m_upSelectedDynamic = false;
  m_controller->m_upSelectedSeasonId = seasonId;
  m_controller->m_upSelectedSeasonName = (seasonId == 0) ? QString() : name;
  m_controller->m_upSelectedIsSeries = (seasonId == 0) ? false : isSeries;
  m_controller->setUpVideoTotal(seasonId == 0 ? 0 : total);
  emit m_controller->upSelectedSeasonChanged();

  if (!m_controller->m_upVideoModel) return;
  // 切换：清空当前视频列表，重置翻页状态，重新拉取
  m_controller->m_upVideoModel->clear();
  m_controller->m_upVideoModel->setHasMore(true);
  m_controller->m_upVideoModel->setErrorMessage("");

  if (seasonId == 0) {
    // 恢复为“视频”全部投稿
    m_controller->m_upVideoPage = 1;
    m_controller->m_upVideoHasMore = true;
    m_controller->m_upVideoCursorNext = 0;
    m_controller->m_upVideoCursorPrev = 0;
    m_controller->m_upVideoHasPrevious = false;
    fetchUpVideos(m_controller->m_upUserMid, 1, 20);
  } else if (isSeries) {
    m_controller->m_upSeasonVideoPage = 1;
    m_controller->m_upSeasonVideoHasMore = true;
    m_controller->m_seasonModule->fetchUpSeriesVideos(1, 30);
  } else {
    m_controller->m_upSeasonVideoPage = 1;
    m_controller->m_upSeasonVideoHasMore = true;
    m_controller->m_seasonModule->fetchUpSeasonVideos(1, 30);
  }
}

void BiliUpModule::selectUpDynamic() {
  if (m_controller->m_upUserMid <= 0) return;
  if (m_controller->m_upSelectedDynamic &&
      m_controller->m_upDynamicModel &&
      m_controller->m_upDynamicModel->count() > 0) {
    return;
  }

  m_controller->m_upSelectedDynamic = true;
  m_controller->m_upSelectedSeasonId = 0;
  m_controller->m_upSelectedSeasonName = QStringLiteral("图文动态");
  m_controller->m_upSelectedIsSeries = false;
  m_controller->setUpVideoTotal(0);
  emit m_controller->upSelectedSeasonChanged();

  if (m_controller->m_upVideoModel) {
    m_controller->m_upVideoModel->setLoading(false);
  }
  m_controller->m_feedModule->fetchUpDynamics(m_controller->m_upUserMid);
}

void BiliUpModule::toggleUpFollow() {
  if (!m_controller->m_loggedIn) {
    emit m_controller->toastMessage("请先登录后再关注");
    return;
  }
  if (m_controller->m_upUserMid <= 0) {
    emit m_controller->toastMessage("UP 主信息无效");
    return;
  }
  if (m_controller->m_userId > 0 && m_controller->m_userId == m_controller->m_upUserMid) {
    emit m_controller->toastMessage("不能关注自己");
    return;
  }
  if (m_controller->m_upFollowLoading) {
    return;
  }

  const bool targetFollow = !m_controller->m_upIsFollowing;
  m_controller->m_upFollowLoading = true;

  QMap<QString, QString> params;
  params["mid"] = QString::number(m_controller->m_upUserMid);
  params["action"] = targetFollow ? "1" : "0";

  QPointer<BiliController> self(m_controller);
  m_controller->apiGet(
      "/user/follow/toggle", params,
      [self, targetFollow](const QJsonObject &data) {
        if (!self)
          return;

        self->m_upFollowLoading = false;

        bool finalFollowState = targetFollow;
        if (data.contains("following")) {
          finalFollowState = data.value("following").toBool(targetFollow);
        }

        bool changed = (self->m_upIsFollowing != finalFollowState);
        self->m_upIsFollowing = finalFollowState;

        if (changed) {
          if (finalFollowState) {
            self->m_upUserFans += 1;
          } else if (self->m_upUserFans > 0) {
            self->m_upUserFans -= 1;
          }
          emit self->upUserChanged();
          emit self->upFollowChanged();
        } else {
          emit self->upFollowChanged();
        }

        emit self->toastMessage(finalFollowState ? "关注成功" : "已取消关注");
      },
      [self](int, const QString &msg) {
        if (!self)
          return;
        self->m_upFollowLoading = false;
        emit self->toastMessage(QString("关注操作失败：%1").arg(msg));
      },
      false);
}

void BiliUpModule::playVideoPart(int index) {
    if (!m_controller->m_videoPartModel || index < 0 || index >= m_controller->m_videoPartModel->count()) {
        return;
    }

    QModelIndex modelIndex = m_controller->m_videoPartModel->index(index, 0);
    qint64 newCid = m_controller->m_videoPartModel->data(modelIndex, VideoPartListModel::CidRole).toLongLong();

    if (newCid > 0 && m_controller->m_currentVideo.cid != newCid) {
        m_controller->m_currentVideo.cid = newCid;
        emit m_controller->videoDetailChanged(); // 更新cid
        emit m_controller->playbackProgressChanged();
        emit m_controller->toastMessage(QString("切换到 P%1").arg(index + 1));
        // 这里可以根据需求决定是否立即播放
        // downloadAndPlay(m_controller->m_playQuality); 
        // 或者只获取URL
        m_controller->m_playbackModule->fetchPlayUrl(m_controller->m_playQuality);
    }
}

void BiliUpModule::restartGoServer() {
    emit m_controller->toastMessage("正在重启 Go 服务端...");
    bili_stopApiServer();
    if (bili_startApiServer()) {
        emit m_controller->toastMessage("Go 服务端已重启");
    } else {
        emit m_controller->toastMessage("Go 服务端重启失败");
    }
}

// ====== 下载到指定目录 ======

void BiliUpModule::downloadVideoToDisk(int quality) {
  if (m_controller->m_currentVideo.bvid.isEmpty() || m_controller->m_currentVideo.cid == 0) {
    emit m_controller->toastMessage("视频信息不完整，无法下载");
    return;
  }

  if (m_controller->m_isDownloading) {
    emit m_controller->toastMessage("已有下载任务进行中");
    return;
  }

  if (m_controller->m_playbackModule &&
      m_controller->m_playbackModule->ensureDefaultSubtitleForCurrentVideo(
          [self = QPointer<BiliUpModule>(this), quality]() {
            if (!self) return;
            self->downloadVideoToDisk(quality);
          })) {
    return;
  }

  const bool audioOnly = (quality == 0);
  const int requestQuality = audioOnly ? 16 : qBound(16, quality, 127);
  quality = requestQuality;

  // 1. 定义存储目录并确保它存在
  QString downloadDir = "/userdisk/Music/bili";
  QDir dir(downloadDir);
  if (!dir.exists()) {
      if (!dir.mkpath(".")) {
          emit m_controller->toastMessage("创建下载目录失败");
          return;
      }
  }

  // 2. 构建并净化文件名
  QString title = m_controller->videoTitle();

  // 多P视频：选集标题前10字符 + ... + 当前P标题
  if (m_controller->m_videoPartModel && m_controller->m_videoPartModel->count() > 1) {
      QString partTitle;
      for (int i = 0; i < m_controller->m_videoPartModel->count(); ++i) {
          QModelIndex idx = m_controller->m_videoPartModel->index(i, 0);
          qint64 cid = m_controller->m_videoPartModel->data(idx, VideoPartListModel::CidRole).toLongLong();
          if (cid == m_controller->m_currentVideo.cid) {
              partTitle = m_controller->m_videoPartModel->data(idx, VideoPartListModel::PartRole).toString();
              break;
          }
      }
      if (!partTitle.isEmpty()) {
          QString collectionTitle = m_controller->videoTitle().left(10);
          title = collectionTitle + "..." + partTitle;
      }
  }

  // 移除Windows和Linux文件名中的非法字符
  title.remove(QRegExp("[/\\\\:*?\"<>|]"));
  title = title.trimmed().left(100); // 限制文件名长度
  if (title.isEmpty()) {
      title = m_controller->m_currentVideo.bvid; // 如果标题为空，使用bvid作为备用
  }
  QString targetPath = dir.filePath(title + (audioOnly ? ".m4a" : ".mp4"));
  QString subtitleUrl;
  QString subtitlePath;
  if (m_controller->m_selectedSubtitleId > 0) {
      subtitleUrl = m_controller->selectedSubtitleAssUrl();
      subtitlePath = dir.filePath(QFileInfo(targetPath).completeBaseName() + ".ass");
  }

  // 3. 检查文件是否已存在
  if (QFile::exists(targetPath)) {
      if (!subtitleUrl.isEmpty() && !subtitlePath.isEmpty() && !QFile::exists(subtitlePath)) {
          m_controller->m_isDownloading = true;
          m_controller->m_downloadProgress = 0;
          m_controller->m_downloadStatus = "正在保存字幕...";
          emit m_controller->downloadStateChanged();

          QPointer<BiliController> self(m_controller);
          m_controller->m_network->downloadVideo(
              subtitleUrl, subtitlePath,
              [self, subtitlePath](const QString &) {
                if (!self) return;
                self->m_isDownloading = false;
                self->m_downloadProgress = 1.0;
                self->m_downloadStatus = "字幕保存完成";
                emit self->downloadStateChanged();
                emit self->toastMessage("字幕下载完成: " + subtitlePath);
              },
              [self](int, const QString &msg) {
                if (!self) return;
                self->m_isDownloading = false;
                self->m_downloadProgress = 0;
                self->m_downloadStatus.clear();
                emit self->downloadStateChanged();
                emit self->toastMessage("字幕下载失败: " + msg);
              });
          return;
      }
      emit m_controller->toastMessage("文件已存在");
      return;
  }

  m_controller->setIsLoading(true);

  QMap<QString, QString> params;
  params["aid"] = QString::number(m_controller->videoAid());
  params["cid"] = QString::number(m_controller->m_currentVideo.cid);
  params["qn"] = QString::number(requestQuality);
  params["bvid"] = m_controller->m_currentVideo.bvid;
  params["fnval"] = audioOnly ? "4048" : "1";

  QPointer<BiliController> self(m_controller);

  m_controller->m_network->get(
      "/video/playurl", params,
      [self, targetPath, quality, requestQuality, audioOnly, subtitleUrl, subtitlePath](const QJsonObject &data) {
        if (!self) return;

        self->updateAcceptQualities(data);

        QString downloadUrl;
        if (audioOnly) {
          downloadUrl = self->pickDashUrls(data, requestQuality).audioUrl;
        } else {
          downloadUrl = self->pickMp4Url(data);
        }

        if (downloadUrl.isEmpty()) {
          emit self->toastMessage(audioOnly ? "未获取到音频下载地址" : "未获取到下载地址");
          self->setIsLoading(false);
          return;
        }

        self->m_downloadStatus = audioOnly ? "准备下载音频..." : "准备下载...";
        emit self->downloadStateChanged();
        emit self->toastMessage(audioOnly ? "开始下载音频..." : "开始下载...");

        self->startDownloadTask(downloadUrl, QString(), targetPath, QString(),
                                audioOnly ? 0 : quality, false,
                                audioOnly ? QStringLiteral("音频下载完成: ") : QStringLiteral("下载完成: "),
                                audioOnly ? QStringLiteral("音频下载失败: ") : QStringLiteral("下载失败: "),
                                subtitleUrl, subtitlePath);
      },
      [self](int, const QString &msg) {
        if (!self) return;
        self->setIsLoading(false);
        emit self->toastMessage("获取下载地址失败: " + msg);
      });
}
