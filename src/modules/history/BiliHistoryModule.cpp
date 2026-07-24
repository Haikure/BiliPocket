#include "modules/history/BiliHistoryModule.h"

#include "BiliAsyncUtils.hpp"
#include "BiliController.h"
#include "BiliModels.h"
#include "modules/favorite/BiliFavoriteModule.h"
#include "BiliNetwork.h"

#include <QJsonArray>
#include <QMap>
#include <QPointer>
#include <QtGlobal>

namespace {

struct ParsedRecentHistory {
  qint64 max = 0;
  qint64 viewAt = 0;
  QVector<VideoItem> items;
};

struct ParsedWatchLater {
  int page = 1;
  QVector<VideoItem> items;
  bool hasMore = false;
};

struct ParsedHistorySearch {
  int page = 1;
  QVector<VideoItem> items;
  bool hasMore = false;
};

QJsonArray recentHistoryList(const QJsonObject &data) {
  QJsonArray list = data.value("list").toArray();
  if (list.isEmpty()) {
    list = data.value("items").toArray();
  }
  return list;
}

QVector<VideoItem> parseRecentHistoryItems(const QJsonObject &data) {
  QJsonArray list = recentHistoryList(data);
  QVector<VideoItem> items;
  items.reserve(list.size());

  for (const QJsonValue &value : list) {
    if (!value.isObject()) continue;
    QJsonObject obj = value.toObject();
    QJsonObject history = obj.value("history").toObject();

    VideoItem item = VideoListModel::parseVideoItem(obj);
    item.bvid = history.value("bvid").toString();
    item.aid = history.value("oid").toVariant().toLongLong();
    item.cid = history.value("cid").toVariant().toLongLong();
    item.historyBusiness = history.value("business").toString(obj.value("business").toString("archive"));
    item.historyKid = history.value("kid").toVariant().toLongLong();
    if (item.historyKid <= 0) {
      item.historyKid = item.aid;
    }
    item.title = obj.value("title").toString();
    item.pic = obj.value("cover").toString();
    item.duration = obj.value("duration").toInt();
    item.ownerName = obj.value("author_name").toString();
    if (item.ownerName.isEmpty()) {
      item.ownerName = obj.value("name").toString();
    }
    item.views = 0;
    item.danmaku = 0;

    if (!item.bvid.isEmpty()) {
      items.append(item);
    }
  }

  return items;
}

QVector<VideoItem> parseWatchLaterItems(const QJsonObject &data) {
  QJsonArray list = data.value("list").toArray();
  if (list.isEmpty()) {
    list = data.value("data").toArray();
  }

  QVector<VideoItem> items;
  items.reserve(list.size());
  for (const QJsonValue &value : list) {
    if (!value.isObject()) continue;
    QJsonObject obj = value.toObject();

    VideoItem item = VideoListModel::parseVideoItem(obj);
    item.aid = obj.value("aid").toVariant().toLongLong();
    item.pic = obj.value("pic").toString();
    if (item.pic.isEmpty()) {
      item.pic = obj.value("cover").toString();
    }
    item.duration = obj.value("duration").toInt();

    QJsonObject ownerObj = obj.value("owner").toObject();
    item.ownerName = ownerObj.value("name").toString();
    if (item.ownerName.isEmpty()) {
      item.ownerName = obj.value("author_name").toString();
    }
    if (item.ownerName.isEmpty()) {
      item.ownerName = obj.value("name").toString();
    }

    if (!item.bvid.isEmpty() || item.aid > 0) {
      items.append(item);
    }
  }

  return items;
}

ParsedRecentHistory parseRecentHistoryPayload(const QJsonObject &data) {
  ParsedRecentHistory result;
  QJsonObject cursor = data.value("cursor").toObject();
  result.max = cursor.value("max").toVariant().toLongLong();
  result.viewAt = cursor.value("view_at").toVariant().toLongLong();
  result.items = parseRecentHistoryItems(data);
  return result;
}

ParsedHistorySearch parseHistorySearchPayload(const QJsonObject &data, int page, int pageSize) {
  ParsedHistorySearch result;
  result.page = page;
  result.items = parseRecentHistoryItems(data);
  result.hasMore = result.items.size() >= pageSize;
  return result;
}

ParsedWatchLater parseWatchLaterPayload(const QJsonObject &data, int page,
                                        int pageSize) {
  ParsedWatchLater result;
  result.page = page;
  result.items = parseWatchLaterItems(data);
  result.hasMore = data.value("has_more").toBool(false);
  if (!data.contains("has_more")) {
    result.hasMore = result.items.size() >= pageSize;
  }
  return result;
}

}  // namespace

BiliHistoryModule::BiliHistoryModule(BiliController *controller)
    : QObject(controller), m_controller(controller) {}

QObject *BiliHistoryModule::recentHistoryModel() { return m_controller->recentHistoryListModel(); }
QObject *BiliHistoryModule::watchLaterModel() { return m_controller->watchLaterListModel(); }

void BiliHistoryModule::fetchRecentHistory() {
  BiliController *controller = m_controller;
  if (!controller) return;
  if (!controller->loggedIn()) {
    emit controller->toastMessage("请先登录后查看最近观看");
    return;
  }

  if (controller->recentHistoryListModel()->loading())
    return;

  m_recentHistoryMax = 0;
  m_recentHistoryViewAt = 0;
  controller->recentHistoryListModel()->clear();
  controller->recentHistoryListModel()->setLoading(true);
  controller->setIsLoading(true);

  QMap<QString, QString> params;
  QPointer<BiliController> self(controller);
  controller->network()->get(
      "/history/recent", params,
      [this, self](const QJsonObject &data) {
        if (!self) return;
        biliRunInWorker(
            self, [data]() { return parseRecentHistoryPayload(data); },
            [this, self](ParsedRecentHistory result) {
              if (!self)
                return;
              m_recentHistoryMax = result.max;
              m_recentHistoryViewAt = result.viewAt;
              self->recentHistoryListModel()->appendItems(result.items);
              self->recentHistoryListModel()->setHasMore(!result.items.isEmpty());
              self->recentHistoryListModel()->setLoading(false);
              self->setIsLoading(false);
            });
      },
      [self](int, const QString &msg) {
        if (!self) return;
        self->recentHistoryListModel()->setLoading(false);
        self->setIsLoading(false);
        emit self->toastMessage(QString("最近观看加载失败：%1").arg(msg));
      });
}

void BiliHistoryModule::fetchMoreRecentHistory() {
  BiliController *controller = m_controller;
  if (!controller) return;
  if (controller->recentHistoryListModel()->loading() || !controller->recentHistoryListModel()->hasMore())
    return;

  QMap<QString, QString> params;
  if (m_recentHistoryMax > 0) {
    params["max"] = QString::number(m_recentHistoryMax);
  }
  if (m_recentHistoryViewAt > 0) {
    params["view_at"] = QString::number(m_recentHistoryViewAt);
  }

  controller->recentHistoryListModel()->setLoading(true);
  controller->setIsLoading(true);

  QPointer<BiliController> self(controller);
  controller->network()->get(
      "/history/recent", params,
      [this, self](const QJsonObject &data) {
        if (!self) return;
        biliRunInWorker(
            self, [data]() { return parseRecentHistoryPayload(data); },
            [this, self](ParsedRecentHistory result) {
              if (!self)
                return;
              m_recentHistoryMax = result.max;
              m_recentHistoryViewAt = result.viewAt;
              self->recentHistoryListModel()->appendItems(result.items);
              self->recentHistoryListModel()->setHasMore(!result.items.isEmpty());
              self->recentHistoryListModel()->setLoading(false);
              self->setIsLoading(false);
            });
      },
      [self](int, const QString &msg) {
        if (!self) return;
        self->recentHistoryListModel()->setLoading(false);
        self->setIsLoading(false);
        emit self->toastMessage(QString("最近观看加载失败：%1").arg(msg));
      });
}

void BiliHistoryModule::searchHistory(const QString &keyword, int page) {
  BiliController *controller = m_controller;
  if (!controller) return;
  if (!controller->loggedIn()) {
    emit controller->toastMessage("请先登录后搜索历史");
    return;
  }

  QString kw = keyword.trimmed();
  if (kw.isEmpty()) {
    clearHistorySearch();
    fetchRecentHistory();
    return;
  }
  if (controller->recentHistoryListModel()->loading()) return;

  page = qBound(1, page, 1000);
  if (page == 1 || kw != m_historySearchKeyword) {
    controller->recentHistoryListModel()->clear();
    m_historySearchKeyword = kw;
    m_historySearchPage = 1;
    m_historySearchHasMore = true;
  }

  controller->recentHistoryListModel()->setLoading(true);
  controller->recentHistoryListModel()->setErrorMessage("");
  controller->setIsLoading(true);

  QMap<QString, QString> params;
  params["keyword"] = kw;
  params["pn"] = QString::number(page);

  QPointer<BiliController> self(controller);
  controller->network()->get(
      "/history/search", params,
      [this, self, page](const QJsonObject &data) {
        if (!self) return;
        biliRunInWorker(
            self, [data, page]() { return parseHistorySearchPayload(data, page, 20); },
            [this, self](ParsedHistorySearch result) {
              if (!self) return;
              m_historySearchPage = result.page;
              m_historySearchHasMore = result.hasMore;
              self->recentHistoryListModel()->appendItems(result.items);
              self->recentHistoryListModel()->setHasMore(result.hasMore);
              self->recentHistoryListModel()->setLoading(false);
              self->setIsLoading(false);
              if (result.items.isEmpty() && result.page == 1) {
                self->recentHistoryListModel()->setErrorMessage("未找到相关历史");
              }
            });
      },
      [self](int, const QString &msg) {
        if (!self) return;
        self->recentHistoryListModel()->setLoading(false);
        self->setIsLoading(false);
        self->recentHistoryListModel()->setErrorMessage(msg);
        emit self->toastMessage(QString("历史搜索失败：%1").arg(msg));
      });
}

void BiliHistoryModule::searchMoreHistory() {
  BiliController *controller = m_controller;
  if (!controller) return;
  if (m_historySearchKeyword.isEmpty() || !m_historySearchHasMore)
    return;
  if (controller->recentHistoryListModel()->loading())
    return;
  searchHistory(m_historySearchKeyword, m_historySearchPage + 1);
}

void BiliHistoryModule::clearHistorySearch() {
  m_historySearchKeyword.clear();
  m_historySearchPage = 1;
  m_historySearchHasMore = true;
}

void BiliHistoryModule::deleteRecentHistoryItem(int row, const QString &business, qint64 kid) {
  BiliController *controller = m_controller;
  if (!controller) return;
  if (!controller->loggedIn()) {
    emit controller->toastMessage("请先登录后删除历史");
    return;
  }
  QString biz = business.trimmed();
  if (biz.isEmpty()) biz = "archive";
  if (kid <= 0) {
    emit controller->toastMessage("历史记录信息不完整，无法删除");
    return;
  }

  QMap<QString, QString> params;
  params["kid"] = QString("%1_%2").arg(biz).arg(kid);
  QPointer<BiliController> self(controller);
  controller->network()->get(
      "/history/delete", params,
      [self, row](const QJsonObject &) {
        if (!self) return;
        self->recentHistoryListModel()->removeAt(row);
        emit self->toastMessage("已删除历史记录");
      },
      [self](int, const QString &msg) {
        if (!self) return;
        emit self->toastMessage(QString("删除历史失败：%1").arg(msg));
      });
}

void BiliHistoryModule::fetchWatchLater(int page, int pageSize) {
  BiliController *controller = m_controller;
  if (!controller) return;
  if (!controller->loggedIn()) {
    emit controller->toastMessage("请先登录后查看稍后再看");
    return;
  }
  if (controller->watchLaterListModel()->loading())
    return;

  page = qBound(1, page, 1000);
  pageSize = qBound(1, pageSize, 30);

  if (page == 1) {
    controller->watchLaterListModel()->clear();
  }
  controller->watchLaterListModel()->setLoading(true);
  controller->watchLaterListModel()->setErrorMessage("");
  controller->setIsLoading(true);

  QMap<QString, QString> params;
  params["pn"] = QString::number(page);
  params["ps"] = QString::number(pageSize);

  QPointer<BiliController> self(controller);
  controller->network()->get(
      "/toview/list", params,
      [this, self, page, pageSize](const QJsonObject &data) {
        if (!self) return;
        biliRunInWorker(
            self,
            [data, page, pageSize]() {
              return parseWatchLaterPayload(data, page, pageSize);
            },
            [this, self](ParsedWatchLater result) {
              if (!self)
                return;
              m_watchLaterPage = result.page;
              m_watchLaterHasMore = result.hasMore;
              self->watchLaterListModel()->appendItems(result.items);
              self->watchLaterListModel()->setHasMore(result.hasMore);
              self->watchLaterListModel()->setLoading(false);
              self->setIsLoading(false);

              if (result.items.isEmpty() && result.page == 1) {
                self->watchLaterListModel()->setErrorMessage("暂无稍后再看");
              }
            });
      },
      [self](int, const QString &msg) {
        if (!self) return;
        self->watchLaterListModel()->setLoading(false);
        self->setIsLoading(false);
        self->watchLaterListModel()->setErrorMessage(msg);
        emit self->toastMessage(QString("稍后再看加载失败：%1").arg(msg));
      });
}

void BiliHistoryModule::fetchMoreWatchLater() {
  BiliController *controller = m_controller;
  if (!controller) return;
  if (!m_watchLaterHasMore || controller->watchLaterListModel()->loading())
    return;
  if (controller->watchLaterListModel()->count() <= 0)
    return;
  fetchWatchLater(m_watchLaterPage + 1, 20);
}

void BiliHistoryModule::addToWatchLater() {
  BiliController *controller = m_controller;
  if (!controller) return;
  controller->favoriteModule()->toggleWatchLater();
}
